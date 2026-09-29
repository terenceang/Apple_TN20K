import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { AppleStream } from './stream.js'
import { encodeGamepad, encodeKey, encodeKeysUp, encodeReset, CTRL_B, CMD } from './protocol.js'
import { SerialLink, serialSupported, BAUD } from './serial-link.js'
import { isLetter, resolve } from './keymap.js'

export type ConnState =
  | 'idle'
  | 'opening'
  | 'open-unchecked'
  | 'probing'
  | 'open'
  | 'wrong-port'
  | 'error'

export type Transport = 'serial'

export interface Conn {
  state: ConnState
  /** Where we are plugged in, for the status bar. */
  detail: string | null
  transport: Transport | null
  error: string | null
}

export interface SerialState {
  kind: 'serial'
  state: ConnState
  detail: string | null
}

export interface Link {
  kind: 'serial'
  onBytes: (b: Uint8Array) => void
  onState?: (s: SerialState) => void
  write: (b: Uint8Array | number[]) => void
  describe: () => string
  open: (opts?: { verify?: boolean }) => Promise<string>
  close: (opts?: { preserveState?: boolean }) => Promise<void>
}

/** The events stream.js emits, mirroring the wire the firmware sends. */
type AppleEvent =
  | { t: 'mode'; mode: Mode }
  | { t: 'banner' }
  | { t: 'resumed' }
  | { t: 'help' }
  | { t: 'prompt' }
  | { t: 'bell' }
  | ({ t: 'regs' } & Regs)
  | ({ t: 'mem' } & MemLine)
  | ({ t: 'status' } & Status)
  | {
      t: 'screen'
      text: boolean
      page2: boolean
      mixed: boolean
      hires: boolean
      pll: boolean
      page: Uint8Array
      gfx: Uint8Array
    }

export type Mode = 'console' | 'debugger'

export interface Regs {
  pc: number
  a: number
  x: number
  y: number
  sp: number
  flags: string
  op: number
}

export interface MemLine {
  addr: number
  bytes: number[]
  text: string
}

export interface Status {
  video: 'text' | 'graphics'
  pll: boolean
}

export interface Screen {
  text: boolean
  page2: boolean
  mixed: boolean
  hires: boolean
  pll: boolean
  page: Uint8Array
  gfx: Uint8Array
  at: number
}

const MAX_LINES = 4000
const MAX_MEM = 512

/**
 * How long the machine has to be quiet before a queued command goes out.
 *
 * The debugger only reads a command when its main state is idle, and drops
 * anything sent sooner without a word. The banner alone prints two prompts --
 * one at the end of the banner string, one after the register dump -- so
 * neither prompt on its own means "idle". Silence does: a register line is
 * about 45 bytes, which is 4 ms at 115200, so 200 ms of nothing is a very safe
 * "it has finished".
 */
const QUIET_MS = 200

/** How long to wait for a $SEND before giving up on a screen capture. The dump
 *  is 1 KB of hex, about 2.3 KB on the wire, so 220 ms is very nearly 0.25 s of
 *  transmission; this leaves generous headroom and still cannot hang the UI. */
const CAPTURE_TIMEOUT_MS = 4000

const IDLE: Conn = { state: 'idle', detail: null, transport: null, error: null }

export function useApple() {
  const link = useRef<Link | null>(null)
  const stream = useRef(new AppleStream())
  const quiet = useRef<ReturnType<typeof setTimeout> | null>(null)
  const queue = useRef<number[]>([])
  const wantResumeAfterScreen = useRef(false)
  const captureTimeout = useRef<ReturnType<typeof setTimeout> | null>(null)

  const [conn, setConn] = useState<Conn>(IDLE)
  const [mode, setMode] = useState<Mode>('console')
  const [lines, setLines] = useState<string[]>([])
  const [regs, setRegs] = useState<Regs | null>(null)
  const [mem, setMem] = useState<MemLine[]>([])
  const [status, setStatus] = useState<Status | null>(null)
  const [screen, setScreen] = useState<Screen | null>(null)
  const [busy, setBusy] = useState(false)
  const [canSerial, setCanSerial] = useState(false)

  useEffect(() => setCanSerial(serialSupported()), [])

  /**
   * Hand a command to the debugger and let the quiet timer release it, so it
   * cannot be dropped by arriving while the machine is still busy.
   */
  const flushQuiet = useCallback(() => {
    if (quiet.current) clearTimeout(quiet.current)
    quiet.current = setTimeout(() => {
      quiet.current = null
      if (queue.current.length) {
        link.current?.write(queue.current)
        queue.current = []
      }
    }, QUIET_MS)
  }, [])

  const release = useCallback(
    (...bytes: number[]) => {
      queue.current.push(...bytes)
      flushQuiet()
    },
    [flushQuiet],
  )

  // --- one place that turns bytes into everything the UI shows -----------
  const onBytes = useCallback(
    (bytes: Uint8Array) => {
      // Any byte at all means the machine is busy, so restart the quiet timer.
      flushQuiet()

      // stream.js is plain JS so node --test can drive it; the event shapes are
      // a discriminated union on `t`, cast once here rather than throughout.
      const { text, events } = stream.current.push(bytes) as {
        text: string[]
        events: AppleEvent[]
      }
      if (text.length) setLines((l) => [...l, ...text].slice(-MAX_LINES))
      for (const e of events) {
        switch (e.t) {
          case 'mode':
            setMode(e.mode)
            break
          case 'regs':
            setRegs(e)
            break
          case 'mem':
            setMem((m2) => [...m2, e].slice(-MAX_MEM))
            break
          case 'status':
            setStatus({ video: e.video, pll: e.pll })
            break
          case 'screen':
            setScreen({
              text: e.text,
              page2: e.page2,
              mixed: e.mixed,
              hires: e.hires,
              pll: e.pll,
              page: e.page,
              gfx: e.gfx,
              at: Date.now(),
            })
            setBusy(false)
            if (captureTimeout.current) {
              clearTimeout(captureTimeout.current)
              captureTimeout.current = null
            }
            if (wantResumeAfterScreen.current) {
              wantResumeAfterScreen.current = false
              release(CMD.cont.charCodeAt(0)) // resume once the dump is home
            }
            break
          case 'bell':
            // Counted only for the tests; the UI does not surface it.
            break
          default:
            break
        }
      }
    },
    [release, flushQuiet],
  )

  useEffect(() => {
    return () => {
      if (quiet.current) clearTimeout(quiet.current)
      if (captureTimeout.current) clearTimeout(captureTimeout.current)
      void link.current?.close()
      link.current = null
    }
  }, [])

  const attach = useCallback(
    (l: Link) => {
      void link.current?.close()
      link.current = l
      l.onBytes = onBytes
      l.onState = (s: SerialState) =>
        setConn({
          state: s.state,
          detail: s.detail,
          transport: 'serial',
          error: s.state === 'error' ? s.detail : null,
        })
    },
    [onBytes],
  )

  /**
   * Plug the board straight into this browser. Must come from a click, because
   * Web Serial's device picker only opens from a user gesture.
   */
  const connectSerial = useCallback(
    async (opts?: { verify?: boolean }) => {
      const l = new SerialLink() as unknown as Link
      attach(l)
      setConn({ state: 'opening', detail: null, transport: 'serial', error: null })
      await l.open(opts)
    },
    [attach],
  )

  const connectWithoutVerify = useCallback(async () => {
    await connectSerial({ verify: false })
  }, [connectSerial])

  const disconnect = useCallback(async () => {
    await link.current?.close()
    link.current = null
    setConn(IDLE)
  }, [])

  const send = useCallback((bytes: number[] | Uint8Array) => link.current?.write(bytes), [])

  /** A keypress. In console mode it goes straight out; in debugger mode the
   *  machine is paused and drops ordinary keystrokes, so letters are commands. */
  const pressKey = useCallback(
    (id: string, mods: { shift?: boolean; caps?: boolean; ctrl?: boolean }, buttons: number) => {
      if (mode === 'debugger') {
        if (isLetter(id)) release(id.toLowerCase().charCodeAt(0))
        return
      }
      const code = resolve(id, mods)
      if (code === null) return
      send(encodeKey(code, buttons))
    },
    [mode, send, release],
  )

  /** The RESET key. The //e's RESET line is CONTROL-gated, so only a press made
   *  with CONTROL down asserts it; a release is always sent. */
  const resetKey = useCallback(
    (down: boolean, buttons: number) => {
      if (mode === 'debugger') return
      send(encodeReset(down, buttons))
    },
    [mode, send],
  )

  /** All character keys are up: drops the //e's any-key-down line ($C010 bit 7). */
  const releaseKeys = useCallback(() => {
    if (mode === 'debugger') return
    send(encodeKeysUp())
  }, [mode, send])

  const toggleDebugger = useCallback(() => send([CTRL_B]), [send])

  /** Freeze, dump the screen, and let it run again. */
  const captureScreen = useCallback(() => {
    setBusy(true)
    wantResumeAfterScreen.current = true
    if (mode !== 'debugger') send([CTRL_B])
    // 'w' once the banner and register dump have gone by
    release(CMD.screen.charCodeAt(0))
    // If no frame comes back -- the machine was not in a state to answer, or the
    // port went away -- do not leave the button stuck on "Capturing...".
    if (captureTimeout.current) clearTimeout(captureTimeout.current)
    captureTimeout.current = setTimeout(() => {
      captureTimeout.current = null
      wantResumeAfterScreen.current = false
      setBusy(false)
    }, CAPTURE_TIMEOUT_MS)
  }, [mode, send, release])

  const setPaddles = useCallback(
    (buttons: number, x: number, y: number) => send(encodeGamepad(buttons, x, y)),
    [send],
  )

  const reconnect = useCallback(() => {
    void connectSerial()
  }, [connectSerial])

  const clearConsole = useCallback(() => setLines([]), [])
  const clearMem = useCallback(() => setMem([]), [])

  return useMemo(
    () => ({
      conn,
      canSerial,
      baud: BAUD,
      connectSerial,
      connectWithoutVerify,
      disconnect,
      mode,
      lines,
      regs,
      mem,
      status,
      screen,
      busy,
      pressKey,
      resetKey,
      releaseKeys,
      toggleDebugger,
      captureScreen,
      setPaddles,
      send,
      reconnect,
      clearConsole,
      clearMem,
    }),
    [
      conn,
      canSerial,
      connectSerial,
      connectWithoutVerify,
      disconnect,
      mode,
      lines,
      regs,
      mem,
      status,
      screen,
      busy,
      pressKey,
      resetKey,
      releaseKeys,
      toggleDebugger,
      captureScreen,
      setPaddles,
      send,
      reconnect,
      clearConsole,
      clearMem,
    ],
  )
}

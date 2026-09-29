import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { AppleStream } from './stream.js'
import { encodeGamepad, encodeKey } from './protocol.js'
import { defaultEndpoint, forget, remember, resolveEndpoint } from './endpoint.js'
import { SerialLink, serialSupported, BAUD } from './serial-link.js'
import { WsLink } from './ws-link.js'
import { isLetter, resolve } from './keymap.js'

/** localStorage, or something harmless if there is none. */
function storage(): Storage | null {
  try {
    return typeof localStorage === 'undefined' ? null : localStorage
  } catch {
    return null // blocked, e.g. private mode
  }
}

/** Always a URL: if nothing was saved or asked for, the page's own address. */
function endpointFor(here: Location | null): string {
  return resolveEndpoint(here, storage()) ?? defaultEndpoint(here)
}

export type ConnState =
  | 'idle'
  | 'opening'
  | 'probing'
  | 'connecting'
  | 'open'
  | 'wrong-port'
  | 'error'

export type Transport = 'serial' | 'bridge'

export interface Conn {
  state: ConnState
  /** Where we are plugged in, for the status bar. */
  detail: string | null
  transport: Transport | null
  error: string | null
}

export interface Job {
  state: 'running' | 'done' | 'failed'
  target: string
  lines: string[]
  started: number
  finished?: number
  error?: string | null
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

/** Anything both transports provide. */
interface Link {
  kind: Transport
  onBytes: (b: Uint8Array) => void
  onState?: (s: { kind: Transport; state: ConnState; detail: string | null }) => void
  onJob?: (j: Job) => void
  write: (b: Uint8Array | number[]) => void
  describe: () => string
  open: () => Promise<string>
  close: () => Promise<void>
  control?: (m: object) => void
}

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
  const [job, setJob] = useState<Job | null>(null)
  const [bells, setBells] = useState(0)
  const [busy, setBusy] = useState(false)
  const [canSerial, setCanSerial] = useState(false)

  // Where the bridge is, for the fallback transport. It is state, not a
  // constant, so a bundle served from somewhere else -- a GitHub Pages site,
  // say -- can be pointed at the bridge on the machine the board is plugged
  // into. See endpoint.js.
  const [endpoint, setEndpointState] = useState<string>(() =>
    endpointFor(typeof location === 'undefined' ? null : location),
  )

  useEffect(() => setCanSerial(serialSupported()), [])

  /**
   * Hand a command to the debugger and let the quiet timer release it, so it
   * cannot be dropped by arriving while the machine is still busy.
   */
  const release = useCallback((...bytes: number[]) => {
    queue.current.push(...bytes)
    if (quiet.current) clearTimeout(quiet.current)
    quiet.current = setTimeout(() => {
      quiet.current = null
      if (queue.current.length) {
        link.current?.write(queue.current)
        queue.current = []
      }
    }, QUIET_MS)
  }, [])

  // --- one place that turns bytes into everything the UI shows -----------
  const onBytes = useCallback(
    (bytes: Uint8Array) => {
      // Any byte at all means the machine is busy, so restart the quiet timer.
      if (quiet.current) clearTimeout(quiet.current)
      quiet.current = setTimeout(() => {
        quiet.current = null
        if (queue.current.length) {
          link.current?.write(queue.current)
          queue.current = []
        }
      }, QUIET_MS)

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
              release(0x63) // 'c' -- resume
            }
            break
          case 'bell':
            setBells((n) => n + 1)
            break
          default:
            break
        }
      }
    },
    [release],
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
      l.onState = (s) =>
        setConn({
          state: s.state,
          detail: s.detail,
          transport: s.kind,
          error: s.state === 'error' ? s.detail : null,
        })
      l.onJob = setJob
    },
    [onBytes],
  )

  /**
   * Plug the board straight into this browser. Must come from a click, because
   * Web Serial's device picker only opens from a user gesture.
   */
  const connectSerial = useCallback(async () => {
    const l = new SerialLink()
    attach(l)
    setConn({ state: 'opening', detail: null, transport: 'serial', error: null })
    await l.open()
  }, [attach])

  /** The bridge, for a board on another machine, or a browser without Web Serial. */
  const connectBridge = useCallback(
    async (url?: string) => {
      const target = url ?? endpoint
      if (url) {
        const n = remember(storage(), url)
        if (n) setEndpointState(n)
      }
      const l = new WsLink(target)
      attach(l)
      setConn({ state: 'opening', detail: null, transport: 'bridge', error: null })
      await l.open()
    },
    [attach, endpoint],
  )

  const disconnect = useCallback(async () => {
    await link.current?.close()
    link.current = null
    setConn(IDLE)
  }, [])

  const setEndpoint = useCallback(
    (value: string) => {
      const next = remember(storage(), value)
      if (next) setEndpointState(next)
    },
    [],
  )

  const resetEndpoint = useCallback(() => {
    forget(storage())
    setEndpointState(endpointFor(typeof location === 'undefined' ? null : location))
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

  const toggleDebugger = useCallback(() => send([0x02]), [send])

  /** Freeze, dump the screen, and let it run again. */
  const captureScreen = useCallback(() => {
    setBusy(true)
    wantResumeAfterScreen.current = true
    if (mode !== 'debugger') send([0x02])
    // 'w' once the banner and register dump have gone by
    release(0x77)
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

  // Programming needs a subprocess, so it is the one thing only the bridge can do.
  const flash = useCallback((toFlash: boolean) => {
    link.current?.control?.({ t: 'flash', flash: toFlash })
  }, [])

  /** Retry whichever transport was in use, rather than always the bridge. */
  const reconnect = useCallback(() => {
    if (link.current?.kind === 'serial') void connectSerial()
    else void connectBridge()
  }, [connectSerial, connectBridge])

  const clearConsole = useCallback(() => setLines([]), [])
  const clearMem = useCallback(() => setMem([]), [])

  return useMemo(
    () => ({
      conn,
      canSerial,
      baud: BAUD,
      endpoint,
      setEndpoint,
      resetEndpoint,
      connectSerial,
      connectBridge,
      disconnect,
      mode,
      lines,
      regs,
      mem,
      status,
      screen,
      job,
      bells,
      busy,
      pressKey,
      toggleDebugger,
      captureScreen,
      setPaddles,
      send,
      flash,
      reconnect,
      clearConsole,
      clearMem,
    }),
    [
      conn,
      canSerial,
      endpoint,
      setEndpoint,
      resetEndpoint,
      connectSerial,
      connectBridge,
      disconnect,
      mode,
      lines,
      regs,
      mem,
      status,
      screen,
      job,
      bells,
      busy,
      pressKey,
      toggleDebugger,
      captureScreen,
      setPaddles,
      send,
      flash,
      reconnect,
      clearConsole,
      clearMem,
    ],
  )
}

import { useCallback, useEffect, useState } from 'react'
import { useApple } from './useApple'
import { Keyboard } from './components/Keyboard'
import { Console } from './components/Console'
import { Screen } from './components/Screen'
import { DebuggerPane } from './components/DebuggerPane'
import { Gamepad } from './components/Gamepad'
import { FlashBar } from './components/FlashBar'

export default function App() {
  const apple = useApple()
  const [held, setHeld] = useState({ shift: false, ctrl: false, caps: false, appleO: false, appleC: false })
  const [buttons, setButtons] = useState(0)
  const [paddles, setPaddles] = useState({ x: 128, y: 128 })

  // Ctrl+B is the debugger toggle, and the firmware throws 0x02 away before the
  // keyboard ever sees it, so it is handled here rather than in the keymap.
  useEffect(() => {
    const h = (e: KeyboardEvent) => {
      if (e.ctrlKey && !e.shiftKey && !e.altKey && e.code === 'KeyB') {
        e.preventDefault()
        apple.toggleDebugger()
      }
      setHeld((s) => ({
        ...s,
        shift: e.shiftKey,
        ctrl: e.ctrlKey,
        caps: s.caps,
        appleO: e.altKey && e.code === 'AltLeft',
        appleC: e.altKey && e.code === 'AltRight',
      }))
      if (e.code === 'CapsLock') setHeld((s) => ({ ...s, caps: !s.caps }))
    }
    const up = (e: KeyboardEvent) => {
      if (e.code === 'ShiftLeft' || e.code === 'ShiftRight') setHeld((s) => ({ ...s, shift: false }))
      if (e.code === 'ControlLeft' || e.code === 'ControlRight')
        setHeld((s) => ({ ...s, ctrl: false }))
      if (e.code === 'AltLeft') setHeld((s) => ({ ...s, appleO: false }))
      if (e.code === 'AltRight') setHeld((s) => ({ ...s, appleC: false }))
    }
    window.addEventListener('keydown', h)
    window.addEventListener('keyup', up)
    return () => {
      window.removeEventListener('keydown', h)
      window.removeEventListener('keyup', up)
    }
  }, [apple])

  const press = useCallback(
    (id: string, mods: { shift: boolean; caps: boolean; ctrl: boolean }, btns: number) => {
      apple.pressKey(id, mods, btns)
    },
    [apple],
  )

  const onGamepad = useCallback(
    (b: number, x: number, y: number) => {
      setButtons(b)
      setPaddles({ x, y })
      apple.setPaddles(b, x, y)
    },
    [apple],
  )

  const onCommand = useCallback(
    (ch: string) => apple.send([ch.charCodeAt(0)]),
    [apple],
  )

  return (
    <div className="app">
      <FlashBar
        conn={apple.conn}
        canSerial={apple.canSerial}
        baud={apple.baud}
        job={apple.job}
        endpoint={apple.endpoint}
        onSerial={apple.connectSerial}
        onBridge={apple.connectBridge}
        onDisconnect={apple.disconnect}
        onResetEndpoint={apple.resetEndpoint}
        onFlash={apple.flash}
        onReconnect={apple.reconnect}
      />

      <main>
        <div className="col-left">
          <Console lines={apple.lines} onClear={apple.clearConsole} />
          <Screen screen={apple.screen} onCapture={apple.captureScreen} busy={apple.busy} />
        </div>

        <div className="col-right">
          <DebuggerPane
            mode={apple.mode}
            regs={apple.regs}
            mem={apple.mem}
            status={apple.status}
            onCommand={onCommand}
            onClearMem={apple.clearMem}
            onToggle={apple.toggleDebugger}
          />
          <Gamepad buttons={buttons} x={paddles.x} y={paddles.y} onChange={onGamepad} />
          <Keyboard mode={apple.mode} onPress={press} held={held} />
        </div>
      </main>
    </div>
  )
}

import { useCallback, useEffect, useState } from 'react'
import { useApple } from './useApple'
import { Keyboard } from './components/Keyboard'
import { Console } from './components/Console'
import { Screen } from './components/Screen'
import { DebuggerPane } from './components/DebuggerPane'
import { Gamepad } from './components/Gamepad'
import { FlashBar } from './components/FlashBar'

import {
  PREF_CONSOLE,
  PREF_DEBUGGER,
  PREF_SCREEN,
  PREF_PADDLES,
  getSavedBool,
  setSavedBool,
} from './prefs.js'

export default function App() {
  const apple = useApple()
  const [held, setHeld] = useState({ shift: false, ctrl: false, caps: false, appleO: false, appleC: false })
  const [buttons, setButtons] = useState(0)
  const [paddles, setPaddles] = useState({ x: 128, y: 128 })

  const store = typeof localStorage !== 'undefined' ? localStorage : null

  // View Visibility Toggles (Screen and Paddles are visible by default; Console and Debugger hidden)
  const [showScreen, setShowScreenState] = useState(() => getSavedBool(store, PREF_SCREEN, true))
  const [showConsole, setShowConsoleState] = useState(() => getSavedBool(store, PREF_CONSOLE, false))
  const [showDebugger, setShowDebuggerState] = useState(() => getSavedBool(store, PREF_DEBUGGER, false))
  const [showPaddles, setShowPaddlesState] = useState(() => getSavedBool(store, PREF_PADDLES, true))

  const setShowScreen = useCallback((show: boolean | ((prev: boolean) => boolean)) => {
    setShowScreenState((prev) => {
      const next = typeof show === 'function' ? show(prev) : show
      setSavedBool(store, PREF_SCREEN, next)
      return next
    })
  }, [store])

  const setShowConsole = useCallback((show: boolean | ((prev: boolean) => boolean)) => {
    setShowConsoleState((prev) => {
      const next = typeof show === 'function' ? show(prev) : show
      setSavedBool(store, PREF_CONSOLE, next)
      return next
    })
  }, [store])

  const setShowDebugger = useCallback((show: boolean | ((prev: boolean) => boolean)) => {
    setShowDebuggerState((prev) => {
      const next = typeof show === 'function' ? show(prev) : show
      setSavedBool(store, PREF_DEBUGGER, next)
      return next
    })
  }, [store])

  const setShowPaddles = useCallback((show: boolean | ((prev: boolean) => boolean)) => {
    setShowPaddlesState((prev) => {
      const next = typeof show === 'function' ? show(prev) : show
      setSavedBool(store, PREF_PADDLES, next)
      return next
    })
  }, [store])

  // Ctrl+B is the debugger toggle. Automatically reveal the debugger pane when engaged.
  useEffect(() => {
    const h = (e: KeyboardEvent) => {
      if (e.ctrlKey && !e.shiftKey && !e.altKey && e.code === 'KeyB') {
        e.preventDefault()
        apple.toggleDebugger()
        setShowDebugger(true)
      }
      setHeld((s) => ({
        ...s,
        shift: e.shiftKey,
        ctrl: e.ctrlKey,
        caps: s.caps,
        appleO: e.code === 'AltLeft' ? true : (s.appleO && e.altKey),
        appleC: e.code === 'AltRight' ? true : (s.appleC && e.altKey),
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
  }, [apple, setShowDebugger])

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

  const hasLeftCol = showConsole || showScreen

  return (
    <div className="app">
      <FlashBar
        conn={apple.conn}
        canSerial={apple.canSerial}
        baud={apple.baud}
        showScreen={showScreen}
        showConsole={showConsole}
        showDebugger={showDebugger}
        showPaddles={showPaddles}
        onToggleScreen={() => setShowScreen((s) => !s)}
        onToggleConsole={() => setShowConsole((s) => !s)}
        onToggleDebugger={() => setShowDebugger((s) => !s)}
        onTogglePaddles={() => setShowPaddles((s) => !s)}
        onSerial={apple.connectSerial}
        onSerialNoVerify={apple.connectWithoutVerify}
        onDisconnect={apple.disconnect}
        onReconnect={apple.reconnect}
      />

      <main className={!hasLeftCol ? 'no-left-col' : ''}>
        {hasLeftCol && (
          <div className="col-left">
            {showConsole && (
              <Console
                lines={apple.lines}
                onClear={apple.clearConsole}
                onClose={() => setShowConsole(false)}
              />
            )}
            {showScreen && (
              <Screen
                screen={apple.screen}
                onCapture={apple.captureScreen}
                busy={apple.busy}
                onClose={() => setShowScreen(false)}
              />
            )}
          </div>
        )}

        <div className="col-right">
          {showDebugger && (
            <DebuggerPane
              mode={apple.mode}
              regs={apple.regs}
              mem={apple.mem}
              status={apple.status}
              onCommand={onCommand}
              onClearMem={apple.clearMem}
              onToggle={apple.toggleDebugger}
              onClose={() => setShowDebugger(false)}
            />
          )}
          {showPaddles && (
            <Gamepad
              buttons={buttons}
              x={paddles.x}
              y={paddles.y}
              onChange={onGamepad}
              onClose={() => setShowPaddles(false)}
            />
          )}
          <Keyboard
            mode={apple.mode}
            onPress={press}
            onReset={apple.resetKey}
            onRelease={apple.releaseKeys}
            held={held}
            conn={apple.conn}
            canSerial={apple.canSerial}
            onConnect={apple.connectSerial}
          />
        </div>
      </main>
    </div>
  )
}

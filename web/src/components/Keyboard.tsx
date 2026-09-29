import { useEffect, useRef, useState } from 'react'
import { KEYS, BOARD_W, BOARD_H, CAPTION } from '../keyboard/layouts.js'
import { hostKey, isModifier, REPEAT_DELAY_MS, REPEAT_INTERVAL_MS } from '../keymap.js'
import type { Mode } from '../useApple'

interface Props {
  mode: Mode
  onPress: (
    id: string,
    mods: { shift: boolean; caps: boolean; ctrl: boolean },
    buttons: number,
  ) => void
  /** Latching switches, so the caps can show as down. */
  held: { shift: boolean; ctrl: boolean; caps: boolean; appleO: boolean; appleC: boolean }
}

const UNIT = 34 // px per keycap unit
type Cap = (typeof KEYS)[number]

/**
 * The Apple //e keyboard, US layout, 1983-86 beige case with the large white
 * keycap print. 63 keys, arranged in layouts.js; this only draws it.
 *
 * Both ways of using it work at once: click a cap, or type on the real
 * keyboard, which is mapped by physical position so a Dvorak or AZERTY layout
 * still gets the //e's QWERTY one.
 */
export function Keyboard({ mode, onPress, held }: Props) {
  const [down, setDown] = useState<Set<string>>(new Set())
  const delay = useRef<number | null>(null)
  const ticker = useRef<number | null>(null)
  const repeatId = useRef<string | null>(null)
  // The real keyboard's modifier state, which the repeat timer has to read
  // too, so a held Shift keeps shifting the repeats.
  const mods = useRef({ shift: false, ctrl: false })

  useEffect(() => {
    const typingInto = (t: EventTarget | null) =>
      t instanceof HTMLElement && /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName)

    const stopRepeat = () => {
      if (delay.current !== null) clearTimeout(delay.current)
      if (ticker.current !== null) clearInterval(ticker.current)
      delay.current = null
      ticker.current = null
      repeatId.current = null
    }

    const press = (id: string) => {
      const buttons = (heldRef.current.appleO ? 0b001 : 0) | (heldRef.current.appleC ? 0b010 : 0)
      onPress(id, { ...mods.current, caps: heldRef.current.caps }, buttons)
    }

    const startRepeat = () => {
      ticker.current = window.setInterval(() => {
        if (repeatId.current) press(repeatId.current)
      }, REPEAT_INTERVAL_MS)
    }

    const onDown = (e: KeyboardEvent) => {
      if (typingInto(e.target)) return
      const id = hostKey(e.code)
      if (!id) return
      // Ctrl+B is the debugger toggle and never reaches the //e -- the
      // firmware drops 0x02 before the keyboard sees it -- so App handles it.
      if (e.ctrlKey && !e.shiftKey && !e.altKey && e.code === 'KeyB') return
      e.preventDefault()
      if (e.repeat) return // our own timer drives repeats, at the //e's rate
      mods.current = { shift: e.shiftKey, ctrl: e.ctrlKey }
      setDown((d) => new Set(d).add(id))
      if (!isModifier(id) && e.code !== 'CapsLock') press(id)

      // Hold-to-repeat. The //e dropped REPT, so the hardware repeats instead,
      // after about a second and then at roughly 10 Hz.
      stopRepeat()
      if (!isModifier(id) && e.code !== 'CapsLock') {
        repeatId.current = id
        delay.current = window.setTimeout(startRepeat, REPEAT_DELAY_MS)
      }
    }

    const onUp = (e: KeyboardEvent) => {
      const id = hostKey(e.code)
      if (id) {
        setDown((d) => {
          if (!d.has(id)) return d
          const n = new Set(d)
          n.delete(id)
          return n
        })
      }
      mods.current = { shift: e.shiftKey, ctrl: e.ctrlKey }
      if (id && id === repeatId.current) stopRepeat()
      if (!e.shiftKey) mods.current.shift = false
      if (!e.ctrlKey) mods.current.ctrl = false
    }

    const onBlur = () => {
      stopRepeat()
      setDown(new Set())
    }

    window.addEventListener('keydown', onDown)
    window.addEventListener('keyup', onUp)
    window.addEventListener('blur', onBlur)
    return () => {
      stopRepeat()
      window.removeEventListener('keydown', onDown)
      window.removeEventListener('keyup', onUp)
      window.removeEventListener('blur', onBlur)
    }
    // `held` is read through a ref so the listeners are registered once.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [onPress])

  const heldRef = useRef(held)
  heldRef.current = held

  // --- clicking a cap -----------------------------------------------------
  const capDown = (k: Cap, capEvent: 'down' | 'up' | 'enter') => {
    if (isModifier(k.id)) return
    const buttons = (held.appleO ? 0b001 : 0) | (held.appleC ? 0b010 : 0)
    if (capEvent === 'enter') {
      onPress(k.id, { shift: held.shift, caps: held.caps, ctrl: held.ctrl }, buttons)
      return
    }
    setDown((d) => {
      const n = new Set(d)
      if (capEvent === 'down') n.add(k.id)
      else n.delete(k.id)
      return n
    })
  }

  const legend = (k: Cap) => k.legend ?? ''
  const caption = (k: Cap) => CAPTION[k.id as keyof typeof CAPTION]

  return (
    <div className="keyboard-case">
      <div className="keyboard-bezel">
        <div
          className="board"
          style={{ width: BOARD_W * UNIT, height: (BOARD_H - 1) * UNIT }}
          role="group"
          aria-label="Apple //e keyboard"
        >
          {KEYS.map((k) => {
            const isDown =
              down.has(k.id) ||
              (k.id.startsWith('shift') && held.shift) ||
              (k.id === 'control' && held.ctrl) ||
              (k.id === 'caps' && held.caps) ||
              (k.id === 'apple-o' && held.appleO) ||
              (k.id === 'apple-c' && held.appleC)
            return (
              <button
                key={k.id}
                type="button"
                className={
                  'cap' + (isDown ? ' down' : '') + (k.mod ? ' mod' : '') + (k.latch ? ' latch' : '')
                }
                style={{
                  left: (k.x + 0.5) * UNIT, // 0.5u inset: the bezel edge
                  top: (k.y + 1) * UNIT,
                  width: k.w ? k.w * UNIT - 3 : UNIT - 3,
                  height: k.h ? k.h * UNIT - 3 : UNIT - 3,
                }}
                onPointerDown={() => capDown(k, 'down')}
                onPointerUp={() => capDown(k, 'up')}
                onPointerLeave={() => capDown(k, 'up')}
                onDoubleClick={() => capDown(k, 'enter')}
                aria-label={k.id}
                aria-pressed={isDown}
              >
                {k.sub && <span className="cap-top">{legend(k)}</span>}
                {k.sub ? (
                  <span className="cap-bottom">{k.sub}</span>
                ) : caption(k) ? (
                  <span className="cap-word">{caption(k)}</span>
                ) : (
                  <span className={legend(k).length > 2 ? 'cap-word' : 'cap-main'}>
                    {legend(k)}
                  </span>
                )}
              </button>
            )
          })}
        </div>
      </div>
      <p className="keyboard-note">
        {mode === 'debugger' ? (
          <>Debugger paused. Letters are commands; <kbd>Ctrl</kbd>+<kbd>B</kbd> resumes.</>
        ) : (
          <>
            Click a cap, or just type. <kbd>Alt</kbd> is the apple key,{' '}
            <kbd>Shift</kbd> and <kbd>Ctrl</kbd> are the //e's own, and holding a key repeats
            after a second the way the hardware does.
          </>
        )}
      </p>
    </div>
  )
}

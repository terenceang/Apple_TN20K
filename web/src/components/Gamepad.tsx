import { PADDLE_BUTTONS } from '../keymap.js'
import { AppleGlyph } from './AppleGlyph.js'

interface Props {
  buttons: number
  x: number
  y: number
  onChange: (buttons: number, x: number, y: number) => void
}

/**
 * The two game buttons and the two paddles.
 *
 * There are two, not three: the //e's keyboard has an Open-Apple and a
 * Solid-Apple key and they are wired to hand-control buttons 0 and 1, which is
 * the whole of the game input on the machine. The RTL does decode a third
 * pushbutton at $C063, but no //e key can close it, so there is nothing to put
 * here.
 *
 * Positions are only sent when something moves, because the firmware latches
 * them rather than counting.
 */
export function Gamepad({ buttons, x, y, onChange }: Props) {
  const set = (b: number, px = x, py = y) => onChange(b, px, py)

  return (
    <section className="pane gamepad-pane">
      <header>
        <h2>Paddles</h2>
        <span className="hint">$C061, $C062, $C064, $C065</span>
      </header>

      <div className="gamepad-buttons">
        {PADDLE_BUTTONS.map((b) => (
          <button
            key={b.key}
            className={'paddle-btn' + (buttons & b.bit ? ' on' : '')}
            onPointerDown={() => set(buttons | b.bit)}
            onPointerUp={() => set(buttons & ~b.bit)}
            onPointerLeave={() => set(buttons & ~b.bit)}
            title={`Hand-control button ${b.which}`}
          >
            <AppleGlyph solid={b.key === 'apple-c'} /> {b.label}
          </button>
        ))}
      </div>

      <label className="paddle">
        <span>Paddle 0</span>
        <input
          type="range"
          min={0}
          max={255}
          value={x}
          onChange={(e) => set(buttons, Number(e.target.value), y)}
        />
        <output>{x}</output>
      </label>
      <label className="paddle">
        <span>Paddle 1</span>
        <input
          type="range"
          min={0}
          max={255}
          value={y}
          onChange={(e) => set(buttons, x, Number(e.target.value))}
        />
        <output>{y}</output>
      </label>

      <p className="dim small">
        The firmware starts a 60&#8239;&micro;s countdown when the ROM reads $C070, and $C064 or
        $C065 reads back 1 until it runs out. Centre is 128, as the hardware sits.
      </p>
    </section>
  )
}

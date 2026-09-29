import { useEffect, useMemo, useRef, useState } from 'react'
import { AppleStream, screenToText } from '../stream.js'
import { dotRow, HAS_GLYPHS, GLYPH_W, GLYPH_H } from '../charset.js'
import { LORES_PALETTE, PHOSPHOR_ON, PHOSPHOR_OFF, SCR_COLS, SCR_GFX_ROWS } from '../protocol.js'
import type { Screen as ScreenFrame } from '../useApple'

const SCALE = 2 // the Apple II raster is 560x384; double it
const FLASH_MS = 620 // video_generator.v's flash_clk is about 1.6 Hz
const COLS = 40
const ROWS = 24
const LORES_BLOCK_W = 14 // a lo-res block is one 14-pixel character cell wide

const rgb = (c: number[]) => `rgb(${c[0]},${c[1]},${c[2]})`

interface Props {
  screen: ScreenFrame | null
  onCapture: () => void
  busy: boolean
}

/**
 * The //e text page, redrawn in the browser from the W screen dump.
 *
 * The dump is only readable while the CPU is paused, so this is on demand:
 * Freeze & capture pauses, dumps, and lets the machine run again. The glyphs
 * come from the same 2732 ROM the FPGA reads, addressed with the same
 * expression video_generator.v uses, so this is the same picture the monitor
 * over HDMI is showing.
 */
export function Screen({ screen, onCapture, busy }: Props) {
  const canvas = useRef<HTMLCanvasElement>(null)
  const [flash, setFlash] = useState(false)

  useEffect(() => {
    const t = setInterval(() => setFlash((f) => !f), FLASH_MS)
    return () => clearInterval(t)
  }, [])

  const cells = useMemo(
    () => (screen ? AppleStream.cells(screen.page) : null),
    [screen],
  )
  const text = useMemo(() => (screen ? screenToText(screen.page) : []), [screen])

  useEffect(() => {
    const cv = canvas.current
    const ctx = cv?.getContext('2d')
    if (!cv || !ctx || !screen || !cells) return

    cv.width = COLS * GLYPH_W * SCALE
    cv.height = ROWS * GLYPH_H * SCALE
    ctx.imageSmoothingEnabled = false
    ctx.fillStyle = 'rgb(0,0,0)'
    ctx.fillRect(0, 0, cv.width, cv.height)

    // The bottom four lines are lo-res graphics in mixed mode, which is where
    // the //e ROM normally leaves them. video_generator.v decides it the same
    // way: is_text_line = text_mode || (mixed_mode && text_row >= 20).
    const isTextLine = (row: number) => screen.text || (screen.mixed && row >= ROWS - 4)

    for (let row = 0; row < ROWS; row++) {
      if (!isTextLine(row)) {
        drawLores(ctx, row, screen)
        continue
      }
      for (let col = 0; col < COLS; col++) {
        const cell = cells[row][col]
        // Inverse video swaps the lit and unlit colours, and the //e draws
        // flashing characters by toggling that bit, so it drives both.
        const inverse = cell.inverse !== flash
        const on = rgb(inverse ? PHOSPHOR_OFF : PHOSPHOR_ON)
        const off = rgb(inverse ? PHOSPHOR_ON : PHOSPHOR_OFF)
        for (let r = 0; r < GLYPH_H; r++) {
          const bits = dotRow(cell.code, r, flash ? 1 : 0)
          const y = (row * GLYPH_H + r) * SCALE
          for (let d = 0; d < GLYPH_W; d++) {
            const lit = (bits >> d) & 1
            ctx.fillStyle = lit ? on : off
            ctx.fillRect((col * GLYPH_W + d) * SCALE, y, SCALE, SCALE)
          }
        }
      }
    }
  }, [screen, cells, flash])

  return (
    <section className="pane screen-pane">
      <header>
        <h2>Screen</h2>
        <span className="hint">40 &times; 24, the text page</span>
        <button onClick={onCapture} disabled={busy}>
          {busy ? 'Capturing...' : 'Freeze & capture'}
        </button>
      </header>

      {HAS_GLYPHS ? (
        <canvas ref={canvas} className="screen" />
      ) : (
        <p className="warn">
          No character ROM, so this is showing text rather than pixels. Run{' '}
          <code>npm run charset</code> in <code>web/</code> after supplying{' '}
          <code>roms/apple2e_char.hex</code> to draw the real //e glyphs.
        </p>
      )}

      {screen ? (
        <>
          <p className="screen-status">
            {screen.text ? 'TEXT' : 'GRAPHICS'}
            {screen.mixed ? ' + MIXED' : ''} &middot; {screen.page2 ? 'PAGE 2' : 'PAGE 1'} &middot;{' '}
            {screen.hires ? 'HIRES' : 'LORES'} &middot; PLL {screen.pll ? 'locked' : 'unlocked'}
          </p>
          {!HAS_GLYPHS && <pre className="screen-fallback">{text.join('\n')}</pre>}
        </>
      ) : (
        <p className="dim">
          Not captured yet. This reads the text page through the debugger, so it pauses the
          //e while it does: there is no way to read RAM while the CPU is running.
        </p>
      )}
    </section>
  )
}

/** Lo-res: 40 blocks across, four scanlines from the high nibble and four from
 *  the low one, which is what video_generator.v does with glyph_row[2]. */
function drawLores(ctx: CanvasRenderingContext2D, row: number, screen: ScreenFrame) {
  const gfxRow = row - (ROWS - 4)
  if (gfxRow < 0 || gfxRow >= SCR_GFX_ROWS) return
  for (let block = 0; block < COLS; block++) {
    // Lo-res only uses the even byte of each pair
    const byte = screen.gfx[gfxRow * (SCR_COLS / 2) * 2 + block * 2] ?? 0
    const y = row * GLYPH_H * SCALE
    ctx.fillStyle = rgb(LORES_PALETTE[(byte >> 4) & 0x0f])
    ctx.fillRect(block * LORES_BLOCK_W * SCALE, y, LORES_BLOCK_W * SCALE, 4 * SCALE)
    ctx.fillStyle = rgb(LORES_PALETTE[byte & 0x0f])
    ctx.fillRect(block * LORES_BLOCK_W * SCALE, y + 4 * SCALE, LORES_BLOCK_W * SCALE, 4 * SCALE)
  }
}

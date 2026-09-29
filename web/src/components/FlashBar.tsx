import { useEffect, useState } from 'react'
import type { Conn, Job, Transport } from '../useApple'

interface Props {
  conn: Conn
  canSerial: boolean
  baud: number
  job: Job | null
  endpoint: string
  onSerial: () => void
  onBridge: (url?: string) => void
  onDisconnect: () => void
  onResetEndpoint: () => void
  onFlash: (toFlash: boolean) => void
  onReconnect: () => void
}

/** One line of plain English for whatever the link is doing. */
function say(conn: Conn, baud: number): string {
  switch (conn.state) {
    case 'idle':
      return 'not connected'
    case 'opening':
      return conn.transport === 'serial' ? 'opening the port...' : 'connecting to the bridge...'
    case 'probing':
      return 'asking the //e who is there...'
    case 'connecting':
      return 'looking for the FPGA UART...'
    case 'open':
      return conn.detail ? `connected to ${conn.detail}` : `connected at ${baud}`
    case 'wrong-port':
      return 'that is the wrong USB channel -- pick the other one'
    case 'error':
      return conn.error ?? conn.detail ?? 'error'
    default:
      return ''
  }
}

const transportName = (t: Transport | null) => (t === 'serial' ? 'USB serial' : 'bridge')

/**
 * How the app is reaching the machine, and the programming buttons.
 *
 * USB serial is the normal path and needs nothing installed -- the board is
 * plugged into the machine running the browser and the browser opens the port
 * itself. The bridge is the fallback: for a board plugged into some *other*
 * machine, and for browsers with no Web Serial. It is also the only transport
 * that can program the FPGA, because openFPGALoader needs a subprocess.
 */
export function FlashBar({
  conn,
  canSerial,
  baud,
  job,
  endpoint,
  onSerial,
  onBridge,
  onDisconnect,
  onResetEndpoint,
  onFlash,
  onReconnect,
}: Props) {
  const [draft, setDraft] = useState(endpoint)
  const [showBridge, setShowBridge] = useState(false)

  useEffect(() => setDraft(endpoint), [endpoint])

  const up = conn.state === 'open'
  const viaBridge = conn.transport === 'bridge'

  return (
    <div className="flashbar">
      <span className={'dot ' + (up ? 'open' : conn.state)} aria-hidden />
      <span className="state">{say(conn, baud)}</span>
      {conn.transport && <span className="tag">{transportName(conn.transport)}</span>}

      {conn.state === 'idle' ? (
        <span className="chooser">
          <button
            onClick={onSerial}
            disabled={!canSerial}
            title={
              canSerial
                ? ''
                : 'This browser has no Web Serial. That needs Chrome or Edge, on https or localhost.'
            }
          >
            Connect USB
          </button>
          <button onClick={() => setShowBridge((s) => !s)}>Use a bridge instead</button>
        </span>
      ) : conn.state === 'error' || conn.state === 'wrong-port' ? (
        <span className="chooser">
          <button onClick={onReconnect}>Try again</button>
          <button onClick={onDisconnect}>Forget it</button>
        </span>
      ) : (
        <button onClick={onDisconnect}>Disconnect</button>
      )}

      {showBridge && (
        <form
          className="endpoint"
          onSubmit={(e) => {
            e.preventDefault()
            onBridge(draft)
            setShowBridge(false)
          }}
        >
          <input
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            spellCheck={false}
            placeholder="ws://127.0.0.1:8781/ws"
            aria-label="Bridge WebSocket URL"
          />
          <button type="submit">Connect</button>
          <button type="button" onClick={onResetEndpoint} title="Back to this page's own address">
            Default
          </button>
          <button type="button" onClick={() => setShowBridge(false)}>
            Cancel
          </button>
        </form>
      )}

      <span className="spacer" />

      <button
        onClick={() => onFlash(false)}
        disabled={job?.state === 'running' || !viaBridge}
        title={viaBridge ? '' : 'Programming runs openFPGALoader, so it needs the bridge'}
      >
        Load to SRAM
      </button>
      <button
        onClick={() => onFlash(true)}
        disabled={job?.state === 'running' || !viaBridge}
        title={viaBridge ? '' : 'Programming runs openFPGALoader, so it needs the bridge'}
      >
        Write flash
      </button>

      {job && (
        <details className="job" open={job.state === 'running'}>
          <summary>
            {job.target === 'flash' ? 'writing flash' : 'loading SRAM'} &mdash; {job.state}
            {job.error ? ` (${job.error})` : ''}
          </summary>
          <pre>{job.lines.slice(-20).join('\n')}</pre>
        </details>
      )}
    </div>
  )
}

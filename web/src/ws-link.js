// ============================================================================
//  ws-link.js -- the bridge, for browsers without Web Serial
//
//  The bridge is a Node process holding the serial port, so it is the way to
//  reach a board that is plugged into a *different* machine, and the only way
//  at all in Firefox and Safari, which have no Web Serial. It also keeps the
//  flash buttons, which need a subprocess to run openFPGALoader.
//
//  It is now the fallback rather than the default: with the board plugged into
//  the machine running the browser, Web Serial does the same job with nothing
//  installed at all.
//
//  Bytes go both ways as raw binary frames rather than JSON, because that is
//  what Web Serial does and it keeps the transport underneath the protocol
//  layer identical for both. Control messages (flash, reconnect) stay JSON.
// ============================================================================

export class WsLink {
  /** @param {string} url */
  constructor(url) {
    this.url = url
    this.ws = null
    this.onBytes = () => {}
    this.onState = () => {}
    this.onJob = () => {}
    this.state = 'idle'
    this.detail = null
  }

  /** @returns {'bridge'} */
  get kind() {
    return 'bridge'
  }

  describe() {
    return this.url
  }

  emit(state, detail = null) {
    this.state = state
    this.detail = detail
    this.onState({ kind: 'bridge', state, detail })
  }

  async open() {
    await this.close()
    this.emit('opening')
    const ws = new WebSocket(this.url)
    ws.binaryType = 'arraybuffer'
    this.ws = ws

    ws.onopen = () => this.emit('connecting') // 'connecting' means the bridge is probing
    ws.onerror = () => this.emit('error', `cannot reach ${this.url}`)
    ws.onclose = () => {
      if (this.state !== 'error') this.emit('idle')
    }
    ws.onmessage = (ev) => {
      if (typeof ev.data === 'string') {
        let m
        try {
          m = JSON.parse(ev.data)
        } catch {
          return
        }
        if (m.t === 'status') {
          this.emit(m.state, m.error ? String(m.error) : (m.port ? `${m.port} at ${m.baud}` : null))
        } else if (m.t === 'job') {
          this.onJob(m.job)
        }
        return
      }
      this.onBytes(new Uint8Array(ev.data))
    }
    return 'ok'
  }

  write(bytes) {
    if (this.ws?.readyState === WebSocket.OPEN) this.ws.send(bytes)
  }

  /** Control messages the bridge understands, which are not //e bytes. */
  control(msg) {
    if (this.ws?.readyState === WebSocket.OPEN) this.ws.send(JSON.stringify(msg))
  }

  async close() {
    const ws = this.ws
    this.ws = null
    if (ws) {
      ws.onopen = ws.onerror = ws.onclose = ws.onmessage = null
      try {
        ws.close()
      } catch {
        /* ignore */
      }
    }
    if (this.state !== 'error') this.emit('idle')
  }
}

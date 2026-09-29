// ============================================================================
//  bridge.mjs -- BL616 USB-serial <-> WebSocket
//
//  The Tang Nano 20K's BL616 is a USB-serial/JTAG bridge, and it shows up as
//  an FT2232C with two channels: one is the FPGA's 115200-baud UART, the other
//  is the BL616's own console. Only the first is interesting, and nothing
//  arrives on it until the //e prints something, so "did I get bytes" is not a
//  usable test. Instead this probes with the debugger's own handshake --
//  Ctrl+B, then '?', looking for the help line -- which is unambiguous, and
//  which leaves the machine exactly as it found it.
//
//  Usage:
//    node bridge/bridge.mjs [--port /dev/ttyUSB0] [--baud 115200]
//                           [--http 8781] [--no-serve] [--repo ..]
//                           [--allow-origin=https://host] [--tls-cert c --tls-key k]
// ============================================================================

import { SerialPort } from 'serialport'
import { WebSocketServer } from 'ws'
import { createServer } from 'node:http'
import { createServer as createHttpsServer } from 'node:https'
import { spawn } from 'node:child_process'
import { readFile, stat } from 'node:fs/promises'
import { existsSync, readFileSync } from 'node:fs'
import { extname, join, normalize, resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const WEB_ROOT = resolve(HERE, '..')
const REPO = resolve(process.env.REPO_ROOT ?? join(WEB_ROOT, '..'))

const HANDSHAKE = 'Cmds: r=Regs'
const CTRL_B = 0x02
const HELP = '?'

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.map': 'application/json; charset=utf-8',
  '.ico': 'image/x-icon',
}

function arg(name, fallback) {
  const i = process.argv.indexOf('--' + name)
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback
}
const hasFlag = (name) => process.argv.includes('--' + name)

const BAUD = Number(arg('baud', 115200))
const HTTP_PORT = Number(arg('http', 8781))
const SERVE = !hasFlag('no-serve')
const FORCED_PORT = arg('port', null)

const log = (...a) => console.log('[bridge]', ...a)

// ---------------------------------------------------------------------------
//  Serial
// ---------------------------------------------------------------------------

let port = null
let connectedPort = null
let state = 'closed' // closed | probing | open | error
let lastError = null
/** Every client sees the same bytes, so this is the only buffer. */
const clients = new Set()

function broadcast(bytes) {
  for (const ws of clients) {
    if (ws.readyState === 1) ws.send(bytes, { binary: true })
  }
}

function status() {
  return {
    t: 'status',
    state,
    port: connectedPort,
    baud: BAUD,
    error: lastError,
    clients: clients.size,
  }
}
function pushStatus() {
  const msg = JSON.stringify(status())
  for (const ws of clients) if (ws.readyState === 1) ws.send(msg)
}

function openPort(path) {
  return new Promise((res, rej) => {
    const p = new SerialPort({ path, baudRate: BAUD, autoOpen: false })
    // Same reasoning as probe(): open() can block in the kernel under USB
    // pass-through, so never await it without a floor.
    const timer = setTimeout(() => rej(new Error(`${path}: open did not complete`)), 3000)
    p.open((err) => {
      clearTimeout(timer)
      if (err) rej(err)
      else res(p)
    })
  })
}

function closePort() {
  return new Promise((res) => {
    if (!port || !port.isOpen) return res()
    port.close(() => res())
  })
}

/**
 * Open a candidate port and ask the debugger who it is. Resolves to true only
 * if the FPGA's UART answers, so the BL616's own console channel is skipped.
 *
 * The timer is a hard floor, not a suggestion: under a VM's USB pass-through
 * (vhci_hcd) an FTDI's open() can block in the kernel and never call back, so
 * the timer has to be what moves us on.
 */
function probe(candidate, timeoutMs = 1800) {
  return new Promise((res) => {
    let p
    try {
      p = new SerialPort({ path: candidate, baudRate: BAUD, autoOpen: false })
    } catch {
      return res(false)
    }
    let seen = ''
    let settled = false
    const done = (ok) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      p.removeAllListeners()
      try {
        p.close(() => res(ok))
      } catch {
        res(ok)
      }
      // Do not wait forever for a close on a port that never opened.
      setTimeout(() => res(ok), 250)
    }
    const timer = setTimeout(() => done(false), timeoutMs)

    p.on('data', (chunk) => {
      seen += chunk.toString('latin1')
      if (seen.includes(HANDSHAKE)) {
        // Put the machine back where we found it: leave the debugger.
        p.write(Uint8Array.from([CTRL_B]), () => {})
        done(true)
      }
    })
    p.on('error', () => done(false))
    p.open((err) => {
      if (err) return done(false)
      // Ctrl+B to enter the debugger, '?' for the help line.
      p.write(Uint8Array.from([CTRL_B, HELP.charCodeAt(0)]), (e) => {
        if (e) done(false)
      })
    })
  })
}

async function candidatePorts() {
  if (FORCED_PORT) return [FORCED_PORT]
  const list = await SerialPort.list()
  // Order matters more than filtering here. The USB metadata is not always
  // populated -- it comes out empty under a VM's USB pass-through, for
  // instance -- so fall back to the device name, which is where a real UART
  // lives anyway. The probe below is what actually decides, by talking to the
  // debugger.
  const score = (p) => {
    const text = `${p.manufacturer ?? ''} ${p.product ?? ''} ${p.vendorId ?? ''}`
    if (/sipeed|usb_debugger|debugger/i.test(text)) return 0
    if (p.vendorId === '0403') return 1
    if (/^ttyUSB\d+$/.test(p.path)) return 2
    if (/^ttyACM\d+$/.test(p.path)) return 2
    return 9 // a plain ttyS is almost never the board
  }
  return [...new Set(list.map((p) => p.path))].sort(
    (a, b) =>
      score(list.find((p) => p.path === a) ?? {}) - score(list.find((p) => p.path === b) ?? {}),
  )
}

async function connect() {
  await closePort()
  const candidates = await candidatePorts()
  if (!candidates.length) {
    state = 'error'
    lastError = 'no serial ports found -- is the board plugged in?'
    log(lastError)
    pushStatus()
    return
  }
  state = 'probing'
  lastError = null
  pushStatus()
  for (const c of candidates) {
    log('probing', c)
    if (await probe(c)) {
      try {
        port = await openPort(c)
      } catch (e) {
        lastError = `${c}: ${e.message}`
        continue
      }
      connectedPort = c
      state = 'open'
      port.on('data', broadcast)
      port.on('error', (e) => {
        lastError = String(e.message ?? e)
        log('serial error:', lastError)
        pushStatus()
      })
      port.on('close', () => {
        state = 'closed'
        pushStatus()
      })
      log(`connected to ${c} at ${BAUD}`)
      pushStatus()
      return
    }
  }
  state = 'error'
  lastError = `none of ${candidates.join(', ')} answered the debugger handshake`
  log(lastError)
  pushStatus()
}

function write(bytes) {
  if (!port || !port.isOpen) return
  port.write(bytes, (e) => {
    if (e) log('write failed:', e.message)
  })
}

// ---------------------------------------------------------------------------
//  Flash
//
//  openFPGALoader resets the BL616, so the port has to be let go of before the
//  job and re-acquired after it, or the FPGA UART is gone by the time the
//  bitstream lands.
// ---------------------------------------------------------------------------

let job = null // { state, lines[], started, finished, error }

function pushJob() {
  const msg = JSON.stringify({ t: 'job', job })
  for (const ws of clients) if (ws.readyState === 1) ws.send(msg)
}

async function flash(flashBitstream) {
  if (job && job.state === 'running') return
  job = { state: 'running', lines: [], started: Date.now(), target: flashBitstream ? 'flash' : 'sram' }
  pushJob()
  log(`flashing to ${job.target}`)

  await closePort()
  state = 'closed'
  pushStatus()

  const args = flashBitstream ? ['--flash'] : []
  const script = join(REPO, 'scripts', 'prog.sh')
  const child = spawn(script, args, { cwd: REPO, stdio: ['ignore', 'pipe', 'pipe'] })

  const onLine = (buf) => {
    const s = buf.toString().replace(/\r/g, '')
    for (const line of s.split('\n')) {
      if (!line.trim()) continue
      job.lines.push(line)
      log('  ' + line)
    }
    pushJob()
  }
  child.stdout.on('data', onLine)
  child.stderr.on('data', onLine)

  const code = await new Promise((res) => child.on('close', res))
  job.state = code === 0 ? 'done' : 'failed'
  job.finished = Date.now()
  job.error = code === 0 ? null : `prog.sh exited ${code}`
  log(`flash ${job.state}`)
  pushJob()

  // The BL616 re-enumerates, so wait for it to come back before reopening.
  await new Promise((r) => setTimeout(r, 2500))
  await connect()
}

// ---------------------------------------------------------------------------
//  WebSocket
// ---------------------------------------------------------------------------

function onMessage(ws, data, isBinary) {
  if (isBinary) return write(Uint8Array.from(data))

  let msg
  try {
    msg = JSON.parse(data.toString())
  } catch {
    return
  }
  switch (msg.t) {
    case 'bytes':
      if (Array.isArray(msg.b)) write(Uint8Array.from(msg.b))
      break
    case 'key':
      write(Uint8Array.from([0xfe, msg.code & 0x7f, (msg.buttons ?? 0) & 0x07]))
      break
    case 'gamepad':
      write(
        Uint8Array.from([
          0xff,
          0x01,
          (msg.buttons ?? 0) & 0x07,
          msg.x & 0xff,
          msg.y & 0xff,
        ]),
      )
      break
    case 'raw': // escape hatch: send a string as ASCII bytes
      write(Uint8Array.from([...Buffer.from(msg.s ?? '', 'latin1')]))
      break
    case 'flash':
      flash(Boolean(msg.flash))
      break
    case 'reconnect':
      connect()
      break
    case 'ping':
      ws.send(JSON.stringify({ t: 'pong', job }))
      break
    default:
      break
  }
}

// ---------------------------------------------------------------------------
//  HTTP: the built app if there is one, plus a small status endpoint
// ---------------------------------------------------------------------------

const DIST = join(WEB_ROOT, 'dist')

async function serveStatic(req, res) {
  const url = new URL(req.url ?? '/', 'http://localhost')
  let p = decodeURIComponent(url.pathname)
  if (p === '/') p = '/index.html'
  // keep the path inside dist
  const full = join(DIST, normalize(p).replace(/^(\.\.[/\\])+/, ''))
  if (!full.startsWith(DIST)) {
    res.writeHead(403).end('no')
    return
  }
  try {
    const s = await stat(full)
    if (!s.isFile()) throw new Error('not a file')
    res.writeHead(200, {
      'content-type': MIME[extname(full)] ?? 'application/octet-stream',
      'cache-control': 'no-cache',
    })
    res.end(await readFile(full))
  } catch {
    res.writeHead(404, { 'content-type': 'text/plain' }).end('not found')
  }
}

// ---------------------------------------------------------------------------
//  Who may talk to this bridge
//
//  This matters more than it looks. The bridge holds a serial port to a real
//  machine: anything that can reach it can type into the Apple //e, read its
//  RAM and trigger a flash. Once the app is served from GitHub Pages that is a
//  page on the public internet talking to a service on localhost, so the
//  browser sends a real Origin -- and so does any other site the user visits,
//  which could type into the //e behind the app's back.
//
//  So: loopback origins are fine (that is `make bridge` and `npm run dev`), a
//  missing Origin is fine (a script, not a browser), and anything else has to
//  be named:
//
//      WEB_ORIGIN=https://terence.github.io scripts/bridge.sh
//      scripts/bridge.sh --allow-origin=https://terence.github.io
//
//  A WebSocket handshake is not subject to CORS, so this is the only thing
//  between a random page and the machine's serial port.
// ---------------------------------------------------------------------------

const EXTRA_ORIGINS = new Set(
  (process.env.WEB_ORIGIN ?? '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean),
)
for (const o of arg('allow-origin', '')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean)) {
  EXTRA_ORIGINS.add(o)
}

const LOOPBACK = new Set(['localhost', '127.0.0.1', '::1'])

function originAllowed(origin) {
  if (!origin) return true // not a browser
  let host
  try {
    host = new URL(origin).hostname
  } catch {
    return false
  }
  if (LOOPBACK.has(host)) return true
  if (EXTRA_ORIGINS.has(origin) || EXTRA_ORIGINS.has(host)) return true
  return false
}


// Optional TLS, for the case where a hosted page is not allowed to open a
// plain ws:// to loopback by your browser. Self-signed, so the browser will
// warn once.
const TLS_CERT = arg('tls-cert', process.env.TLS_CERT ?? null)
const TLS_KEY = arg('tls-key', process.env.TLS_KEY ?? null)
if ((TLS_CERT && !TLS_KEY) || (!TLS_CERT && TLS_KEY)) {
  console.error('[bridge] --tls-cert and --tls-key go together')
  process.exit(1)
}
const server = TLS_CERT
  ? createHttpsServer({ cert: readFileSync(TLS_CERT), key: readFileSync(TLS_KEY) }, handler)
  : createServer(handler)

function handler(req, res) {
  if (req.url?.startsWith('/api/status')) {
    res.writeHead(200, { 'content-type': 'application/json' })
    res.end(JSON.stringify({ ...status(), job, dist: existsSync(DIST), tls: Boolean(TLS_CERT) }))
    return
  }
  if (SERVE && existsSync(DIST)) return serveStatic(req, res)
  res.writeHead(404, { 'content-type': 'text/plain' })
  res.end('web/dist not built. Run `npm run build` in web/, or use `npm run dev`.')
}

const wss = new WebSocketServer({
  server,
  path: '/ws',
  // Refuse during the upgrade, not after it. Closing with 1008 once the
  // handshake is done still hands a stranger a live socket for a moment, and
  // the point of this check is that they never get one.
  verifyClient: ({ origin }) => {
    if (originAllowed(origin)) return true
    log(`refused a connection from ${origin} -- name it with WEB_ORIGIN to allow it`)
    return false
  },
})

wss.on('connection', (ws, req) => {
  clients.add(ws)
  log(`client connected from ${req.headers.origin ?? 'a non-browser client'} (${clients.size})`)
  ws.send(JSON.stringify(status()))
  ws.on('message', (d, isBinary) => onMessage(ws, d, isBinary))
  ws.on('close', () => {
    clients.delete(ws)
    pushStatus()
  })
  ws.on('error', () => clients.delete(ws))
})

server.listen(HTTP_PORT, () => {
  log(`listening on ${TLS_CERT ? 'https' : 'http'}://127.0.0.1:${HTTP_PORT}  (ws path /ws)`)
  if (SERVE && existsSync(DIST)) log('serving web/dist')
  else if (SERVE) log('web/dist not built; run `npm run build` or use `npm run dev`')
  if (EXTRA_ORIGINS.size) log(`also allowing page origins: ${[...EXTRA_ORIGINS].join(', ')}`)
  else
    log('only loopback pages are allowed; set WEB_ORIGIN to allow a hosted page')
  connect()
})

for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, async () => {
    log('shutting down')
    await closePort()
    process.exit(0)
  })
}

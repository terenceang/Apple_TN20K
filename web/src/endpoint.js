// ============================================================================
//  endpoint.js -- where the bridge is
//
//  The app is a static bundle and the bridge is a Node process holding the
//  board's serial port, so the two can be on different machines. That matters
//  for GitHub Pages: the Pages site can be reached from anywhere, but the
//  bridge has to be running on the machine the board is plugged into, and the
//  app has to be told where it is.
//
//  Resolution order, first match wins:
//
//    1. a ?ws= query parameter, remembered for next time
//    2. whatever the user typed into the bridge box
//    3. VITE_WS, baked in at build time
//    4. the page's own origin, which is right when the bridge is serving the
//       app itself (`make bridge` and `npm run dev` both do)
//
//  Plain JS with JSDoc so `node --test` can check the normalisation without a
//  browser.
// ============================================================================

const KEY = 'a2e.bridge'

/** The default bridge URL, given where the page is being served from. */
export function defaultEndpoint(here) {
  const buildTime = readEnv()
  if (buildTime) {
    const n = normalise(buildTime)
    if (n) return n
  }
  if (!here) return 'ws://127.0.0.1:8781/ws'
  const proto = here.protocol === 'https:' ? 'wss:' : 'ws:'
  return `${proto}//${here.host}/ws`
}

function readEnv() {
  // import.meta.env only exists under Vite; guard so node --test can import.
  try {
    return typeof import.meta !== 'undefined' && import.meta.env ? import.meta.env.VITE_WS : ''
  } catch {
    return ''
  }
}

/**
 * Turn whatever the user typed into a WebSocket URL, or null if it is not one.
 *
 *   127.0.0.1:8781          -> ws://127.0.0.1:8781/ws
 *   ws://box.local:8781     -> unchanged
 *   https://box.local       -> wss://box.local/ws
 *   '://'                   -> null, because that is not a host
 */
export function normalise(input) {
  const s = String(input ?? '').trim()
  if (!s) return null

  let url
  // A scheme has to be "scheme://" to be a scheme. Requiring the slashes is
  // what keeps a bare "box.local:8781" from looking like a scheme called
  // "box.local".
  const m = /^([a-z][a-z0-9+.-]*):\/\//i.exec(s)
  if (m) {
    const scheme = m[1].toLowerCase()
    if (scheme !== 'ws' && scheme !== 'wss' && scheme !== 'http' && scheme !== 'https') return null
    const rest = s.slice(m[0].length)
    url =
      (scheme === 'https' ? 'wss://' : scheme === 'http' ? 'ws://' : scheme + '://') + rest
  } else if (/^[a-z][a-z0-9+.-]*:(?!\d)/i.test(s)) {
    // Something like "ws:/" or "javascript:" -- a scheme with no // and not a
    // host:port, so nothing sensible can come of it.
    return null
  } else {
    url = 'ws://' + s.replace(/^\/+/, '')
  }

  // Let the URL parser decide whether the result is real, and reject the
  // nonsense it produces from half-typed input rather than sending the user a
  // WebSocket to nowhere.
  let parsed
  try {
    parsed = new URL(url)
  } catch {
    return null
  }
  if (parsed.protocol !== 'ws:' && parsed.protocol !== 'wss:') return null
  if (!parsed.hostname) return null

  // Give it the path the bridge serves, unless one was typed.
  const path = parsed.pathname.replace(/\/+$/, '') || '/ws'
  return `${parsed.protocol}//${parsed.host}${/\/ws$/.test(path) ? path : path + '/ws'}`
}

/**
 * The bridge URL to use: the saved one, else ?ws=, else the default. Always a
 * URL, so callers do not have to handle a null.
 */
export function resolveEndpoint(here, store) {
  const saved = store ? read(store) : null
  if (saved) {
    const n = normalise(saved)
    if (n) return n
  }

  if (here && here.search) {
    const q = new URLSearchParams(here.search).get('ws')
    if (q) {
      const n = normalise(q)
      if (n) {
        if (store) write(store, n)
        return n
      }
    }
  }
  return defaultEndpoint(here)
}

function read(store) {
  try {
    return store.getItem(KEY)
  } catch {
    return null // private mode, or no localStorage
  }
}

function write(store, value) {
  try {
    store.setItem(KEY, value)
  } catch {
    /* not fatal: the setting just will not persist */
  }
}

export function remember(store, value) {
  const n = normalise(value)
  if (n) write(store, n)
  return n
}

export function forget(store) {
  try {
    store.removeItem(KEY)
  } catch {
    /* ignore */
  }
}

export { KEY as STORAGE_KEY }

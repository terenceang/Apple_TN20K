// ============================================================================
//  endpoint.test.js -- resolving where the bridge is
//
//  This is what makes a GitHub Pages deployment work: the bundle is served
//  from github.io, but the bridge is on the machine the board is plugged into,
//  so the URL has to come from somewhere other than location.host.
// ============================================================================

import test from 'node:test'
import assert from 'node:assert/strict'
import { normalise, resolveEndpoint, remember, forget, defaultEndpoint, STORAGE_KEY } from '../src/endpoint.js'

/** A localStorage stand-in. */
function store() {
  const m = new Map()
  return {
    getItem: (k) => (m.has(k) ? m.get(k) : null),
    setItem: (k, v) => m.set(k, String(v)),
    removeItem: (k) => m.delete(k),
    dump: () => m,
  }
}

const localPage = { protocol: 'http:', host: '127.0.0.1:8781', search: '' }
const pagesPage = { protocol: 'https:', host: 'terence.github.io', search: '' }

test('the default is the page it is served from, wss on https', () => {
  assert.equal(defaultEndpoint(localPage), 'ws://127.0.0.1:8781/ws')
  assert.equal(defaultEndpoint(pagesPage), 'wss://terence.github.io/ws')
  // no page at all, e.g. under node --test
  assert.equal(defaultEndpoint(null), 'ws://127.0.0.1:8781/ws')
})

test('a bare host:port becomes a ws:// URL with the /ws path', () => {
  assert.equal(normalise('127.0.0.1:8781'), 'ws://127.0.0.1:8781/ws')
  assert.equal(normalise('localhost:9000'), 'ws://localhost:9000/ws')
})

test('an https URL becomes wss, because the bridge has no plain http there', () => {
  assert.equal(normalise('https://box.local:8781'), 'wss://box.local:8781/ws')
})

test('a full ws:// URL is left alone', () => {
  assert.equal(normalise('ws://127.0.0.1:8781/ws'), 'ws://127.0.0.1:8781/ws')
  assert.equal(normalise('ws://box.local:8781'), 'ws://box.local:8781/ws')
  assert.equal(normalise('wss://box.local/ws'), 'wss://box.local/ws')
})

test('trailing slashes and stray whitespace do not matter', () => {
  assert.equal(normalise('  127.0.0.1:8781///  '), 'ws://127.0.0.1:8781/ws')
  assert.equal(normalise('ws://box.local/ws/'), 'ws://box.local/ws')
})

test('nothing is nothing', () => {
  assert.equal(normalise(''), null)
  assert.equal(normalise('   '), null)
  assert.equal(normalise(null), null)
  assert.equal(normalise(undefined), null)
})

test('half-typed rubbish is rejected rather than turned into a wrong URL', () => {
  for (const junk of ['://', 'ws://', 'http://', 'wss://', '/', 'ws:/']) {
    assert.equal(normalise(junk), null, junk)
  }
})

test('a scheme the bridge does not speak is rejected', () => {
  assert.equal(normalise('ftp://box.local'), null)
})

test('the saved setting wins over everything', () => {
  const s = store()
  remember(s, '10.0.0.5:8781')
  assert.equal(s.dump().get(STORAGE_KEY), 'ws://10.0.0.5:8781/ws')
  assert.equal(resolveEndpoint(pagesPage, s), 'ws://10.0.0.5:8781/ws')
  forget(s)
  assert.equal(resolveEndpoint(pagesPage, s), 'wss://terence.github.io/ws')
})

test('?ws= in the URL is used and then remembered', () => {
  const s = store()
  const page = { protocol: 'https:', host: 'terence.github.io', search: '?ws=127.0.0.1:8781' }
  assert.equal(resolveEndpoint(page, s), 'ws://127.0.0.1:8781/ws')
  // so a bookmarked link only needs it once
  assert.equal(resolveEndpoint({ ...page, search: '' }, s), 'ws://127.0.0.1:8781/ws')
})

test('a bad ?ws= falls back rather than failing', () => {
  const s = store()
  const page = { protocol: 'https:', host: 'terence.github.io', search: '?ws=' }
  assert.equal(resolveEndpoint(page, s), 'wss://terence.github.io/ws')
})

test('a saved value that no longer parses falls back rather than failing', () => {
  const s = store()
  s.setItem(STORAGE_KEY, '://')
  assert.equal(resolveEndpoint(localPage, s), 'ws://127.0.0.1:8781/ws')
})

test('a store that throws does not take the app down', () => {
  const hostile = {
    getItem() {
      throw new Error('denied')
    },
    setItem() {
      throw new Error('denied')
    },
    removeItem() {
      throw new Error('denied')
    },
  }
  assert.doesNotThrow(() => resolveEndpoint(localPage, hostile))
  assert.equal(resolveEndpoint(localPage, hostile), 'ws://127.0.0.1:8781/ws')
})

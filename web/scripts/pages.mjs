// ============================================================================
//  pages.mjs -- build the bundle GitHub Pages will serve, and check it
//
//  GitHub Pages for this repo can only be served from the root of a branch or
//  from /docs, so the built output has to land inside the repository and be
//  committed. It goes in docs/web/, not docs/ itself: /docs already holds the
//  board documentation -- Sipeed's datasheet and schematics -- and those are
//  tracked, so the deploy must not touch anything but its own subdirectory.
//  The app ends up at https://<owner>.github.io/<repo>/web/.
//
//  Two things a plain `vite build` does not do, and this script is the
//  difference between them and a script that just copies files:
//
//    1. It must not carry the character ROM. src/charset.js imports
//       generated/charset.json, Vite inlines it, and a build made after
//       `npm run charset` therefore contains all 4096 bytes of Apple's 2732.
//       A Pages site is public the moment it is published, which is the same
//       reason roms/*.hex is gitignored. PAGES=1 swaps that import for a
//       stub and the app falls back to showing the screen as text.
//
//    2. It has to work from a subpath. Pages serves docs/web/ at /<repo>/web/,
//       so absolute asset paths would 404.
//
//  And then it checks its own work, because a leaked ROM is the kind of
//  mistake nobody notices until it is up.
//
//      npm run pages            build, check, copy into ../docs/web
//      npm run pages:check      build and check, copy nothing
// ============================================================================

import { spawnSync } from 'node:child_process'
import { readdir, readFile, rm, mkdir, cp, stat, writeFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { dirname, join, resolve, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const WEB = resolve(HERE, '..')
const REPO = resolve(WEB, '..')
const DIST = join(WEB, 'dist')
const DOCS = join(REPO, 'docs')
// Our own subdirectory inside docs/. Never docs/ itself: that holds the board
// documentation and is tracked.
const OUT = join(DOCS, 'web')
const CHECK_ONLY = process.argv.includes('--check')

const log = (...a) => console.log('[pages]', ...a)

// ---------------------------------------------------------------------------
//  Build
// ---------------------------------------------------------------------------

log('building for Pages (no character ROM, relative asset paths)')
const build = spawnSync('npx', ['vite', 'build'], {
  cwd: WEB,
  stdio: 'inherit',
  env: { ...process.env, PAGES: '1' },
})
if (build.status !== 0) {
  log('build failed')
  process.exit(build.status ?? 1)
}

// ---------------------------------------------------------------------------
//  Check, before anything is published
// ---------------------------------------------------------------------------

/** Byte values of the real character ROM, if the user has supplied it. */
async function romProbe() {
  const hex = join(REPO, 'roms', 'apple2e_char.hex')
  if (!existsSync(hex)) return null
  const bytes = []
  for (const line of (await readFile(hex, 'utf8')).split(/\r?\n/)) {
    const tok = line.replace(/\/\/.*$/, '').trim().split(/\s+/)[0]
    if (tok && /^[0-9a-fA-F]{1,2}$/.test(tok)) bytes.push(parseInt(tok, 16))
  }
  // Glyph 1 is a capital A, and unlike a run of zeroes it cannot appear by
  // coincidence in a minified bundle.
  return bytes.length >= 32 ? bytes.slice(8, 24).join(',') : null
}

async function jsFiles(dir) {
  const out = []
  for (const e of await readdir(dir, { withFileTypes: true })) {
    const p = join(dir, e.name)
    if (e.isDirectory()) out.push(...(await jsFiles(p)))
    else if (e.name.endsWith('.js')) out.push(p)
  }
  return out
}

const probe = await romProbe()
let problems = 0

if (probe) {
  const files = await jsFiles(DIST)
  for (const f of files) {
    if ((await readFile(f, 'utf8')).includes(probe)) {
      console.error(`[pages] FAIL: the character ROM is in ${relative(REPO, f)}`)
      problems++
    }
  }
  if (problems === 0) log('no character ROM in the bundle')
} else {
  log('no character ROM supplied, so nothing to check against (this build has none either)')
}

for (const f of await jsFiles(DIST)) {
  if (f.endsWith('.map')) {
    console.error(`[pages] FAIL: a sourcemap would be published: ${relative(REPO, f)}`)
    problems++
  }
}

// Assets must be referenced relatively, or they 404 from /<repo>/.
const html = await readFile(join(DIST, 'index.html'), 'utf8')
for (const m of html.matchAll(/(?:src|href)="([^"]+)"/g)) {
  if (m[1].startsWith('/')) {
    console.error(`[pages] FAIL: absolute asset path in index.html: ${m[1]}`)
    problems++
  }
}
if (problems === 0) log('asset paths are relative, so this works from a subpath')

if (problems) {
  console.error('\n[pages] not publishing. Fix the above first.')
  process.exit(1)
}

// ---------------------------------------------------------------------------
//  Copy to /docs
// ---------------------------------------------------------------------------

if (CHECK_ONLY) {
  log('check only, nothing copied')
  process.exit(0)
}

// Only ever clear our own subdirectory. docs/ itself holds the board
// documentation and is tracked, and a deploy that wiped it would be very
// hard to notice in the diff and impossible to undo by accident.
if (relative(DOCS, OUT).startsWith('..')) {
  console.error('[pages] FAIL: refusing to write outside docs/')
  process.exit(1)
}
if (existsSync(OUT)) {
  const before = await readdir(OUT)
  if (before.some((f) => !['assets', 'index.html', '.nojekyll', 'favicon.ico'].includes(f))) {
    console.error(`[pages] FAIL: docs/web/ holds files this script did not put there:`)
    for (const f of before) console.error(`  ${f}`)
    process.exit(1)
  }
}
await rm(OUT, { recursive: true, force: true })
await mkdir(OUT, { recursive: true })
await cp(DIST, OUT, { recursive: true })

// GitHub Pages runs Jekyll over a branch without this, and Jekyll ignores
// files whose names begin with an underscore.
await writeFile(join(OUT, '.nojekyll'), '')

let bytes = 0
for (const f of await jsFiles(OUT)) bytes += (await stat(f)).size
log(`copied dist -> ${relative(REPO, OUT)}/ (${(bytes / 1024).toFixed(0)} KB of JavaScript)`)

// The Pages URL, if we can work it out, because it is the thing you want next.
// A project site is at <owner>.github.io/<repo>/, and this is a subdirectory of
// that, so the path is /<repo>/web/ -- not /web/.
let owner = ''
let repoName = ''
try {
  const url = spawnSync('git', ['remote', 'get-url', 'origin'], {
    cwd: REPO,
    encoding: 'utf8',
  }).stdout
  const m = url?.match(/github\.com[:/]([^/]+)\/([^/]+?)(?:\.git)?\s*$/)
  if (m) {
    owner = m[1]
    repoName = m[2]
  }
} catch {
  /* not a git checkout, or no remote: the URL is a nicety, not a requirement */
}

log('')
if (owner && repoName) log(`  will be at  https://${owner}.github.io/${repoName}/web/`)
log(`  commit ${relative(REPO, OUT)} and push to main to publish`)
log('')
log('The published site has no character ROM in it, so the screen pane shows')
log('text rather than the real //e glyphs. That is deliberate: see')
log('src/generated/no-charset.js. A local build still has them.')


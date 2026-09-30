// ============================================================================
//  disk.test.js -- Apple //e Disk II image handling & transfer protocol tests
// ============================================================================

import test from 'node:test'
import assert from 'node:assert/strict'

import {
  TRACKS,
  SECTORS_PER_TRACK,
  SECTOR_BYTES,
  TRACK_BYTES,
  DISK_BYTES,
  ACK_BYTE,
  DOS_TO_PHYS,
  PHYS_TO_DOS,
  detectDiskFormat,
  validateDiskImage,
  dosToPhysical,
  physicalToDos,
  prepareUploadImage,
  prepareDownloadImage,
  uploadDisk,
  downloadDisk,
} from '../src/disk.js'

test('disk dimensions match standard 140K 5.25" floppy geometry', () => {
  assert.equal(TRACKS, 35)
  assert.equal(SECTORS_PER_TRACK, 16)
  assert.equal(SECTOR_BYTES, 256)
  assert.equal(TRACK_BYTES, 4096)
  assert.equal(DISK_BYTES, 143360)
  assert.equal(ACK_BYTE, 0x06)
})

test('interleave tables are bijections and mutually inverse', () => {
  assert.equal(DOS_TO_PHYS.length, 16)
  assert.equal(PHYS_TO_DOS.length, 16)

  const dosSet = new Set(DOS_TO_PHYS)
  const physSet = new Set(PHYS_TO_DOS)
  assert.equal(dosSet.size, 16)
  assert.equal(physSet.size, 16)

  for (let i = 0; i < 16; i++) {
    assert.equal(PHYS_TO_DOS[DOS_TO_PHYS[i]], i)
    assert.equal(DOS_TO_PHYS[PHYS_TO_DOS[i]], i)
  }

  // Canonical DOS 3.3 RWTS interleave check
  assert.equal(DOS_TO_PHYS[0], 0x0)
  assert.equal(DOS_TO_PHYS[1], 0x7)
  assert.equal(DOS_TO_PHYS[2], 0xe)
  assert.equal(DOS_TO_PHYS[3], 0x6)
  assert.equal(DOS_TO_PHYS[13], 0x1)
  assert.equal(DOS_TO_PHYS[14], 0x8)
  assert.equal(DOS_TO_PHYS[15], 0xf)
})

test('detectDiskFormat distinguishes ProDOS and DOS orders by extension', () => {
  assert.equal(detectDiskFormat('master.dsk'), 'dos')
  assert.equal(detectDiskFormat('game.do'), 'dos')
  assert.equal(detectDiskFormat('prodos.po'), 'prodos')
  assert.equal(detectDiskFormat('PRODOS.PO'), 'prodos')
  assert.equal(detectDiskFormat('unknown.bin'), 'dos')
  assert.equal(detectDiskFormat(''), 'dos')
})

test('validateDiskImage enforces exact 143,360 byte size', () => {
  const good = new Uint8Array(DISK_BYTES)
  const res = validateDiskImage(good.buffer, 'test.po')
  assert.equal(res.data.byteLength, DISK_BYTES)
  assert.equal(res.order, 'prodos')
  assert.equal(res.filename, 'test.po')

  assert.throws(
    () => validateDiskImage(new Uint8Array(100), 'small.dsk'),
    /Invalid disk image size/,
  )
  assert.throws(
    () => validateDiskImage(new Uint8Array(143361), 'big.dsk'),
    /Invalid disk image size/,
  )
})

test('dosToPhysical and physicalToDos interleave each track correctly and round-trip', () => {
  const original = new Uint8Array(DISK_BYTES)
  // Fill each sector with a unique track & sector tag
  for (let t = 0; t < TRACKS; t++) {
    for (let s = 0; s < SECTORS_PER_TRACK; s++) {
      const off = t * TRACK_BYTES + s * SECTOR_BYTES
      original[off] = t
      original[off + 1] = s
      original[off + 2] = 0xaa
    }
  }

  const physical = dosToPhysical(original)
  assert.equal(physical.length, DISK_BYTES)

  // Track 0, logical sector 1 should have moved to physical sector 7 (offset 7 * 256)
  const physSec7Off = 7 * SECTOR_BYTES
  assert.equal(physical[physSec7Off], 0)
  assert.equal(physical[physSec7Off + 1], 1)
  assert.equal(physical[physSec7Off + 2], 0xaa)

  // Track 0, logical sector 2 should have moved to physical sector 14 (offset 14 * 256)
  const physSec14Off = 14 * SECTOR_BYTES
  assert.equal(physical[physSec14Off], 0)
  assert.equal(physical[physSec14Off + 1], 2)
  assert.equal(physical[physSec14Off + 2], 0xaa)

  // Converting back must return the exact original
  const roundTrip = physicalToDos(physical)
  assert.deepEqual(roundTrip, original)
})

test('prepareUploadImage and prepareDownloadImage respect format selection', () => {
  const sample = new Uint8Array(DISK_BYTES)
  sample[0] = 0x42
  sample[1] = 0x99

  // ProDOS order is identity
  const poUp = prepareUploadImage(sample, 'prodos')
  assert.deepEqual(poUp, sample)
  const poDn = prepareDownloadImage(sample, 'po')
  assert.deepEqual(poDn, sample)

  // DOS order applies interleave
  const dosUp = prepareUploadImage(sample, 'dos')
  const dosDn = prepareDownloadImage(dosUp, 'dsk')
  assert.deepEqual(dosDn, sample)
})

/**
 * Creates a mock serial link for testing upload and download protocols.
 */
function createMockLink() {
  const written = []
  let onBytes = (b) => {}

  const link = {
    written,
    get onBytes() {
      return onBytes
    },
    set onBytes(fn) {
      onBytes = fn
    },
    write(bytes) {
      const arr = bytes instanceof Uint8Array ? bytes : Uint8Array.from(bytes)
      written.push(arr)
    },
    feed(data) {
      const bytes = typeof data === 'string'
        ? new TextEncoder().encode(data)
        : data instanceof Uint8Array ? data : Uint8Array.from(data)
      onBytes(bytes)
    },
  }
  return link
}

test('uploadDisk executes full 35-track paced handshake and verifies done', async () => {
  const link = createMockLink()
  const payload = new Uint8Array(DISK_BYTES)
  for (let i = 0; i < DISK_BYTES; i++) payload[i] = (i * 7) & 0xff

  const progressEvents = []
  const originalOnBytes = link.onBytes

  // Run upload in background while mock responder answers
  const uploadPromise = uploadDisk(link, 1, payload, {
    onProgress: (p) => progressEvents.push(p),
    timeoutMs: 1000,
  })

  // 1. Board receives 'd' and '1'
  // Wait until 'd' and '1' are written
  await new Promise((r) => setTimeout(r, 60))
  assert.equal(link.written[0][0], 0x64) // 'd'
  assert.equal(link.written[1][0], 0x31) // '1'

  // Board responds with upload banner
  link.feed('\r\nUPLOAD 143360 bytes, send now\r\n')

  // 2. Feed ACK for each of the 35 tracks
  for (let t = 0; t < 35; t++) {
    // Wait for the track chunk to be written
    while (link.written.length < 3 + t) {
      await new Promise((r) => setTimeout(r, 5))
    }
    const chunk = link.written[2 + t]
    assert.equal(chunk.length, 4096)
    // Board sends ACK
    link.feed([ACK_BYTE])
  }

  // 3. Board finishes with done
  link.feed('\r\ndone\r\n> ')

  await uploadPromise

  // Verify all 35 tracks were reported
  assert.equal(progressEvents.length, 35)
  assert.equal(progressEvents[34].track, 35)
  assert.equal(progressEvents[34].bytesSent, 143360)

  // Verify link.onBytes was restored
  assert.equal(link.onBytes, originalOnBytes)
})

test('uploadDisk throws if FPGA reports lost bytes', async () => {
  const link = createMockLink()
  const payload = new Uint8Array(DISK_BYTES)

  const uploadPromise = uploadDisk(link, 2, payload, { timeoutMs: 1000 })

  await new Promise((r) => setTimeout(r, 60))
  assert.equal(link.written[0][0], 0x64) // 'd'
  assert.equal(link.written[1][0], 0x32) // '2' (drive 2)

  link.feed('\r\nUPLOAD 143360 bytes, send now\r\n')

  for (let t = 0; t < 35; t++) {
    while (link.written.length < 3 + t) {
      await new Promise((r) => setTimeout(r, 5))
    }
    link.feed([ACK_BYTE])
  }

  link.feed('\r\nlost\r\n> ')

  await assert.rejects(uploadPromise, /FPGA reported bytes lost/)
})

test('downloadDisk streams 143,360 bytes from FPGA and returns full image', async () => {
  const link = createMockLink()
  const expected = new Uint8Array(DISK_BYTES)
  for (let i = 0; i < DISK_BYTES; i++) expected[i] = (i ^ 0x5a) & 0xff

  const progressEvents = []
  const originalOnBytes = link.onBytes

  const downloadPromise = downloadDisk(link, 1, {
    onProgress: (p) => progressEvents.push(p),
    timeoutMs: 1000,
  })

  await new Promise((r) => setTimeout(r, 60))
  assert.equal(link.written[0][0], 0x65) // 'e'
  assert.equal(link.written[1][0], 0x31) // '1'

  // Board responds with download banner
  link.feed('\r\nDOWNLOAD 143360 bytes\r\n')

  // Feed the 143,360 bytes in multiple chunks (e.g. 512-byte slices)
  const chunkSize = 512
  for (let i = 0; i < DISK_BYTES; i += chunkSize) {
    link.feed(expected.subarray(i, Math.min(i + chunkSize, DISK_BYTES)))
  }

  // Board finishes with done
  link.feed('\r\ndone\r\n> ')

  const downloaded = await downloadPromise

  assert.equal(downloaded.length, DISK_BYTES)
  assert.deepEqual(downloaded, expected)
  assert.ok(progressEvents.length > 0)
  assert.equal(progressEvents[progressEvents.length - 1].bytesReceived, DISK_BYTES)
  assert.equal(link.onBytes, originalOnBytes)
})

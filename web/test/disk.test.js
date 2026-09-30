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
  HD_BLOCK_BYTES,
  HD_BLOCKS,
  HD_BYTES,
  HD_CHUNK_BYTES,
  HD_CHUNKS,
  validateHardDiskImage,
  uploadHardDisk,
  downloadHardDisk,
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

test('hard disk geometry constants match 2 MB ProDOS specifications', () => {
  assert.equal(HD_BLOCK_BYTES, 512)
  assert.equal(HD_BLOCKS, 4096)
  assert.equal(HD_BYTES, 2097152)
  assert.equal(HD_CHUNK_BYTES, 4096)
  assert.equal(HD_CHUNKS, 512)
})

test('validateHardDiskImage parses raw images and enforces <= 2 MB', () => {
  // Exact 2 MB
  const raw2mb = new Uint8Array(HD_BYTES)
  raw2mb[0] = 0xa5
  raw2mb[HD_BYTES - 1] = 0x5a
  const res1 = validateHardDiskImage(raw2mb.buffer, 'drive1.po')
  assert.equal(res1.data.length, HD_BYTES)
  assert.equal(res1.originalSize, HD_BYTES)
  assert.equal(res1.is2mg, false)
  assert.equal(res1.data[0], 0xa5)
  assert.equal(res1.data[HD_BYTES - 1], 0x5a)

  // Sub-2 MB image (e.g. 800 KB) is padded with zeros to 2 MB
  const raw800k = new Uint8Array(800 * 1024)
  raw800k[0] = 0x11
  raw800k[raw800k.length - 1] = 0x22
  const res2 = validateHardDiskImage(raw800k, 'small.hdv')
  assert.equal(res2.data.length, HD_BYTES)
  assert.equal(res2.originalSize, 800 * 1024)
  assert.equal(res2.data[0], 0x11)
  assert.equal(res2.data[800 * 1024 - 1], 0x22)
  assert.equal(res2.data[800 * 1024], 0x00) // padding

  // Oversized image throws
  const oversized = new Uint8Array(HD_BYTES + 1)
  assert.throws(
    () => validateHardDiskImage(oversized, 'huge.hdv'),
    /exceeds 2 MB limit/,
  )

  // Empty buffer throws
  assert.throws(
    () => validateHardDiskImage(new Uint8Array(0), 'empty.po'),
    /empty/,
  )
})

test('validateHardDiskImage parses 2MG container files', () => {
  const payloadSize = 4096
  const file = new Uint8Array(64 + payloadSize)
  // '2IMG' magic
  file[0] = 0x32
  file[1] = 0x49
  file[2] = 0x4d
  file[3] = 0x47

  const view = new DataView(file.buffer)
  view.setUint32(0x18, 64, true) // data offset
  view.setUint32(0x1c, payloadSize, true) // data length

  file[64] = 0xee
  file[64 + payloadSize - 1] = 0xff

  const res = validateHardDiskImage(file, 'test.2mg')
  assert.equal(res.is2mg, true)
  assert.equal(res.originalSize, payloadSize)
  assert.equal(res.data.length, HD_BYTES) // padded to 2MB
  assert.equal(res.data[0], 0xee)
  assert.equal(res.data[payloadSize - 1], 0xff)
  assert.equal(res.data[payloadSize], 0x00)
})

test('uploadHardDisk executes 512-chunk handshake with p1/p2 command', async () => {
  const link = createMockLink()
  const payload = new Uint8Array(HD_BYTES)
  for (let i = 0; i < 256; i++) payload[i] = i

  const progressEvents = []
  const originalOnBytes = link.onBytes

  const uploadPromise = uploadHardDisk(link, 1, payload, {
    onProgress: (p) => progressEvents.push(p),
    timeoutMs: 1000,
  })

  await new Promise((r) => setTimeout(r, 60))
  assert.equal(link.written[0][0], 0x70) // 'p'
  assert.equal(link.written[1][0], 0x31) // '1'

  // Board responds with upload prompt
  link.feed('\r\nUPLOAD 2097152 bytes, send now\r\n')

  // Stream 512 chunks
  for (let c = 0; c < HD_CHUNKS; c++) {
    while (link.written.length < 3 + c) {
      await new Promise((r) => setTimeout(r, 2))
    }
    assert.equal(link.written[2 + c].length, HD_CHUNK_BYTES)
    link.feed([ACK_BYTE])
  }

  link.feed('\r\ndone\r\n> ')

  await uploadPromise

  assert.equal(progressEvents.length, HD_CHUNKS)
  assert.equal(progressEvents[HD_CHUNKS - 1].chunk, 512)
  assert.equal(progressEvents[HD_CHUNKS - 1].bytesSent, HD_BYTES)
  assert.equal(link.onBytes, originalOnBytes)
})

test('downloadHardDisk streams 2 MB from FPGA with o1/o2 command', async () => {
  const link = createMockLink()
  const expected = new Uint8Array(HD_BYTES)
  expected[0] = 0x77
  expected[HD_BYTES - 1] = 0x88

  const progressEvents = []
  const originalOnBytes = link.onBytes

  const downloadPromise = downloadHardDisk(link, 2, {
    onProgress: (p) => progressEvents.push(p),
    timeoutMs: 1000,
  })

  await new Promise((r) => setTimeout(r, 60))
  assert.equal(link.written[0][0], 0x6f) // 'o'
  assert.equal(link.written[1][0], 0x32) // '2'

  // Board responds with download banner
  link.feed('\r\nDOWNLOAD 2097152 bytes\r\n')

  // Feed chunks of 64 KB
  const chunkSize = 65536
  for (let i = 0; i < HD_BYTES; i += chunkSize) {
    link.feed(expected.subarray(i, Math.min(i + chunkSize, HD_BYTES)))
  }

  link.feed('\r\ndone\r\n> ')

  const downloaded = await downloadPromise

  assert.equal(downloaded.length, HD_BYTES)
  assert.equal(downloaded[0], 0x77)
  assert.equal(downloaded[HD_BYTES - 1], 0x88)
  assert.ok(progressEvents.length > 0)
  assert.equal(progressEvents[progressEvents.length - 1].bytesReceived, HD_BYTES)
  assert.equal(link.onBytes, originalOnBytes)
})

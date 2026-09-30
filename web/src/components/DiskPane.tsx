import { useRef, useState } from 'react'
import type { DriveState, DiskProgress } from '../useApple'

interface Props {
  drives: Record<1 | 2, DriveState>
  hardDrives?: Record<1 | 2, DriveState>
  progress: DiskProgress | null
  error: string | null
  onUpload: (drive: 1 | 2, file: File) => Promise<void>
  onDownload: (drive: 1 | 2, format: 'dsk' | 'po') => Promise<void>
  onEject: (drive: 1 | 2) => void
  onUploadHardDisk?: (drive: 1 | 2, file: File) => Promise<void>
  onDownloadHardDisk?: (drive: 1 | 2) => Promise<void>
  onEjectHardDisk?: (drive: 1 | 2) => void
  onClearError: () => void
  onClose: () => void
  disabled?: boolean
}

export function DiskPane({
  drives,
  hardDrives = { 1: { filename: null, busy: false }, 2: { filename: null, busy: false } },
  progress,
  error,
  onUpload,
  onDownload,
  onEject,
  onUploadHardDisk,
  onDownloadHardDisk,
  onEjectHardDisk,
  onClearError,
  onClose,
  disabled = false,
}: Props) {
  const [activeSlot, setActiveSlot] = useState<6 | 7>(6)

  const fileInputFloppy1 = useRef<HTMLInputElement>(null)
  const fileInputFloppy2 = useRef<HTMLInputElement>(null)
  const fileInputHd1 = useRef<HTMLInputElement>(null)
  const fileInputHd2 = useRef<HTMLInputElement>(null)

  const [dragOver1, setDragOver1] = useState(false)
  const [dragOver2, setDragOver2] = useState(false)

  const isFloppy = activeSlot === 6
  const currentDrives = isFloppy ? drives : hardDrives

  const handleFile = (drive: 1 | 2, files: FileList | null) => {
    if (!files || !files.length) return
    const file = files[0]
    if (isFloppy) {
      void onUpload(drive, file)
    } else if (onUploadHardDisk) {
      void onUploadHardDisk(drive, file)
    }
  }

  const renderDriveCard = (
    drive: 1 | 2,
    fileInputRef: React.RefObject<HTMLInputElement | null>,
    dragOver: boolean,
    setDragOver: (v: boolean) => void,
  ) => {
    const d = currentDrives[drive]
    const devMatch = progress?.device ? (isFloppy ? progress.device === 'floppy' : progress.device === 'harddisk') : true
    const isBusy = d.busy || (progress?.drive === drive && devMatch)
    const hasDisk = Boolean(d.filename)

    return (
      <div
        className={`disk-drive-card ${hasDisk ? 'has-disk' : 'empty'} ${dragOver ? 'drag-over' : ''} ${isBusy ? 'busy' : ''}`}
        onDragOver={(e) => {
          e.preventDefault()
          if (!disabled && !isBusy) setDragOver(true)
        }}
        onDragLeave={() => setDragOver(false)}
        onDrop={(e) => {
          e.preventDefault()
          setDragOver(false)
          if (!disabled && !isBusy && e.dataTransfer.files) {
            handleFile(drive, e.dataTransfer.files)
          }
        }}
      >
        <div className="disk-drive-header">
          <div className="disk-drive-title">
            <span className={`disk-led ${isBusy ? 'busy' : hasDisk ? 'active' : 'off'}`} />
            <h3>{isFloppy ? `Floppy Drive ${drive}` : `Hard Disk ${drive}`}</h3>
          </div>
          <span className="disk-status-tag">
            {isBusy ? 'Busy' : hasDisk ? 'Mounted' : 'Empty'}
          </span>
        </div>

        <div className="disk-drive-body">
          {hasDisk ? (
            <div className="disk-info">
              <span className="disk-icon" aria-hidden>{isFloppy ? '💾' : '💽'}</span>
              <div className="disk-details">
                <span className="disk-filename" title={d.filename ?? ''}>
                  {d.filename}
                </span>
                <span className="disk-meta">
                  {isFloppy ? '140 KB Floppy (35 Tracks)' : '2 MB ProDOS Volume (4,096 Blocks)'}
                </span>
              </div>
            </div>
          ) : (
            <div
              className="disk-dropzone"
              onClick={() => !disabled && !isBusy && fileInputRef.current?.click()}
            >
              <span className="drop-icon">⇪</span>
              <span>
                {isFloppy
                  ? 'Drop .dsk / .do / .po image here'
                  : 'Drop .po / .hdv / .2mg image here'}
              </span>
              <span className="drop-sub">or click to browse</span>
            </div>
          )}

          <input
            ref={fileInputRef}
            type="file"
            accept={isFloppy ? '.dsk,.do,.po,.bin' : '.po,.hdv,.2mg,.bin,.img'}
            style={{ display: 'none' }}
            onChange={(e) => {
              handleFile(drive, e.target.files)
              e.target.value = ''
            }}
          />
        </div>

        <div className="disk-drive-actions">
          {hasDisk ? (
            <>
              <button
                type="button"
                className="btn-disk-action"
                onClick={() => (isFloppy ? onEject(drive) : onEjectHardDisk?.(drive))}
                disabled={disabled || isBusy}
                title="Eject this disk"
              >
                ⏏ Eject
              </button>
              {isFloppy ? (
                <>
                  <button
                    type="button"
                    className="btn-disk-action"
                    onClick={() => void onDownload(drive, 'dsk')}
                    disabled={disabled || isBusy}
                    title="Download image from FPGA in DOS 3.3 (.dsk) format"
                  >
                    ⬇ Save .dsk
                  </button>
                  <button
                    type="button"
                    className="btn-disk-action"
                    onClick={() => void onDownload(drive, 'po')}
                    disabled={disabled || isBusy}
                    title="Download image from FPGA in ProDOS (.po) format"
                  >
                    ⬇ Save .po
                  </button>
                </>
              ) : (
                <button
                  type="button"
                  className="btn-disk-action"
                  onClick={() => void onDownloadHardDisk?.(drive)}
                  disabled={disabled || isBusy || !onDownloadHardDisk}
                  title="Download 2 MB ProDOS hard disk image from FPGA (.po format)"
                >
                  ⬇ Save .po
                </button>
              )}
              <button
                type="button"
                className="btn-disk-action secondary"
                onClick={() => fileInputRef.current?.click()}
                disabled={disabled || isBusy}
                title="Replace disk with a different file"
              >
                Change
              </button>
            </>
          ) : (
            <button
              type="button"
              className="btn-disk-insert"
              onClick={() => fileInputRef.current?.click()}
              disabled={disabled || isBusy}
            >
              {isFloppy ? 'Insert Floppy Image...' : 'Insert Hard Disk Image...'}
            </button>
          )}
        </div>
      </div>
    )
  }

  return (
    <section className="pane disk-pane" aria-label="Storage Manager">
      <header className="pane-header">
        <span className="pane-title">💾 Storage Manager</span>
        <button
          type="button"
          className="pane-close"
          onClick={onClose}
          aria-label="Close Storage Pane"
          title="Close"
        >
          ×
        </button>
      </header>

      <div className="disk-tabs" role="tablist">
        <button
          type="button"
          role="tab"
          aria-selected={activeSlot === 6}
          className={`disk-tab-btn ${activeSlot === 6 ? 'active' : ''}`}
          onClick={() => setActiveSlot(6)}
        >
          💾 Slot 6: Floppy (140 KB)
        </button>
        <button
          type="button"
          role="tab"
          aria-selected={activeSlot === 7}
          className={`disk-tab-btn ${activeSlot === 7 ? 'active' : ''}`}
          onClick={() => setActiveSlot(7)}
        >
          💽 Slot 7: ProDOS HD (2 MB)
        </button>
      </div>

      {error && (
        <div className="disk-error-banner" role="alert">
          <span>⚠️ {error}</span>
          <button type="button" onClick={onClearError} title="Dismiss">
            ×
          </button>
        </div>
      )}

      {progress && (
        <div className="disk-progress-bar-container">
          <div className="disk-progress-labels">
            <span className="progress-phase">
              {progress.phase === 'uploading' ? 'Uploading to' : 'Downloading from'}{' '}
              {progress.device === 'harddisk' ? 'Slot 7' : 'Slot 6'} Drive {progress.drive}
            </span>
            <span className="progress-detail">{progress.detail}</span>
          </div>
          <div className="progress-track">
            <div
              className="progress-fill"
              style={{ width: `${progress.percent}%` }}
            />
          </div>
        </div>
      )}

      <div className="disk-drives-grid">
        {isFloppy ? (
          <>
            {renderDriveCard(1, fileInputFloppy1, dragOver1, setDragOver1)}
            {renderDriveCard(2, fileInputFloppy2, dragOver2, setDragOver2)}
          </>
        ) : (
          <>
            {renderDriveCard(1, fileInputHd1, dragOver1, setDragOver1)}
            {renderDriveCard(2, fileInputHd2, dragOver2, setDragOver2)}
          </>
        )}
      </div>

      <footer className="disk-pane-footer">
        <span className="disk-tip">
          {isFloppy
            ? 'Supported: 140 KB 5.25" floppy images (143,360 bytes). Logical sector order (.dsk, .do) is automatically translated to physical order for the FPGA.'
            : 'Supported: 2 MB ProDOS volumes (.po, .hdv, .2mg, max 4,096 blocks). Images smaller than 2 MB are automatically padded with zeros.'}
        </span>
      </footer>
    </section>
  )
}

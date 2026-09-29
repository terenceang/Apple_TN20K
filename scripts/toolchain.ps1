# ============================================================================
#  scripts/toolchain.ps1 -- dot-source this to configure the OSS CAD Suite
#  environment and set $OssCadBin / $script:NextPnr.
#
#  Tool discovery order (same as the old toolchain.sh, but Windows):
#    1. $env:OSS_CAD_SUITE, if set
#    2. "openfpga.toolchain.path" from VS Code user settings
#    3. C:\oss-cad-suite  (the default install location)
#    4. Whatever is already on $env:PATH
#
#  After dot-sourcing, $OssCadBin is the bin\ path and $script:NextPnr is the
#  correct executable name.  The OSS CAD Suite environment.ps1 is applied so
#  that lib\ (DLLs) is on PATH and all other required env-vars are set.
# ============================================================================

$OssCadBin = $null

function _FindOssCadRoot {
    param([string]$Root)
    if ($Root -and (Test-Path (Join-Path $Root 'bin\yosys.exe'))) { return $Root }
    return $null
}

# 1. Explicit env var
$found = _FindOssCadRoot $env:OSS_CAD_SUITE

# 2. VS Code user settings
if (-not $found) {
    $vsSettings = Join-Path $env:APPDATA 'Code\User\settings.json'
    if (Test-Path $vsSettings) {
        try {
            $json = Get-Content $vsSettings -Raw | ConvertFrom-Json -ErrorAction Stop
            $found = _FindOssCadRoot $json.'openfpga.toolchain.path'
        } catch {}
    }
}

# 3. Default install location
if (-not $found) { $found = _FindOssCadRoot 'C:\oss-cad-suite' }

if ($found) {
    $OssCadBin = Join-Path $found 'bin'

    # Apply the suite's environment so DLLs in lib\ are loadable
    if (-not $env:YOSYSHQ_ROOT) {
        $env:YOSYSHQ_ROOT      = $found
        $env:SSL_CERT_FILE     = Join-Path $found 'etc\cacert.pem'
        $env:PYTHON_EXECUTABLE = Join-Path $found 'lib\python3.exe'
        $env:QT_PLUGIN_PATH    = Join-Path $found 'lib\qt6\plugins'
        $env:QT_LOGGING_RULES  = '*=false'
        $env:GTK_EXE_PREFIX    = $found
        $env:GTK_DATA_PREFIX   = $found
        $env:GDK_PIXBUF_MODULEDIR   = Join-Path $found 'lib\gdk-pixbuf-2.0\2.10.0\loaders'
        $env:GDK_PIXBUF_MODULE_FILE = Join-Path $found 'lib\gdk-pixbuf-2.0\2.10.0\loaders.cache'
        $env:OPENFPGALOADER_SOJ_DIR = Join-Path $found 'share\openFPGALoader'

        # Prepend bin\ and lib\ to PATH (lib\ carries the Windows DLLs)
        $env:PATH = "$OssCadBin;$(Join-Path $found 'lib');$env:PATH"

        # Run the pixbuf cache update silently (it's fast, output goes nowhere)
        $gdk = Join-Path $found 'lib\gdk-pixbuf-query-loaders.exe'
        if (Test-Path $gdk) {
            & $gdk --update-cache 2>$null | Out-Null
        }
    }
}

# Resolve the nextpnr executable name
function Resolve-NextPnr {
    param([string]$BinDir)
    $names = @('nextpnr-himbaechel', 'nextpnr-himbaechel-gowin')
    foreach ($n in $names) {
        if ($BinDir) {
            if (Test-Path (Join-Path $BinDir "$n.exe")) { return Join-Path $BinDir "$n.exe" }
        } else {
            if (Get-Command $n -ErrorAction SilentlyContinue) { return $n }
        }
    }
    throw "nextpnr-himbaechel not found.`nInstall OSS CAD Suite to C:\oss-cad-suite or set `$env:OSS_CAD_SUITE."
}

$script:NextPnr = Resolve-NextPnr -BinDir $OssCadBin

function Invoke-Tool {
    <#
    .SYNOPSIS
        Run a tool from the OSS CAD Suite bin dir.
        Throws on non-zero exit code.
    #>
    param(
        [string]$Name,
        [string[]]$Arguments
    )
    if ($OssCadBin) {
        $exe = Join-Path $OssCadBin "$Name.exe"
        if (-not (Test-Path $exe)) { $exe = $Name }  # fallback for scripts
    } else {
        $exe = $Name
    }
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $exe @Arguments
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    if ($LASTEXITCODE -ne 0) {
        throw "'$Name' exited with code $LASTEXITCODE"
    }
}

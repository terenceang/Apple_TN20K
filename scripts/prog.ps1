# ============================================================================
#  scripts/prog.ps1 -- load the bitstream into the Tang Nano 20K.
#
#    scripts\prog.ps1           SRAM load (fast, lost on power cycle)
#    scripts\prog.ps1 -Flash    write configuration flash (persistent)
#
#  The transfer frequency defaults to 2.5 MHz but can be overridden via
#  $env:FREQ (e.g. $env:FREQ = '1M'; scripts\prog.ps1).
# ============================================================================
[CmdletBinding()]
param(
    [switch]$Flash
)
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
. (Join-Path $PSScriptRoot 'toolchain.ps1')

$name = Get-FpgaName

$fs   = "build/bitstream/$name.fs"
$freq = if ($env:FREQ) { $env:FREQ } else { '2.5M' }

$gowinProg = 'C:\Gowin\Gowin_V1.9.12_x64\Programmer\bin\programmer_cli.exe'
if (-not (Test-Path $gowinProg)) {
    $gowinProg = 'C:\Gowin\Gowin_V1.9.11.03_Education_x64\Programmer\bin\programmer_cli.exe'
}

$fsFullPath = (Resolve-Path $fs).Path

if (Test-Path $gowinProg) {
    Write-Host "Using Gowin programmer_cli: $gowinProg"
    if ($Flash) {
        & $gowinProg --device GW2AR-18C --run 8 --fsFile $fsFullPath
    } else {
        & $gowinProg --device GW2AR-18C --run 2 --fsFile $fsFullPath
    }
    if ($LASTEXITCODE -ne 0) {
        throw "programmer_cli exited with code $LASTEXITCODE"
    }
} else {
    Write-Host "Using openFPGALoader"
    if ($Flash) {
        Invoke-Tool 'openFPGALoader' @('--freq', $freq, '-b', 'tangnano20k', '-f', $fs)
    } else {
        Invoke-Tool 'openFPGALoader' @('--freq', $freq, '-b', 'tangnano20k', $fs)
    }
}

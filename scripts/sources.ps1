# ============================================================================
#  scripts/sources.ps1 -- print the RTL source list from fpga.yaml.
#
#  Usage:
#    scripts/sources.ps1
#    scripts/sources.ps1 --except src/foo/bar.v [--except ...]
#
#  Mirrors sources.sh: outputs one path per line, relative to the repo root.
# ============================================================================
[CmdletBinding()]
param(
    [string[]]$Except = @()
)

$root = Split-Path -Parent $PSScriptRoot
$yaml = Get-Content (Join-Path $root 'fpga.yaml') -Raw

# Parse the 'sources:' block: lines that start with '  - '
$inSources = $false
foreach ($line in $yaml -split "`n") {
    if ($line -match '^sources:') { $inSources = $true; continue }
    if ($inSources -and $line -match '^[^ ]') { $inSources = $false }
    if ($inSources -and $line -match '^\s*-\s+(\S+)') {
        $f = $Matches[1].Trim()
        if ($f -and $f -notin $Except) {
            Write-Output $f
        }
    }
}

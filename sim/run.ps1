# ============================================================================
#  sim/run.ps1 -- build and run every testbench with iverilog.
#
#  Run from anywhere; tools run from the repo root so `include and $readmemh
#  paths resolve.  tb_top and tb_cpu_trace need the ROM images in roms/
#  (see roms/README.md).
#
#  The RTL file list is fpga.yaml, read through scripts/sources.ps1.
# ============================================================================
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
. (Join-Path $root 'scripts\toolchain.ps1')

New-Item -ItemType Directory -Force -Path (Join-Path $root 'build') | Out-Null

function Run-Tb {
    param(
        [string]$Name,
        [string[]]$Files,
        [string]$Gen = '2005'
    )
    Write-Host "=== $Name ==="
    # On Windows iverilog -o writes a vvp script whatever the extension is, so
    # name the output .vvp and run it through vvp explicitly.
    $outVvp = Join-Path $root "build\$Name.vvp"
    $tbFile = Join-Path $root "sim\$Name.v"

    $iverilogArgs = @("-g$Gen", '-o', $outVvp, $tbFile) + $Files
    Invoke-Tool 'iverilog' $iverilogArgs

    $logFile = Join-Path $root "build\$Name.log"
    $vvp = if ($OssCadBin) { Join-Path $OssCadBin 'vvp.exe' } else { 'vvp' }

    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $vvp $outVvp > $logFile 2>&1
    } finally {
        $ErrorActionPreference = $prevEAP
    }

    Get-Content $logFile | Write-Host
    if ($LASTEXITCODE -ne 0) {
        throw "FAILED: $Name exited with code $LASTEXITCODE"
    }

    $logContent = Get-Content $logFile -Raw
    if ($logContent -match '(?m)^FAIL' -or $logContent -notmatch 'PASS') {
        throw "FAILED: $Name did not report PASS"
    }
    Write-Host ""
}

$hdmi = @('src/hdmi/hdmi_tx.v', 'src/hdmi/hdmi_island_scheduler.v', 'src/hdmi/hdmi_data_island.v',
          'src/hdmi/hdmi_packet_ecc.v', 'src/hdmi/hdmi_packets.v', 'src/hdmi/hdmi_tmds_encoder.v')
$island = @('src/hdmi/hdmi_data_island.v', 'src/hdmi/hdmi_packet_ecc.v', 'src/hdmi/hdmi_tmds_encoder.v')

# Guard against the hdmi list drifting from fpga.yaml (tb_top below reads the
# yaml through sources.ps1; the unit testbenches above use this hand-made copy).
$fpgaHdmi = @(& (Join-Path $root 'scripts\sources.ps1') | Where-Object { $_ -like 'src/hdmi/*' })
if ((Compare-Object $hdmi $fpgaHdmi).Count -ne 0) {
    throw "the `$hdmi list no longer matches fpga.yaml: $($hdmi -join ', ') vs $($fpgaHdmi -join ', ')"
}

Run-Tb 'tb_tmds_encoder' @('src/hdmi/hdmi_tmds_encoder.v')
Run-Tb 'tb_packet_ecc'   @('src/hdmi/hdmi_packet_ecc.v')
Run-Tb 'tb_packets'      @('src/hdmi/hdmi_packets.v')
Run-Tb 'tb_data_island'  $island
Run-Tb 'tb_sound'        @('src/sound_generator.v')
Run-Tb 'tb_input'        @('src/input_controller.v')
Run-Tb 'tb_video_hdmi'   (@('src/video_generator.v', 'src/colorbar_gen.v') + $hdmi)
Run-Tb 'tb_cpu_trace'    @('src/apple2_core.v', 'src/apple2_mem.v', 'src/cpu/cpu_65c02.v', 'src/cpu/ALU.v')
Run-Tb 'tb_auxsw'        @('src/apple2_core.v', 'src/apple2_mem.v', 'src/cpu/cpu_65c02.v', 'src/cpu/ALU.v')

Run-Tb 'tb_aux_ram'      @('sim/models/sdram_model.v', 'src/aux_ram.v', 'src/sdram/sdram.v') -Gen '2012'

$allSources = & (Join-Path $root 'scripts\sources.ps1')
Run-Tb 'tb_top'          (@('sim/models/gowin_prims.v', 'sim/models/sdram_model.v') + $allSources) -Gen '2012'

Write-Host "all testbenches passed"

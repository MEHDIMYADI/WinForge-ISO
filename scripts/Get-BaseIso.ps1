#requires -Version 7.0
<# Downloads the user-supplied base ISO (LTSC) and checks that it really is an ISO 9660/UDF image. #>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigPath)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/WinForge.Common.psm1') -Force
$cfg = Read-WinForgeConfig -Path $ConfigPath
if (-not $cfg.LtscBaseIsoUrl) { Stop-Build 'No base ISO URL configured.' }

$work = Get-WorkRoot
New-Item -ItemType Directory -Force -Path $work | Out-Null
Assert-FreeSpace -Path $work -MinGB 40
$iso = Join-Path $work 'base.iso'
Remove-Item -LiteralPath $iso -Force -ErrorAction SilentlyContinue

Write-Section 'Download base ISO'
Invoke-WithRetry -What 'base ISO download' -MaxAttempts 3 -BaseDelaySec 20 -Script {
    Remove-Item -LiteralPath $iso -Force -ErrorAction SilentlyContinue
    Invoke-Native -FilePath 'aria2c' -ArgumentList @(
        '--max-connection-per-server=8', '--split=8', '--max-tries=5', '--console-log-level=warn',
        '--summary-interval=60', '--allow-overwrite=true', '-d', $work, '-o', 'base.iso', $cfg.LtscBaseIsoUrl)
}
Close-Section

$len = (Get-Item -LiteralPath $iso).Length
if ($len -lt 1GB) { Stop-Build "Downloaded file is only $([math]::Round($len / 1MB)) MB; it is not a Windows ISO (wrong link or an HTML page?)." }
$fs = [IO.File]::OpenRead($iso)
try {
    $buf = [byte[]]::new(5)
    [void]$fs.Seek(0x8001, 'Begin')
    [void]$fs.Read($buf, 0, 5)
}
finally { $fs.Dispose() }
if ([Text.Encoding]::ASCII.GetString($buf) -ne 'CD001') { Stop-Build 'The downloaded file is not a valid ISO image (CD001 signature missing).' }
Write-Host "Base ISO OK: $([math]::Round($len / 1GB, 2)) GB"
Set-GhOutput 'iso_path' $iso

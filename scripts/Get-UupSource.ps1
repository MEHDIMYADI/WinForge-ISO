#requires -Version 7.0
<# Fetches a fresh UUP file list (URLs expire quickly) and downloads it with aria2 + SHA-1 verification. #>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigPath)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/WinForge.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/WinForge.UupDump.psm1') -Force

$cfg = Read-WinForgeConfig -Path $ConfigPath
$work = Get-WorkRoot
$dir = Join-Path $work 'UUPs'
$list = Join-Path $work 'aria2_list.txt'
New-Item -ItemType Directory -Force -Path $dir | Out-Null

Write-Section 'Build UUP file list'
$info = Invoke-WithRetry -What 'UUP file list' -MaxAttempts 3 -BaseDelaySec 30 -Script {
    New-Aria2List -Uuid $cfg.Uuid -Language $cfg.Language -Editions @($cfg.Editions) -OutFile $list
}
Write-Host "$($info.FileCount) files, about $($info.TotalGB) GB"
Close-Section

Assert-FreeSpace -Path $dir -MinGB ([math]::Max(30, [math]::Ceiling($info.TotalGB * 3)))

Write-Section 'Download UUP files'
$aria = @(
    "--input-file=$list", "--dir=$dir",
    '--max-connection-per-server=16', '--split=16', '--max-concurrent-downloads=8', '--min-split-size=1M',
    '--check-integrity=true', '--continue=true', '--retry-wait=5', '--max-tries=8',
    '--console-log-level=warn', '--summary-interval=60', '--file-allocation=none'
)
Invoke-Native -FilePath 'aria2c' -ArgumentList $aria
Close-Section

$files = @(Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.Extension -ne '.aria2' })
if ($files.Count -lt $info.FileCount) { Stop-Build "Expected $($info.FileCount) files but found $($files.Count) in $dir." }
if (Get-ChildItem -LiteralPath $dir -Filter '*.aria2' -File -ErrorAction SilentlyContinue) { Stop-Build 'Incomplete downloads detected (.aria2 control files remain).' }
Write-Host "Downloaded $($files.Count) files ($([math]::Round(($files | Measure-Object Length -Sum).Sum / 1GB, 2)) GB)"

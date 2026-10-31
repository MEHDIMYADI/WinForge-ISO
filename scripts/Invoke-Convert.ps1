#requires -Version 7.0
<# Runs the UUP converter with a generated ConvertConfig.ini and returns the produced ISO path. #>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigPath)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/WinForge.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/WinForge.Config.psm1') -Force

$cfg = Read-WinForgeConfig -Path $ConfigPath
$work = Get-WorkRoot
$conv = Join-Path $work 'converter'
$uup = Join-Path $work 'UUPs'
$drv = Join-Path $work 'drivers'

foreach ($p in @($conv, $uup)) { if (-not (Test-Path -LiteralPath $p)) { Stop-Build "Required folder missing: $p" } }
Assert-FreeSpace -Path $conv -MinGB 25

# Drivers are copied into the converter's Drivers\ folder (OS\, WinPE\, ALL\ subfolders).
$hasDrivers = $false
if (Test-Path -LiteralPath $drv) {
    $dst = Join-Path $conv 'Drivers'
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    Copy-Item -Path (Join-Path $drv '*') -Destination $dst -Recurse -Force
    $hasDrivers = $true
}

$ini = New-ConverterIni -Config $cfg -HasDrivers $hasDrivers
[IO.File]::WriteAllText((Join-Path $conv 'ConvertConfig.ini'), $ini, [Text.Encoding]::ASCII)
Write-Section 'ConvertConfig.ini'
Write-Host $ini
Close-Section

$target = Join-Path $conv 'UUPs'
New-Item -ItemType Directory -Force -Path $target | Out-Null
Move-Item -Path (Join-Path $uup '*') -Destination $target -Force

Write-Section 'Run converter'
Write-Host 'This usually takes 30-120 minutes.'
Push-Location $conv
try {
    & cmd.exe /c 'convert-UUP.cmd < nul' | Out-Host
    $code = $LASTEXITCODE
}
finally { Pop-Location }
Write-Host "convert-UUP.cmd exit code: $code"
Close-Section

# The converter's exit code is not reliable; success means an ISO exists and is plausible.
$iso = Get-ChildItem -LiteralPath $conv -Filter '*.iso' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $iso) {
    Get-ChildItem -LiteralPath $conv -Recurse -File | Select-Object -First 80 FullName, Length | Format-Table | Out-Host
    Stop-Build 'Conversion failed: the converter produced no ISO.'
}
if ($iso.Length -lt 1GB) { Stop-Build "Conversion produced a suspiciously small ISO ($([math]::Round($iso.Length / 1MB)) MB)." }

Write-Host "ISO: $($iso.Name) ($([math]::Round($iso.Length / 1GB, 2)) GB)"
Set-GhOutput 'iso_path' $iso.FullName

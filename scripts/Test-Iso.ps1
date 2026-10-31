#requires -Version 7.0
<# Mounts the finished ISO and verifies structure, boot files and image contents. Fails the build on problems. #>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$IsoPath, [Parameter(Mandatory)][string]$ConfigPath, [string]$ReportPath)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/WinForge.Common.psm1') -Force
$cfg = Read-WinForgeConfig -Path $ConfigPath

if (-not (Test-Path -LiteralPath $IsoPath)) { Stop-Build "ISO not found: $IsoPath" }
$iso = Get-Item -LiteralPath $IsoPath
Write-Section 'Verify ISO'
$problems = [System.Collections.Generic.List[string]]::new()
$editions = @()
$image = $null

$disk = Mount-DiskImage -ImagePath $iso.FullName -PassThru
try {
    $letter = ($disk | Get-Volume).DriveLetter
    if (-not $letter) { Stop-Build 'The ISO mounted without a drive letter.' }
    $root = "${letter}:\"

    $required = @('efi\boot', 'sources\boot.wim', 'sources\setup.exe', 'setup.exe')
    if ($cfg.Architecture -ne 'arm64') { $required += @('bootmgr', 'boot\bcd', 'boot\boot.sdi') }   # arm64 media is UEFI-only
    foreach ($rel in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $root $rel))) { $problems.Add("missing $rel") }
    }
    foreach ($name in @('install.wim', 'install.esd', 'install.swm')) {
        $p = Join-Path $root "sources\$name"
        if (Test-Path -LiteralPath $p) { $image = $p; break }
    }
    if (-not $image) { $problems.Add('no install.wim / install.esd / install.swm in sources\') }
    else {
        $dismArgs = @('/English', '/Get-WimInfo', "/WimFile:$image")
        if ($image -like '*.swm') { $dismArgs += "/SWMFile:$(Join-Path (Split-Path $image) 'install*.swm')" }
        $info = & dism.exe @dismArgs
        if ($LASTEXITCODE -ne 0) {
            if ($image -like '*.swm') { Write-Warn 'dism could not enumerate the split image; only its presence was verified.'; $editions = @('(split image)') }
            else { $problems.Add("dism could not read $image") }
        }
        else { $editions = @($info | Where-Object { $_ -match '^\s*Name\s*:' } | ForEach-Object { ($_ -split ':', 2)[1].Trim() }) }
        $expect = [string]$cfg.ImageFormat
        if ((Split-Path $image -Leaf) -notlike "install.$expect") { $problems.Add("image format is $(Split-Path $image -Leaf), expected install.$expect") }
    }
    if ($editions.Count -eq 0) { $problems.Add('no editions found in the install image') }
    Write-Host "Editions in ISO: $($editions -join '; ')"
}
finally { Dismount-DiskImage -ImagePath $iso.FullName | Out-Null }

if ($problems.Count -gt 0) { Stop-Build "ISO verification failed: $($problems -join '; ')" }

$report = [ordered]@{
    File     = $iso.Name
    SizeGB   = [math]::Round($iso.Length / 1GB, 2)
    Editions = $editions
}
if ($ReportPath) { $report | ConvertTo-Json | Set-Content -LiteralPath $ReportPath -Encoding utf8 }
Set-GhOutput 'editions' ($editions -join '; ')
Write-Host "ISO verification passed ($($report.SizeGB) GB)."
Close-Section

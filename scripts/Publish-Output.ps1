#requires -Version 7.0
<# Computes checksums, splits the ISO into GitHub-sized 7z volumes and writes release notes. #>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$IsoPath,
    [Parameter(Mandatory)][string]$ConfigPath,
    [string]$Editions = '',
    [string]$OsUpdate = 'n/a',
    [string]$NetUpdate = 'n/a'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/WinForge.Common.psm1') -Force
$cfg = Read-WinForgeConfig -Path $ConfigPath

$work = Get-WorkRoot
$out = Join-Path $work 'release'
Remove-Item -LiteralPath $out -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $out | Out-Null

$iso = Get-Item -LiteralPath $IsoPath
$base = [IO.Path]::GetFileNameWithoutExtension($iso.Name)

Write-Section 'Checksums'
$isoHash = Get-FileSha256 -Path $iso.FullName
"$isoHash  $($iso.Name)" | Set-Content -LiteralPath (Join-Path $out "$($iso.Name).sha256") -Encoding ascii
Write-Host "SHA-256 $isoHash"
Close-Section

Write-Section 'Split archive'
$mx = switch ($cfg.ArchiveMode) { 'store' { 0 } 'normal' { 5 } 'ultra' { 9 } }
$archive = Join-Path $out "$base.7z"
Invoke-Native -FilePath '7z' -ArgumentList @('a', '-t7z', "-mx=$mx", "-v$($cfg.PartSizeMB)m", '-bso0', '-bsp0', $archive, $iso.FullName)
$parts = @(Get-ChildItem -LiteralPath $out -Filter "$base.7z.*" -File | Sort-Object Name)
if ($parts.Count -eq 0) { Stop-Build '7z produced no archive parts.' }
$limit = 2GB - 1MB
foreach ($p in $parts) { if ($p.Length -ge $limit) { Stop-Build "Part $($p.Name) exceeds the GitHub release asset limit." } }

# Verify the archive before the (large) upload; extraction test needs no extra disk space.
Invoke-Native -FilePath '7z' -ArgumentList @('t', $parts[0].FullName, '-bso0', '-bsp0')

$partHashes = foreach ($p in $parts) { "$(Get-FileSha256 -Path $p.FullName)  $($p.Name)" }
$partHashes | Set-Content -LiteralPath (Join-Path $out "$base.parts.sha256") -Encoding ascii
Write-Host "$($parts.Count) part(s), $([math]::Round(($parts | Measure-Object Length -Sum).Sum / 1GB, 2)) GB total"
Close-Section

$edText = if ($Editions) { $Editions } elseif ($cfg.Editions.Count -gt 0) { $cfg.Editions -join ', ' } else { 'see ISO' }
$notes = @"
## $($cfg.BuildTitle)

| | |
|---|---|
| Product | $($cfg.Product) |
| Channel | $($cfg.ChannelLabel) |
| Architecture / language | $($cfg.Architecture) / $($cfg.Language) |
| Editions | $edText |
| Image format | install.$($cfg.ImageFormat) |
| Updates | $($cfg.Updates) |
| Cleanup | $($cfg.Cleanup) |
| .NET 3.5 | $($cfg.NetFx3) |
| Catalog OS update | $OsUpdate |
| Catalog .NET update | $NetUpdate |
| ISO | ``$($iso.Name)`` ($([math]::Round($iso.Length / 1GB, 2)) GB) |
| ISO SHA-256 | ``$isoHash`` |

### Extract

Download **all** parts into one folder and extract the first one:

``````
7z x $base.7z.001
``````

Verify afterwards with ``certutil -hashfile $($iso.Name) SHA256`` and compare with ``$($iso.Name).sha256``.
Individual parts are listed in ``$base.parts.sha256``.

Built with [WinForge ISO](https://github.com/$($env:GITHUB_REPOSITORY)). Windows needs a valid license to activate.
"@
Set-Content -LiteralPath (Join-Path $out 'release-notes.md') -Value $notes -Encoding utf8
Add-GhSummary $notes

Set-GhOutput 'release_dir' $out
Set-GhOutput 'iso_sha256' $isoHash
Set-GhOutput 'part_count' "$($parts.Count)"
Remove-Item -LiteralPath $iso.FullName -Force

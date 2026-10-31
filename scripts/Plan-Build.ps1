#requires -Version 7.0
<#
.SYNOPSIS
  Validates workflow inputs, resolves the exact UUP build and writes the normalized config.
  Runs first so that invalid or unavailable requests fail in seconds.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputConfig,
    [string]$MilestonesPath = (Join-Path (Join-Path $PSScriptRoot '..') 'config/milestones.psd1')
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/WinForge.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/WinForge.Config.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/WinForge.UupDump.psm1') -Force

$map = @{
    Product = 'INPUT_PRODUCT'; Channel = 'INPUT_CHANNEL'; Milestone = 'INPUT_MILESTONE'
    Architecture = 'INPUT_ARCHITECTURE'; Language = 'INPUT_LANGUAGE'; Edition = 'INPUT_EDITION'
    Updates = 'INPUT_UPDATES'; Cleanup = 'INPUT_CLEANUP'; NetFx3 = 'INPUT_NETFX3'
    ImageFormat = 'INPUT_IMAGE_FORMAT'; SkipWinRE = 'INPUT_SKIP_WINRE'; SkipEdge = 'INPUT_SKIP_EDGE'
    UpdateBootFiles = 'INPUT_UPDATE_BOOT_FILES'; StoreApps = 'INPUT_STORE_APPS'; StubAppsFull = 'INPUT_STUB_APPS_FULL'
    VirtualEditions = 'INPUT_VIRTUAL_EDITIONS'; DriversUrl = 'INPUT_DRIVERS_URL'; LtscBaseIsoUrl = 'INPUT_LTSC_BASE_ISO_URL'
    CatalogUpdate = 'INPUT_CATALOG_UPDATE'; PartSizeMB = 'INPUT_PART_SIZE_MB'; ArchiveMode = 'INPUT_ARCHIVE_MODE'
    PublishRelease = 'INPUT_PUBLISH_RELEASE'; PlanOnly = 'INPUT_PLAN_ONLY'
}
$raw = @{}
foreach ($k in $map.Keys) {
    $v = [Environment]::GetEnvironmentVariable($map[$k])
    if ($null -ne $v -and $v.Trim() -ne '') { $raw[$k] = $v }
}

try { $cfg = Resolve-WinForgeConfig -Raw $raw }
catch { Stop-Build "Invalid configuration: $($_.Exception.Message)" }

Write-Section 'Resolve UUP build'
$table = Import-PowerShellDataFile -Path $MilestonesPath
$build = $null
try { $build = Resolve-UupBuild -Config ([pscustomobject]$cfg) -Table $table }
catch { Stop-Build $_.Exception.Message }
Close-Section

$buildMajor = 0
if ($build.BuildNumber -match '^(\d{5})') { $buildMajor = [int]$Matches[1] }
if ($cfg.NetFx3 -and $buildMajor -ge 27965 -and $cfg.IsClient) {
    Write-Warn '.NET Framework 3.5 is not part of Windows 11 builds 27965 and later; the converter skips it automatically.'
}

$date = [DateTime]::UtcNow.ToString('yyyyMMdd')
$tag = Get-ReleaseTag -Config ([pscustomobject]$cfg) -BuildNumber $build.BuildNumber -Date $date
if ($env:GITHUB_RUN_NUMBER) { $tag += "-r$($env:GITHUB_RUN_NUMBER)" }   # unique per run, reruns never collide

$cfg['Uuid'] = $build.Uuid
$cfg['BuildTitle'] = $build.Title
$cfg['BuildNumber'] = $build.BuildNumber
$cfg['ChannelLabel'] = $build.ChannelLabel
$cfg['ReleaseTag'] = $tag
$cfg['BuildDate'] = $date

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputConfig) | Out-Null
$cfg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputConfig -Encoding utf8

Set-GhOutput 'release_tag' $tag
Set-GhOutput 'build_title' $build.Title
Set-GhOutput 'build_number' $build.BuildNumber
Set-GhOutput 'plan_only' ([string]$cfg.PlanOnly).ToLowerInvariant()

$editionText = if ($cfg.Editions.Count -gt 0) { $cfg.Editions -join ', ' } else { 'from base ISO' }
$virtualText = if (@($cfg.VirtualEditions).Count -gt 0) { @($cfg.VirtualEditions) -join ', ' } else { '-' }
Add-GhSummary @"
## Build plan

| Setting | Value |
|---|---|
| Product | $($cfg.Product) |
| Resolved build | $($build.Title) |
| Channel | $($build.ChannelLabel) |
| Architecture / language | $($cfg.Architecture) / $($cfg.Language) |
| Editions | $editionText |
| Virtual editions | $virtualText |
| Updates / cleanup | $($cfg.Updates) / $($cfg.Cleanup) |
| .NET 3.5 | $($cfg.NetFx3) |
| Image format | $($cfg.ImageFormat) |
| Store apps | $($cfg.StoreApps) |
| Release tag | ``$tag`` |
"@
Write-Host "Plan complete: $($build.Title)  ->  $tag"

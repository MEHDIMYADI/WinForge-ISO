#requires -Version 7.0
<#
.SYNOPSIS
  Offline servicing for Windows Server 2025 and Windows 11 LTSC 2024 ISOs:
  latest cumulative update + .NET update from the Microsoft Update Catalog, .NET 3.5, drivers,
  component cleanup, image export (WIM/ESD/SWM) and bootable ISO rebuild.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$BaseIsoPath,
    [string]$MilestonesPath = (Join-Path (Join-Path $PSScriptRoot '..') 'config/milestones.psd1')
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/WinForge.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/WinForge.Catalog.psm1') -Force

$cfg = Read-WinForgeConfig -Path $ConfigPath
$work = Get-WorkRoot
$svc = Join-Path $work 'servicing'
$isoDir = Join-Path $svc 'iso'
$mount = Join-Path $svc 'mount'
$cdimage = Join-Path $work 'converter/bin/cdimage.exe'

if (-not (Test-Path -LiteralPath $BaseIsoPath)) { Stop-Build "Base ISO not found: $BaseIsoPath" }
if (-not (Test-Path -LiteralPath $cdimage)) { Stop-Build 'cdimage.exe not found; run Install-Tools.ps1 first.' }
Assert-FreeSpace -Path $work -MinGB 40

function Invoke-Dism {
    param([string[]]$Arguments, [int[]]$Allowed = @(0, 3010))
    & dism.exe @Arguments | Out-Host
    $code = $LASTEXITCODE
    if ($code -notin $Allowed) { Stop-Build "dism.exe $($Arguments[0]) failed with exit code $code" }
    return $code
}

function Get-WimIndexes {
    param([string]$Wim)
    $out = & dism.exe /English /Get-WimInfo "/WimFile:$Wim"
    if ($LASTEXITCODE -ne 0) { Stop-Build "dism /Get-WimInfo failed for $Wim" }
    $items = @(); $idx = $null
    foreach ($line in $out) {
        if ($line -match '^\s*Index\s*:\s*(\d+)') { $idx = [int]$Matches[1] }
        elseif ($line -match '^\s*Name\s*:\s*(.+)$' -and $null -ne $idx) { $items += [pscustomobject]@{ Index = $idx; Name = $Matches[1].Trim() }; $idx = $null }
    }
    if ($items.Count -eq 0) { Stop-Build "No images found in $Wim" }
    return $items
}

function Get-MountedVersion {
    param([string]$MountDir)
    $hive = Join-Path $MountDir 'Windows/System32/config/SOFTWARE'
    & reg.exe load 'HKLM\WF_OFFLINE' $hive | Out-Null
    if ($LASTEXITCODE -ne 0) { Stop-Build 'Could not load the offline SOFTWARE hive.' }
    try {
        $v = Get-ItemProperty 'HKLM:\WF_OFFLINE\Microsoft\Windows NT\CurrentVersion'
        return "$($v.CurrentBuildNumber).$($v.UBR)"
    }
    finally { [GC]::Collect(); & reg.exe unload 'HKLM\WF_OFFLINE' | Out-Null }
}

function Add-PackagesFrom {
    param([string]$MountDir, [string]$Folder, [switch]$Optional)
    if (-not (Test-Path -LiteralPath $Folder) -or -not (Get-ChildItem -LiteralPath $Folder -File -ErrorAction SilentlyContinue)) { return }
    # Pointing DISM at the folder lets it discover checkpoint packages in the right order.
    & dism.exe "/Image:$MountDir" /Add-Package "/PackagePath:$Folder"
    $code = $LASTEXITCODE
    # 0x800f081e / 0x80070228: not applicable or already installed.
    $benign = @(-2146498530, 2148468766, -2147024344, 2147942952)
    if ($code -in @(0, 3010) -or $code -in $benign) { return }
    if ($Optional) { Write-Warn "Optional package integration failed (exit $code); continuing." ; return }
    Stop-Build "Package integration failed with exit code $code"
}

# --- 1. Extract the base ISO -----------------------------------------------------------
Write-Section 'Extract base ISO'
Remove-Item -LiteralPath $svc -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $isoDir, $mount | Out-Null
Invoke-Native -FilePath '7z' -ArgumentList @('x', $BaseIsoPath, "-o$isoDir", '-y', '-bso0', '-bsp0')
Get-ChildItem -LiteralPath $isoDir -Recurse -File | ForEach-Object { if ($_.IsReadOnly) { $_.IsReadOnly = $false } }
$installWim = Join-Path $isoDir 'sources/install.wim'
$installEsd = Join-Path $isoDir 'sources/install.esd'
if (-not (Test-Path -LiteralPath $installWim)) {
    if (Test-Path -LiteralPath $installEsd) {
        Write-Host 'Base ISO contains install.esd; converting to WIM for servicing'
        Invoke-Dism @('/Export-Image', "/SourceImageFile:$installEsd", '/SourceIndex:1', "/DestinationImageFile:$installWim", '/Compress:max', '/CheckIntegrity') | Out-Null
        # Export all remaining indexes
        $all = @(Get-WimIndexes -Wim $installEsd)
        foreach ($i in $all | Where-Object { $_.Index -gt 1 }) {
            Invoke-Dism @('/Export-Image', "/SourceImageFile:$installEsd", "/SourceIndex:$($i.Index)", "/DestinationImageFile:$installWim", '/Compress:max') | Out-Null
        }
        Remove-Item -LiteralPath $installEsd -Force
    }
    else { Stop-Build 'The base ISO has neither sources\install.wim nor install.esd.' }
}
Close-Section

# --- 2. Updates from the Microsoft Update Catalog ----------------------------------------------
$table = Import-PowerShellDataFile -Path $MilestonesPath
$catKey = if ($cfg.IsServer) { 'Server2025' } else { 'Ltsc2024' }
$cat = $table.Catalog[$catKey]
$archName = if ($cfg.Architecture -eq 'arm64') { 'ARM64' } else { 'x64' }

$cuDir = Join-Path $svc 'cu'; $netDir = Join-Path $svc 'net'
$selectedOs = $null; $selectedNet = $null
if ($cfg.CatalogUpdate) {
    Write-Section 'Microsoft Update Catalog'
    $osRows = @(Search-UpdateCatalog -Query ($cat.OsQuery -replace '\{ARCH\}', $archName))
    if ($osRows.Count -eq 0) { Stop-Build 'The Microsoft Update Catalog returned no cumulative updates.' }
    $selectedOs = Select-LatestCatalogUpdate -Entries $osRows -MustMatch 'Cumulative Update' -Exclude @('Preview', 'Out-of-Band', '\.NET', 'Dynamic')
    if (-not $selectedOs) { $selectedOs = Select-LatestCatalogUpdate -Entries $osRows -MustMatch 'Cumulative Update' -Exclude @('\.NET', 'Dynamic') }
    if (-not $selectedOs) { Stop-Build 'No suitable cumulative update found in the catalog results.' }
    Write-Host "OS update : $($selectedOs.Title)"
    [void](Save-CatalogUpdate -Entry $selectedOs -Destination $cuDir)

    try {
        $netRows = @(Search-UpdateCatalog -Query ($cat.NetQuery -replace '\{ARCH\}', $archName))
        $selectedNet = Select-LatestCatalogUpdate -Entries $netRows -MustMatch '\.NET Framework' -Exclude @('Preview')
        if ($selectedNet) {
            Write-Host ".NET update: $($selectedNet.Title)"
            [void](Save-CatalogUpdate -Entry $selectedNet -Destination $netDir)
        }
        else { Write-Warn 'No .NET Framework cumulative update found; skipping.' }
    }
    catch { Write-Warn ".NET update unavailable: $($_.Exception.Message)"; $selectedNet = $null }
    Close-Section
}

# --- 3. Service install.wim --------------------------------------------------------------------
$sxs = Join-Path $isoDir 'sources/sxs'
$hasSxs = Test-Path -LiteralPath $sxs
if ($cfg.NetFx3 -and -not $hasSxs) { Write-Warn '.NET 3.5 requested but sources\sxs is missing in the ISO; skipping .NET 3.5.' }

$drvRoot = Join-Path $work 'drivers'
$osDrivers = @('OS', 'ALL') | ForEach-Object { Join-Path $drvRoot $_ } | Where-Object { Test-Path -LiteralPath $_ }
$peDrivers = @('WinPE', 'ALL') | ForEach-Object { Join-Path $drvRoot $_ } | Where-Object { Test-Path -LiteralPath $_ }

$images = @(Get-WimIndexes -Wim $installWim)
$baseVersion = $null; $patchedVersion = $null
$changed = $false
try {
    foreach ($img in $images) {
        Write-Section "Index $($img.Index): $($img.Name)"
        Invoke-Dism @('/Mount-Image', "/ImageFile:$installWim", "/Index:$($img.Index)", "/MountDir:$mount") | Out-Null
        $before = Get-MountedVersion -MountDir $mount
        if (-not $baseVersion) { $baseVersion = $before }

        if ($cfg.NetFx3 -and $hasSxs) {
            Invoke-Dism @("/Image:$mount", '/Enable-Feature', '/FeatureName:NetFx3', '/All', "/Source:$sxs", '/LimitAccess') | Out-Null
        }
        if ($selectedOs) { Add-PackagesFrom -MountDir $mount -Folder $cuDir }
        if ($selectedNet) { Add-PackagesFrom -MountDir $mount -Folder $netDir -Optional }
        foreach ($d in $osDrivers) { Invoke-Dism @("/Image:$mount", '/Add-Driver', "/Driver:$d", '/Recurse') -Allowed @(0, 3010) | Out-Null }

        $after = Get-MountedVersion -MountDir $mount
        if (-not $patchedVersion) { $patchedVersion = $after }
        Write-Host "Version: $before -> $after"

        Invoke-Dism @('/Unmount-Image', "/MountDir:$mount", '/Commit') | Out-Null

        if ($cfg.Cleanup -ne 'none') {
            Invoke-Dism @('/Mount-Image', "/ImageFile:$installWim", "/Index:$($img.Index)", "/MountDir:$mount") | Out-Null
            $cl = @("/Image:$mount", '/Cleanup-Image', '/StartComponentCleanup')
            if ($cfg.Cleanup -like 'resetbase*') { $cl += '/ResetBase' }
            Invoke-Dism $cl -Allowed @(0, 3010) | Out-Null
            Invoke-Dism @('/Unmount-Image', "/MountDir:$mount", '/Commit') | Out-Null
        }
        $changed = $true
        Close-Section
    }
}
catch {
    Write-Warning "Servicing failed; discarding mounted image. $($_.Exception.Message)"
    & dism.exe /Unmount-Image "/MountDir:$mount" /Discard | Out-Null
    & dism.exe /Cleanup-Wim | Out-Null
    throw
}

# --- 4. WinPE drivers (boot.wim) -----------------------------------------------------------------
$bootWim = Join-Path $isoDir 'sources/boot.wim'
if ($peDrivers.Count -gt 0 -and (Test-Path -LiteralPath $bootWim)) {
    foreach ($bi in @(Get-WimIndexes -Wim $bootWim)) {
        Write-Section "boot.wim index $($bi.Index)"
        Invoke-Dism @('/Mount-Image', "/ImageFile:$bootWim", "/Index:$($bi.Index)", "/MountDir:$mount") | Out-Null
        try { foreach ($d in $peDrivers) { Invoke-Dism @("/Image:$mount", '/Add-Driver', "/Driver:$d", '/Recurse') | Out-Null } }
        catch { & dism.exe /Unmount-Image "/MountDir:$mount" /Discard | Out-Null; throw }
        Invoke-Dism @('/Unmount-Image', "/MountDir:$mount", '/Commit') | Out-Null
        Close-Section
    }
}

# --- 5. Export (compacts the WIM) and convert to the requested format --------------------------
Write-Section 'Export image'
$exported = Join-Path $isoDir 'sources/install.export.wim'
$compress = if ($cfg.ImageFormat -eq 'esd') { 'recovery' } else { 'max' }
$target = if ($cfg.ImageFormat -eq 'esd') { Join-Path $isoDir 'sources/install.esd' } else { $exported }
foreach ($img in $images) {
    Invoke-Dism @('/Export-Image', "/SourceImageFile:$installWim", "/SourceIndex:$($img.Index)", "/DestinationImageFile:$target", "/Compress:$compress") | Out-Null
}
Remove-Item -LiteralPath $installWim -Force
if ($cfg.ImageFormat -eq 'swm') {
    Invoke-Dism @('/Split-Image', "/ImageFile:$exported", "/SWMFile:$(Join-Path $isoDir 'sources/install.swm')", '/FileSize:3800') | Out-Null
    Remove-Item -LiteralPath $exported -Force
}
elseif ($cfg.ImageFormat -eq 'wim') { Move-Item -LiteralPath $exported -Destination $installWim }
Close-Section

# --- 6. Rebuild a bootable ISO ----------------------------------------------------------------------
Write-Section 'Build ISO'
$etfs = Join-Path $isoDir 'boot/etfsboot.com'
$efi = Join-Path $isoDir 'efi/microsoft/boot/efisys.bin'
if (-not (Test-Path -LiteralPath $efi)) { $efi = Join-Path $isoDir 'efi/Microsoft/boot/efisys.bin' }
foreach ($f in @($etfs, $efi)) { if (-not (Test-Path -LiteralPath $f)) { Stop-Build "Boot file missing: $f" } }

$versionTag = if ($patchedVersion) { $patchedVersion } else { $cfg.BuildNumber }
$slug = if ($cfg.IsServer) { 'WindowsServer2025' } else { 'W11_LTSC2024' }
$isoName = "${slug}_${versionTag}_$($cfg.Architecture)_$($cfg.Language).iso"
$label = if ($cfg.IsServer) { 'SERVER2025' } else { 'W11LTSC2024' }
$outIso = Join-Path (Join-Path $work 'converter') $isoName
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outIso) | Out-Null
$bootData = "-bootdata:2#p0,e,b$etfs#pEF,e,b$efi"
Invoke-Native -FilePath $cdimage -ArgumentList @($bootData, '-o', '-m', '-u2', '-udfver102', "-l$label", $isoDir, $outIso)
if (-not (Test-Path -LiteralPath $outIso) -or (Get-Item -LiteralPath $outIso).Length -lt 1GB) { Stop-Build 'cdimage did not produce a valid ISO.' }
Close-Section

Remove-Item -LiteralPath $svc -Recurse -Force -ErrorAction SilentlyContinue
if ($BaseIsoPath -ne $outIso -and $BaseIsoPath.StartsWith($work)) { Remove-Item -LiteralPath $BaseIsoPath -Force -ErrorAction SilentlyContinue }
Set-GhOutput 'iso_path' $outIso
Set-GhOutput 'patched_version' "$versionTag"
Set-GhOutput 'os_update' $(if ($selectedOs) { $selectedOs.Title } else { 'none' })
Set-GhOutput 'net_update' $(if ($selectedNet) { $selectedNet.Title } else { 'none' })
Write-Host "ISO ready: $outIso (base $baseVersion -> $patchedVersion)"

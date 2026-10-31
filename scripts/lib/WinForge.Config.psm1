#requires -Version 7.0
Set-StrictMode -Version Latest

$script:Products          = @('Windows 11', 'Windows 10', 'Windows Server 2025', 'Windows 11 LTSC 2024')
$script:Channels          = @('Retail', 'ReleasePreview', 'Beta', 'Experimental')
$script:Milestones        = @('27H2', '26H2', '26H1', '25H2', '24H2')
$script:Architectures     = @('amd64', 'arm64', 'x86')
$script:ClientEditions    = @('PROFESSIONAL', 'PROFESSIONALN', 'CORE', 'COREN', 'CORESINGLELANGUAGE', 'CORECOUNTRYSPECIFIC')
$script:ServerEditions    = @('SERVERSTANDARD', 'SERVERSTANDARDCORE', 'SERVERDATACENTER', 'SERVERDATACENTERCORE')
$script:VirtualEditions   = @(
    'Education', 'EducationN', 'Enterprise', 'EnterpriseN',
    'ProfessionalEducation', 'ProfessionalEducationN',
    'ProfessionalWorkstation', 'ProfessionalWorkstationN', 'IoTEnterprise'
)
$script:UpdateModes       = @('integrate', 'none', 'external')
$script:CleanupModes      = @('none', 'cleanup', 'resetbase', 'resetbase-per-lcu')
$script:ImageFormats      = @('wim', 'esd', 'swm')
$script:StoreAppModes     = @('all', 'level1', 'level2', 'level3', 'level4', 'none')
$script:ArchiveModes      = @('store', 'normal', 'ultra')

function ConvertTo-Bool {
    param($Value, [bool]$Default = $false)
    if ($null -eq $Value -or "$Value".Trim() -eq '') { return $Default }
    switch -Regex ("$Value".Trim().ToLowerInvariant()) {
        '^(true|1|yes|y|on)$'  { return $true }
        '^(false|0|no|n|off)$' { return $false }
        default { throw "Cannot interpret '$Value' as a boolean." }
    }
}

function Resolve-WinForgeConfig {
    <#
      Validates raw workflow inputs and returns a normalized configuration object.
      Throws a descriptive error for every invalid or conflicting combination, so a bad
      request fails in seconds instead of after hours of downloading.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Raw)

    function Get-Raw { param([string]$Key, $Default = '') if ($Raw.ContainsKey($Key) -and $null -ne $Raw[$Key]) { "$($Raw[$Key])".Trim() } else { $Default } }

    $product = Get-Raw 'Product' 'Windows 11'
    if ($product -notin $script:Products) { throw "Unsupported product '$product'. Choose one of: $($script:Products -join ', ')." }
    $isClient = $product -in @('Windows 11', 'Windows 10')
    $isServer = $product -eq 'Windows Server 2025'
    $isLtsc   = $product -eq 'Windows 11 LTSC 2024'

    $channel   = Get-Raw 'Channel' 'Retail'
    $milestone = Get-Raw 'Milestone' '25H2'
    if ($channel -notin $script:Channels)     { throw "Unsupported channel '$channel'." }
    if ($milestone -notin $script:Milestones) { throw "Unsupported milestone '$milestone'." }

    $arch = (Get-Raw 'Architecture' 'amd64').ToLowerInvariant()
    if ($arch -notin $script:Architectures) { throw "Unsupported architecture '$arch'." }

    $language = (Get-Raw 'Language' 'en-us').ToLowerInvariant()
    if ($language -notmatch '^[a-z]{2,3}(-[a-z]{2,4}){1,2}$') {
        throw "Invalid language code '$language'. Expected a UUP dump code such as en-us, fa-ir, zh-cn or sr-latn-rs."
    }

    # --- Product / architecture / channel rules --------------------------------------
    if ($product -eq 'Windows 11' -and $arch -eq 'x86') { throw 'Windows 11 is not available for x86.' }
    if (($isServer -or $isLtsc) -and $arch -ne 'amd64') { throw "$product supports amd64 only." }

    if ($product -eq 'Windows 11') {
        if ($channel -in @('Retail', 'ReleasePreview')) {
            if ($milestone -eq '27H2') { throw 'Windows 11 27H2 has no retail build. Use the Experimental channel.' }
            if ($milestone -eq '26H1' -and $arch -ne 'arm64') { throw 'Windows 11 26H1 is available for arm64 only in Retail/ReleasePreview.' }
        }
    }
    else {
        # Channel and milestone only apply to Windows 11; normalize so release tags stay stable.
        $channel = 'Retail'
        $milestone = if ($isClient) { '22H2' } else { '24H2' }
    }

    # --- Editions ---------------------------------------------------------------------
    $editionRaw = Get-Raw 'Edition' $(if ($isServer) { 'SERVERSTANDARD' } else { 'PROFESSIONAL' })
    $editions = @($editionRaw -split '[,;\s]+' | Where-Object { $_ } | ForEach-Object { $_.ToUpperInvariant() } | Select-Object -Unique)
    if ($isLtsc) {
        $editions = @()   # LTSC editions come from the supplied base ISO
    }
    else {
        if ($editions.Count -eq 0) { throw 'At least one edition is required.' }
        $allowed = if ($isServer) { $script:ServerEditions } else { $script:ClientEditions }
        foreach ($e in $editions) {
            if ($e -notin $allowed) { throw "Edition '$e' is not valid for $product. Allowed: $($allowed -join ', ')." }
        }
    }

    # --- Updates / cleanup --------------------------------------------------------------
    $updates = (Get-Raw 'Updates' 'integrate').ToLowerInvariant()
    if ($updates -notin $script:UpdateModes) { throw "Invalid updates mode '$updates'. Allowed: $($script:UpdateModes -join ', ')." }
    $catalogUpdate = ConvertTo-Bool (Get-Raw 'CatalogUpdate' 'true') $true
    # Server and LTSC receive their updates from the Microsoft Update Catalog.
    if (($isServer -or $isLtsc) -and $catalogUpdate) { $updates = 'integrate' }
    $cleanup = (Get-Raw 'Cleanup' 'resetbase').ToLowerInvariant()
    if ($cleanup -notin $script:CleanupModes) { throw "Invalid cleanup mode '$cleanup'. Allowed: $($script:CleanupModes -join ', ')." }
    if ($cleanup -ne 'none' -and $updates -ne 'integrate') {
        throw "Cleanup mode '$cleanup' requires updates mode 'integrate' (components are only superseded after updates are installed)."
    }

    $imageFormat = (Get-Raw 'ImageFormat' 'wim').ToLowerInvariant()
    if ($imageFormat -notin $script:ImageFormats) { throw "Invalid image format '$imageFormat'." }

    $storeApps = (Get-Raw 'StoreApps' 'all').ToLowerInvariant()
    if ($storeApps -notin $script:StoreAppModes) { throw "Invalid store apps mode '$storeApps'." }

    # --- Virtual editions ---------------------------------------------------------------
    $virtualRaw = Get-Raw 'VirtualEditions' ''
    $virtual = @($virtualRaw -split '[,;\s]+' | Where-Object { $_ })
    $virtualCanon = @()
    foreach ($v in $virtual) {
        $match = $script:VirtualEditions | Where-Object { $_ -ieq $v } | Select-Object -First 1
        if (-not $match) { throw "Unknown virtual edition '$v'. Allowed: $($script:VirtualEditions -join ', ')." }
        if ($match -notin $virtualCanon) { $virtualCanon += $match }
    }
    if ($virtualCanon.Count -gt 0 -and -not $isClient) { throw 'Virtual editions are only supported for Windows 10/11 client builds.' }

    # --- External inputs ------------------------------------------------------------------
    $driversUrl = Get-Raw 'DriversUrl' ''
    if ($driversUrl -and $driversUrl -notmatch '^https://') { throw 'Drivers URL must start with https://' }
    $ltscUrl = Get-Raw 'LtscBaseIsoUrl' ''
    if ($isLtsc) {
        if (-not $ltscUrl) { throw 'Windows 11 LTSC 2024 requires a base ISO URL (ltsc_base_iso_url).' }
        if ($ltscUrl -notmatch '^https://') { throw 'LTSC base ISO URL must start with https://' }
    }
    elseif ($ltscUrl) { Write-Warning 'ltsc_base_iso_url is ignored for this product.' }

    $partSize = [int](Get-Raw 'PartSizeMB' '1900')
    if ($partSize -lt 100 -or $partSize -gt 1990) { throw 'Release part size must be between 100 and 1990 MB (GitHub release assets are limited to 2 GiB).' }

    $archiveMode = (Get-Raw 'ArchiveMode' 'store').ToLowerInvariant()
    if ($archiveMode -notin $script:ArchiveModes) { throw "Invalid archive mode '$archiveMode'." }

    if ($isLtsc -and -not $catalogUpdate -and $updates -eq 'none') { Write-Warning 'LTSC: no updates, .NET or drivers will be applied; the output equals the base ISO.' }

    [ordered]@{
        Product         = $product
        Channel         = $channel
        Milestone       = $milestone
        Architecture    = $arch
        Language        = $language
        Editions        = $editions
        Updates         = $updates
        Cleanup         = $cleanup
        NetFx3          = ConvertTo-Bool (Get-Raw 'NetFx3' 'true') $true
        ImageFormat     = $imageFormat
        SkipWinRE       = ConvertTo-Bool (Get-Raw 'SkipWinRE' 'false')
        SkipEdge        = ConvertTo-Bool (Get-Raw 'SkipEdge' 'false')
        UpdateBootFiles = ConvertTo-Bool (Get-Raw 'UpdateBootFiles' 'false')
        StoreApps       = $storeApps
        StubAppsFull    = ConvertTo-Bool (Get-Raw 'StubAppsFull' 'true') $true
        VirtualEditions = $virtualCanon
        DriversUrl      = $driversUrl
        LtscBaseIsoUrl  = $ltscUrl
        CatalogUpdate   = $catalogUpdate
        PartSizeMB      = $partSize
        ArchiveMode     = $archiveMode
        PublishRelease  = ConvertTo-Bool (Get-Raw 'PublishRelease' 'true') $true
        PlanOnly        = ConvertTo-Bool (Get-Raw 'PlanOnly' 'false')
        IsClient        = $isClient
        IsServer        = $isServer
        IsLtsc          = $isLtsc
    }
}

function New-ConverterIni {
    <#
      Builds ConvertConfig.ini text for abbodi1406's uup-converter-wimlib from a normalized config.
      Key names are exactly those the converter reads (see convert-UUP.cmd :ReadINI).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [bool]$HasDrivers = $false
    )

    $serviced = [bool]$Config.IsServer   # Server is finished by Invoke-CatalogServicing (cleanup, format)
    $addUpdates = switch ($Config.Updates) { 'integrate' { 1 } 'external' { 2 } default { 0 } }
    $cleanupVal = if ($Config.Cleanup -eq 'none' -or $serviced) { 0 } else { 1 }
    $resetBase  = if ($serviced) { 0 } else { switch ($Config.Cleanup) { 'resetbase' { 1 } 'resetbase-per-lcu' { 2 } default { 0 } } }
    $autoStart  = if ($Config.ImageFormat -eq 'esd' -and -not $serviced) { 2 } else { 1 }
    $wim2esd    = if ($Config.ImageFormat -eq 'esd' -and -not $serviced) { 1 } else { 0 }
    $wim2swm    = if ($Config.ImageFormat -eq 'swm' -and -not $serviced) { 1 } else { 0 }
    $hasVirtual = @($Config.VirtualEditions).Count -gt 0

    $skipApps = if ($Config.StoreApps -eq 'none') { 1 } else { 0 }
    $appsLevel = switch ($Config.StoreApps) { 'level1' { 1 } 'level2' { 2 } 'level3' { 3 } 'level4' { 4 } default { 0 } }

    $lines = @(
        '[convert-UUP]'
        "AutoStart=$autoStart"
        "AddUpdates=$addUpdates"
        "Cleanup=$cleanupVal"
        "ResetBase=$resetBase"
        "NetFx3=$([int]$Config.NetFx3)"
        "StartVirtual=$([int]$hasVirtual)"
        "wim2esd=$wim2esd"
        "wim2swm=$wim2swm"
        'SkipISO=0'
        "SkipWinRE=$([int]$Config.SkipWinRE)"
        'LCUwinre=0'
        'LCUmsuExpand=0'
        "UpdtBootFiles=$([int]$Config.UpdateBootFiles)"
        'ForceDism=0'
        'RefESD=0'
        'SkipLCUmsu=0'
        "SkipEdge=$([int]$Config.SkipEdge)"
        'AutoExit=1'
        'DisableUpdatingUpgrade=0'
        "AddDrivers=$([int]$HasDrivers)"
        'Drv_Source=\Drivers'
        ''
        '[Store_Apps]'
        "SkipApps=$skipApps"
        "AppsLevel=$appsLevel"
        "StubAppsFull=$([int]$Config.StubAppsFull)"
        'CustomList=0'
        ''
        '[create_virtual_editions]'
        'vUseDism=1'
        "vAutoStart=$([int]$hasVirtual)"
        'vDeleteSource=0'
        'vPreserve=0'
        "vwim2esd=$wim2esd"
        "vwim2swm=$wim2swm"
        'vSkipISO=0'
        "vAutoEditions=$(@($Config.VirtualEditions) -join ',')"
        'vSortEditions='
    )
    return ($lines -join "`r`n") + "`r`n"
}

function Get-ReleaseTag {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$BuildNumber, [Parameter(Mandatory)][string]$Date)
    $slug = ($Config.Product -replace '[^A-Za-z0-9]+', '').ToLowerInvariant()
    $ed = if ($Config.Editions.Count -gt 0) { ($Config.Editions -join '-').ToLowerInvariant() } else { 'ltsc' }
    $tag = "$Date-$slug-$BuildNumber-$($Config.Architecture)-$($Config.Language)-$ed"
    if ($Config.Product -eq 'Windows 11' -and $Config.Channel -ne 'Retail') { $tag += "-$($Config.Channel.ToLowerInvariant())" }
    if (@($Config.VirtualEditions).Count -gt 0) { $tag += '-' + ((@($Config.VirtualEditions) -join '-').ToLowerInvariant()) }
    return $tag
}

Export-ModuleMember -Function Resolve-WinForgeConfig, New-ConverterIni, Get-ReleaseTag, ConvertTo-Bool

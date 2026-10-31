#requires -Version 7.0
# Strict mode is intentionally NOT enabled here: UUP dump JSON objects have variable shapes
# (e.g. no 'error' member on success) and strict mode would turn absent members into exceptions.

$script:ApiBase = 'https://api.uupdump.net'
$script:ApiPauseSec = 10

function Invoke-UupApi {
    # UUP dump answers known errors with HTTP 4xx/5xx plus a JSON body. Those are returned as a
    # normal object (response.error set); rate limits and upstream hiccups are retried.
    param([Parameter(Mandatory)][string]$Uri, [int]$MaxRetries = 5, [int]$BaseDelaySec = 15)
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        $resp = $null
        try { $resp = Invoke-RestMethod -Uri $Uri -Method Get -TimeoutSec 120 }
        catch {
            $body = "$($_.ErrorDetails.Message)"
            if ($body) { try { $resp = $body | ConvertFrom-Json } catch { $resp = $null } }
            if (-not $resp) {
                if ($attempt -lt $MaxRetries) {
                    $delay = $BaseDelaySec * $attempt
                    Write-Warning "Request failed ($($_.Exception.Message)); retrying in ${delay}s ($attempt/$MaxRetries)"
                    Start-Sleep -Seconds $delay
                    continue
                }
                throw
            }
        }
        $apiError = "$($resp.response.error)"
        if ($apiError -match 'RATE_LIMITED' -or ($apiError -eq 'WU_REQUEST_FAILED' -and $attempt -lt 3)) {
            $delay = $BaseDelaySec * $attempt
            Write-Warning "UUP dump returned $apiError; waiting ${delay}s ($attempt/$MaxRetries)"
            Start-Sleep -Seconds $delay
            continue
        }
        return $resp
    }
    throw "UUP dump API still failing after $MaxRetries attempts: $Uri"
}

function ConvertTo-BuildList {
    # listid.php returns "builds" as an array or as an object keyed by index.
    param($Builds)
    if ($null -eq $Builds) { return @() }
    if ($Builds -is [System.Array]) { return @($Builds) }
    return @($Builds.PSObject.Properties | ForEach-Object { $_.Value })
}

function Find-ListIdBuild {
    param([string]$Search, [string]$TitlePattern, [string]$BuildPattern, [string]$Arch)
    $uri = "$script:ApiBase/listid.php?search=$([uri]::EscapeDataString($Search))&sortByDate=1"
    Write-Host "Searching UUP dump database: $uri"
    $resp = Invoke-UupApi -Uri $uri
    if ($resp.response.error) { Write-Warning "listid returned $($resp.response.error)"; return $null }
    foreach ($b in (ConvertTo-BuildList $resp.response.builds)) {
        if ($b.arch -ne $Arch) { continue }
        if ("$($b.title)" -notmatch $TitlePattern) { continue }
        if ("$($b.build)" -notmatch $BuildPattern) { continue }
        return [pscustomobject]@{ Uuid = $b.uuid; Title = $b.title; Build = $b.build }
    }
    return $null
}

function Select-OsUpdate {
    # Picks the OS build from a fetchupd updateArray (skips .NET, OOBE, servicing stack ...).
    # Feature updates / Insider flights ("Windows 11*") win over e.g. "Preview Update for Windows 11".
    param($Updates, [string]$BuildPattern, [string]$Arch)
    $skip = 'Framework|Stack Package|Servicing Stack|OOBE|Feature Experience Pack|Autopilot|Microsoft Edge|Malicious Software|Hotpatch|Defender|Safe OS|Dynamic Update'
    foreach ($preferFeature in @($true, $false)) {
        foreach ($u in $Updates) {
            $title = "$($u.updateTitle)"
            $found = "$($u.foundBuild)"
            if ($Arch -and $u.arch -and $u.arch -ne $Arch) { continue }
            if ($found -notmatch '^\d{5}\.\d+$') { continue }
            if ($found -notmatch $BuildPattern) { continue }
            if ($title -match $skip) { continue }
            if ($preferFeature -and $title -notlike 'Windows 11*') { continue }
            return [pscustomobject]@{ Uuid = $u.updateId; Title = $u.updateTitle; Build = $found }
        }
    }
    return $null
}

function Invoke-FetchUpd {
    param([string]$Arch, [string]$Ring, [string]$Build, [string]$BuildPattern, [string]$WantArch)
    $uri = "$script:ApiBase/fetchupd.php?arch=$Arch&ring=$Ring"
    if ($Build) { $uri += "&build=$Build" }
    Write-Host "Querying fetchupd: $uri"
    $resp = Invoke-UupApi -Uri $uri
    if ($resp.response.error) { Write-Host "  API returned: $($resp.response.error)"; return $null }
    $updates = @($resp.response.updateArray)
    if ($updates.Count -eq 0) { Write-Host '  empty updateArray'; return $null }
    Write-Host "  $($updates.Count) update(s): $(($updates | ForEach-Object { "$($_.updateTitle) [$($_.arch)]" }) -join '; ')"
    return Select-OsUpdate -Updates $updates -BuildPattern $BuildPattern -Arch $WantArch
}

function Find-FetchUpdBuild {
    # Tries each candidate base build for the requested architecture, then again with arch=all
    # (Windows Update refuses some arm64-only offers unless requested for all architectures).
    param([string]$Ring, [string[]]$BuildCandidates, [string]$BuildPattern, [string]$Arch)
    foreach ($archMode in @($Arch, 'all')) {
        foreach ($build in $BuildCandidates) {
            $found = Invoke-FetchUpd -Arch $archMode -Ring $Ring -Build $build -BuildPattern $BuildPattern -WantArch $Arch
            if ($found) { Write-Host "Matched via ring=$Ring build=$build arch=$archMode"; return $found }
            Write-Host "  no match for pattern $BuildPattern; waiting ${script:ApiPauseSec}s"
            Start-Sleep -Seconds $script:ApiPauseSec
        }
    }
    return $null
}

function Resolve-UupBuild {
    <# Returns @{ Uuid; Title; BuildNumber; ChannelLabel } for a normalized config, or throws. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][hashtable]$Table)

    $arch = $Config.Architecture
    $found = $null
    $label = $Config.Channel

    switch ($Config.Product) {
        'Windows 10' {
            $t = $Table.Windows10
            $found = Find-ListIdBuild -Search $t.Search -TitlePattern $t.TitlePattern -BuildPattern $t.BuildPattern -Arch $arch
            $label = 'Retail'
        }
        { $_ -in @('Windows Server 2025') } {
            $t = $Table.Server2025
            $found = Find-ListIdBuild -Search $t.Search -TitlePattern $t.TitlePattern -BuildPattern $t.BuildPattern -Arch $arch
            $label = 'Retail'
        }
        'Windows 11 LTSC 2024' {
            # LTSC is built from a user-supplied base ISO; there is no UUP build to resolve.
            return [pscustomobject]@{ Uuid = ''; Title = 'Windows 11 Enterprise LTSC 2024'; BuildNumber = '26100'; ChannelLabel = 'LTSC' }
        }
        'Windows 11' {
            $cfg = $Table.Windows11[$Config.Milestone]
            if (-not $cfg) { throw "No milestone table entry for $($Config.Milestone)." }
            switch ($Config.Channel) {
                { $_ -in @('Retail', 'ReleasePreview') } {
                    $ring = if ($Config.Channel -eq 'Retail') { 'RETAIL' } else { 'RP' }
                    if (@($cfg.RetailBuilds).Count -eq 0) { throw "Windows 11 $($Config.Milestone) is not available in $($Config.Channel). Use Experimental." }
                    $found = Find-FetchUpdBuild -Ring $ring -BuildCandidates $cfg.RetailBuilds -BuildPattern $cfg.RetailPattern -Arch $arch
                    if (-not $found) {
                        Write-Warning 'fetchupd returned nothing usable; falling back to the UUP dump build database'
                        $found = Find-ListIdBuild -Search "Windows 11, version $($Config.Milestone)" `
                            -TitlePattern "^Windows 11, version $($Config.Milestone) \(" -BuildPattern $cfg.RetailPattern -Arch $arch
                    }
                    $label = if ($Config.Channel -eq 'Retail') { 'Retail' } else { 'Release Preview' }
                }
                'Beta' {
                    $b = $Table.Beta
                    $found = Find-FetchUpdBuild -Ring 'BETA' -BuildCandidates $b.Builds -BuildPattern $b.Pattern -Arch $arch
                    if (-not $found) {
                        $found = Find-ListIdBuild -Search 'Windows 11 Insider Preview' -TitlePattern '^Windows 11 Insider Preview' -BuildPattern '^26[2-3]\d{2}\.' -Arch $arch
                    }
                    $label = 'Beta'
                }
                'Experimental' {
                    $found = Find-FetchUpdBuild -Ring $cfg.ExpRing -BuildCandidates $cfg.ExpBuilds -BuildPattern $cfg.ExpPattern -Arch $arch
                    if (-not $found) {
                        $found = Find-ListIdBuild -Search 'Windows 11 Insider Preview' -TitlePattern '^Windows 11 Insider Preview' -BuildPattern $cfg.ExpPattern -Arch $arch
                    }
                    $label = "Experimental ($($cfg.Label))"
                }
            }
        }
    }

    if (-not $found) { throw "No matching UUP build found for $($Config.Product) $($Config.Milestone) ($arch) in channel $($Config.Channel)." }

    $number = 'unknown'
    if ($found.Title -match '(\d{5}\.\d+)') { $number = $Matches[1] }
    elseif ($found.Title -match '(\d{5})') { $number = $Matches[1] }

    return [pscustomobject]@{ Uuid = $found.Uuid; Title = $found.Title; BuildNumber = $number; ChannelLabel = $label }
}

function New-Aria2List {
    <# Fetches the file list (plus Store app packages when present) and writes an aria2 input file. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uuid,
        [Parameter(Mandatory)][string]$Language,
        [Parameter(Mandatory)][string[]]$Editions,
        [Parameter(Mandatory)][string]$OutFile
    )
    $edition = ($Editions -join ';')
    Start-Sleep -Seconds $script:ApiPauseSec
    $resp = Invoke-UupApi -Uri "$script:ApiBase/get.php?id=$Uuid&lang=$Language&edition=$([uri]::EscapeDataString($edition))"
    if ($resp.response.error) { throw "UUP dump get.php error: $($resp.response.error)" }
    $files = $resp.response.files
    if (-not $files) { throw 'UUP dump returned no files for this build/language/edition.' }

    $entries = [ordered]@{}
    foreach ($p in $files.PSObject.Properties) { $entries[$p.Name] = $p.Value }

    if ($resp.response.appxPresent -eq $true) {
        Write-Host 'Store app packages detected; fetching the app file list'
        $apps = $null
        for ($i = 1; $i -le 3 -and -not $apps; $i++) {
            Start-Sleep -Seconds $script:ApiPauseSec
            try {
                $r = Invoke-UupApi -Uri "$script:ApiBase/get.php?id=$Uuid&lang=neutral&edition=APP"
                if ($r.response.error) { Write-Warning "APP list error: $($r.response.error)" } else { $apps = $r.response.files }
            }
            catch { Write-Warning "APP list request failed: $_" }
        }
        if (-not $apps) { throw 'Failed to fetch the Store app package list after 3 attempts.' }
        foreach ($p in $apps.PSObject.Properties) { $entries[$p.Name] = $p.Value }
    }

    $sb = [System.Text.StringBuilder]::new()
    $count = 0; $total = [long]0
    foreach ($name in $entries.Keys) {
        $info = $entries[$name]
        if (-not $info.url) { continue }
        [void]$sb.AppendLine($info.url)
        [void]$sb.AppendLine("  out=$name")
        if ($info.sha1) { [void]$sb.AppendLine("  checksum=sha-1=$($info.sha1)") }
        [void]$sb.AppendLine('')
        $count++; $total += [long]$info.size
    }
    if ($count -eq 0) { throw 'No downloadable files in the UUP dump response (all entries lack URLs).' }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutFile) | Out-Null
    [System.IO.File]::WriteAllText($OutFile, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{ FileCount = $count; TotalGB = [math]::Round($total / 1GB, 2) }
}

Export-ModuleMember -Function Invoke-UupApi, ConvertTo-BuildList, Find-ListIdBuild, Select-OsUpdate, Resolve-UupBuild, New-Aria2List

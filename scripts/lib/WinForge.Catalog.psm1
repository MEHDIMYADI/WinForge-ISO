#requires -Version 7.0
Set-StrictMode -Version Latest

$script:CatalogBase = 'https://www.catalog.update.microsoft.com'
$script:UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'

function ConvertFrom-CatalogHtml {
    # Extracts GUID + title pairs from a Search.aspx result page.
    param([Parameter(Mandatory)][string]$Html)
    $pattern = '<a[^>]*goToDetails\("([a-f0-9\-]+)"\)[^>]*>\s*(.*?)\s*</a>'
    $found = [regex]::Matches($Html, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $seen = @{}
    foreach ($m in $found) {
        $guid = $m.Groups[1].Value
        if ($seen.ContainsKey($guid)) { continue }
        $seen[$guid] = $true
        [pscustomobject]@{
            GUID  = $guid
            Title = [System.Net.WebUtility]::HtmlDecode(($m.Groups[2].Value -replace '<[^>]+>', '')).Trim()
        }
    }
}

function Search-UpdateCatalog {
    param([Parameter(Mandatory)][string]$Query, [int]$MaxAttempts = 4)
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-Host "Catalog search ($attempt/$MaxAttempts): $Query"
        try {
            $resp = Invoke-WebRequest -Uri "$script:CatalogBase/Search.aspx?q=$([uri]::EscapeDataString($Query))" `
                -Headers @{ 'User-Agent' = $script:UserAgent } -UseBasicParsing -TimeoutSec 120
            $results = @(ConvertFrom-CatalogHtml -Html $resp.Content)
            if ($results.Count -gt 0) { return $results }
            Write-Warning 'Catalog returned no rows (possible rate limit).'
        }
        catch { Write-Warning "Catalog request failed: $($_.Exception.Message)" }
        if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds (20 * $attempt) }
    }
    return @()
}

function Select-LatestCatalogUpdate {
    # Catalog row order is not guaranteed: rank by "YYYY-MM" title prefix, then OS build, then KB number.
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Entries, [Parameter(Mandatory)][string]$MustMatch, [string[]]$Exclude = @())
    $candidates = @($Entries | Where-Object { $_.Title -match $MustMatch })
    foreach ($pattern in $Exclude) { $candidates = @($candidates | Where-Object { $_.Title -notmatch $pattern }) }
    if ($candidates.Count -eq 0) { return $null }

    $ranked = $candidates | ForEach-Object {
        $ym = 0;    if ($_.Title -match '^\s*(\d{4})-(\d{2})') { $ym = [int]$Matches[1] * 100 + [int]$Matches[2] }
        $build = 0; if ($_.Title -match '\((\d{5})\.(\d+)\)') { $build = [long]$Matches[1] * 1000000 + [long]$Matches[2] }
        $kb = 0;    if ($_.Title -match 'KB(\d+)') { $kb = [long]$Matches[1] }
        [pscustomobject]@{ Entry = $_; YearMonth = $ym; Build = $build; KB = $kb }
    } | Sort-Object -Property @{ Expression = 'YearMonth'; Descending = $true }, @{ Expression = 'Build'; Descending = $true }, @{ Expression = 'KB'; Descending = $true }

    return ($ranked | Select-Object -First 1).Entry
}

function Get-CatalogDownloadUrls {
    param([Parameter(Mandatory)][string]$Guid)
    $json = '[{"size":0,"languages":"","uidInfo":"' + $Guid + '","updateID":"' + $Guid + '"}]'
    $resp = Invoke-WebRequest -Uri "$script:CatalogBase/DownloadDialog.aspx" -Method Post `
        -Body @{ updateIDs = $json } -Headers @{ 'User-Agent' = $script:UserAgent } -UseBasicParsing -TimeoutSec 120
    $urls = [regex]::Matches($resp.Content, "https?://[^'""\s]+\.(msu|cab)") | ForEach-Object { $_.Value } | Select-Object -Unique
    return @($urls)
}

function Save-CatalogUpdate {
    # Downloads every file of a catalog entry and verifies it is a non-empty file.
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][string]$Destination)
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $urls = @(Get-CatalogDownloadUrls -Guid $Entry.GUID)
    if ($urls.Count -eq 0) { throw "No download URLs for catalog entry $($Entry.GUID) ($($Entry.Title))." }
    foreach ($url in $urls) {
        $name = [IO.Path]::GetFileName(($url -split '\?')[0])
        Write-Host "Downloading $name"
        & aria2c --max-connection-per-server=16 --split=16 --max-tries=5 --retry-wait=5 --console-log-level=warn -d $Destination -o $name $url
        if ($LASTEXITCODE -ne 0) { throw "aria2c failed for $url (exit $LASTEXITCODE)" }
        $file = Join-Path $Destination $name
        if (-not (Test-Path -LiteralPath $file) -or (Get-Item -LiteralPath $file).Length -lt 1024) { throw "Downloaded file looks invalid: $file" }
    }
    return @(Get-ChildItem -LiteralPath $Destination -File)
}

Export-ModuleMember -Function ConvertFrom-CatalogHtml, Search-UpdateCatalog, Select-LatestCatalogUpdate, Get-CatalogDownloadUrls, Save-CatalogUpdate

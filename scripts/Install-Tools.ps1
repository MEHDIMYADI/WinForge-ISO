#requires -Version 7.0
<#
.SYNOPSIS
  Downloads the pinned UUP converter (abbodi1406/BatUtil) and, optionally, a drivers archive.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    # Pinned commit: the converter changes often; bump deliberately after testing.
    [string]$ConverterCommit = '4c02e02d86d2f01e4ef556bc6a080382bd21cae4'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/WinForge.Common.psm1') -Force

$cfg = Read-WinForgeConfig -Path $ConfigPath
$work = Get-WorkRoot
New-Item -ItemType Directory -Force -Path $work | Out-Null

function Test-ArchiveMagic {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path) -or (Get-Item -LiteralPath $Path).Length -lt 4) { return $false }
    $h = [byte[]]::new(4)
    $fs = [IO.File]::OpenRead($Path)
    try { [void]$fs.Read($h, 0, 4) } finally { $fs.Dispose() }
    return (($h[0] -eq 0x50 -and $h[1] -eq 0x4B) -or ($h[0] -eq 0x37 -and $h[1] -eq 0x7A))
}

# --- Converter -----------------------------------------------------------------------
if ($true) {
    # The converter is needed for every product: it ships cdimage.exe, wimlib and 7z used for ISO creation.
    Write-Section 'Download UUP converter'
    $zip = Join-Path $work 'batutil.zip'
    $extract = Join-Path $work 'batutil_extract'
    $conv = Join-Path $work 'converter'
    foreach ($p in @($zip, $extract, $conv)) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }

    $url = "https://github.com/abbodi1406/BatUtil/archive/$ConverterCommit.zip"
    Invoke-WithRetry -What 'converter download' -Script {
        Invoke-Native -FilePath 'aria2c' -ArgumentList @('--max-tries=5', '--console-log-level=warn', '-d', $work, '-o', 'batutil.zip', $url)
    }
    if (-not (Test-ArchiveMagic $zip)) { Stop-Build 'Converter download is not a valid archive.' }
    Invoke-Native -FilePath '7z' -ArgumentList @('x', $zip, "-o$extract", '-y', '-bso0', '-bsp0')

    $src = Join-Path $extract "BatUtil-$ConverterCommit/uup-converter-wimlib"
    if (-not (Test-Path -LiteralPath (Join-Path $src 'convert-UUP.cmd'))) { Stop-Build 'convert-UUP.cmd not found in the converter archive.' }
    New-Item -ItemType Directory -Force -Path $conv | Out-Null
    Copy-Item -Path (Join-Path $src '*') -Destination $conv -Recurse -Force
    foreach ($f in @('7z.exe', 'cdimage.exe', 'wimlib-imagex.exe', 'offlinereg.exe')) {
        if (-not (Test-Path -LiteralPath (Join-Path $conv "bin/$f"))) { Stop-Build "Converter is missing bin/$f" }
    }
    Remove-Item -LiteralPath $zip, $extract -Recurse -Force
    Write-Host "Converter ready at $conv (commit $ConverterCommit)"
    Close-Section
}

# --- Drivers ----------------------------------------------------------------------------
if ($cfg.DriversUrl) {
    Write-Section 'Download drivers'
    $drvZip = Join-Path $work 'drivers.zip'
    $drvDir = Join-Path $work 'drivers'
    Remove-Item -LiteralPath $drvZip, $drvDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $drvDir | Out-Null

    $ok = $false
    foreach ($method in @('curl-get', 'curl-post', 'aria2')) {
        Remove-Item -LiteralPath $drvZip -Force -ErrorAction SilentlyContinue
        switch ($method) {
            'curl-get'  { & curl.exe -L -f -sS --retry 3 -o $drvZip $cfg.DriversUrl }
            'curl-post' { & curl.exe -L -f -sS -X POST -o $drvZip $cfg.DriversUrl }
            'aria2'     { & aria2c --console-log-level=warn -d $work -o drivers.zip $cfg.DriversUrl }
        }
        if (Test-ArchiveMagic $drvZip) { $ok = $true; break }
        Write-Warning "Drivers download via $method did not produce a valid archive."
    }
    if (-not $ok) { Stop-Build 'Could not download a valid drivers archive (zip or 7z) from the given URL.' }

    Invoke-Native -FilePath '7z' -ArgumentList @('x', $drvZip, "-o$drvDir", '-y', '-bso0', '-bsp0')
    Remove-Item -LiteralPath $drvZip -Force
    $inf = @(Get-ChildItem -LiteralPath $drvDir -Recurse -Filter '*.inf' -File)
    if ($inf.Count -eq 0) { Stop-Build 'The drivers archive contains no .inf files.' }
    $targets = @('OS', 'WinPE', 'ALL') | Where-Object { Test-Path -LiteralPath (Join-Path $drvDir $_) }
    if (-not $targets) { Stop-Build 'The drivers archive must contain at least one of the folders OS/, WinPE/ or ALL/.' }
    Write-Host "Drivers: $($inf.Count) .inf files in folders: $($targets -join ', ')"
    Close-Section
}

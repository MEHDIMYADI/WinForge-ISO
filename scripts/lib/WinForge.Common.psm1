#requires -Version 7.0
Set-StrictMode -Version Latest

function Write-Section {
    param([Parameter(Mandatory)][string]$Title)
    Write-Host ''
    Write-Host "::group::$Title"
}

function Close-Section { Write-Host '::endgroup::' }

function Write-Warn { param([string]$Message) Write-Host "::warning::$Message" }

function Stop-Build {
    # Single exit point for fatal errors: annotate, then throw so callers/finally blocks run.
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "::error::$Message"
    throw $Message
}

function Set-GhOutput {
    param([Parameter(Mandatory)][string]$Name, [AllowEmptyString()][string]$Value = '')
    if ($Value -match "[\r\n]") { Stop-Build "Output '$Name' contains a newline." }
    if ($env:GITHUB_OUTPUT) { "$Name=$Value" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8 }
    else { Write-Host "[output] $Name=$Value" }
}

function Add-GhSummary {
    param([Parameter(Mandatory)][string]$Markdown)
    if ($env:GITHUB_STEP_SUMMARY) { $Markdown | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8 }
}

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory)][scriptblock]$Script,
        [int]$MaxAttempts = 4,
        [int]$BaseDelaySec = 10,
        [string]$What = 'operation'
    )
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        try { return & $Script }
        catch {
            if ($i -eq $MaxAttempts) { throw }
            $delay = $BaseDelaySec * $i
            Write-Warning "$What failed ($($_.Exception.Message)); retry $i/$($MaxAttempts - 1) in ${delay}s"
            Start-Sleep -Seconds $delay
        }
    }
}

function Invoke-Native {
    # Runs an external program and fails on an unexpected exit code.
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int[]]$AllowedExitCodes = @(0)
    )
    & $FilePath @ArgumentList | Out-Host
    $code = $LASTEXITCODE
    if ($code -notin $AllowedExitCodes) {
        Stop-Build "$([IO.Path]::GetFileName($FilePath)) exited with code $code"
    }
}

function Assert-FreeSpace {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][double]$MinGB)
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    $freeGB = [math]::Round(([IO.DriveInfo]::new($root)).AvailableFreeSpace / 1GB, 1)
    Write-Host "Free space on ${root}: $freeGB GB (need $MinGB GB)"
    if ($freeGB -lt $MinGB) { Stop-Build "Not enough free disk space on ${root}: $freeGB GB free, $MinGB GB required." }
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Read-WinForgeConfig {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { Stop-Build "Config file not found: $Path" }
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Get-WorkRoot {
    if ($env:WINFORGE_WORK) { return $env:WINFORGE_WORK }
    if ($IsWindows -and (Test-Path 'D:\')) { return 'D:\winforge' }
    return (Join-Path ([IO.Path]::GetTempPath()) 'winforge')
}

Export-ModuleMember -Function *

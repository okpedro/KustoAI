<#
.SYNOPSIS
    Ensures WinGet is installed and available.

.DESCRIPTION
    - Checks whether WinGet is already available.
    - Verifies the OS supports WinGet.
    - Attempts App Installer registration.
    - Downloads App Installer if necessary.
    - Verifies WinGet is available.
    - If WinGet had to be installed, exits with code 3010 and instructs
      the user to rerun the bootstrap script in a new PowerShell session.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Test-IsAdministrator {

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Ensure-Elevation {

    if (Test-IsAdministrator) {
        return
    }

    Write-Warn "Elevation required. Relaunching as Administrator..."

    $arguments = @(
        '-ExecutionPolicy'
        'Bypass'
        '-File'
        "`"$PSCommandPath`""
    )

    Start-Process `
        -FilePath "powershell.exe" `
        -Verb RunAs `
        -ArgumentList $arguments

    exit 0
}

function Get-WinGet {

    try {
        return Get-Command winget.exe -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Test-OperatingSystem {

    $build = [Environment]::OSVersion.Version.Build

    if ($build -lt 17763) {
        throw "WinGet requires Windows 10 version 1809 / Server 2019 or later. Current build: $build"
    }

    Write-Info "Operating system build $build is supported."
}

function Register-AppInstaller {

    try {

        Write-Info "Attempting App Installer registration..."

        Add-AppxPackage `
            -RegisterByFamilyName `
            -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe `
            -ErrorAction Stop

        Start-Sleep -Seconds 5

        return $true
    }
    catch {

        Write-Warn "App Installer registration failed."

        return $false
    }
}

function Install-AppInstaller {

    $downloadUrl = "https://aka.ms/getwinget"

    $packageFile = Join-Path `
        $env:TEMP `
        "Microsoft.DesktopAppInstaller.msixbundle"

    try {

        Write-Info "Downloading App Installer..."

        Invoke-WebRequest `
            -Uri $downloadUrl `
            -OutFile $packageFile

        Write-Info "Installing App Installer..."

        Add-AppxPackage `
            -Path $packageFile `
            -ErrorAction Stop

        return $true
    }
    catch {

        Write-Err $_.Exception.Message

        return $false
    }
    finally {

        if (Test-Path $packageFile) {
            Remove-Item $packageFile -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------

$existingWinget = Get-WinGet

if ($existingWinget) {

    try {
        $version = (& winget --version)
    }
    catch {
        $version = "Unknown"
    }

    Write-Info "WinGet already installed."
    Write-Info "Version: $version"

    exit 0
}

Ensure-Elevation

Test-OperatingSystem

Write-Info "WinGet not detected."

$wingetInstalledThisRun = $false

Register-AppInstaller | Out-Null

if (-not (Get-WinGet)) {

    Write-Info "Installing App Installer..."

    if (-not (Install-AppInstaller)) {
        throw "Failed to install App Installer."
    }

    $wingetInstalledThisRun = $true
}

# Give AppX registration a chance to complete.
Start-Sleep -Seconds 10

$winget = Get-WinGet

if ($wingetInstalledThisRun) {

    if (-not $winget) {

        Write-Warn ""
        Write-Warn "WinGet appears to have been installed but is not available in the current session."
        Write-Warn "Close this PowerShell window and rerun your bootstrap script."
        Write-Warn "If that still does not work, sign out and sign back into Windows."
        Write-Warn ""

        exit 3010
    }

    Write-Info ""
    Write-Info "WinGet has been installed successfully."
    Write-Info "To ensure package aliases and registration are fully available,"
    Write-Info "please rerun your bootstrap script."
    Write-Info ""

    exit 3010
}

$winget = Get-WinGet

if (-not $winget) {
    throw "WinGet is still not available after installation attempts."
}

try {
    $version = (& winget --version)
}
catch {
    $version = "Unknown"
}

Write-Info "WinGet is available."
Write-Info "Version: $version"

exit 0
<#
.SYNOPSIS
    Silently installs Git for Windows via WinGet, selecting the correct native
    architecture (x64 or ARM64) automatically.

.DESCRIPTION
    - Detects the *native OS* architecture (not the process architecture, which
      lies when PowerShell runs emulated x64 on an ARM64 device).
    - Verifies WinGet is present and usable before attempting anything.
    - Skips installation if Git is already present (unless -Force).
    - Installs with: winget install --id Git.Git -e --source winget
      plus silent / architecture / scope switches.
    - Falls back gracefully: ARM64 -> x64 (emulated) if no ARM64 installer is
      published; machine scope -> user scope if not elevated.
    - Refreshes PATH in the current session so 'git' works immediately.

.PARAMETER Scope
    'machine' (default, requires elevation) or 'user'.

.PARAMETER Force
    Reinstall / upgrade even if Git is already detected.

.PARAMETER LogPath
    Optional path for the WinGet installer log.

.EXAMPLE
    .\Install-Git.ps1
.EXAMPLE
    .\Install-Git.ps1 -Scope user -Force -LogPath C:\Temp\git-winget.log

.NOTES
    Exit codes: 0 = success/already installed, 1 = prerequisite failure,
                2 = install failure.
#>

[CmdletBinding()]
param(
    [ValidateSet('machine', 'user')]
    [string]$Scope = 'machine',

    [switch]$Force,

    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Step { param([string]$Message) Write-Host "[*] $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "[+] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[!] $Message" -ForegroundColor Yellow }
function Write-Err  { param([string]$Message) Write-Host "[x] $Message" -ForegroundColor Red }

# ---------------------------------------------------------------------------
# 1. Determine the NATIVE OS architecture
#    The registry value under Session Manager\Environment always reflects the
#    physical/native architecture, even inside a WOW64 or ARM64-emulated x64
#    process. $env:PROCESSOR_ARCHITECTURE does NOT.
# ---------------------------------------------------------------------------
function Get-NativeArchitecture {
    $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    $arch = $null
    try {
        $arch = (Get-ItemProperty -Path $regPath -Name 'PROCESSOR_ARCHITECTURE' -ErrorAction Stop).PROCESSOR_ARCHITECTURE
    } catch {
        # Fallback chain
        if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
        elseif ($env:PROCESSOR_ARCHITECTURE) { $arch = $env:PROCESSOR_ARCHITECTURE }
    }

    switch -Regex ($arch) {
        '^ARM64$' { return 'arm64' }
        '^AMD64$' { return 'x64' }
        '^x86$'   { return 'x86' }
        default   { return 'x64' }   # conservative default
    }
}

# ---------------------------------------------------------------------------
# 2. Helpers
# ---------------------------------------------------------------------------
function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Update-SessionPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (($machinePath, $userPath) | Where-Object { $_ }) -join ';'
}

function Get-InstalledGit {
    Update-SessionPath
    $cmd = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    foreach ($candidate in @(
            "$env:ProgramFiles\Git\cmd\git.exe",
            "${env:ProgramFiles(x86)}\Git\cmd\git.exe",
            "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe")) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    return $null
}

# ---------------------------------------------------------------------------
# 3. Already installed?
# ---------------------------------------------------------------------------
$existing = Get-InstalledGit
if ($existing -and -not $Force) {
    $version = (& $existing --version) 2>$null
    Write-Ok "Git is already installed at '$existing' ($version). Use -Force to reinstall/upgrade."
    exit 0
}
elseif ($existing) {
    Write-Warn "Git already present at '$existing' - proceeding because -Force was specified."
}

# ---------------------------------------------------------------------------
# 4. Prerequisite: WinGet
# ---------------------------------------------------------------------------
Write-Step 'Checking for WinGet (Windows Package Manager)...'
$winget = Get-Command winget.exe -ErrorAction SilentlyContinue
if (-not $winget) {
    Write-Err 'WinGet was not found on this system.'
    Write-Host '    Remediation options:' -ForegroundColor Yellow
    Write-Host '      1) Update "App Installer" from the Microsoft Store, or'
    Write-Host '      2) In an elevated PowerShell 7 session:  Install-Module Microsoft.WinGet.Client; Repair-WinGetPackageManager, or'
    Write-Host '      3) Register it:  Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe'
    exit 1
}
Write-Ok "WinGet found: $($winget.Source)"

# ---------------------------------------------------------------------------
# 5. Architecture + scope decisions
# ---------------------------------------------------------------------------
$arch = Get-NativeArchitecture
Write-Step "Native OS architecture detected: $arch"

if ($arch -eq 'x86') {
    Write-Warn '32-bit x86 Windows detected. Installing the x86/x64 package WinGet selects by default.'
}

$effectiveScope = $Scope
if ($Scope -eq 'machine' -and -not (Test-Elevated)) {
    Write-Warn 'Machine scope requested but session is not elevated. Falling back to user scope.'
    $effectiveScope = 'user'
}

# ---------------------------------------------------------------------------
# 6. Build and run the WinGet command
# ---------------------------------------------------------------------------
function Invoke-GitInstall {
    param([string]$Architecture)

    $wingetArgs = @(
        'install',
        '--id', 'Git.Git',
        '-e',
        '--source', 'winget',
        '--silent',
        '--scope', $effectiveScope,
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity'
    )
    if ($Architecture) { $wingetArgs += @('--architecture', $Architecture) }
    if ($LogPath)      { $wingetArgs += @('--log', $LogPath) }

    Write-Step "Running: winget $($wingetArgs -join ' ')"
    & winget.exe @wingetArgs
    return $LASTEXITCODE
}

# Only pin --architecture where it is meaningful (arm64 / x64).
$requestedArch = if ($arch -in @('arm64', 'x64')) { $arch } else { $null }

$exitCode = Invoke-GitInstall -Architecture $requestedArch

# 0x8A15002B = APPINSTALLER_CLI_ERROR_NO_APPLICABLE_INSTALLER (-1978335189)
$noApplicableInstaller = @(-1978335189, 0x8A15002B)

if ($exitCode -ne 0 -and $requestedArch -eq 'arm64' -and ($exitCode -in $noApplicableInstaller)) {
    Write-Warn 'No native ARM64 installer available for Git.Git. Retrying with x64 (runs under emulation).'
    $exitCode = Invoke-GitInstall -Architecture 'x64'
}
elseif ($exitCode -ne 0 -and $requestedArch) {
    Write-Warn 'Pinned-architecture install failed. Retrying and letting WinGet auto-select the installer.'
    $exitCode = Invoke-GitInstall -Architecture $null
}

# ---------------------------------------------------------------------------
# 7. Verify
# ---------------------------------------------------------------------------
# -1978335189 = already installed / no applicable upgrade; -1978335135 = no newer version
if ($exitCode -ne 0 -and $exitCode -ne -1978335135) {
    Write-Err "WinGet returned exit code $exitCode. Git installation did not complete cleanly."
    if ($LogPath) { Write-Host "    Review the log at: $LogPath" }
    else { Write-Host "    Default WinGet logs: $env:LOCALAPPDATA\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\DiagOutputDir" }
    exit 2
}

Update-SessionPath
$gitPath = Get-InstalledGit
if (-not $gitPath) {
    Write-Err 'Installation reported success but git.exe could not be located. Open a new shell and re-check.'
    exit 2
}

$installedVersion = (& $gitPath --version) 2>$null
Write-Ok "Git installed successfully: $gitPath"
Write-Ok "$installedVersion  (architecture target: $(if ($requestedArch) { $requestedArch } else { 'winget default' }), scope: $effectiveScope)"
Write-Host ''
Write-Host 'PATH has been refreshed for THIS session. Other open terminals need to be restarted.' -ForegroundColor DarkGray
exit 0

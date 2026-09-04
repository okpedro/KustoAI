<#
.SYNOPSIS
    Silently installs Visual Studio Code - Insiders via winget with Explorer context-menu
    integration enabled. Handles both x64 and ARM64 Windows 11.

.DESCRIPTION
    winget's default manifest for Microsoft.VisualStudioCode.Insiders passes only
    /SILENT /mergetasks="!runcode", which leaves the "Open with Code" context-menu
    checkboxes UNCHECKED. This script uses winget's --override switch to pass a complete,
    explicit Inno Setup command line to the installer.

    IMPORTANT: --override REPLACES winget's default installer arguments rather than
    appending to them, so every switch (including the silent switches) must be supplied
    here. That is intentional and is why /VERYSILENT etc. appear below.
    Ref: https://learn.microsoft.com/en-us/windows/package-manager/winget/install

    Architecture is resolved from the OS (not the process), so this behaves correctly even
    when run from an x64-emulated PowerShell host on an ARM64 device.

.PARAMETER Scope
    'User'    - Installs to %LOCALAPPDATA%\Programs\Microsoft VS Code Insiders.
                Context menu registers under HKCU. No admin rights required. (Default)
    'Machine' - Installs to C:\Program Files\Microsoft VS Code Insiders.
                Context menu registers under HKLM for all users. REQUIRES ADMIN.

.PARAMETER Tasks
    Inno Setup /MERGETASKS list. Defaults to both context menus, file association,
    PATH registration, and suppressed post-install launch.
    Prefix a task with '!' to explicitly deselect it (e.g. '!desktopicon').

.PARAMETER Force
    Reinstall even if VS Code Insiders is already installed in the requested scope.

.PARAMETER LogPath
    Directory for the winget log. Defaults to %TEMP%.

.EXAMPLE
    .\Install-VSCodeInsiders.ps1
    Per-user silent install with file + folder context menus.

.EXAMPLE
    .\Install-VSCodeInsiders.ps1 -Scope Machine
    All-users install (run from an elevated session).

.EXAMPLE
    .\Install-VSCodeInsiders.ps1 -Tasks '!runcode,addcontextmenufiles,addcontextmenufolders'
    Context menus only - no PATH change, no file associations.

.NOTES
    Tested target: Windows 11 (x64 and ARM64). Requires App Installer / winget 1.4+.
    Exit code 0 = success. 3010 = success, reboot pending. Anything else: see the log.
#>

[CmdletBinding()]
param(
    [ValidateSet('User', 'Machine')]
    [string] $Scope = 'User',

    [ValidateNotNullOrEmpty()]
    [string] $Tasks = '!runcode,addcontextmenufiles,addcontextmenufolders,associatewithfiles,addtopath',

    [switch] $Force,

    [string] $LogPath = $env:TEMP
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$PackageId = 'Microsoft.VisualStudioCode.Insiders'

function Write-Step { param([string]$Message) Write-Host "[*] $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "[+] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[!] $Message" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# 1. Skip installation when the requested scope is already installed
# ---------------------------------------------------------------------------
$expectedExePath = if ($Scope -eq 'Machine') {
    Join-Path $env:ProgramFiles 'Microsoft VS Code Insiders\Code - Insiders.exe'
}
else {
    Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code Insiders\Code - Insiders.exe'
}

if ((Test-Path -LiteralPath $expectedExePath -PathType Leaf) -and -not $Force) {
    $fileVersion = (Get-Item -LiteralPath $expectedExePath).VersionInfo.ProductVersion
    Write-Ok "VS Code Insiders is already installed at '$expectedExePath' (v$fileVersion)."
    Write-Ok 'No installation was performed. Use -Force to reinstall.'
    exit 0
}
elseif (Test-Path -LiteralPath $expectedExePath -PathType Leaf) {
    Write-Warn "VS Code Insiders is already installed at '$expectedExePath'; proceeding because -Force was specified."
}

# ---------------------------------------------------------------------------
# 2. Preflight: winget availability
# ---------------------------------------------------------------------------
Write-Step 'Checking for winget (App Installer)...'

$winget = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue |
          Select-Object -First 1

if (-not $winget) {
    throw @'
winget was not found on PATH.

winget ships as part of App Installer. If this is a freshly imaged machine or a new user
profile, App Installer may not have registered yet. Try:

    Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe

If that fails, install App Installer from the Microsoft Store or from
https://github.com/microsoft/winget-cli/releases and re-run this script.
'@
}

$wingetVersion = (& $winget.Source --version) 2>$null
Write-Ok "winget found: $($winget.Source) ($wingetVersion)"

# ---------------------------------------------------------------------------
# 3. Preflight: elevation (only required for Machine scope)
# ---------------------------------------------------------------------------
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($Scope -eq 'Machine' -and -not $isAdmin) {
    throw "-Scope Machine writes to Program Files and HKLM. Re-run this script from an elevated PowerShell session."
}

Write-Ok "Scope: $Scope (elevated session: $isAdmin)"

# ---------------------------------------------------------------------------
# 4. Resolve OS architecture
#    RuntimeInformation::OSArchitecture reports the *OS* architecture, so this stays
#    correct even under x64 emulation on ARM64 - unlike $env:PROCESSOR_ARCHITECTURE.
# ---------------------------------------------------------------------------
$osArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()

switch ($osArch) {
    'Arm64' { $wingetArch = 'arm64' }
    'X64'   { $wingetArch = 'x64'   }
    default {
        throw "Unsupported OS architecture '$osArch'. VS Code dropped 32-bit (x86) Windows support after v1.83."
    }
}

Write-Ok "Detected OS architecture: $osArch -> winget --architecture $wingetArch"

# ---------------------------------------------------------------------------
# 5. Build the Inno Setup override string
#    /VERYSILENT        - no UI at all
#    /SUPPRESSMSGBOXES  - suppress any unexpected modal prompts
#    /NORESTART         - never reboot on our behalf
#    /MERGETASKS=...    - the optional-tasks checkboxes from the GUI installer
#
#    No spaces inside the /MERGETASKS value, so no nested quoting is required. This
#    avoids the classic PowerShell -> winget -> Inno triple-quoting breakage.
# ---------------------------------------------------------------------------
$override = "/VERYSILENT /NORESTART /SUPPRESSMSGBOXES /MERGETASKS=$Tasks"

$logFile = Join-Path $LogPath ("VSCodeInsiders-winget-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))

$wingetArgs = @(
    'install'
    '--id', $PackageId
    '--exact'
    '--source', 'winget'
    '--scope', $Scope.ToLower()
    '--architecture', $wingetArch
    '--accept-package-agreements'   # Insiders ships under a pre-release license
    '--accept-source-agreements'
    '--disable-interactivity'
    '--log', $logFile
    '--override', $override
)

Write-Step "Installing $PackageId"
Write-Host "    Tasks    : $Tasks"       -ForegroundColor DarkGray
Write-Host "    Override : $override"    -ForegroundColor DarkGray
Write-Host "    Log      : $logFile"     -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# 6. Execute, with a fallback that lets winget pick the architecture itself
# ---------------------------------------------------------------------------
& $winget.Source @wingetArgs
$exitCode = $LASTEXITCODE

if ($exitCode -ne 0 -and $exitCode -ne 3010) {
    Write-Warn "winget returned $exitCode (0x{0:X8}). Retrying without an explicit --architecture pin..." -f $exitCode

    $fallbackArgs = $wingetArgs | Where-Object { $_ -ne '--architecture' -and $_ -ne $wingetArch }
    & $winget.Source @fallbackArgs
    $exitCode = $LASTEXITCODE
}

# ---------------------------------------------------------------------------
# 7. Report
# ---------------------------------------------------------------------------
switch ($exitCode) {
    0     { Write-Ok 'Installer reported success.' }
    3010  { Write-Warn 'Installer reported success, but a reboot is pending (exit 3010).' }
    default {
        Write-Warn ("winget exited with {0} (0x{1:X8}). Review the log: {2}" -f $exitCode, $exitCode, $logFile)
    }
}

# ---------------------------------------------------------------------------
# 8. Verify the binary landed
# ---------------------------------------------------------------------------
$candidatePaths = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code Insiders\Code - Insiders.exe')
    (Join-Path $env:ProgramFiles 'Microsoft VS Code Insiders\Code - Insiders.exe')
)

$exePath = $candidatePaths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

if ($exePath) {
    $fileVersion = (Get-Item -LiteralPath $exePath).VersionInfo.ProductVersion
    Write-Ok "Installed: $exePath (v$fileVersion)"
}
else {
    Write-Warn 'Could not locate "Code - Insiders.exe" in either the user or machine install path.'
}

# ---------------------------------------------------------------------------
# 9. Verify the context-menu registration actually took effect
#    Rather than assuming a specific key name, scan the shell verb containers for any
#    command whose value points at Code - Insiders.exe. Works for HKCU (user scope)
#    and HKLM (machine scope) alike.
# ---------------------------------------------------------------------------
Write-Step 'Verifying Explorer context-menu registration...'

$hives = if ($Scope -eq 'Machine') { 'HKLM:\SOFTWARE\Classes' } else { 'HKCU:\SOFTWARE\Classes' }

$verbRoots = @(
    '*\shell'                       # right-click a file
    'Directory\shell'               # right-click a folder
    'Directory\Background\shell'    # right-click inside a folder
)

$found = @{}

foreach ($root in $verbRoots) {
    $regPath = Join-Path $hives $root
    if (-not (Test-Path -LiteralPath $regPath)) { continue }

    $hit = Get-ChildItem -LiteralPath $regPath -ErrorAction SilentlyContinue | ForEach-Object {
        $cmdKey = Join-Path $_.PSPath 'command'
        if (Test-Path -LiteralPath $cmdKey) {
            $cmd = (Get-ItemProperty -LiteralPath $cmdKey -ErrorAction SilentlyContinue).'(default)'
            if ($cmd -and $cmd -like '*Code - Insiders.exe*') { $_.PSChildName }
        }
    } | Select-Object -First 1

    $found[$root] = $hit
}

foreach ($root in $verbRoots) {
    if ($found[$root]) {
        Write-Ok  ("{0,-28} -> '{1}'" -f $root, $found[$root])
    }
    else {
        Write-Warn ("{0,-28} -> not registered" -f $root)
    }
}

Write-Host ''
Write-Host 'Note: Explorer caches shell verbs. If the menu entries do not appear immediately,' -ForegroundColor DarkGray
Write-Host 'sign out and back in, or restart explorer.exe.'                                    -ForegroundColor DarkGray

exit $exitCode

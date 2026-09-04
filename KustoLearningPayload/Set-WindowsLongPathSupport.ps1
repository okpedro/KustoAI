<#
.SYNOPSIS
    Audits and remediates Windows long-path support for Git workloads on deep repositories.

.DESCRIPTION
    Windows "Filename too long" failures during git clone/checkout are caused by up to three
    independent layers, all of which must be cleared:

      1. OS layer  - HKLM\SYSTEM\CurrentControlSet\Control\FileSystem\LongPathsEnabled (REG_DWORD)
                     Requires Windows 10 1607+ / Windows 11 / Server 2016+. Requires reboot.
                     Only affects applications manifested as longPathAware.
      2. Git layer - core.longpaths=true. Requires Git for Windows >= 1.9.5 (2.x recommended).
                     Some GUI clients read --global but ignore --system, so --global is default.
      3. Layout    - Clone root path length. Purely advisory here; the script measures and warns.

    This script is defensive by design:
      * Runs an AUDIT pass first and always reports current state before changing anything.
      * Honours -WhatIf / -Confirm via SupportsShouldProcess.
      * Exports the target registry key with reg.exe BEFORE modification.
      * Copies every .gitconfig it will touch to a timestamped backup directory.
      * Records the exact prior value (including "value did not exist") so rollback is faithful.
      * Emits a self-contained Rollback.ps1 alongside the backups.
      * Writes a transcript-style log and returns a structured object for pipeline/CI use.
      * Is fully idempotent - re-running on a compliant machine changes nothing.

.PARAMETER BackupRoot
    Directory under which a timestamped backup folder is created.
    Defaults to $env:LOCALAPPDATA\LongPathRemediation.

.PARAMETER GitScope
    Which Git config scope to write. 'Global' (per-user, no elevation) is the default and is the
    safest choice because GUI clients such as GitHub Desktop honour --global but not --system.
    'System' writes machine-wide and requires elevation. 'Both' writes each.

.PARAMETER SkipRegistry
    Do not touch the OS long-path registry value. Useful when policy is managed by Group Policy /
    Intune and local edits would be reverted or would drift from the managed baseline.

.PARAMETER SkipGit
    Do not touch any Git configuration.

.PARAMETER AuditOnly
    Report current state and exit. Makes no backups and no changes. Equivalent in spirit to -WhatIf
    but with no ShouldProcess prompts and a cleaner report.

.PARAMETER CloneRoot
    Optional path you intend to clone into. The script measures it and warns if the remaining
    headroom before Git's 4096-character internal path ceiling is uncomfortably small.

.EXAMPLE
    .\Set-WindowsLongPathSupport.ps1 -AuditOnly

.EXAMPLE
    .\Set-WindowsLongPathSupport.ps1 -WhatIf

.EXAMPLE
    .\Set-WindowsLongPathSupport.ps1 -GitScope Both -CloneRoot 'C:\src'

.NOTES
    Author : Generated for Pedro Salinas-Ruiz
    Requires: PowerShell 5.1+ ; elevation only when writing registry or --system git config.
    Exit codes: 0 = compliant / success, 1 = action required, 2 = fatal error.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter()]
    [string] $BackupRoot = (Join-Path $env:LOCALAPPDATA 'LongPathRemediation'),

    [Parameter()]
    [ValidateSet('Global', 'System', 'Both')]
    [string] $GitScope = 'Global',

    [Parameter()]
    [switch] $SkipRegistry,

    [Parameter()]
    [switch] $SkipGit,

    [Parameter()]
    [switch] $AuditOnly,

    [Parameter()]
    [string] $CloneRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$RegKeyPath      = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
$RegKeyNative    = 'HKLM\SYSTEM\CurrentControlSet\Control\FileSystem'
$RegValueName    = 'LongPathsEnabled'
$MinGitVersion   = [Version]'1.9.5'
$GitPathCeiling  = 4096      # Git's own internal per-path limit, regardless of OS
$LegacyMaxPath   = 260       # Classic Win32 MAX_PATH

$Script:Changes  = New-Object System.Collections.Generic.List[string]
$Script:LogLines = New-Object System.Collections.Generic.List[string]
$Script:Cmdlet   = $PSCmdlet          # captured so nested helpers can call ShouldProcess safely
$Script:Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$Script:BackupDir = Join-Path $BackupRoot $Script:Timestamp

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Message,
        [ValidateSet('INFO', 'WARN', 'FAIL', 'OK', 'ACT')][string] $Level = 'INFO'
    )
    $stamp = (Get-Date).ToString('HH:mm:ss')
    $Script:LogLines.Add("[$stamp][$Level] $Message") | Out-Null

    $color = switch ($Level) {
        'OK'   { 'Green' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
        'ACT'  { 'Cyan' }
        default { 'Gray' }
    }
    Write-Host ("  [{0,-4}] {1}" -f $Level, $Message) -ForegroundColor $color
}

function Test-IsElevated {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Test-IsWindows {
    # PS 5.1 has no $IsWindows automatic variable.
    if (Test-Path Variable:\IsWindows) { return [bool] $IsWindows }
    return $true
}

function New-BackupDirectory {
    if (Test-Path -LiteralPath $Script:BackupDir) { return }
    New-Item -Path $Script:BackupDir -ItemType Directory -Force | Out-Null
    Write-Log "Backup directory: $Script:BackupDir" -Level 'INFO'
}

function Get-GitExecutable {
    $cmd = Get-Command git.exe -ErrorAction SilentlyContinue
    if (-not $cmd) { $cmd = Get-Command git -ErrorAction SilentlyContinue }
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-GitVersion {
    param([Parameter(Mandatory)][string] $GitExe)
    $raw = & $GitExe --version 2>&1 | Out-String
    if ($raw -match '(\d+)\.(\d+)\.(\d+)') {
        return [Version]("{0}.{1}.{2}" -f $Matches[1], $Matches[2], $Matches[3])
    }
    return $null
}

function Get-GitConfigValue {
    param(
        [Parameter(Mandatory)][string] $GitExe,
        [Parameter(Mandatory)][ValidateSet('global', 'system')][string] $Scope,
        [Parameter(Mandatory)][string] $Name
    )
    # git exits 1 when the key is simply absent - that is not an error condition here.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $out = & $GitExe config "--$Scope" --get $Name 2>$null
    $ErrorActionPreference = $prev
    $global:LASTEXITCODE = 0
    if ($out) { return ([string] $out).Trim() }
    return $null
}

function Get-GitConfigPath {
    param(
        [Parameter(Mandatory)][string] $GitExe,
        [Parameter(Mandatory)][ValidateSet('global', 'system')][string] $Scope
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $out = & $GitExe config "--$Scope" --list --show-origin 2>$null | Select-Object -First 1
    $ErrorActionPreference = $prev
    $global:LASTEXITCODE = 0
    if ($out -and ($out -match '^file:([^\t]+)')) { return $Matches[1].Trim() }

    # Fall back to conventional locations if the scope is currently empty.
    if ($Scope -eq 'global') { return (Join-Path $env:USERPROFILE '.gitconfig') }
    return $null
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=== Windows Long-Path Remediation for Git =========================' -ForegroundColor White
Write-Host ''

if (-not (Test-IsWindows)) {
    Write-Log 'This script targets Windows only. Nothing to do.' -Level 'FAIL'
    exit 2
}

$IsElevated = Test-IsElevated
$osCaption  = $null
$osBuild    = 0
try {
    $os        = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $osCaption = $os.Caption
    $osBuild   = [int]($os.BuildNumber)
}
catch {
    Write-Log "Could not query OS build via CIM: $($_.Exception.Message)" -Level 'WARN'
}

Write-Log ("OS         : {0} (build {1})" -f $osCaption, $osBuild)
Write-Log ("Elevated   : {0}" -f $IsElevated)
Write-Log ("Git scope  : {0}" -f $GitScope)
Write-Log ("Mode       : {0}" -f $(if ($AuditOnly) { 'AUDIT ONLY' } elseif ($WhatIfPreference) { 'WHAT-IF' } else { 'REMEDIATE' }))

# Windows 10 1607 == build 14393. Below that, LongPathsEnabled does not exist as a feature.
$OsSupportsLongPaths = ($osBuild -ge 14393)
if (-not $OsSupportsLongPaths -and $osBuild -gt 0) {
    Write-Log 'This OS build predates Windows 10 1607; OS-level long paths are unavailable.' -Level 'WARN'
}

Write-Host ''

# ---------------------------------------------------------------------------
# AUDIT
# ---------------------------------------------------------------------------
Write-Host '--- Audit ---------------------------------------------------------' -ForegroundColor White

$report = [ordered]@{
    Timestamp            = (Get-Date).ToString('o')
    ComputerName         = $env:COMPUTERNAME
    OsBuild              = $osBuild
    Elevated             = $IsElevated
    OsSupportsLongPaths  = $OsSupportsLongPaths
    RegistryValueBefore  = $null
    RegistryValueAfter   = $null
    RegistryCompliant    = $false
    GitExecutable        = $null
    GitVersion           = $null
    GitVersionSupported  = $false
    GitGlobalBefore      = $null
    GitSystemBefore      = $null
    GitCompliant         = $false
    CloneRoot            = $CloneRoot
    CloneRootLength      = $null
    RebootRequired       = $false
    BackupDirectory      = $null
    RollbackScript       = $null
    LogFile              = $null
    ChangesMade          = @()
    OverallCompliant     = $false
}

# --- Registry state
$regValueBefore = $null
$regValueExists = $false
try {
    $item = Get-ItemProperty -Path $RegKeyPath -Name $RegValueName -ErrorAction Stop
    $regValueBefore = [int] $item.$RegValueName
    $regValueExists = $true
    Write-Log ("Registry  : {0} = {1}" -f $RegValueName, $regValueBefore) -Level $(if ($regValueBefore -eq 1) { 'OK' } else { 'WARN' })
}
catch {
    Write-Log "Registry  : $RegValueName is NOT present (defaults to disabled / MAX_PATH $LegacyMaxPath)" -Level 'WARN'
}
$report.RegistryValueBefore = $regValueBefore
$report.RegistryCompliant   = ($regValueBefore -eq 1)

# --- Git state
$gitExe = Get-GitExecutable
$gitVersion = $null
$gitGlobalBefore = $null
$gitSystemBefore = $null

if (-not $gitExe) {
    Write-Log 'Git       : git.exe not found on PATH. Git remediation will be skipped.' -Level 'FAIL'
}
else {
    $report.GitExecutable = $gitExe
    $gitVersion = Get-GitVersion -GitExe $gitExe
    $report.GitVersion = if ($gitVersion) { $gitVersion.ToString() } else { 'unknown' }

    if ($gitVersion -and $gitVersion -ge $MinGitVersion) {
        $report.GitVersionSupported = $true
        Write-Log ("Git       : {0} at {1}" -f $gitVersion, $gitExe) -Level 'OK'
    }
    else {
        Write-Log ("Git       : version {0} predates {1}; core.longpaths is unsupported. Upgrade Git for Windows." -f $report.GitVersion, $MinGitVersion) -Level 'FAIL'
    }

    $gitGlobalBefore = Get-GitConfigValue -GitExe $gitExe -Scope 'global' -Name 'core.longpaths'
    Write-Log ("Git global: core.longpaths = {0}" -f $(if ($gitGlobalBefore) { $gitGlobalBefore } else { '<unset>' })) -Level $(if ($gitGlobalBefore -eq 'true') { 'OK' } else { 'WARN' })

    $gitSystemBefore = Get-GitConfigValue -GitExe $gitExe -Scope 'system' -Name 'core.longpaths'
    Write-Log ("Git system: core.longpaths = {0}" -f $(if ($gitSystemBefore) { $gitSystemBefore } else { '<unset>' })) -Level $(if ($gitSystemBefore -eq 'true') { 'OK' } else { 'WARN' })

    $report.GitGlobalBefore = $gitGlobalBefore
    $report.GitSystemBefore = $gitSystemBefore

    $gitOk = switch ($GitScope) {
        'Global' { $gitGlobalBefore -eq 'true' }
        'System' { $gitSystemBefore -eq 'true' }
        'Both'   { ($gitGlobalBefore -eq 'true') -and ($gitSystemBefore -eq 'true') }
    }
    $report.GitCompliant = [bool] $gitOk
}

# --- Clone root advisory
if ($CloneRoot) {
    $len = $CloneRoot.Length
    $report.CloneRootLength = $len
    $headroom = $GitPathCeiling - $len
    if ($len -gt 40) {
        Write-Log ("CloneRoot : '{0}' is {1} chars. Consider a short root such as C:\src to preserve depth headroom." -f $CloneRoot, $len) -Level 'WARN'
    }
    else {
        Write-Log ("CloneRoot : '{0}' is {1} chars ({2} of Git's {3}-char ceiling remaining)." -f $CloneRoot, $len, $headroom, $GitPathCeiling) -Level 'OK'
    }
}

Write-Host ''

if ($AuditOnly) {
    $report.OverallCompliant = ($report.RegistryCompliant -and $report.GitCompliant)
    Write-Host '--- Result --------------------------------------------------------' -ForegroundColor White
    if ($report.OverallCompliant) {
        Write-Log 'Machine is compliant. No action required.' -Level 'OK'
    }
    else {
        Write-Log 'Machine is NOT compliant. Re-run without -AuditOnly to remediate.' -Level 'ACT'
    }
    Write-Host ''
    [pscustomobject] $report
    exit $(if ($report.OverallCompliant) { 0 } else { 1 })
}

# ---------------------------------------------------------------------------
# Guard rails before we mutate anything
# ---------------------------------------------------------------------------
$needsRegistryWrite = (-not $SkipRegistry) -and $OsSupportsLongPaths -and (-not $report.RegistryCompliant)
$needsSystemGit     = (-not $SkipGit) -and $gitExe -and $report.GitVersionSupported -and
                      ($GitScope -in @('System', 'Both')) -and ($gitSystemBefore -ne 'true')
$needsGlobalGit     = (-not $SkipGit) -and $gitExe -and $report.GitVersionSupported -and
                      ($GitScope -in @('Global', 'Both')) -and ($gitGlobalBefore -ne 'true')

if (($needsRegistryWrite -or $needsSystemGit) -and (-not $IsElevated)) {
    Write-Log 'Elevation is required for the registry write and/or --system git config.' -Level 'FAIL'
    Write-Log 'Re-run this script from an elevated PowerShell session, or use -GitScope Global -SkipRegistry.' -Level 'ACT'
    exit 1
}

if (-not ($needsRegistryWrite -or $needsSystemGit -or $needsGlobalGit)) {
    Write-Log 'Nothing to change - all in-scope settings are already compliant.' -Level 'OK'
    $report.OverallCompliant = $true
    Write-Host ''
    [pscustomobject] $report
    exit 0
}

# ---------------------------------------------------------------------------
# BACKUP  (always before mutation; skipped under -WhatIf)
# ---------------------------------------------------------------------------
Write-Host '--- Backup --------------------------------------------------------' -ForegroundColor White

$regBackupFile = $null
$gitBackups    = @{}

if (-not $WhatIfPreference) {
    New-BackupDirectory
    $report.BackupDirectory = $Script:BackupDir

    if ($needsRegistryWrite) {
        $regBackupFile = Join-Path $Script:BackupDir 'FileSystem-key.reg'
        $regArgs = @('export', $RegKeyNative, $regBackupFile, '/y')
        $null = & reg.exe @regArgs 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $regBackupFile)) {
            Write-Log 'reg.exe export FAILED. Aborting before any registry modification.' -Level 'FAIL'
            exit 2
        }
        Write-Log "Registry key exported -> $regBackupFile" -Level 'OK'
    }

    foreach ($scope in @('global', 'system')) {
        $wanted = ($scope -eq 'global' -and $needsGlobalGit) -or ($scope -eq 'system' -and $needsSystemGit)
        if (-not $wanted) { continue }

        $cfgPath = Get-GitConfigPath -GitExe $gitExe -Scope $scope
        if ($cfgPath -and (Test-Path -LiteralPath $cfgPath)) {
            $dest = Join-Path $Script:BackupDir ("gitconfig-{0}.bak" -f $scope)
            Copy-Item -LiteralPath $cfgPath -Destination $dest -Force
            $gitBackups[$scope] = @{ Source = $cfgPath; Backup = $dest }
            Write-Log ("Git {0} config backed up -> {1}" -f $scope, $dest) -Level 'OK'
        }
        else {
            Write-Log ("Git {0} config file does not exist yet; git will create it. Nothing to back up." -f $scope) -Level 'INFO'
        }
    }
}
else {
    Write-Log ("WhatIf: backups would be created under {0}" -f $Script:BackupDir) -Level 'INFO'
}

Write-Host ''

# ---------------------------------------------------------------------------
# REMEDIATE
# ---------------------------------------------------------------------------
Write-Host '--- Remediate -----------------------------------------------------' -ForegroundColor White

# --- 1. Registry
if ($needsRegistryWrite) {
    $target = "$RegKeyPath\$RegValueName"
    if ($PSCmdlet.ShouldProcess($target, "Set REG_DWORD to 1 (enable Win32 long paths)")) {
        try {
            if ($regValueExists) {
                Set-ItemProperty -Path $RegKeyPath -Name $RegValueName -Value 1 -Type DWord -Force
            }
            else {
                New-ItemProperty -Path $RegKeyPath -Name $RegValueName -Value 1 -PropertyType DWord -Force | Out-Null
            }
            $verify = (Get-ItemProperty -Path $RegKeyPath -Name $RegValueName).$RegValueName
            if ([int]$verify -eq 1) {
                Write-Log "LongPathsEnabled set to 1 (verified)." -Level 'OK'
                $Script:Changes.Add('Registry: LongPathsEnabled -> 1') | Out-Null
                $report.RegistryValueAfter = 1
                $report.RebootRequired = $true
            }
            else {
                Write-Log "Post-write verification failed: value reads back as $verify." -Level 'FAIL'
            }
        }
        catch {
            Write-Log "Registry write failed: $($_.Exception.Message)" -Level 'FAIL'
            Write-Log "Restore with: reg.exe import `"$regBackupFile`"" -Level 'ACT'
            exit 2
        }
    }
}
elseif ($SkipRegistry) {
    Write-Log 'Registry step skipped by -SkipRegistry.' -Level 'INFO'
}
elseif ($report.RegistryCompliant) {
    Write-Log 'Registry already compliant - no write performed.' -Level 'OK'
    $report.RegistryValueAfter = 1
}

# --- 2. Git config
function Set-GitLongPaths {
    param(
        [Parameter(Mandatory)][ValidateSet('global', 'system')][string] $Scope
    )
    $target = "git config --$Scope core.longpaths"
    if (-not $Script:Cmdlet.ShouldProcess($target, 'Set to true')) { return }

    try {
        & $gitExe config "--$Scope" core.longpaths true 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git exited with code $LASTEXITCODE" }

        $verify = Get-GitConfigValue -GitExe $gitExe -Scope $Scope -Name 'core.longpaths'
        if ($verify -eq 'true') {
            Write-Log ("core.longpaths=true written to --{0} (verified)." -f $Scope) -Level 'OK'
            $Script:Changes.Add("Git ${Scope}: core.longpaths -> true") | Out-Null
        }
        else {
            Write-Log ("Verification failed for --{0}; reads back as '{1}'." -f $Scope, $verify) -Level 'FAIL'
        }
    }
    catch {
        Write-Log ("Failed to set --{0} core.longpaths: {1}" -f $Scope, $_.Exception.Message) -Level 'FAIL'
    }
}

if ($needsGlobalGit) { Set-GitLongPaths -Scope 'global' }
elseif (-not $SkipGit -and $GitScope -in @('Global', 'Both')) {
    Write-Log 'Git --global already set to true - no write performed.' -Level 'OK'
}

if ($needsSystemGit) { Set-GitLongPaths -Scope 'system' }
elseif (-not $SkipGit -and $GitScope -in @('System', 'Both')) {
    Write-Log 'Git --system already set to true - no write performed.' -Level 'OK'
}

Write-Host ''

# ---------------------------------------------------------------------------
# ROLLBACK ARTIFACT
# ---------------------------------------------------------------------------
if (-not $WhatIfPreference -and $Script:Changes.Count -gt 0) {
    Write-Host '--- Rollback artifact ---------------------------------------------' -ForegroundColor White

    $rollbackPath = Join-Path $Script:BackupDir 'Rollback.ps1'

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<# Auto-generated rollback for Set-WindowsLongPathSupport.ps1')
    [void]$sb.AppendLine("   Generated : $((Get-Date).ToString('o'))")
    [void]$sb.AppendLine("   Machine   : $env:COMPUTERNAME")
    [void]$sb.AppendLine('   Run from an ELEVATED PowerShell session if registry was changed. #>')
    [void]$sb.AppendLine('[CmdletBinding(SupportsShouldProcess=$true)] param()')
    [void]$sb.AppendLine('$ErrorActionPreference = ''Stop''')
    [void]$sb.AppendLine('')

    if ($report.RegistryValueAfter -eq 1 -and $Script:Changes -contains 'Registry: LongPathsEnabled -> 1') {
        if ($regValueExists) {
            [void]$sb.AppendLine("# Restore prior LongPathsEnabled value: $regValueBefore")
            [void]$sb.AppendLine("if (`$PSCmdlet.ShouldProcess('$RegValueName','Restore to $regValueBefore')) {")
            [void]$sb.AppendLine("    Set-ItemProperty -Path '$RegKeyPath' -Name '$RegValueName' -Value $regValueBefore -Type DWord -Force")
            [void]$sb.AppendLine("    Write-Host 'Restored $RegValueName = $regValueBefore'")
            [void]$sb.AppendLine('}')
        }
        else {
            [void]$sb.AppendLine('# Value did not exist prior to remediation - remove it entirely.')
            [void]$sb.AppendLine("if (`$PSCmdlet.ShouldProcess('$RegValueName','Remove value')) {")
            [void]$sb.AppendLine("    Remove-ItemProperty -Path '$RegKeyPath' -Name '$RegValueName' -Force -ErrorAction SilentlyContinue")
            [void]$sb.AppendLine("    Write-Host 'Removed $RegValueName'")
            [void]$sb.AppendLine('}')
        }
        [void]$sb.AppendLine("# Full key backup also available: $regBackupFile")
        [void]$sb.AppendLine("# Restore it with:  reg.exe import `"$regBackupFile`"")
        [void]$sb.AppendLine('Write-Warning ''A reboot is required for the registry change to take full effect.''')
        [void]$sb.AppendLine('')
    }

    foreach ($scope in @('global', 'system')) {
        $changed = $Script:Changes -contains "Git ${scope}: core.longpaths -> true"
        if (-not $changed) { continue }

        if ($gitBackups.ContainsKey($scope)) {
            $src = $gitBackups[$scope].Backup
            $dst = $gitBackups[$scope].Source
            [void]$sb.AppendLine("# Restore original --$scope gitconfig verbatim")
            [void]$sb.AppendLine("if (`$PSCmdlet.ShouldProcess('$dst','Restore from backup')) {")
            [void]$sb.AppendLine("    Copy-Item -LiteralPath '$src' -Destination '$dst' -Force")
            [void]$sb.AppendLine("    Write-Host 'Restored $dst'")
            [void]$sb.AppendLine('}')
        }
        else {
            [void]$sb.AppendLine("# --$scope config did not exist before; just unset the key we added.")
            [void]$sb.AppendLine("if (`$PSCmdlet.ShouldProcess('git --$scope core.longpaths','Unset')) {")
            [void]$sb.AppendLine("    & git config --$scope --unset core.longpaths 2>`$null")
            [void]$sb.AppendLine("    Write-Host 'Unset --$scope core.longpaths'")
            [void]$sb.AppendLine('}')
        }
        [void]$sb.AppendLine('')
    }

    Set-Content -LiteralPath $rollbackPath -Value $sb.ToString() -Encoding UTF8
    $report.RollbackScript = $rollbackPath
    Write-Log "Rollback script written -> $rollbackPath" -Level 'OK'
    Write-Host ''
}

# ---------------------------------------------------------------------------
# SUMMARY
# ---------------------------------------------------------------------------
Write-Host '--- Summary -------------------------------------------------------' -ForegroundColor White

$report.ChangesMade = @($Script:Changes)

if ($Script:Changes.Count -eq 0) {
    Write-Log 'No changes were applied.' -Level 'INFO'
}
else {
    foreach ($c in $Script:Changes) { Write-Log $c -Level 'ACT' }
}

$report.OverallCompliant = (
    ($SkipRegistry -or $report.RegistryValueAfter -eq 1 -or $report.RegistryCompliant) -and
    ($SkipGit -or $report.GitCompliant -or $Script:Changes.Count -gt 0)
)

if ($report.RebootRequired) {
    Write-Host ''
    Write-Log 'REBOOT REQUIRED for the OS long-path change to take effect across all processes.' -Level 'ACT'
}

Write-Host ''
Write-Host 'Remaining manual considerations (cannot be automated):' -ForegroundColor White
Write-Host '  * OS long paths only help applications manifested as longPathAware. Older build' -ForegroundColor Gray
Write-Host '    tooling, 32-bit installers and some GUI utilities still fail at 260 characters.' -ForegroundColor Gray
Write-Host '  * Relative paths are ALWAYS capped at 260 - the \\?\ prefix cannot be used with them.' -ForegroundColor Gray
Write-Host '  * Git enforces its own 4096-character path ceiling regardless of OS settings.' -ForegroundColor Gray
Write-Host '  * A single path COMPONENT (one folder or file name) is still capped at ~255 on NTFS.' -ForegroundColor Gray
Write-Host '  * Prefer a short clone root (C:\src, D:\repos) - it is the cheapest, most durable fix.' -ForegroundColor Gray
Write-Host ''

# Persist log
if (-not $WhatIfPreference) {
    try {
        New-BackupDirectory
        $logFile = Join-Path $Script:BackupDir 'remediation.log'
        Set-Content -LiteralPath $logFile -Value ($Script:LogLines -join [Environment]::NewLine) -Encoding UTF8
        $report.LogFile = $logFile

        $jsonFile = Join-Path $Script:BackupDir 'report.json'
        [pscustomobject]$report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $jsonFile -Encoding UTF8

        Write-Host "Log    : $logFile" -ForegroundColor DarkGray
        Write-Host "Report : $jsonFile" -ForegroundColor DarkGray
        Write-Host ''
    }
    catch {
        Write-Warning "Could not persist log/report: $($_.Exception.Message)"
    }
}

[pscustomobject] $report

exit $(if ($report.OverallCompliant) { 0 } else { 1 })

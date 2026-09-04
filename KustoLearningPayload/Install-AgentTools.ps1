[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$sourcePath = Join-Path -Path $PSScriptRoot -ChildPath 'AgentTools'
$destinationPath = 'C:\AgentTools'

if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
    throw "The AgentTools folder was not found next to this script: '$sourcePath'."
}

if (-not (Test-Path -LiteralPath $destinationPath -PathType Container)) {
    New-Item -Path $destinationPath -ItemType Directory | Out-Null
}

function Test-AgentToolsCurrent {
    $sourceFiles = @(Get-ChildItem -LiteralPath $sourcePath -File -Recurse -Force)

    foreach ($sourceFile in $sourceFiles) {
        $relativePath = $sourceFile.FullName.Substring($sourcePath.Length).TrimStart('\')
        $destinationFile = Join-Path $destinationPath $relativePath

        if (-not (Test-Path -LiteralPath $destinationFile -PathType Leaf)) {
            return $false
        }

        $installedFile = Get-Item -LiteralPath $destinationFile
        if ($installedFile.Length -ne $sourceFile.Length) {
            return $false
        }

        if ((Get-FileHash -LiteralPath $sourceFile.FullName -Algorithm SHA256).Hash -ne
            (Get-FileHash -LiteralPath $destinationFile -Algorithm SHA256).Hash) {
            return $false
        }
    }

    return $true
}

$agentToolsCurrent = Test-AgentToolsCurrent

if ($agentToolsCurrent) {
    Write-Host "AgentTools is already installed and current at '$destinationPath'."
}
else {
    Get-ChildItem -LiteralPath $sourcePath -Force | Copy-Item `
        -Destination $destinationPath `
        -Recurse `
        -Force

    if (-not (Test-AgentToolsCurrent)) {
        throw "AgentTools verification failed after copying files to '$destinationPath'."
    }

    Write-Host "AgentTools was copied to '$destinationPath'."
}

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$pathEntries = if ([string]::IsNullOrWhiteSpace($userPath)) {
    @()
}
else {
    @($userPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

$normalizedDestination = $destinationPath.TrimEnd('\')
$destinationIsOnPath = $pathEntries | Where-Object {
    $_.Trim().TrimEnd('\') -ieq $normalizedDestination
}

if (-not $destinationIsOnPath) {
    $updatedUserPath = (@($pathEntries) + $destinationPath) -join ';'
    [Environment]::SetEnvironmentVariable('Path', $updatedUserPath, 'User')
}

$processPathEntries = @($env:Path -split ';')
if (-not ($processPathEntries | Where-Object {
    $_.Trim().TrimEnd('\') -ieq $normalizedDestination
})) {
    $env:Path = "$env:Path;$destinationPath"
}

Write-Host 'The folder is now on the user PATH. Open a new terminal to use it.'

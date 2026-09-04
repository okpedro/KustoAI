$ErrorActionPreference = 'Stop'

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Bootstrap Script Starting" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

$Scripts = @(
    "Ensure-Winget.ps1",
    "Install-VSCodeInsiders.ps1",
    "Install-AgentTools.ps1",
    "Install-Git.ps1"
    #"Configure-Git.ps1",
    "Set-WindowsLongPathSupport.ps1"
)

foreach ($Script in $Scripts)
{
    $ScriptPath = Join-Path $PSScriptRoot $Script

    Write-Host ""
    Write-Host "------------------------------------------------" -ForegroundColor Yellow
    Write-Host "Running: $Script" -ForegroundColor Yellow
    Write-Host "------------------------------------------------" -ForegroundColor Yellow

    try
    {
        if (-not (Test-Path $ScriptPath))
        {
            throw "Script not found: $ScriptPath"
        }

        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath

        switch ($LASTEXITCODE) {

            0 {
                # Continue
            }

            3010 {
                Write-Host ""
                Write-Host "WinGet was installed."
                Write-Host "Please rerun this bootstrap script."
                Write-Host ""
                exit 0
            }

            default {
                throw "Uh oh, we made a booboo. Failed with exit code $LASTEXITCODE"
            }
        }

        Write-Host "[SUCCESS] $Script completed successfully." -ForegroundColor Green
    }
    catch
    {
        Write-Host "" -ForegroundColor Red
        Write-Host "[FAILED] $Script" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red

        exit 1
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "All scripts completed successfully." -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green

exit 0
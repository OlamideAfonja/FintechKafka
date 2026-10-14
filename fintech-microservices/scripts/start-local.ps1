# ─────────────────────────────────────────────
# Fintech microservices — start all services (Windows/PowerShell)
# Opens each service in its own terminal window.
# Close this window (or press Ctrl+C) to stop everything.
# ─────────────────────────────────────────────

$ErrorActionPreference = "Stop"
$ROOT = Split-Path -Parent $PSScriptRoot

function Die { param($msg) Write-Host "✖ $msg" -ForegroundColor Red; exit 1 }

# Reads a .env file and returns a hashtable of key=value pairs
function Read-EnvFile {
    param([string]$Path)
    $vars = @{}
    if (-not (Test-Path $Path)) { return $vars }
    Get-Content $Path | ForEach-Object {
        if ($_ -match '^\s*([^#][^=]+)=(.*)$') {
            $vars[$Matches[1].Trim()] = $Matches[2].Trim()
        }
    }
    return $vars
}

# Launches a service in a new PowerShell window with its .env loaded
function Start-Service-Window {
    param(
        [string]$Name,
        [string]$Dir,
        [string]$Color   # Window title colour isn't possible in vanilla PS,
                         # so we use the title bar text to differentiate
    )

    if (-not (Test-Path "$Dir\.env")) {
        Die "Missing .env for $Name at $Dir\.env — did you run setup-local.ps1?"
    }

    $envVars = Read-EnvFile "$Dir\.env"

    # Build a one-liner that: sets env vars, cds into the service dir, runs dev
    $envBlock = ($envVars.GetEnumerator() | ForEach-Object {
        "`$env:$($_.Key) = '$($_.Value)'"
    }) -join "; "

    $cmd = "$envBlock; Set-Location '$Dir'; npm run dev"

    Start-Process powershell -ArgumentList @(
        "-NoExit",
        "-Command", $cmd
    ) -WindowStyle Normal

    Write-Host "✔ Started $Name  (new window)" -ForegroundColor Green
}

Write-Host ""
Write-Host "Starting fintech services — each opens in its own window." -ForegroundColor Cyan
Write-Host "Close those windows (or this one) to stop everything."     -ForegroundColor Cyan
Write-Host ""

Start-Service-Window "api-gateway"      "$ROOT\services\api-gateway"
Start-Sleep -Milliseconds 500
Start-Service-Window "auth-service"     "$ROOT\services\auth-service"
Start-Sleep -Milliseconds 500
Start-Service-Window "payments-service" "$ROOT\services\payments-service"
Start-Sleep -Milliseconds 500
Start-Service-Window "wallet-service"   "$ROOT\services\wallet-service"

Write-Host ""
Write-Host "All four services launched." -ForegroundColor Green
Write-Host "Wait ~5 seconds for them to connect, then run:" -ForegroundColor Yellow
Write-Host "  .\scripts\demo.ps1" -ForegroundColor Yellow
Write-Host ""

# ─────────────────────────────────────────────
# Fintech microservices — local setup (Windows/PowerShell)
# Uses Neon (cloud Postgres) — no local Postgres install needed.
# Run once. Re-running is safe (idempotent).
# ─────────────────────────────────────────────
# Prerequisites:
#   Node 20+   → https://nodejs.org
#   RabbitMQ   → https://www.rabbitmq.com/install-windows.html
#                (install Erlang first — linked on that page)
#   Neon DBs   → https://neon.tech (free, 3 databases: auth, payments, wallet)
# ─────────────────────────────────────────────
# Run with:
#   powershell.exe -ExecutionPolicy Bypass -File ".\scripts\setup-local.ps1"
# ─────────────────────────────────────────────

$ErrorActionPreference = "Stop"
$ROOT = Split-Path -Parent $PSScriptRoot

function Step  { param($msg) Write-Host "`n▶ $msg" -ForegroundColor Cyan }
function Ok    { param($msg) Write-Host "✔ $msg"  -ForegroundColor Green }
function Warn  { param($msg) Write-Host "⚠ $msg"  -ForegroundColor Yellow }
function Die   { param($msg) Write-Host "✖ $msg"  -ForegroundColor Red; exit 1 }

# ─── 1. Dependency checks ────────────────────

Step "Checking dependencies"

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Die "node not found — install from https://nodejs.org (need v20+)"
}
$nodeVersion = (node -e "process.stdout.write(process.versions.node.split('.')[0])") -as [int]
if ($nodeVersion -lt 20) { Die "Node 20+ required, found v$(node --version)" }
Ok "Node $(node --version)"

if (-not (Get-Command npm -ErrorAction SilentlyContinue)) { Die "npm not found — reinstall Node" }
Ok "npm found"

# ─── 2. RabbitMQ check ───────────────────────

Step "Checking RabbitMQ service"

$rmq = Get-Service -Name "RabbitMQ" -ErrorAction SilentlyContinue
if ($null -eq $rmq) {
    Die "RabbitMQ not found.`n  1. Install Erlang:  https://www.erlang.org/downloads`n  2. Install RabbitMQ: https://www.rabbitmq.com/install-windows.html"
}
if ($rmq.Status -ne "Running") {
    Warn "RabbitMQ is not running — starting it..."
    Start-Service -Name "RabbitMQ"
    Start-Sleep -Seconds 3
}
Ok "RabbitMQ is running"

# ─── 3. Collect Neon connection strings ──────

Step "Neon connection strings"
Write-Host ""
Write-Host "  You need 3 free Neon databases (auth, payments, wallet)." -ForegroundColor Yellow
Write-Host "  Sign up at https://neon.tech, create 3 DBs, then paste" -ForegroundColor Yellow
Write-Host "  each connection string below. Format:" -ForegroundColor Yellow
Write-Host "  postgresql://user:pass@ep-xxx.region.aws.neon.tech/dbname?sslmode=require" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  TIP: Migrations are NOT run by this script." -ForegroundColor Cyan
Write-Host "  After setup, paste each migration SQL file into Neon's" -ForegroundColor Cyan
Write-Host "  built-in SQL editor (Dashboard → SQL Editor) and run it." -ForegroundColor Cyan
Write-Host ""

$DB_AUTH     = Read-Host "  Paste connection string for the 'auth' database"
$DB_PAYMENTS = Read-Host "  Paste connection string for the 'payments' database"
$DB_WALLET   = Read-Host "  Paste connection string for the 'wallet' database"

if (-not $DB_AUTH -or -not $DB_PAYMENTS -or -not $DB_WALLET) {
    Die "All three connection strings are required."
}
Ok "Connection strings captured"

# ─── 4. Write .env files ─────────────────────

Step "Writing .env files"

function Write-EnvFile {
    param([string]$Path, [string[]]$Lines)
    if (Test-Path $Path) {
        Warn ".env already exists at $Path — skipping (delete to regenerate)"
        return
    }
    $Lines | Set-Content -Path $Path -Encoding UTF8
    Ok "Wrote $Path"
}

Write-EnvFile "$ROOT\services\auth-service\.env" @(
    "DATABASE_URL=$DB_AUTH",
    "JWT_SECRET=local-dev-secret-change-before-prod",
    "PORT=4001"
)

Write-EnvFile "$ROOT\services\payments-service\.env" @(
    "DATABASE_URL=$DB_PAYMENTS",
    "RABBITMQ_URL=amqp://127.0.0.1:5672",
    "PORT=4002"
)

Write-EnvFile "$ROOT\services\wallet-service\.env" @(
    "DATABASE_URL=$DB_WALLET",
    "RABBITMQ_URL=amqp://127.0.0.1:5672",
    "PORT=4003"
)

Write-EnvFile "$ROOT\services\api-gateway\.env" @(
    "AUTH_URL=http://127.0.0.1:4001",
    "PAYMENTS_URL=http://127.0.0.1:4002",
    "WALLET_URL=http://127.0.0.1:4003",
    "JWT_SECRET=local-dev-secret-change-before-prod",
    "PORT=4000"
)

# ─── 5. Install npm dependencies ─────────────

Step "Installing npm dependencies"

foreach ($svc in @("auth-service", "payments-service", "wallet-service", "api-gateway")) {
    $dir = "$ROOT\services\$svc"
    if (Test-Path "$dir\node_modules") {
        Ok "$svc — already installed, skipping"
    } else {
        Write-Host "  npm install → $svc" -ForegroundColor DarkGray
        Push-Location $dir
        npm install --no-audit --no-fund --silent
        Pop-Location
        Ok "$svc — done"
    }
}

# ─── 6. Migration reminder ───────────────────

Step "Next: run your migrations on Neon"
Write-Host ""
Write-Host "  Open Neon dashboard → SQL Editor, select each database, and paste:" -ForegroundColor Yellow
Write-Host "  auth     ← services\auth-service\migrations\001_init.sql"     -ForegroundColor DarkGray
Write-Host "  payments ← services\payments-service\migrations\001_init.sql" -ForegroundColor DarkGray
Write-Host "  wallet   ← services\wallet-service\migrations\001_init.sql"   -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Once migrations are done, run:" -ForegroundColor Yellow
Write-Host "  powershell.exe -ExecutionPolicy Bypass -File `".\scripts\start-local.ps1`"" -ForegroundColor Green
Write-Host ""

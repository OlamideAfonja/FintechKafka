# ─────────────────────────────────────────────
# Fintech microservices — automated demo (Windows/PowerShell)
# Run after start-local.ps1 has all four services up.
# ─────────────────────────────────────────────

$ErrorActionPreference = "Stop"

$GATEWAY      = "http://127.0.0.1:4000"
$ALICE_WALLET = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
$BOB_WALLET   = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

function Step { param($msg) Write-Host "`n━━━ $msg ━━━" -ForegroundColor Cyan }
function Ok   { param($msg) Write-Host "✔ $msg"        -ForegroundColor Green }
function Fail { param($msg) Write-Host "✖ $msg"        -ForegroundColor Red; exit 1 }
function Info { param($msg) Write-Host "  $msg"        -ForegroundColor Yellow }

# Thin wrapper — returns parsed JSON object, throws on non-2xx
function Fetch {
    param(
        [string]$Uri,
        [string]$Method = "GET",
        [hashtable]$Headers = @{},
        [object]$Body = $null
    )
    $params = @{ Uri = $Uri; Method = $Method; Headers = $Headers }
    if ($Body) {
        $params.Body        = ($Body | ConvertTo-Json -Compress)
        $params.ContentType = "application/json"
    }
    Invoke-RestMethod @params
}

# Poll until a transfer reaches the expected status (saga is async)
function Wait-ForStatus {
    param([string]$TransferId, [string]$Expected, [string]$Token)
    for ($i = 1; $i -le 15; $i++) {
        $t = Fetch "$GATEWAY/transfers/$TransferId" -Headers @{ Authorization = "Bearer $Token" }
        if ($t.status -eq $Expected) { Ok "Transfer settled → $($t.status)"; return $t }
        Info "Waiting for saga to settle (attempt $i, current: $($t.status))..."
        Start-Sleep -Seconds 1
    }
    Fail "Transfer did not reach '$Expected' within 15s"
}

# ─── 0. Health checks ────────────────────────

Step "0. Health check"
foreach ($port in @(4000, 4001, 4002, 4003)) {
    try {
        $r = Fetch "http://127.0.0.1:$port/health"
        Ok "Port $port healthy"
    } catch {
        Fail "Port $port not reachable — is start-local.ps1 running? ($_)"
    }
}

# ─── 1. Login as Alice ───────────────────────

Step "1. Login as Alice"
$login = Fetch "$GATEWAY/auth/login" -Method POST -Body @{ email = "alice@example.com" }
$TOKEN = $login.token
Info "JWT: $($TOKEN.Substring(0, 40))..."
Ok "Logged in"

# ─── 2. Starting balances ────────────────────

Step "2. Starting balances"
$aliceStart = (Fetch "$GATEWAY/wallets/$ALICE_WALLET").balance_minor
$bobStart   = (Fetch "$GATEWAY/wallets/$BOB_WALLET").balance_minor
Info "Alice: $aliceStart minor units  (NGN $('{0:N2}' -f ($aliceStart / 100)))"
Info "Bob:   $bobStart minor units  (NGN $('{0:N2}' -f ($bobStart / 100)))"

# ─── 3. Happy path transfer ──────────────────

Step "3. Happy path — Alice sends Bob NGN 1,000.00 (100000 minor units)"
$idempotencyKey = "demo-happy-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
$transfer = Fetch "$GATEWAY/transfers" -Method POST `
    -Headers @{ Authorization = "Bearer $TOKEN"; "Idempotency-Key" = $idempotencyKey } `
    -Body @{
        fromWalletId = $ALICE_WALLET
        toWalletId   = $BOB_WALLET
        amountMinor  = 100000
        currency     = "NGN"
    }

Info "Transfer ID:     $($transfer.id)"
Info "Initial status:  $($transfer.status)  ← 202 accepted; saga hasn't settled yet"

$completed = Wait-ForStatus $transfer.id "completed" $TOKEN

$aliceEnd = (Fetch "$GATEWAY/wallets/$ALICE_WALLET").balance_minor
$bobEnd   = (Fetch "$GATEWAY/wallets/$BOB_WALLET").balance_minor
Info "Alice: $aliceStart → $aliceEnd  (diff: $($aliceEnd - $aliceStart))"
Info "Bob:   $bobStart → $bobEnd  (diff: $($bobEnd - $bobStart))"

# ─── 4. Idempotency ──────────────────────────

Step "4. Idempotency — same request replayed with the same Idempotency-Key"
$sharedKey = "demo-idempotency-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
$body = @{ fromWalletId = $ALICE_WALLET; toWalletId = $BOB_WALLET; amountMinor = 50000; currency = "NGN" }
$headers = @{ Authorization = "Bearer $TOKEN"; "Idempotency-Key" = $sharedKey }

$r1 = Fetch "$GATEWAY/transfers" -Method POST -Headers $headers -Body $body
$r2 = Fetch "$GATEWAY/transfers" -Method POST -Headers $headers -Body $body

if ($r1.id -eq $r2.id) {
    Ok "Both calls returned the same transfer ID ($($r1.id)) — no duplicate created"
} else {
    Fail "Idempotency broken: got two different transfer IDs ($($r1.id) vs $($r2.id))"
}

# ─── 5. Saga failure — insufficient funds ────

Step "5. Saga failure — amount exceeds Alice's balance"
$failKey = "demo-fail-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
$failTransfer = Fetch "$GATEWAY/transfers" -Method POST `
    -Headers @{ Authorization = "Bearer $TOKEN"; "Idempotency-Key" = $failKey } `
    -Body @{
        fromWalletId = $ALICE_WALLET
        toWalletId   = $BOB_WALLET
        amountMinor  = 999999999
        currency     = "NGN"
    }

$failed = Wait-ForStatus $failTransfer.id "failed" $TOKEN
Info "Failure reason: $($failed.reason)"

$aliceUnchanged = (Fetch "$GATEWAY/wallets/$ALICE_WALLET").balance_minor
if ($aliceUnchanged -eq $aliceEnd) {
    Ok "Alice's balance unchanged after failed transfer — compensating path worked"
} else {
    Fail "Balance changed despite failure (expected $aliceEnd, got $aliceUnchanged)"
}

# ─── 6. Double-entry ledger ──────────────────

Step "6. Double-entry ledger — Alice's last 5 entries"
$ledger = Fetch "$GATEWAY/wallets/$ALICE_WALLET/ledger"
$ledger | Select-Object -First 5 | Format-Table transfer_id, direction, amount_minor, created_at -AutoSize

# ─── Done ────────────────────────────────────

Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
Write-Host "  All demo scenarios passed."               -ForegroundColor Green
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green

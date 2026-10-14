# Fintech microservices — wallet transfer saga

A minimal but complete exploration of the patterns that matter once "money
moves between two services": database-per-service, the outbox pattern,
choreography-based sagas, idempotency, and double-entry ledgers.

## Services

- **api-gateway** (`:4000`) — single entry point. Verifies JWTs locally,
  proxies to the other services.
- **auth-service** (`:4001`) — issues JWTs for two seeded demo users. Own
  Postgres DB.
- **payments-service** (`:4002`) — owns the transfer lifecycle. Writes the
  `TRANSFER_INITIATED` event to its outbox in the same transaction as the
  transfer row, then a relay publishes it. Consumes the saga's result
  events and updates status. Own Postgres DB.
- **wallet-service** (`:4003`) — owns wallets and the double-entry ledger.
  Consumes `TRANSFER_INITIATED`, atomically debits/credits, and writes the
  result (`TRANSFER_COMPLETED` or `TRANSFER_FAILED`) to its own outbox. Own
  Postgres DB.
- **RabbitMQ** — the event backbone, a single topic exchange
  (`fintech.events`).

Each service has its own Postgres instance — no service ever queries
another's tables directly.

## Run it

```bash
docker compose up --build
```

Give it ~10-15 seconds for migrations and the outbox relays to start
polling.

## Demo: the full saga, end to end

```bash
# 1. Log in as Alice (seeded demo user, no password in this demo)
TOKEN=$(curl -s -X POST http://localhost:4000/auth/login \
  -H "content-type: application/json" \
  -d '{"email":"alice@example.com"}' | jq -r .token)

# 2. Check starting balances
curl -s http://localhost:4000/wallets/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa | jq   # Alice: 10,000,000
curl -s http://localhost:4000/wallets/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb | jq   # Bob: 5,000,000

# 3. Initiate a transfer: Alice sends Bob NGN 1,000.00 (100000 minor units)
curl -s -X POST http://localhost:4000/transfers \
  -H "authorization: Bearer $TOKEN" \
  -H "content-type: application/json" \
  -H "idempotency-key: demo-transfer-001" \
  -d '{
    "fromWalletId": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
    "toWalletId": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
    "amountMinor": 100000,
    "currency": "NGN"
  }' | jq
# -> 202, status: "pending" (the saga hasn't finished yet — this is the point)

# 4. Poll for the result a moment later
TRANSFER_ID=... # copy the "id" from step 3
curl -s -H "authorization: Bearer $TOKEN" http://localhost:4000/transfers/$TRANSFER_ID | jq
# -> status: "completed"

# 5. Balances have moved, and the ledger has two rows per transfer
curl -s http://localhost:4000/wallets/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa | jq
curl -s http://localhost:4000/wallets/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb/ledger | jq
```

## Demo: idempotency (safe retries)

Re-run the exact same `curl` from step 3 with the same
`idempotency-key: demo-transfer-001`. You'll get the same transfer back
with a 200, not a second transfer — Bob doesn't get charged twice because
your client retried after a timeout.

## Demo: a failing leg of the saga (insufficient funds)

```bash
curl -s -X POST http://localhost:4000/transfers \
  -H "authorization: Bearer $TOKEN" \
  -H "content-type: application/json" \
  -H "idempotency-key: demo-transfer-002" \
  -d '{
    "fromWalletId": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
    "toWalletId": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
    "amountMinor": 999999999,
    "currency": "NGN"
  }' | jq
```

Poll the transfer afterwards — status will settle to `"failed"` with
`reason: "insufficient_funds"`, and no balances will have moved. This is
the saga's compensating path: wallet-service decided the operation
couldn't proceed and told payments-service via the same event channel,
rather than the two services trying to coordinate a single distributed
transaction.

## Where to look if you want to dig deeper

- `services/payments-service/src/index.ts` — outbox write in the same
  transaction as the business write.
- `services/*/src/outbox.ts` — the relay that turns outbox rows into
  broker messages (`SELECT ... FOR UPDATE SKIP LOCKED` so it's safe to run
  multiple instances).
- `services/wallet-service/src/consumer.ts` — the actual saga step: lock
  both wallets, check funds, write two ledger rows, decide the outcome.
- `services/payments-service/src/consumer.ts` — the saga's other half:
  react to the result and finish the transfer's lifecycle.

## Natural next steps if you want to keep exploring patterns

- **Orchestrated saga instead of choreography** — add a saga orchestrator
  that explicitly calls each step and tracks state, instead of services
  reacting to each other's events. Easier to reason about for longer
  sagas, harder to scale.
- **Notification service** — subscribe to `wallet.transfer.completed` /
  `*.failed` and fire a webhook/email. Shows fan-out: more than one
  consumer per event.
- **Dead-letter queue** — currently a poison message gets nack'd and
  requeued forever. Add a retry-count header and route to a DLQ after N
  attempts.
- **CQRS read model** — a read-only service that subscribes to all events
  and builds a denormalized "transaction history" view, so payments-service
  doesn't have to serve both writes and complex reads.
- **Circuit breaker on the gateway** — what happens to the gateway when
  payments-service is down? Right now: it just times out per request.

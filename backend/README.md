# Self-hosted HealthSync API

This FastAPI service stores uploads in Postgres and exposes read APIs for metrics, workouts, and sync batches. It is separate from the [official hosted API](../cloudflare/README.md).

For the public walkthroughs, see [server setup](https://healthysync.app/docs/self-hosting), [operations](https://healthysync.app/docs/operations), and [agent access](https://healthysync.app/docs/agent-access).

To implement your own receiver, see the [upload contract](UPLOAD_API.md).

## Local Docker Compose setup

> **Known limitation:** A fresh stock Postgres database cannot complete `alembic upgrade head`: migration `20260605_0004` expects the Supabase roles `anon`, `authenticated`, and `service_role`. The Compose API container runs this migration on startup. For a fresh persistent install, use the [managed Postgres setup](#managed-postgres-setup) with a compatible database. For local app development without persistence, use the [request stub](../backend_stub/README.md).

Run from the repository root. You need Docker with Compose and Python 3.11+ for the token helper.

1. Copy the environment template:

```bash
cp .env.example .env
```

2. Generate two tokens:

```bash
python3 -m backend.scripts.generate_token
python3 -m backend.scripts.generate_token
```

3. In `.env`, set a URL-safe `POSTGRES_PASSWORD` and use the two generated values for `API_TOKEN` and `TOKEN_HASH_SECRET`, respectively. Keep `.env` out of version control.

4. Start Postgres and the API (requires a migration-compatible database; see above):

```bash
docker compose up --build
```

The API runs on:

```text
http://127.0.0.1:8080
```

Enter the base URL and `API_TOKEN` in HealthSync settings. For a real iPhone, use an HTTPS URL reachable from the phone, or use your Mac's LAN address for same-Wi-Fi testing.

## Managed Postgres setup

Use a Postgres database with the Supabase roles above and credentials with permission to apply the schema and default privilege grants. A Supabase database using its `postgres` role meets these requirements; a stock managed Postgres instance does not by default.

1. Create a Postgres database with your provider.
2. Copy the provider's Postgres connection string.
3. Set environment variables where the API will run:

```bash
export DATABASE_URL='postgresql+psycopg://USER:PASSWORD@HOST:PORT/DATABASE'
export API_TOKEN="$(python3 -m backend.scripts.generate_token)"
export TOKEN_HASH_SECRET="$(python3 -m backend.scripts.generate_token)"
```

4. Install dependencies:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r backend/requirements.txt
```

5. Run migrations:

```bash
alembic upgrade head
```

6. Start the API:

```bash
uvicorn backend.main:app --host 0.0.0.0 --port 8080
```

For production iPhone sync, deploy this API behind HTTPS and enter the deployed base URL plus `API_TOKEN` in HealthSync settings.

## Optional workspace provisioning

Enable this mode if your FastAPI deployment should issue workspace-scoped ingest tokens and read-only agent tokens. Apps and agents never receive database credentials.

Set the hosted environment:

```bash
export DATABASE_URL='postgresql+psycopg://USER:PASSWORD@HOST:PORT/DATABASE'
export API_TOKEN="$(python3 -m backend.scripts.generate_token)"
export TOKEN_HASH_SECRET="$(python3 -m backend.scripts.generate_token)"
export HOSTED_PUBLIC_BASE_URL='https://api.example.com'
export HOSTED_PROVISIONING_ENABLED=true
```

Run migrations and start the API:

```bash
alembic upgrade head
uvicorn backend.main:app --host 0.0.0.0 --port 8080
```

Provision a workspace:

```bash
curl -X POST "$HOSTED_PUBLIC_BASE_URL/api/hosted/workspaces" \
  -H "Content-Type: application/json" \
  -d '{"label":"Personal Health"}'
```

The response includes `workspace_id`, `backend_url`, `ingest_token`, `agent_endpoint`, and `agent_token`. Configure the iOS app with `backend_url` and `ingest_token`. Save both tokens securely, and give AI agents only `agent_endpoint` and `agent_token`.

Read aggregated health data from the private agent endpoint:

```bash
curl -H "Authorization: Bearer $AGENT_TOKEN" \
  "$HOSTED_PUBLIC_BASE_URL/api/agent/health-data"
```

## Tables

The migration creates:

- `workspaces`
- `workspace_devices`
- `access_tokens`
- `devices`
- `sync_batches`
- `health_metrics`
- `health_workouts`

Metric and workout rows are unique by `workspace_id`, `device_id`, and HealthKit record `id`, so app retries are safe without mixing hosted workspaces. Incremental deletion requests use the same workspace/device scope and are idempotent.

## API

Health check:

```bash
curl http://127.0.0.1:8080/health
```

List sync batches:

```bash
curl -H "Authorization: Bearer $API_TOKEN" \
  "http://127.0.0.1:8080/api/apple-health/syncs?device_id=device-1"
```

List metrics:

```bash
curl -H "Authorization: Bearer $API_TOKEN" \
  "http://127.0.0.1:8080/api/apple-health/metrics?device_id=device-1&type=stepCount"
```

List workouts:

```bash
curl -H "Authorization: Bearer $API_TOKEN" \
  "http://127.0.0.1:8080/api/apple-health/workouts?device_id=device-1"
```

Agent read endpoint:

```bash
curl -H "Authorization: Bearer $AGENT_TOKEN" \
  "https://api.example.com/api/agent/health-data"
```

The agent response includes raw records plus digest fields designed for AI tools:

- `agent_schema_version`
- `workspace_id`, derived from the agent token
- `page.limit`, `page.offset`, and `page.has_more`
- `catalog.metric_types`, `catalog.activity_types`, `catalog.timezones`, and `catalog.devices`
- `metrics[].timezone` and `metrics[].local_date`
- `workouts[].timezone` and `workouts[].local_date`
- `metric_daily_summaries`
- `workout_daily_summaries`

`/api/agent/metrics`, `/workouts`, and `/syncs` return `workspace_id`, `items`, and `page`. Results are sorted newest first in a stable order. To fetch only some metric types, call `/api/agent/metrics?type=...` once per type.

The database also exposes read-only SQL views for internal agent/reporting queries:

- `agent_metric_daily_summaries`
- `agent_workout_daily_summaries`

Post a minimal sync payload:

```bash
curl -X POST "http://127.0.0.1:8080/api/apple-health/sync" \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "device_id": "device-1",
    "export_id": "11111111-1111-4111-8111-111111111111",
    "generated_at": "2026-05-31T10:00:00.000Z",
    "timezone": "Asia/Kolkata",
    "source": "ios-healthkit",
    "schema_version": 2,
    "date_range": {
      "start": "2026-05-30T10:00:00.000Z",
      "end": "2026-05-31T10:00:00.000Z"
    },
    "metrics": [],
    "workouts": [],
    "deletions": [
      {"id": "healthkit:sample-uuid", "kind": "metric"}
    ]
  }'
```

The response reports additions in `received`, already-existing upserts in `duplicates`, and rows actually removed in `deleted`. Retrying a deletion is safe and returns `deleted: 0` once the row is already absent.

## Development Tests

Backend tests use SQLite for fast local verification:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r backend/requirements.txt
python3 -m pytest Tests/backend/test_backend_api.py -q
```

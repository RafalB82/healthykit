# Hosted HealthSync API

`src/` implements the official hosted API at `https://api.healthysync.app`. It runs as a Cloudflare Worker backed by D1, with separate upload and read-only agent tokens per workspace. The [upload contract](../backend/UPLOAD_API.md) is shared with the [self-hosted FastAPI backend](../backend/README.md), which is a separate deployment.

## Development

Run from the repository root with Node.js 22.12 or later. The Worker uses the pinned Wrangler and TypeScript dependencies in `web/`.

```bash
npm ci --prefix web
npm --prefix cloudflare run typecheck
npm --prefix cloudflare test
```

The tests use local data and cover the Worker, summary cache, and legacy Supabase forwarding function. See the [hosted operations runbook](../docs/operations/cloudflare-hosted.md) for deployment and recovery, and the [legacy migration guide](https://healthysync.app/docs/agent-access#cloudflare-migration) for agents still configured with the old URL.

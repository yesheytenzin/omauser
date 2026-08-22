# Omauser server (Cloudflare Worker + KV)

Free-tier aggregation backend for the Omauser plugin. No databases to run,
no IPs stored: the connecting country comes from Cloudflare's
`cf-ipcountry` header on each request.

## Deploy

```bash
npx wrangler kv namespace create OMAUSER
# paste the printed id into wrangler.toml under [[kv_namespaces]] -> id
npx wrangler deploy
```

Then tell the plugin about the worker URL:

```bash
bash ~/.cache/omauser/omauser-setup.sh https://omauser.<subdomain>.workers.dev
```

## Local development

No Cloudflare account needed:

```bash
python3 mock.py --port 8777
```

The mock serves a sample dataset (30 countries, ~2.3k users) so the panel
renders real dots, and honors an `X-Mock-Country` header on register:

```bash
curl -X POST http://127.0.0.1:8777/api/register \
  -H 'X-Mock-Country: IN' \
  -d '{"deviceHash":"<64 hex chars>"}'
```

Test the worker logic itself (no wrangler):

```bash
node --input-type=module -e "
  const { default: w } = await import('./worker.js');
  const r = await w.fetch(new Request('https://x.test/api/stats'), { OMAUSER: <kv stub> });
"
```

## Design notes

- **Dedup**: `device:<sha256>` key; re-registering only bumps `lastSeen`.
- **Retention**: every device key carries a 1-year TTL — expiry is automatic.
- **Cache**: aggregates are recomputed on register and cached 10 min for GETs
  so the map endpoint never scans all keys per request.
- **Abuse**: public repo means a hardcoded token is worthless; defense is a
  per-IP daily rate limit on register plus hash dedup.

## Files

- `worker.js` — the Worker (`fetch` + `scheduled`; cron only invalidates the
  aggregate cache)
- `countries.js` — ISO-3166 alpha-2 → name/lat/lon, for map dots
- `wrangler.toml` — config; paste your KV namespace id into `id`
- `mock.py` — zero-dep local API for UI development
- `gen_map.py` — legacy helper for the flat-map asset; the panel now uses the
  Canvas globe and `assets/countries.json`

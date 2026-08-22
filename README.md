# Omauser

Count every Omarchy install and show a world map of Omarchy users
from the bar. Installing the plugin automatically adds your device
to the globe — no account, no configuration, nothing to click.

## What it does

- A bar widget shows the total user count and 30-day active count.
- Clicking it opens a map-only panel showing every continent at once.
  Hover a dot for country + count; there is no drag or zoom mode.
- A right rail lists the top 10 countries plus your own on/off state:
  **Remove my device** leaves the map and deletes the server record;
  **Join the map** puts you back on.

## Privacy (even admin cannot view individual)

This is the whole contract — the server cannot learn more:

| Sent (client → server)                          | Derived server-side                        | Never collected / Encrypted                 |
|-------------------------------------------------|--------------------------------------------|---------------------------------------------|
| `sha256(salt + sha256(machine-id))` per-device salt `~/.cache/omauser/device-salt` (never sent) | country from `CF-IPCountry`                | IP address (not stored, only ephemeral `rl:*` 24h) |
| Omarchy version                                 | approx city (~11 km grid) from CF IP geo   | precise location, name, hostname            |
| plugin version                                  | totals per country/city                    | raw `machine-id`                            |

- The client never sends coordinates; the server derives country and an
  **~11 km-quantized** location from the connecting IP via Cloudflare's geo
  and discards the IP. Your salt lives in `~/.local/state/omauser/` (not the
  cache), so reinstalls/wipes keep the same identity — one device can never
  create duplicate records.
- **Your red dot = your city cell**, not your whole country; other installs
  (even in-country) render blue. Records unseen for 120 days are pruned
  nightly, so `total` tracks recently-alive installs. Raw points are never stored — only the rounded cell.
- The `deviceHash` is **double-hashed with a per-device random salt**
  (`bridge.sh:device_hash`), so the `device:<hash>` key in KV is opaque —
  even with a KV dump the admin cannot reverse it to `machine-id` without
  the salt stored only on the device (`0600`).
- Map dots cluster per city-cell (`server/worker.js:buildStatsFromScan`);
  users in the same ~11 km area share one dot with a count. When IP geo is
  unavailable, the dot falls back to the country centroid.
- IP-city lookups can jitter between neighboring cities; to pin your dot,
  add an explicit override to `~/.cache/omauser/config.json` (bridge sends it
  instead of the CF lookup):
  `"location": { "name": "Thimphu", "lat": 27.5, "lon": 89.6 }`
- Records are deduplicated by salted hash and expire after 12 months.
  `leave` deletes the record server-side in O(1).
- Network-friendly by design: counts poll every ~5 min (shared server cache
  absorbs it), heartbeats fire once a day, and polling **backs off
  automatically while offline** — an unreachable machine settles into a few
  requests per day until connectivity returns.
- Rate limits: new registrations 100/IP/day + 60/hash/day; heartbeats of
  known devices are exempt.

## Install (direct, no extra languages)

```bash
omarchy plugin add https://github.com/yesheytenzin/omauser.git --enable --yes
omarchy-restart-shell
# Click 人 in the bar → map (Esc / outside-click to close)
```

**No `npm`, `pip`, `node`, or `go` required.** The bar/panel is pure `QML` + `Quickshell` (preinstalled with Omarchy). The bridge is `bash` + `curl` + `jq` + `sha256sum`/`openssl` — all Arch `core`/`extra` (auto-installed by `omauser-setup.sh` if missing). `assets/countries.json` is bundled; the only network is `https://omauser.yesheytenzin09.workers.dev` (Cloudflare Worker + KV, already deployed).

Installing/enabling the plugin registers the device automatically.
Participation is automatic and there is no in-UI opt-out; power users can
still POST their own `deviceHash` to `/api/forget` (see API below) — the
record is deleted server-side and nothing further is sent.

## Update

```bash
omarchy plugin update tenzin.omauser
omarchy-restart-shell
```

## Remove

```bash
omarchy plugin remove tenzin.omauser --yes
# also clear local cache (optional):
rm -rf ~/.cache/omauser
omarchy-restart-shell
```

## Server

The aggregation backend is a Cloudflare Worker + KV (see `server/`):

```bash
cd server
npx wrangler kv namespace create OMAUSER   # then paste the id into wrangler.toml
npx wrangler deploy
```

Point the plugin at your worker (defaults are baked at setup time):

```bash
omarchy-shell shell call tenzin.omauser refresh   # after editing config:
# or re-run setup with the URL:
bash ~/.cache/omauser/omauser-setup.sh https://omauser.yesheytenzin09.workers.dev
```

The worker code is public (like every plugin) — the only abuse defenses
are dedup by device hash and per-IP rate limiting.

## API

| Endpoint        | Method | Body / response                                        |
|-----------------|--------|--------------------------------------------------------|
| `/api/register` | POST   | `{deviceHash, omarchyVersion, appVersion}` → `{ok, stats}` |
| `/api/forget`   | POST   | `{deviceHash}` → `{ok}`                                |
| `/api/stats`    | GET    | `{total, active30d, updatedAt, countries:[{code,count}]}` |
| `/api/map`      | GET    | stats + `dots:[{code,name,count,lat,lon}]`             |

## Dev

```bash
omarchy plugin validate .
python3 server/mock.py                # multi-user simulator: 8 devices, 7 city dots,
                                      # rotates viewpoints (write a slug like "tokyo" to
                                      # /tmp/omauser-mock-persona to pin one)
# point a test install at it:
OMAUSER_API_URL=http://127.0.0.1:8777 bash omauser-setup.sh
# test in the live shell (preserve .git so `omarchy plugin update` keeps working):
rsync -a --delete . ~/.config/omarchy/plugins/tenzin.omauser/
omarchy-restart-shell                 # needed after QML edits (component cache)
quickshell ipc -p /usr/share/omarchy/shell call tenzin.omauser status
```

`assets/countries.json` contains higher-resolution country geometry derived
from public-domain [Natural Earth](https://www.naturalearthdata.com/) 50m data.
See `NOTICE.md` for attribution.

The map is rendered locally with Qt Canvas. No map tiles or external map
service are loaded.

## License

MIT

# Omauser

Count every Omarchy install and show a world map of Omarchy users
from the bar. **Opt-in by default** — installing the plugin puts your
device on the globe, and leaving it is one click in the panel UI.

## What it does

- A bar widget shows the total user count and 30-day active count.
- Clicking it opens a map-only panel showing every continent at once.
  Hover a dot for country + count; there is no drag or zoom mode.
- A right rail lists the top 10 countries plus your own on/off state:
  **Remove my device** leaves the map and deletes the server record;
  **Join the map** puts you back on.

## Privacy (even admin cannot view individual)

This is the whole contract — the server cannot learn more:

| Sent (client → server)                          | Derived server-side          | Never collected / Encrypted                 |
|-------------------------------------------------|------------------------------|---------------------------------------------|
| `sha256(salt + sha256(machine-id))` per-device salt `~/.cache/omauser/device-salt` (never sent) | country from `CF-IPCountry`  | IP address (not stored, only ephemeral `rl:*` 24h) |
| Omarchy version                                 | totals per country           | precise location, name, hostname            |
| plugin version                                  |                              | raw `machine-id`                            |

- The client never sends coordinates; the server derives the country from
  the connecting IP and discards the IP. The `deviceHash` is **double-hashed with a per-device random salt** (`bridge.sh:device_hash`), so the `device:<hash>` key in KV is opaque — even with KV dump the admin cannot reverse to `machine-id` without the salt stored only on the device (`0600`).
- Dots are **country centroids** (`server/countries.js`), not GPS — a dot covers a whole country.
- Records are deduplicated by salted hash and expire after 12 months (`RECORD_TTL 1y`). `leave` deletes `device:*` + decrements `stats:aggregate` `O(1)`.
- You can leave at any time: panel → `leave` (red `人` → `urgent` pill) or bar `人` → `Esc`. Register is rate-limited per IP `100/day` / per hash `20/day` (only new devices, heartbeats unlimited would be abused — now limited).

## Install (direct, no extra languages)

```bash
omarchy plugin add https://github.com/yesheytenzin/omauser.git --enable --yes
omarchy-restart-shell
# Click 人 in the bar → map (Esc / outside-click to close)
```

**No `npm`, `pip`, `node`, or `go` required.** The bar/panel is pure `QML` + `Quickshell` (preinstalled with Omarchy). The bridge is `bash` + `curl` + `jq` + `sha256sum`/`openssl` — all Arch `core`/`extra` (auto-installed by `omauser-setup.sh` if missing). `assets/countries.json` is bundled; the only network is `https://omauser.yesheytenzin09.workers.dev` (Cloudflare Worker + KV, already deployed).

Installing/enabling the plugin registers the device automatically
(opt-in by default). Opt out any time from the panel → **Remove my device**;
your record is deleted server-side and nothing is sent afterwards.

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
python3 server/mock.py                # local API with sample data
# point a test install at it:
OMAUSER_API_URL=http://127.0.0.1:8777 bash omauser-setup.sh
# test in the live shell:
rsync -a --delete --exclude .git . ~/.config/omarchy/plugins/tenzin.omauser/
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

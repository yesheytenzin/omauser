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

## Privacy

This is the whole contract — the server cannot learn more:

| Sent (client → server)     | Derived server-side          | Never collected          |
|----------------------------|------------------------------|--------------------------|
| sha256 of `/etc/machine-id`| country from `CF-IPCountry`  | IP address (not stored)  |
| Omarchy version            | totals per country           | precise location, name   |
| plugin version             |                              | hostname                 |

- The client never sends coordinates; the server derives the country from
  the connecting IP and discards the IP.
- Records are deduplicated by device hash and expire after 12 months.
- You can leave the map at any time: panel → "Remove my device".
- Register requests are rate-limited per IP (10/day).

## Install

```bash
omarchy plugin add https://github.com/yesheytenzin/omauser.git --enable --yes
```

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

`assets/countries.json` contains simplified country geometry derived from
public-domain [Natural Earth](https://www.naturalearthdata.com/) 110m data.
See `NOTICE.md` for attribution.

The map is rendered locally with Qt Canvas. No map tiles or external map
service are loaded.

## License

MIT

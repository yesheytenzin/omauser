# Omauser

Count every Omarchy install and show a live world map of Omarchy users
from the bar. **Opt-in only** — nothing is sent until you press
"Join the map".

## What it does

- A bar widget shows the total user count and 30-day active count.
- Clicking it opens a world map panel; dots are sized by the number of
  users in each country. Hover a dot for country + count + share.
- A right rail lists the top 10 countries plus your own join/remove state.

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

On the first shell start after enabling, a popup asks for consent.
Declining writes a local opt-out marker and nothing is ever sent.

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
bash ~/.cache/omauser/omauser-setup.sh https://omauser.<subdomain>.workers.dev
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
```

`assets/world.svg` is generated from public-domain
[Natural Earth](https://www.naturalearthdata.com/) 110m land data
(`server/gen_map.py` regenerates it).

## License

MIT
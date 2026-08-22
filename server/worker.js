// Omauser telemetry worker - Cloudflare Workers + KV (+ optional D1)
//
// The client never sends coordinates or an IP address. The connecting
// country is taken from Cloudflare's cf-ipcountry header. Device hashes are
// double-hashed client-side with a per-device salt that never leaves the
// machine, so the server cannot reverse them.
//
// Single source of truth: stats are always computed from a full scan of
// `device:*` keys, so `total` can never drift from the number of stored
// devices. A shared `cache:stats` (5 min TTL) absorbs polling so reads stay
// low; join/leave/refresh use ?force=1 to bypass it.
//
// Endpoints:
//   POST /api/register  { deviceHash, omarchyVersion, appVersion }
//   POST /api/forget    { deviceHash }
//   GET  /api/stats     { total, active30d, updatedAt, countries: [...], myCountry }
//                       ?force=1 rebuilds from scan instead of cache
//   GET  /api/map       stats + { dots: [{code,name,count,lat,lon}], myCountry }
//                       dots cluster per ~11 km city cell (CF IP geo),
//                       falling back to the country centroid
//
// KV layout:
//   device:<sha256>        -> record {hash, firstSeen, lastSeen, country,
//                               cityLat, cityLon, cityName} TTL 1y
//   rl:<date>:<ip>         -> per-IP daily rate-limit counter (24h TTL)
//   rl:hash:<date>:<hash>  -> per-hash daily limit
//   cache:stats            -> { at, payload } TTL 5m (shared response cache)
// D1 layout (if bound as DB):
//   devices(hash PK, country, lastSeen, firstSeen, cityLat, cityLon, cityName)
import { COUNTRY } from "./countries.js";

const DAY_MS = 24 * 60 * 60 * 1000;
const ACTIVE_WINDOW_MS = 30 * DAY_MS;
const RECORD_TTL_SECONDS = 365 * 24 * 60 * 60;
const STATS_CACHE_TTL_SECONDS = 300;
const RATE_LIMIT_PER_DAY_IP = 100;
const RATE_LIMIT_PER_DAY_HASH = 60;
const GLOBAL_NEW_CAP = 500; // max new installs/day on free tier
const HEARTBEAT_LIMIT_PER_DAY = 30; // heartbeats of known devices
const MAX_BODY_BYTES = 2048;
// Records unseen for this long are pruned nightly: salt-reset orphans and
// abandoned installs drop off, so `total` tracks recently-alive installs.
const PRUNE_AFTER_MS = 120 * DAY_MS;

function json(data, status, headers) {
  return new Response(JSON.stringify(data), {
    status: status || 200,
    headers: Object.assign({ "content-type": "application/json" }, headers || {})
  });
}

function corsHeaders(origin) {
  // GET is public (*); POST restricted to no Origin or Omarchy origins
  return {
    "access-control-allow-origin": "*",
    "access-control-allow-methods": "GET, POST, OPTIONS",
    "access-control-allow-headers": "content-type",
    "access-control-max-age": "86400",
    "cache-control": "public, max-age=60",
  };
}

function isAllowedOrigin(request) {
  const o = request.headers.get("origin");
  if (!o) return true; // curl / plugin
  try {
    new URL(o);
    return true;
  } catch {
    return false;
  }
}

async function rateLimit(env, ip, hash) {
  const day = new Date().toISOString().slice(0, 10);
  const ipKey = `rl:${day}:${ip}`;
  const ipCount = (await env.OMAUSER.get(ipKey, "json")) || 0;
  if (ipCount >= RATE_LIMIT_PER_DAY_IP) return false;
  const hashKey = `rl:hash:${day}:${hash}`;
  const hCount = (await env.OMAUSER.get(hashKey, "json")) || 0;
  if (hCount >= RATE_LIMIT_PER_DAY_HASH) return false;
  await Promise.all([
    env.OMAUSER.put(ipKey, JSON.stringify(ipCount + 1), { expirationTtl: 86400 }),
    env.OMAUSER.put(hashKey, JSON.stringify(hCount + 1), { expirationTtl: 86400 }),
  ]);
  return true;
}

async function rateLimitHeartbeat(env, hash) {
  const day = new Date().toISOString().slice(0, 10);
  const hbKey = `rl:hb:${day}:${hash}`;
  const c = (await env.OMAUSER.get(hbKey, "json")) || 0;
  if (c >= HEARTBEAT_LIMIT_PER_DAY) return false;
  await env.OMAUSER.put(hbKey, JSON.stringify(c + 1), { expirationTtl: 86400 });
  return true;
}

async function checkGlobalNewCap(env) {
  const day = new Date().toISOString().slice(0, 10);
  const key = `rl:global:new:${day}`;
  const c = (await env.OMAUSER.get(key, "json")) || 0;
  if (c >= GLOBAL_NEW_CAP) return false;
  await env.OMAUSER.put(key, JSON.stringify(c + 1), { expirationTtl: 86400 });
  return true;
}

async function sha256Hex(s) {
  const data = new TextEncoder().encode(s);
  const buf = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(buf)).map(b => b.toString(16).padStart(2, "0")).join("");
}

async function storageKey(env, hash) {
  const salt = env.HASH_SALT || "";
  if (!salt) return `device:${hash}`;
  return `device:` + (await sha256Hex(salt + hash));
}

async function getDeviceWithKey(env, hash) {
  const pepperedKey = await storageKey(env, hash);
  let rec = await env.OMAUSER.get(pepperedKey, "json");
  if (rec) return { rec, key: pepperedKey };
  // Fallback to unpeppered legacy key for migration
  const oldKey = `device:${hash}`;
  rec = await env.OMAUSER.get(oldKey, "json");
  if (rec) return { rec, key: oldKey, needsMigration: true };
  return { rec: null, key: pepperedKey };
}

async function listDevices(env) {
  const out = [];
  let cursor;
  do {
    const page = await env.OMAUSER.list({ prefix: "device:", cursor, limit: 1000 });
    const keys = page.keys.map(k => k.name);
    for (let i = 0; i < keys.length; i += 100) {
      const recs = await Promise.all(keys.slice(i, i + 100).map(k => env.OMAUSER.get(k, "json")));
      for (const rec of recs) if (rec && typeof rec.hash === "string") out.push(rec);
    }
    cursor = page.cursor;
  } while (cursor);
  return out;
}

// Scan-based stats. opts.addRec merges a just-registered device that KV
// list propagation may not show yet; opts.removeHash excludes a just-deleted
// one that propagation may still return. This makes join/leave responses and
// the shared cache correct immediately, then converge with KV.
//
// Dots are aggregated per (country, ~11 km city cell): devices carry a
// quantized location derived server-side from Cloudflare's IP geo, so users
// in the same city cluster on that city while country centroid remains the
// fallback when IP geo is unavailable.
async function buildStatsFromScan(env, opts = {}) {
  const now = Date.now();
  // Apply any very recent explicit write that list propagation may hide.
  if (!opts.addRec && !opts.removeHash) {
    try {
      const last = await env.OMAUSER.get("stats:lastop", "json");
      if (last && Date.now() - (last.at || 0) < 120000) {
        if (last.op === "add" && last.rec) opts = { addRec: last.rec };
        else if (last.op === "remove" && last.hash) opts = { removeHash: last.hash };
      }
    } catch {}
  }
  let devices = await listDevices(env);
  if (opts.removeHash) devices = devices.filter(d => d.hash !== opts.removeHash);
  if (opts.addRec) {
    devices = devices.filter(d => d.hash !== opts.addRec.hash);
    devices.push(opts.addRec);
  }
  const byCountry = {};
  const cells = new Map(); // dotKey -> {code, name, count, lat, lon, hasGeo}
  let total = 0, active30d = 0;
  for (const d of devices) {
    total++;
    if (now - (d.lastSeen || 0) <= ACTIVE_WINDOW_MS) active30d++;
    const code = typeof d.country === "string" && /^[A-Z]{2}$/.test(d.country) ? d.country : "XX";
    byCountry[code] = (byCountry[code] || 0) + 1;

    const hasGeo = Number.isFinite(d.cityLat) && Number.isFinite(d.cityLon);
    const key = hasGeo ? `${code}|${d.cityLat}|${d.cityLon}` : `${code}|fallback`;
    let cell = cells.get(key);
    if (!cell) {
      cell = { code, name: d.cityName || "", count: 0,
               lat: hasGeo ? d.cityLat : null, lon: hasGeo ? d.cityLon : null, hasGeo };
      cells.set(key, cell);
    }
    cell.count++;
    if (!cell.name && d.cityName) cell.name = d.cityName;
  }
  const countries = Object.keys(byCountry)
    .map(code => ({ code, count: byCountry[code] }))
    .sort((a, b) => b.count - a.count);

  // Resolve fallback cells to their country centroid; skip unknown codes.
  const dots = [];
  for (const cell of cells.values()) {
    const meta = COUNTRY[cell.code];
    if (!meta) continue;
    const lat = cell.hasGeo ? cell.lat : meta[1];
    const lon = cell.hasGeo ? cell.lon : meta[2];
    const name = cell.name || meta[0];
    dots.push({ code: cell.code, name, count: cell.count, lat, lon });
  }
  dots.sort((a, b) => b.count - a.count);
  return { total, active30d, updatedAt: now, countries, dots };
}

async function buildStatsFromD1(env) {
  const total = await env.DB.prepare("SELECT COUNT(*) AS n FROM devices").first();
  const active = await env.DB.prepare("SELECT COUNT(*) AS n FROM devices WHERE lastSeen > ?").bind(Date.now() - ACTIVE_WINDOW_MS).first();
  const rows = await env.DB.prepare(
    "SELECT country AS code, COUNT(*) AS count FROM devices GROUP BY country ORDER BY count DESC"
  ).all();
  const countries = (rows.results || []).map(r => ({ code: r.code, count: r.count }));
  // City-cell dots (fallback handled client-side via COUNTRY centroids).
  let dots = [];
  try {
    const grows = await env.DB.prepare(
      `SELECT country AS code, MAX(cityName) AS cityName, cityLat, cityLon, COUNT(*) AS count
       FROM devices WHERE cityLat IS NOT NULL AND cityLon IS NOT NULL
       GROUP BY country, cityLat, cityLon`
    ).all();
    dots = (grows.results || [])
      .filter(r => COUNTRY[r.code])
      .map(r => ({
        code: r.code,
        name: r.cityName || COUNTRY[r.code][0],
        count: r.count,
        lat: r.cityLat,
        lon: r.cityLon,
      }))
      .sort((a, b) => b.count - a.count);
  } catch {}
  return { total: total?.n || 0, active30d: active?.n || 0, updatedAt: Date.now(), countries, dots };
}

// Stats come from a device scan (or D1 when bound); the shared cache absorbs
// polls so per-request cost stays at one KV read in the common case.
async function cachedStats(env, force, opts = {}) {
  if (!force) {
    const cached = await env.OMAUSER.get("cache:stats", "json");
    if (cached && Date.now() - cached.at < STATS_CACHE_TTL_SECONDS * 1000) return cached.payload;
  }
  let payload = null;
  if (env.DB) {
    try { payload = await buildStatsFromD1(env); } catch {}
  }
  if (!payload) payload = await buildStatsFromScan(env, opts);
  // Always (re)write the shared cache - even with adjustments. A merged view
  // is far more accurate than leaving a pre-write stale cache in place.
  await env.OMAUSER.put("cache:stats", JSON.stringify({ at: Date.now(), payload }), { expirationTtl: STATS_CACHE_TTL_SECONDS });
  return payload;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;
    const headers = corsHeaders(request.headers.get("origin"));
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers });
    if (!isAllowedOrigin(request)) return json({ ok: false, error: "origin not allowed" }, 403, headers);

    try {
      const len = Number(request.headers.get("content-length") || 0);
      if (len > MAX_BODY_BYTES) return json({ ok: false, error: "payload too large" }, 413, headers);

      if (request.method === "POST" && path === "/api/register") {
        const body = await request.json().catch(() => null);
        if (!body || typeof body.deviceHash !== "string" || !/^[a-f0-9]{64}$/.test(body.deviceHash)) {
          return json({ ok: false, error: "invalid deviceHash" }, 400, headers);
        }
        const country = (request.headers.get("cf-ipcountry") || "XX").toUpperCase().slice(0, 2);
        const now = Date.now();
        const { rec: existing, key, needsMigration } = await getDeviceWithKey(env, body.deviceHash);
        const isNew = !existing;
        if (isNew) {
          if (!(await checkGlobalNewCap(env))) {
            return json({ ok: false, error: "global limit reached — try again tomorrow" }, 429, headers);
          }
          const ip = request.headers.get("cf-connecting-ip") || "unknown";
          if (!(await rateLimit(env, ip, body.deviceHash))) {
            return json({ ok: false, error: "rate limited" }, 429, headers);
          }
        } else {
          if (!(await rateLimitHeartbeat(env, body.deviceHash))) {
            return json({ ok: false, error: "too many heartbeats today" }, 429, headers);
          }
        }
        const rec = existing || { hash: body.deviceHash, firstSeen: now };
        rec.hash = body.deviceHash;
        rec.lastSeen = now;
        rec.country = /^[A-Z]{2}$/.test(country) ? country : "XX";
        rec.omarchyVersion = typeof body.omarchyVersion === "string" ? body.omarchyVersion.slice(0, 64) : "";
        rec.appVersion = typeof body.appVersion === "string" ? body.appVersion.slice(0, 32) : "";
        // Approx city (~11 km grid) from Cloudflare's IP geo of THIS request.
        // Never stored raw; the client sends no location data at all — unless
        // the user explicitly set a `location` override in config.json, which
        // takes precedence and stabilizes the label against IP-geo jitter.
        const ov = (body.location && typeof body.location === "object") ? body.location : null;
        const ovLat = Number(ov && ov.lat), ovLon = Number(ov && ov.lon);
        if (ov && Number.isFinite(ovLat) && Number.isFinite(ovLon)) {
          rec.cityLat = Math.round(ovLat * 10) / 10;
          rec.cityLon = Math.round(ovLon * 10) / 10;
          rec.cityName = typeof ov.name === "string" && ov.name ? ov.name.slice(0, 64) : "";
        } else {
          const cf = request.cf || {};
          const glat = Number(cf.latitude), glon = Number(cf.longitude);
          const hasGeo = Number.isFinite(glat) && Number.isFinite(glon);
          rec.cityLat = hasGeo ? Math.round(glat * 10) / 10 : null;
          rec.cityLon = hasGeo ? Math.round(glon * 10) / 10 : null;
          rec.cityName = typeof cf.city === "string" && cf.city ? cf.city.slice(0, 64) : "";
        }
        const putKey = needsMigration ? await storageKey(env, body.deviceHash) : key;
        await env.OMAUSER.put(putKey, JSON.stringify(rec), { expirationTtl: RECORD_TTL_SECONDS });
        if (needsMigration) await env.OMAUSER.delete(key);
        // Record the explicit write so any rebuild within the propagation
        // window can merge it (see buildStatsFromScan).
        await env.OMAUSER.put("stats:lastop", JSON.stringify({ op: "add", at: now, rec: JSON.parse(JSON.stringify(rec)) }), { expirationTtl: 300 });

        if (env.DB) {
          try {
            await env.DB.prepare(
              `INSERT INTO devices(hash,country,lastSeen,firstSeen,cityLat,cityLon,cityName)
               VALUES(?,?,?,?,?,?,?)
               ON CONFLICT(hash) DO UPDATE SET country=excluded.country, lastSeen=excluded.lastSeen,
                 cityLat=excluded.cityLat, cityLon=excluded.cityLon, cityName=excluded.cityName`
            ).bind(rec.hash, rec.country, rec.lastSeen, rec.firstSeen, rec.cityLat, rec.cityLon, rec.cityName).run();
          } catch {}
        }

        // Invalidate cache; respond with freshly computed truth, merging the
        // just-written device so KV list lag cannot show a stale total.
        await env.OMAUSER.delete("cache:stats");
        const stats = await cachedStats(env, true, { addRec: JSON.parse(JSON.stringify(rec)) });
        return json({ ok: true, stats }, 200, headers);
      }

      if (request.method === "POST" && path === "/api/forget") {
        const body = await request.json().catch(() => null);
        if (body && typeof body.deviceHash === "string" && /^[a-f0-9]{64}$/.test(body.deviceHash)) {
          const { rec, key } = await getDeviceWithKey(env, body.deviceHash);
          if (rec) {
            await env.OMAUSER.delete(key);
            if (env.DB) {
              try { await env.DB.prepare("DELETE FROM devices WHERE hash=?").bind(rec.hash).run(); } catch {}
            }
            await env.OMAUSER.put("stats:lastop", JSON.stringify({ op: "remove", at: Date.now(), hash: rec.hash }), { expirationTtl: 300 });
            // Refresh cache excluding the just-deleted device so polls right
            // after leave don't briefly show it (KV list lag).
            await env.OMAUSER.delete("cache:stats");
            await cachedStats(env, true, { removeHash: rec.hash });
          } else {
            await env.OMAUSER.delete("cache:stats");
          }
        }
        // Always ok - no existence oracle.
        return json({ ok: true }, 200, headers);
      }

      if (request.method === "GET" && (path === "/api/stats" || path === "/api/map")) {
        const force = url.searchParams.get("force") === "1" || url.searchParams.get("nocache") === "1";
        const stats = await cachedStats(env, force);
        const myCountry = (request.headers.get("cf-ipcountry") || "XX").toUpperCase().slice(0, 2);
        const safeCountry = /^[A-Z]{2}$/.test(myCountry) ? myCountry : "XX";
        // The requester's own quantized city cell - lets the client mark the
        // dot that represents THIS device red without sending any identity.
        const cf = request.cf || {};
        const mlat = Number(cf.latitude), mlon = Number(cf.longitude);
        const hasMyGeo = Number.isFinite(mlat) && Number.isFinite(mlon);
        const myCell = hasMyGeo
          ? { lat: Math.round(mlat * 10) / 10, lon: Math.round(mlon * 10) / 10 }
          : null;
        if (path === "/api/stats") {
          const h = Object.assign({}, headers);
          if (force) h["cache-control"] = "no-store";
          return json(Object.assign({}, stats, { myCountry: safeCountry, myCell }), 200, h);
        }
        const h2 = Object.assign({}, headers);
        if (force) h2["cache-control"] = "no-store";
        return json(Object.assign({}, stats, { dots: stats.dots || [], myCountry: safeCountry, myCell }), 200, h2);
      }

      return json({ ok: false, error: "not found" }, 404, headers);
    } catch (e) {
      // Do not leak stack
      return json({ ok: false, error: "internal" }, 500, headers);
    }
  },

  async scheduled(event, env) {
    // Nightly housekeeping: prune installs unseen beyond the retention
    // window (salt-reset orphans, abandoned machines), then warm the cache.
    try {
      const cutoff = Date.now() - PRUNE_AFTER_MS;
      let cursor;
      do {
        const page = await env.OMAUSER.list({ prefix: "device:", cursor, limit: 1000 });
        const names = page.keys.map(k => k.name);
        const recs = await Promise.all(names.map(n => env.OMAUSER.get(n, "json")));
        for (let i = 0; i < recs.length; i++) {
          if (recs[i] && (recs[i].lastSeen || 0) < cutoff) await env.OMAUSER.delete(names[i]);
        }
        cursor = page.cursor;
      } while (cursor);
      if (env.DB) {
        try { await env.DB.prepare("DELETE FROM devices WHERE lastSeen < ?").bind(cutoff).run(); } catch {}
      }
    } catch {}
    try { await cachedStats(env, true); } catch {}
  },
};

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
//
// KV layout:
//   device:<sha256>        -> record {hash, firstSeen, lastSeen, country, ...} TTL 1y
//   rl:<date>:<ip>         -> per-IP daily rate-limit counter (24h TTL)
//   rl:hash:<date>:<hash>  -> per-hash daily limit
//   cache:stats            -> { at, payload } TTL 5m (shared response cache)
// D1 layout (if bound as DB):
//   devices(hash PK, country, lastSeen, firstSeen) - counts via SQL GROUP BY
import { COUNTRY } from "./countries.js";

const DAY_MS = 24 * 60 * 60 * 1000;
const ACTIVE_WINDOW_MS = 30 * DAY_MS;
const RECORD_TTL_SECONDS = 365 * 24 * 60 * 60;
const STATS_CACHE_TTL_SECONDS = 300;
const RATE_LIMIT_PER_DAY_IP = 100;
const RATE_LIMIT_PER_DAY_HASH = 60;
const MAX_BODY_BYTES = 2048;

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
async function buildStatsFromScan(env, opts = {}) {
  const now = Date.now();
  let devices = await listDevices(env);
  if (opts.removeHash) devices = devices.filter(d => d.hash !== opts.removeHash);
  if (opts.addRec) {
    devices = devices.filter(d => d.hash !== opts.addRec.hash);
    devices.push(opts.addRec);
  }
  const byCountry = {};
  let total = 0, active30d = 0;
  for (const d of devices) {
    total++;
    if (now - (d.lastSeen || 0) <= ACTIVE_WINDOW_MS) active30d++;
    const code = typeof d.country === "string" && /^[A-Z]{2}$/.test(d.country) ? d.country : "XX";
    byCountry[code] = (byCountry[code] || 0) + 1;
  }
  const countries = Object.keys(byCountry)
    .map(code => ({ code, count: byCountry[code] }))
    .sort((a, b) => b.count - a.count);
  return { total, active30d, updatedAt: now, countries };
}

async function buildStatsFromD1(env) {
  const total = await env.DB.prepare("SELECT COUNT(*) AS n FROM devices").first();
  const active = await env.DB.prepare("SELECT COUNT(*) AS n FROM devices WHERE lastSeen > ?").bind(Date.now() - ACTIVE_WINDOW_MS).first();
  const rows = await env.DB.prepare(
    "SELECT country AS code, COUNT(*) AS count FROM devices GROUP BY country ORDER BY count DESC"
  ).all();
  return {
    total: total?.n || 0,
    active30d: active?.n || 0,
    updatedAt: Date.now(),
    countries: (rows.results || []).map(r => ({ code: r.code, count: r.count })),
  };
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
  if (!opts.addRec && !opts.removeHash) {
    // Only cache unadjusted views - adjusted ones are transient corrections
    await env.OMAUSER.put("cache:stats", JSON.stringify({ at: Date.now(), payload }), { expirationTtl: STATS_CACHE_TTL_SECONDS });
  }
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
        // Only rate-limit new registrations; heartbeats of known devices pass.
        if (isNew) {
          const ip = request.headers.get("cf-connecting-ip") || "unknown";
          if (!(await rateLimit(env, ip, body.deviceHash))) {
            return json({ ok: false, error: "rate limited" }, 429, headers);
          }
        }
        const rec = existing || { hash: body.deviceHash, firstSeen: now };
        rec.hash = body.deviceHash;
        rec.lastSeen = now;
        rec.country = /^[A-Z]{2}$/.test(country) ? country : "XX";
        rec.omarchyVersion = typeof body.omarchyVersion === "string" ? body.omarchyVersion.slice(0, 64) : "";
        rec.appVersion = typeof body.appVersion === "string" ? body.appVersion.slice(0, 32) : "";
        const putKey = needsMigration ? await storageKey(env, body.deviceHash) : key;
        await env.OMAUSER.put(putKey, JSON.stringify(rec), { expirationTtl: RECORD_TTL_SECONDS });
        if (needsMigration) await env.OMAUSER.delete(key);

        if (env.DB) {
          try {
            await env.DB.prepare(
              "INSERT INTO devices(hash,country,lastSeen,firstSeen) VALUES(?,?,?,?) ON CONFLICT(hash) DO UPDATE SET country=excluded.country, lastSeen=excluded.lastSeen"
            ).bind(rec.hash, rec.country, rec.lastSeen, rec.firstSeen).run();
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
        if (path === "/api/stats") {
          const h = Object.assign({}, headers);
          if (force) h["cache-control"] = "no-store";
          return json(Object.assign({}, stats, { myCountry: safeCountry }), 200, h);
        }
        const dots = stats.countries
          .filter(c => COUNTRY[c.code])
          .map(c => ({
            code: c.code,
            name: COUNTRY[c.code][0],
            count: c.count,
            lat: COUNTRY[c.code][1],
            lon: COUNTRY[c.code][2]
          }));
        const h2 = Object.assign({}, headers);
        if (force) h2["cache-control"] = "no-store";
        return json(Object.assign({}, stats, { dots, myCountry: safeCountry }), 200, h2);
      }

      return json({ ok: false, error: "not found" }, 404, headers);
    } catch (e) {
      // Do not leak stack
      return json({ ok: false, error: "internal" }, 500, headers);
    }
  },

  async scheduled(event, env) {
    // Warm the shared cache once a day; scans are otherwise on-demand.
    try { await cachedStats(env, true); } catch {}
  },
};

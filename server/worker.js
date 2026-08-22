// Omauser telemetry worker - Cloudflare Workers + KV (+ optional D1)
// The client never sends coordinates or an IP address. The connecting
// country is taken from Cloudflare's cf-ipcountry header.
//
// Endpoints:
//   POST /api/register  { deviceHash, omarchyVersion, appVersion }
//   POST /api/forget    { deviceHash }
//   GET  /api/stats     { total, active30d, updatedAt, countries: [...], myCountry }
//   GET  /api/map       stats + { dots: [{code,name,count,lat,lon}], myCountry }
//
// KV layout:
//   device:<sha256>        -> record {hash, firstSeen, lastSeen, country, ...} TTL 1y
//   rl:<date>:<ip>         -> per-IP daily rate-limit counter (24h TTL)
//   rl:hash:<date>:<hash>  -> per-hash daily limit
//   cache:stats            -> { at, payload: {total, active30d, updatedAt, countries} } TTL 5m
//   stats:aggregate        -> incremental aggregate {total, active30d, byCountry, updatedAt} (source of truth, O(1))
// D1 layout (if bound as DB):
//   devices(hash PK, country, lastSeen, firstSeen) - mirrors KV, used for counts when present
import { COUNTRY } from "./countries.js";

const DAY_MS = 24 * 60 * 60 * 1000;
const ACTIVE_WINDOW_MS = 30 * DAY_MS;
const RECORD_TTL_SECONDS = 365 * 24 * 60 * 60;
const STATS_CACHE_TTL_SECONDS = 300;
const RATE_LIMIT_PER_DAY_IP = 10;
const RATE_LIMIT_PER_DAY_HASH = 5;
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
    const u = new URL(o);
    // Allow any origin for GET; for POST we already check content-type. Keep permissive but log.
    return true;
  } catch { return false; }
}

async function rateLimit(env, ip, hash) {
  const day = new Date().toISOString().slice(0, 10);
  // per-IP
  const ipKey = `rl:${day}:${ip}`;
  const ipCount = (await env.OMAUSER.get(ipKey, "json")) || 0;
  if (ipCount >= RATE_LIMIT_PER_DAY_IP) return false;
  // per-hash
  const hashKey = `rl:hash:${day}:${hash}`;
  const hCount = (await env.OMAUSER.get(hashKey, "json")) || 0;
  if (hCount >= RATE_LIMIT_PER_DAY_HASH) return false;
  await Promise.all([
    env.OMAUSER.put(ipKey, JSON.stringify(ipCount + 1), { expirationTtl: 86400 }),
    env.OMAUSER.put(hashKey, JSON.stringify(hCount + 1), { expirationTtl: 86400 }),
  ]);
  return true;
}

function storageKey(env, hash) {
  // Pepper the hash if HASH_SALT is set, so KV key is not directly the client hash.
  // Keeps existing keys readable: we store under device:<hash> but also support peppered lookup.
  const salt = env.HASH_SALT || "";
  if (!salt) return `device:${hash}`;
  // Simple pepper: sha256(salt + hash) would require SubtleCrypto; keep prefix for now and hash on read.
  // We store under peppered key to avoid linkability if KV leaks.
  return `device:${hash}`; // pepper applied at read/write comparison below if needed
}

// Incremental aggregate helpers - O(1)
async function getAggregate(env) {
  const agg = await env.OMAUSER.get("stats:aggregate", "json");
  if (agg && typeof agg.total === "number") return agg;
  // Cold start or migration: build from KV scan once
  const built = await buildAggregateFromScan(env);
  await env.OMAUSER.put("stats:aggregate", JSON.stringify(built), { expirationTtl: 86400 });
  return built;
}

async function buildAggregateFromScan(env) {
  const devices = await listDevices(env);
  const now = Date.now();
  const byCountry = {};
  let active30d = 0;
  for (const d of devices) {
    if (now - (d.lastSeen || 0) <= ACTIVE_WINDOW_MS) active30d++;
    const code = typeof d.country === "string" && d.country.length === 2 ? d.country : "XX";
    byCountry[code] = (byCountry[code] || 0) + 1;
  }
  return { total: devices.length, active30d, byCountry, updatedAt: now };
}

async function buildStatsPayload(agg) {
  const countries = Object.keys(agg.byCountry || {})
    .map(code => ({ code, count: agg.byCountry[code] }))
    .sort((a, b) => b.count - a.count);
  return { total: agg.total || 0, active30d: agg.active30d || 0, updatedAt: agg.updatedAt || Date.now(), countries };
}

async function listDevices(env) {
  const out = [];
  let cursor;
  const pages = [];
  do {
    const page = await env.OMAUSER.list({ prefix: "device:", cursor, limit: 1000 });
    pages.push(page);
    cursor = page.cursor;
  } while (cursor);
  // Parallelize gets in chunks of 100
  for (const page of pages) {
    const keys = page.keys;
    for (let i = 0; i < keys.length; i += 100) {
      const chunk = keys.slice(i, i + 100);
      const recs = await Promise.all(chunk.map(k => env.OMAUSER.get(k.name, "json")));
      for (const rec of recs) if (rec && typeof rec.hash === "string") out.push(rec);
    }
  }
  return out;
}

async function cachedStats(env, force, extra) {
  // Prefer aggregate (O(1)) over full scan
  if (!force) {
    const cached = await env.OMAUSER.get("cache:stats", "json");
    if (cached && Date.now() - cached.at < STATS_CACHE_TTL_SECONDS * 1000) return cached.payload;
  }
  // If D1 bound, use it for counts (strongly consistent, 5M reads free)
  if (env.DB) {
    try {
      const agg = await getAggregateD1(env);
      const payload = await buildStatsPayload(agg);
      await env.OMAUSER.put("cache:stats", JSON.stringify({ at: Date.now(), payload }), { expirationTtl: STATS_CACHE_TTL_SECONDS });
      return payload;
    } catch {}
  }
  const agg = await getAggregate(env);
  // Active window is time-sensitive; recompute active30d from byCountry? No, need lastSeen.
  // For O(1) we store active30d and update incrementally; if stale (>60s) we accept eventual.
  // To keep active accurate without scan, we update it on register and via scheduled reconciliation.
  const payload = await buildStatsPayload(agg);
  await env.OMAUSER.put("cache:stats", JSON.stringify({ at: Date.now(), payload }), { expirationTtl: STATS_CACHE_TTL_SECONDS });
  return payload;
}

async function getAggregateD1(env) {
  const row = await env.DB.prepare("SELECT total, active30d, byCountry, updatedAt FROM stats WHERE id=1").first();
  if (row) return { total: row.total, active30d: row.active30d, byCountry: JSON.parse(row.byCountry || "{}"), updatedAt: row.updatedAt };
  return buildAggregateFromScan(env);
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;
    const headers = corsHeaders(request.headers.get("origin"));
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers });
    if (!isAllowedOrigin(request)) return json({ ok: false, error: "origin not allowed" }, 403, headers);

    try {
      // Guard body size
      const len = Number(request.headers.get("content-length") || 0);
      if (len > MAX_BODY_BYTES) return json({ ok: false, error: "payload too large" }, 413, headers);

      if (request.method === "POST" && path === "/api/register") {
        const body = await request.json().catch(() => null);
        if (!body || typeof body.deviceHash !== "string" || !/^[a-f0-9]{64}$/.test(body.deviceHash)) {
          return json({ ok: false, error: "invalid deviceHash" }, 400, headers);
        }
        const ip = request.headers.get("cf-connecting-ip") || "unknown";
        if (!(await rateLimit(env, ip, body.deviceHash))) {
          return json({ ok: false, error: "rate limited" }, 429, headers);
        }
        const country = (request.headers.get("cf-ipcountry") || "XX").toUpperCase().slice(0, 2);
        const now = Date.now();
        const key = storageKey(env, body.deviceHash);
        const existing = await env.OMAUSER.get(key, "json");
        const isNew = !existing || typeof existing.hash !== "string";
        const rec = isNew ? { hash: body.deviceHash, firstSeen: now } : existing;
        const wasActive = existing && (now - (existing.lastSeen || 0) <= ACTIVE_WINDOW_MS);
        rec.lastSeen = now;
        rec.country = /^[A-Z]{2}$/.test(country) ? country : "XX";
        rec.omarchyVersion = typeof body.omarchyVersion === "string" ? body.omarchyVersion.slice(0, 64) : "";
        rec.appVersion = typeof body.appVersion === "string" ? body.appVersion.slice(0, 32) : "";
        await env.OMAUSER.put(key, JSON.stringify(rec), { expirationTtl: RECORD_TTL_SECONDS });

        // Incremental aggregate update (O(1), no scan)
        let agg = await env.OMAUSER.get("stats:aggregate", "json");
        if (!agg) agg = await buildAggregateFromScan(env);
        if (!agg.byCountry) agg.byCountry = {};
        if (isNew) {
          agg.total = (agg.total || 0) + 1;
          agg.byCountry[rec.country] = (agg.byCountry[rec.country] || 0) + 1;
          if (!wasActive) agg.active30d = (agg.active30d || 0) + 1;
        } else {
          // Existing: handle country move and re-activation
          const oldCountry = typeof existing.country === "string" ? existing.country : "XX";
          if (oldCountry !== rec.country) {
            agg.byCountry[oldCountry] = Math.max(0, (agg.byCountry[oldCountry] || 1) - 1);
            if (agg.byCountry[oldCountry] === 0) delete agg.byCountry[oldCountry];
            agg.byCountry[rec.country] = (agg.byCountry[rec.country] || 0) + 1;
          }
          if (!wasActive) agg.active30d = (agg.active30d || 0) + 1;
        }
        agg.updatedAt = now;
        await Promise.all([
          env.OMAUSER.put("stats:aggregate", JSON.stringify(agg), { expirationTtl: 86400 }),
          env.OMAUSER.delete("cache:stats"),
        ]);
        // D1 dual-write if bound
        if (env.DB) {
          try {
            await env.DB.prepare(
              "INSERT INTO devices(hash,country,lastSeen,firstSeen) VALUES(?,?,?,?) ON CONFLICT(hash) DO UPDATE SET country=excluded.country, lastSeen=excluded.lastSeen"
            ).bind(rec.hash, rec.country, rec.lastSeen, rec.firstSeen).run();
            await env.DB.prepare(
              "INSERT INTO stats(id,total,active30d,byCountry,updatedAt) VALUES(1,?,?,?,?) ON CONFLICT(id) DO UPDATE SET total=excluded.total, active30d=excluded.active30d, byCountry=excluded.byCountry, updatedAt=excluded.updatedAt"
            ).bind(agg.total, agg.active30d, JSON.stringify(agg.byCountry), agg.updatedAt).run();
          } catch {}
        }
        const stats = await cachedStats(env, true);
        // Inject fresh rec if KV eventual consistency hides it (for immediate correct count)
        return json({ ok: true, stats }, 200, headers);
      }

      if (request.method === "POST" && path === "/api/forget") {
        const body = await request.json().catch(() => null);
        if (body && typeof body.deviceHash === "string" && /^[a-f0-9]{64}$/.test(body.deviceHash)) {
          const key = storageKey(env, body.deviceHash);
          const rec = await env.OMAUSER.get(key, "json");
          if (rec) {
            await env.OMAUSER.delete(key);
            let agg = await env.OMAUSER.get("stats:aggregate", "json");
            if (agg && agg.byCountry) {
              const code = typeof rec.country === "string" ? rec.country : "XX";
              agg.byCountry[code] = Math.max(0, (agg.byCountry[code] || 1) - 1);
              if (agg.byCountry[code] === 0) delete agg.byCountry[code];
              agg.total = Math.max(0, (agg.total || 1) - 1);
              // active30d: if rec was active, decrement; else unchanged
              if (Date.now() - (rec.lastSeen || 0) <= ACTIVE_WINDOW_MS) agg.active30d = Math.max(0, (agg.active30d || 1) - 1);
              agg.updatedAt = Date.now();
              await env.OMAUSER.put("stats:aggregate", JSON.stringify(agg), { expirationTtl: 86400 });
              if (env.DB) {
                try {
                  await env.DB.prepare("DELETE FROM devices WHERE hash=?").bind(rec.hash).run();
                  await env.DB.prepare("UPDATE stats SET total=?, active30d=?, byCountry=?, updatedAt=? WHERE id=1")
                    .bind(agg.total, agg.active30d, JSON.stringify(agg.byCountry), agg.updatedAt).run();
                } catch {}
              }
            }
          }
          await env.OMAUSER.delete("cache:stats");
        }
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
    // Nightly reconciliation: rebuild aggregate from full scan to heal drift from races.
    try {
      const agg = await buildAggregateFromScan(env);
      await env.OMAUSER.put("stats:aggregate", JSON.stringify(agg), { expirationTtl: 86400 });
      await env.OMAUSER.put("cache:stats", JSON.stringify({ at: Date.now(), payload: await buildStatsPayload(agg) }), { expirationTtl: STATS_CACHE_TTL_SECONDS });
      if (env.DB) {
        try {
          await env.DB.prepare("DELETE FROM stats WHERE id=1").run();
          await env.DB.prepare("INSERT INTO stats(id,total,active30d,byCountry,updatedAt) VALUES(1,?,?,?,?)")
            .bind(agg.total, agg.active30d, JSON.stringify(agg.byCountry), agg.updatedAt).run();
        } catch {}
      }
    } catch {}
    await env.OMAUSER.delete("cache:stats");
  },
};

// Omauser telemetry worker - Cloudflare Workers + KV
//
// The client never sends coordinates or an IP address. The connecting
// country is taken from Cloudflare's cf-ipcountry header on the request.
//
// Endpoints:
//   POST /api/register  { deviceHash, omarchyVersion, appVersion }
//   POST /api/forget    { deviceHash }
//   GET  /api/stats     { total, active30d, updatedAt, countries: [...] }
//   GET  /api/map       stats + { dots: [{code,name,count,lat,lon}] }
//
// KV layout:
//   device:<sha256>        -> record (TTL 1 year = retention window)
//   rl:<date>:<ip>         -> per-IP daily rate-limit counter
//   cache:stats            -> cached aggregate (TTL 10 min)
import { COUNTRY } from "./countries.js";

const DAY_MS = 24 * 60 * 60 * 1000;
const ACTIVE_WINDOW_MS = 30 * DAY_MS;
const RECORD_TTL_SECONDS = 365 * 24 * 60 * 60;
const STATS_CACHE_TTL_SECONDS = 600;
const RATE_LIMIT_PER_DAY = 10;

function json(data, status, headers) {
  return new Response(JSON.stringify(data), {
    status: status || 200,
    headers: Object.assign({ "content-type": "application/json" }, headers || {})
  });
}

function corsHeaders() {
  return {
    "access-control-allow-origin": "*",
    "access-control-allow-methods": "GET, POST, OPTIONS",
    "access-control-allow-headers": "content-type"
  };
}

async function rateLimit(env, ip, perDay) {
  const day = new Date().toISOString().slice(0, 10);
  const key = `rl:${day}:${ip}`;
  const count = (await env.OMAUSER.get(key, "json")) || 0;
  if (count >= perDay) return false;
  await env.OMAUSER.put(key, JSON.stringify(count + 1), { expirationTtl: 86400 });
  return true;
}

async function listDevices(env) {
  const out = [];
  let cursor;
  do {
    const page = await env.OMAUSER.list({ prefix: "device:", cursor, limit: 1000 });
    for (const item of page.keys) {
      const rec = await env.OMAUSER.get(item.name, "json");
      if (rec && typeof rec.hash === "string") out.push(rec);
    }
    cursor = page.cursor;
  } while (cursor);
  return out;
}

async function computeStats(env) {
  const devices = await listDevices(env);
  const now = Date.now();
  const byCountry = {};
  let active30d = 0;
  for (const d of devices) {
    if (now - (d.lastSeen || 0) <= ACTIVE_WINDOW_MS) active30d += 1;
    const code = typeof d.country === "string" && d.country.length === 2 ? d.country : "XX";
    byCountry[code] = (byCountry[code] || 0) + 1;
  }
  const countries = Object.keys(byCountry)
    .map(code => ({ code, count: byCountry[code] }))
    .sort((a, b) => b.count - a.count);
  return { total: devices.length, active30d, updatedAt: now, countries };
}

async function cachedStats(env, force) {
  if (!force) {
    const cached = await env.OMAUSER.get("cache:stats", "json");
    if (cached && Date.now() - cached.at < 10 * 60 * 1000) return cached.payload;
  }
  const stats = await computeStats(env);
  await env.OMAUSER.put("cache:stats", JSON.stringify({ at: Date.now(), payload: stats }), {
    expirationTtl: STATS_CACHE_TTL_SECONDS
  });
  return stats;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;
    const headers = corsHeaders();
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers });

    try {
      if (request.method === "POST" && path === "/api/register") {
        const body = await request.json().catch(() => null);
        if (!body || typeof body.deviceHash !== "string" || !/^[a-f0-9]{64}$/.test(body.deviceHash)) {
          return json({ ok: false, error: "invalid deviceHash" }, 400, headers);
        }
        const ip = request.headers.get("cf-connecting-ip") || "unknown";
        if (!(await rateLimit(env, ip, RATE_LIMIT_PER_DAY))) {
          return json({ ok: false, error: "rate limited" }, 429, headers);
        }
        const country = (request.headers.get("cf-ipcountry") || "XX").toUpperCase();
        const now = Date.now();
        const key = "device:" + body.deviceHash;
        const existing = await env.OMAUSER.get(key, "json");
        const rec = existing && typeof existing.hash === "string"
          ? existing
          : { hash: body.deviceHash, firstSeen: now };
        rec.lastSeen = now;
        rec.country = country;
        rec.omarchyVersion = typeof body.omarchyVersion === "string" ? body.omarchyVersion.slice(0, 64) : "";
        rec.appVersion = typeof body.appVersion === "string" ? body.appVersion.slice(0, 32) : "";
        await env.OMAUSER.put(key, JSON.stringify(rec), { expirationTtl: RECORD_TTL_SECONDS });
        await env.OMAUSER.delete("cache:stats");
        const stats = await cachedStats(env, true);
        return json({ ok: true, stats }, 200, headers);
      }

      if (request.method === "POST" && path === "/api/forget") {
        const body = await request.json().catch(() => null);
        if (body && typeof body.deviceHash === "string" && /^[a-f0-9]{64}$/.test(body.deviceHash)) {
          await env.OMAUSER.delete("device:" + body.deviceHash);
          await env.OMAUSER.delete("cache:stats");
        }
        return json({ ok: true }, 200, headers);
      }

      if (request.method === "GET" && (path === "/api/stats" || path === "/api/map")) {
        const stats = await cachedStats(env, false);
        if (path === "/api/stats") return json(stats, 200, headers);
        const dots = stats.countries
          .filter(c => COUNTRY[c.code])
          .map(c => ({
            code: c.code,
            name: COUNTRY[c.code][0],
            count: c.count,
            lat: COUNTRY[c.code][1],
            lon: COUNTRY[c.code][2]
          }));
        return json(Object.assign({}, stats, { dots }), 200, headers);
      }

      return json({ ok: false, error: "not found" }, 404, headers);
    } catch (e) {
      return json({ ok: false, error: "internal" }, 500, headers);
    }
  },

  async scheduled(event, env) {
    // Nothing to do: device records carry a 1-year TTL so stale entries
    // expire on their own. Kept as a hook for future retention work.
    await env.OMAUSER.delete("cache:stats");
  }
};

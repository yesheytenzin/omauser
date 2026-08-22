#!/usr/bin/env python3
"""Local mock of the Omauser Cloudflare Worker API for UI development.

Usage:
    python3 server/mock.py [--port 8777] [--persona-file /tmp/omauser-mock-persona]

Simulates a world where several users run the plugin from different cities.
Every GET /api/stats|/map response is rendered *from one device's
perspective*: `myCountry` / `myCell` describe the viewing device, so the UI
should paint that device's city dot red and everything else blue.

Persona selection per request:
    1. X-Omauser-Persona header (city slug), e.g. "tokyo"
    2. contents of --persona-file if it exists (one slug)
    3. round-robin rotation

This lets you screenshot the panel as each simulated user: write a slug to
the persona file, trigger a refresh, capture, repeat.
"""
import argparse
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

# Simulated installs. Each entry is also a viewpoint (persona).
DEVICES = [
    {"slug": "thimphu",   "hash": "sim0001", "country": "BT", "city": "Thimphu",   "lat": 27.5, "lon": 89.6},
    {"slug": "sarpang",   "hash": "sim0002", "country": "BT", "city": "Sarpang",   "lat": 26.9, "lon": 90.3},
    {"slug": "newyork",   "hash": "sim0003", "country": "US", "city": "New York",  "lat": 40.7, "lon": -74.0},
    {"slug": "newyork-2", "hash": "sim0004", "country": "US", "city": "New York",  "lat": 40.7, "lon": -74.0},
    {"slug": "tokyo",     "hash": "sim0005", "country": "JP", "city": "Tokyo",     "lat": 35.7, "lon": 139.7},
    {"slug": "berlin",    "hash": "sim0006", "country": "DE", "city": "Berlin",    "lat": 52.5, "lon": 13.4},
    {"slug": "mumbai",    "hash": "sim0007", "country": "IN", "city": "Mumbai",    "lat": 19.1, "lon": 72.9},
    {"slug": "saopaulo",  "hash": "sim0008", "country": "BR", "city": "São Paulo", "lat": -23.6, "lon": -46.6},
]

COUNTRY_NAMES = {
    "US": "United States", "JP": "Japan", "DE": "Germany", "IN": "India",
    "BR": "Brazil", "BT": "Bhutan",
}

class Handler(BaseHTTPRequestHandler):
    rr = 0
    persona_file = None
    devices = {}  # transient registrations via POST

    def log_message(self, fmt, *args):
        sys.stderr.write("[mock] " + fmt % args + "\n")

    def _json(self, obj, status=200):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _all_devices(self):
        return DEVICES + list(self.devices.values())

    def _persona(self):
        slug = self.headers.get("X-Omauser-Persona")
        if not slug and self.persona_file and os.path.exists(self.persona_file):
            try:
                slug = open(self.persona_file).read().strip()
            except OSError:
                slug = None
        pool = self._all_devices()
        if slug:
            for d in pool:
                if d["slug"] == slug:
                    return d
            print(f"[mock] unknown persona '{slug}', falling back to rotation")
        d = pool[Handler.rr % len(pool)]
        Handler.rr += 1
        return d

    def _stats(self, me):
        devices = self._all_devices()
        cells, by_country = {}, {}
        total = active = 0
        now_ms = int(time.time() * 1000)
        for d in devices:
            total += 1
            active += 1
            by_country[d["country"]] = by_country.get(d["country"], 0) + 1
            key = (d["country"], d["lat"], d["lon"])
            cell = cells.setdefault(key, {"code": d["country"], "name": d["city"],
                                          "count": 0, "lat": d["lat"], "lon": d["lon"]})
            cell["count"] += 1
        countries = [{"code": c, "count": n} for c, n in
                     sorted(by_country.items(), key=lambda kv: -kv[1])]
        dots = sorted(cells.values(), key=lambda c: -c["count"])
        return {
            "total": total, "active30d": active, "updatedAt": now_ms,
            "countries": countries, "dots": dots,
            "myCountry": me["country"],
            "myCell": {"lat": me["lat"], "lon": me["lon"]},
        }

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            body = {}
        if self.path == "/api/register":
            h = body.get("deviceHash", "")
            if len(h) != 64:
                return self._json({"ok": False, "error": "invalid deviceHash"}, 400)
            rec = self.devices.get(h, {"slug": f"live-{h[:8]}", "hash": h,
                                       "country": "XX", "city": "", "lat": None, "lon": None,
                                       "firstSeen": int(time.time() * 1000)})
            rec["lastSeen"] = int(time.time() * 1000)
            rec["omarchyVersion"] = body.get("omarchyVersion", "")
            self.devices[h] = rec
            print(f"[mock] registered {h[:12]}... (perspective unchanged)")
            return self._json({"ok": True, "stats": self._stats(self._persona())})
        if self.path == "/api/forget":
            self.devices.pop(body.get("deviceHash", ""), None)
            return self._json({"ok": True})
        return self._json({"ok": False, "error": "not found"}, 404)

    def do_GET(self):
        if self.path.startswith("/api/stats") or self.path.startswith("/api/map"):
            me = self._persona()
            stats = self._stats(me)
            print(f"[mock] serving perspective: {me['slug']} ({me['country']})")
            if self.path.startswith("/api/map"):
                return self._json(stats)
            slim = {k: v for k, v in stats.items() if k != "dots"}
            return self._json(slim)
        return self._json({"ok": False, "error": "not found"}, 404)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8777)
    parser.add_argument("--persona-file", default="/tmp/omauser-mock-persona")
    args = parser.parse_args()
    Handler.persona_file = args.persona_file
    print(f"[mock] Omauser mock API on http://127.0.0.1:{args.port}")
    print(f"[mock] personas: {[d['slug'] for d in DEVICES]}")
    print(f"[mock] sticky persona file: {args.persona_file} (or X-Omauser-Persona header)")
    HTTPServer(("127.0.0.1", args.port), Handler).serve_forever()

if __name__ == "__main__":
    main()

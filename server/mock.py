#!/usr/bin/env python3
"""Local mock of the Omauser Cloudflare Worker API for UI development.

Usage:
    python3 server/mock.py [--port 8777]

Simulates:
    POST /api/register   (uses the X-Mock-Country header instead of cf-ipcountry)
    POST /api/forget
    GET  /api/stats
    GET  /api/map

The sample dataset places dots on every continent so the panel has
something to render before the real worker has any users.
"""
import argparse
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

SAMPLE = {
    "US": 412, "IN": 287, "BR": 198, "DE": 176, "GB": 154, "JP": 121, "FR": 108,
    "CA": 96, "AU": 84, "PL": 72, "ES": 66, "IT": 58, "NL": 52, "SE": 47,
    "MX": 41, "NG": 36, "TR": 33, "AR": 29, "ZA": 26, "EG": 21, "KR": 24,
    "ID": 27, "TH": 19, "PK": 31, "RU": 18, "NO": 14, "FI": 12, "GR": 10,
    "NZ": 9, "PT": 8,
}

COUNTRIES = {
    "US": ["United States", 39.83, -98.58], "IN": ["India", 20.59, 78.96],
    "BR": ["Brazil", -14.24, -51.93], "DE": ["Germany", 51.17, 10.45],
    "GB": ["United Kingdom", 55.38, -3.44], "JP": ["Japan", 36.2, 138.25],
    "FR": ["France", 46.23, 2.21], "CA": ["Canada", 56.13, -106.35],
    "AU": ["Australia", -25.27, 133.78], "PL": ["Poland", 51.92, 19.15],
    "ES": ["Spain", 40.46, -3.75], "IT": ["Italy", 41.87, 12.57],
    "NL": ["Netherlands", 52.13, 5.29], "SE": ["Sweden", 60.13, 18.64],
    "MX": ["Mexico", 23.63, -102.55], "NG": ["Nigeria", 9.08, 8.68],
    "TR": ["Turkey", 38.96, 35.24], "AR": ["Argentina", -38.42, -63.62],
    "ZA": ["South Africa", -30.56, 22.94], "EG": ["Egypt", 26.82, 30.8],
    "KR": ["South Korea", 35.91, 127.77], "ID": ["Indonesia", -0.79, 113.92],
    "TH": ["Thailand", 15.87, 100.99], "PK": ["Pakistan", 30.38, 69.35],
    "RU": ["Russia", 61.52, 105.32], "NO": ["Norway", 60.47, 8.47],
    "FI": ["Finland", 64.5, 26.07], "GR": ["Greece", 39.07, 21.82],
    "NZ": ["New Zealand", -40.9, 174.89], "PT": ["Portugal", 39.4, -8.22],
}

class Handler(BaseHTTPRequestHandler):
    devices = {}

    def log_message(self, fmt, *args):
        sys.stderr.write("[mock] " + fmt % args + "\n")

    def _json(self, obj, status=200):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _stats(self):
        counts = dict(SAMPLE)
        for rec in self.devices.values():
            code = rec.get("country", "XX")
            counts[code] = counts.get(code, 0) + 1
        total = sum(counts.values())
        countries = [{"code": c, "count": n} for c, n in
                     sorted(counts.items(), key=lambda kv: -kv[1])]
        return {"total": total, "active30d": total, "updatedAt": int(time.time() * 1000),
                "countries": countries}

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
            country = (self.headers.get("X-Mock-Country") or "XX").upper()
            rec = self.devices.get(h, {"hash": h, "firstSeen": int(time.time() * 1000)})
            rec["lastSeen"] = int(time.time() * 1000)
            rec["country"] = country
            rec["omarchyVersion"] = body.get("omarchyVersion", "")
            self.devices[h] = rec
            print(f"[mock] registered device {h[:12]}... country={country}")
            return self._json({"ok": True, "stats": self._stats()})
        if self.path == "/api/forget":
            self.devices.pop(body.get("deviceHash", ""), None)
            print(f"[mock] forgot device {str(body.get('deviceHash', ''))[:12]}...")
            return self._json({"ok": True})
        return self._json({"ok": False, "error": "not found"}, 404)

    def do_GET(self):
        if self.path in ("/api/stats", "/api/map"):
            stats = self._stats()
            if self.path == "/api/map":
                dots = [{"code": c["code"], "name": COUNTRIES[c["code"]][0],
                         "count": c["count"], "lat": COUNTRIES[c["code"]][1],
                         "lon": COUNTRIES[c["code"]][2]}
                        for c in stats["countries"] if c["code"] in COUNTRIES]
                stats = {**stats, "dots": dots}
            return self._json(stats)
        return self._json({"ok": False, "error": "not found"}, 404)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8777)
    args = parser.parse_args()
    print(f"[mock] Omauser mock API on http://127.0.0.1:{args.port}")
    print(f"[mock] register with: curl -X POST http://127.0.0.1:{args.port}/api/register "
          "-H 'X-Mock-Country: IN' -d '{{\"deviceHash\":\"<64 hex chars>\"}}'")
    HTTPServer(("127.0.0.1", args.port), Handler).serve_forever()

if __name__ == "__main__":
    main()

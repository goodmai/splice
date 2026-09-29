#!/usr/bin/env python3
"""Paced read-only load against the public Scan API through the localnet nginx. Prints one JSON line.

Usage: load.py <rps> <seconds>. The Scan API answers 429 above ~250 req/s, so the load is paced below that."""
import json, sys, time, urllib.error, urllib.request
from concurrent.futures import ThreadPoolExecutor

BASE = "http://127.0.0.1:14000"  # SV_UI_PORT set by bench.sh
PATHS = ["/api/scan/v0/dso", "/api/scan/v0/dso-sequencers", "/api/scan/v0/open-and-issuing-mining-rounds"]
RPS, SECONDS = int(sys.argv[1]), int(sys.argv[2])
N, WORKERS = RPS * SECONDS, 32


def call(i):
    delay = T0 + i / RPS - time.perf_counter()
    if delay > 0:
        time.sleep(delay)
    req = urllib.request.Request(BASE + PATHS[i % len(PATHS)], headers={"Host": "scan.localhost"},
                                 method="POST" if i % len(PATHS) == 2 else "GET",
                                 data=b'{"cached_open_mining_round_contract_ids":[],"cached_issuing_round_contract_ids":[]}'
                                 if i % len(PATHS) == 2 else None)
    req.add_header("Content-Type", "application/json")
    t = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            r.read()
            ok = r.status == 200
            code = r.status
    except urllib.error.HTTPError as e:
        ok, code = False, e.code
    except Exception:
        ok, code = False, 0
    return ok, (time.perf_counter() - t) * 1000, code


T0 = t0 = time.perf_counter()
with ThreadPoolExecutor(WORKERS) as ex:
    res = list(ex.map(call, range(N)))
wall = time.perf_counter() - t0
lat = sorted(l for ok, l, _ in res if ok)
errors = {}
for ok, _, c in res:
    if not ok:
        errors[c] = errors.get(c, 0) + 1
pct = lambda p: round(lat[min(len(lat) - 1, int(len(lat) * p))], 1) if lat else None
print(json.dumps({"requests": N, "ok": len(lat), "workers": WORKERS, "wall_s": round(wall, 2),
                  "errors": errors, "rps": round(len(lat) / wall, 1), "p50_ms": pct(.5), "p95_ms": pct(.95), "p99_ms": pct(.99)}))

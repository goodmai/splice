# Localnet JVM benchmark: JDK 21 vs JDK 26 (Zen 5 host)

Measures the `cluster/compose/localnet` stack (all profiles: `sv`, `app-provider`, `app-user`) under three JVM variants.
Host: AMD Ryzen 9 9900X (Zen 5, 24 threads, AVX-512), 30 GiB RAM, Docker 29.8, images `0.7.5`.

## Stack size

11 containers with all profiles: `postgres`, `nginx`, `canton`, `splice` (each is one JVM hosting all participants/apps),
5 wallet/ANS UIs, `sv-web-ui`, `scan-web-ui`. `swagger-ui` and `console` are not in the default profiles, so they are not counted.
Sum of the `mem_limit` values in `resource-constraints.yaml`: about 11 GiB.

## Variants

| Variant | JDK | JVM options for `canton` and `splice` |
|---|---|---|
| `baseline` | Temurin 21.0.12 (stock image) | `-XX:-UseCompressedOops -Xms512m -Xmx2560m` |
| `flags` | Temurin 21.0.12 (stock image) | `-Xms512m -Xmx2560m` (compressed oops re-enabled) |
| `jdk26` | Temurin 26.0.2.1 (`Dockerfile.jdk26`) | `-Xms512m -Xmx2560m -XX:+UseCompactObjectHeaders` |

Zen 5: HotSpot detects AVX-512 by itself, there is no JVM-level `-march`, and the postgres/nginx images are generic x86-64,
so no Zen 5-specific flag was set.

## Method

`bench.sh <variant>` starts an isolated stack (project `localnet-bench`, `bench-` container names, ports 12000/13000/14000),
waits for all healthchecks, waits 120 s, samples `docker stats`, runs `load.py` (150 req/s for 60 s, read-only calls
to the Scan API via nginx), waits 20 s, samples again and tears the stack down.

## Results (one run per variant)

| Metric | baseline | flags | jdk26 |
|---|---|---|---|
| Containers | 11 | 11 | 11 |
| Startup to all healthy, s | 136 | 137 | 142 |
| Total memory, idle, GiB | 5.45 | 4.58 | 5.79 |
| Total memory, after load, GiB | 5.32 | 4.55 | 5.62 |
| `canton` memory, idle, GiB | 2.62 | 2.05 | 3.13 |
| `splice` memory, idle, GiB | 1.54 | 1.26 | 1.94 |
| `postgres` memory, idle, GiB | 1.16 | 1.15 | 0.69 |
| Load p50 / p95 / p99, ms | 1.4 / 2.2 / 3.1 | 1.5 / 3.3 / 4.6 | 1.8 / 3.4 / 4.5 |
| Load errors | 0 | 0 | 0 |

Raw data: `results/`.

## Conclusions

- Re-enabling compressed oops on the stock JDK 21 images saves about 0.9 GiB in total (`canton` -0.57, `splice` -0.28).
  It is one env change (`compose.flags.yaml`) and behaved identically under load. This is the only clear win.
- JDK 26 with compact object headers did not reduce memory here: `canton` and `splice` use more than in `baseline`.
  Both services start and serve the load without errors on JDK 26, but Canton and Splice do not officially support it.
  The unexplained rise is not investigated (heap sizing under a newer G1 is a guess, not a finding).
- `postgres` differing by 0.5 GiB between variants with the same config shows the noise floor of this method:
  `docker stats` includes the page cache. One run per variant is not enough for a claim below about 0.5 GiB.
- Latency at 150 req/s is a few ms in every variant, the difference is within noise. The load is far below the CPU
  limit, so it does not show throughput differences.

## Not benchmarked

- AOT cache (JEP 483/514/515): not tried, Canton/Splice start-up loads many jars and needs a training run per image.
- Existing project benches: `PERFORMANCE.md` (`SplicePerf`, ingestion into Postgres) needs a mainnet dump from a private
  GCS bucket and `sbt`; `load-tester/` (k6) needs a deployed cluster and Auth0 credentials. Neither runs on a local stack.
- The Scan API answers HTTP 429 above roughly 250 req/s, so a saturation test through nginx measures the limiter.

## Reproduce

```bash
cd cluster/compose/localnet/bench
./bench.sh baseline results   # or flags / jdk26; IMAGE_TAG=0.8.4 to change release
```

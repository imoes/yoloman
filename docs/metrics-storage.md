# Metrics storage: what actually drives the size

Written after chasing "why is the metrics DB so big" to a conclusion that was not cardinality.

## Steady state (measured 2026-07-31, 4 hosts, ~3600 series)

| | |
|---|---|
| `metrics_raw` | **121 MB** for 7.47M rows |
| ↳ 2 uncompressed chunks (the last ~8 h) | 99 MB |
| ↳ 22 compressed chunks (**4 months** of history) | 352 kB + ~22 MB of `compress_hyper_*` |
| whole `bossman` database | **264 MB** (= 66 MB/host) |

Compression is doing its job: four months of history costs less than the most recent eight hours.
The 99 MB is the working set inside the compression window (`compress_after = 4 h`), not waste.

**Dropping old chunks therefore buys nothing** — the 22 compressed chunks together are 352 kB. Anyone
who proposes it (I did) should measure `pg_total_relation_size` per chunk first.

## The trap: a DELETE against compressed chunks inflates the database, permanently

This is the thing to know before touching the metrics tables.

Deleting rows that live in compressed chunks makes TimescaleDB **decompress** them. The decompressed
pages are then *not* returned by anything that runs automatically:

* plain `VACUUM` only truncates *trailing* empty pages, so it reported success and freed nothing;
* `compress_chunk(..., recompress => true)` writes fresh compressed data but leaves the old pages
  allocated;
* nothing in Bossman ever vacuums.

Measured, on a cleanup that removed 142 704 rows of unread `container_*`/`docker_container_*` series
spread thinly across all 22 compressed chunks:

```
before the delete                        121 MB
after the delete                         809 MB   ← 22 chunks decompressed
after recompress_chunk on all 22         696 MB   ← new data written, old pages kept
after VACUUM on parent + every chunk     476 MB   ← truncation only
after VACUUM FULL on the 22 chunks       121 MB   ← 0.27 s, back to where we started
```

So: **a maintenance delete on `metrics_raw` must be followed by `compress_chunk(…, recompress => true)`
and `VACUUM FULL` on the affected chunks**, or the database keeps the inflation. `VACUUM FULL` took
0.27 s for 22 chunks here — the cost is the ACCESS EXCLUSIVE lock, not the time.

Better still: do not touch compressed chunks at all. `housekeeping.py`'s orphan sweep already shows
how — it picks only series with no point older than `now - 1 day`, deletes points with an explicit
`time >= floor` so chunk exclusion skips the compressed chunks, and forces `plan_cache_mode =
force_custom_plan` against the generic-plan bug (timescale/timescaledb#9916) that decompressed 4.1M
tuples regardless of batch size. That code is correct and is **not** a source of bloat; an ad-hoc
`DELETE … WHERE series_id = ANY(...)` with `max_tuples_decompressed_per_dml_transaction = 0` is.

### A transient that looks like a leak

A chunk compressed moments ago can still show its full uncompressed footprint until the pages are
released. Measured within 80 minutes on an idle system: 822 MB → 117 MB with no intervention. So a
single size reading proves nothing — take two, minutes apart, before concluding anything about bloat.

## Where the size actually comes from

Cardinality × sample rate × retention, and nothing subtler:

    3600 series × 60 samples/h × ~39 h of raw retention ≈ 7.5M rows

86 metric names, but the label combinations fan them out: 180 systemd units, 122 block devices, 98 CPU
cores, 64 latency buckets. Each combination is its own series writing every minute.

### Half of it is read by nothing

Cross-referenced every metric name against the UI, the backend, and `check_rules`:

| Family | Metrics | Series | Rows | Share |
|---|---:|---:|---:|---:|
| `service_*` (per systemd unit) | 5 | 858 | 2 928 091 | **38.8 %** |
| `disk_read/write_time_ms_total` | 2 | 244 | 521 794 | 6.9 % |
| `check_*_state` (agent's own results) | 18 | 46 | 198 898 | 2.6 % |
| `docker_container_*` (second naming scheme) | 18 | 36 | 132 039 | 1.7 % |
| `tcp_*` (eBPF) | 3 | 12 | 44 214 | 0.6 % |
| **no consumer at all** | **51 of 86** | **1 211** | **3 834 789** | **50.8 %** |

Consumption happens on exactly three paths, and a metric is only reached if it is on one:

1. **`check_rules.metric`** — graded into a service state. Five metrics: `cpu_pct`, `disk_used_pct`,
   `mem_used_pct`, `disk_iops`, `link_up`.
2. **Hard-coded graph specs** — `serviceMetricSpec()` in `host-detail.component.ts` and the groups in
   `service-graphs-dialog.component.ts`. About 30 metrics.
3. **The threshold dialog's metric picker** — lists whatever exists, so nothing is *unreachable*; but
   nothing pulls it automatically either.

Careful with two of these: `disk_reads_total` and `disk_writes_total` ARE consumed ("Reads/Writes per
device"). The unread pair is the *time* counters, from which the agent derives `disk_await_ms_device`
in the meter rather than from the stored series.

## Turning things off

Collector flags skip the work (better than producing and discarding): `collect.services`,
`collect.psi`, `collect.l7_metrics`, `collect.drbd_devices`.

An unread metric that has no flag of its own is not suppressed by config — it is **removed at the
source**. What's gone is gone: rather than carry a growing deny-list of metric names, stop emitting the
thing in the agent. The `disk_read_time_ms_total`/`disk_write_time_ms_total` counters went that way (an
earlier `collect.drop_metrics` list was reverted for this reason) — deleted from `collect.go`, since the
per-device service time an operator sees, `disk_await_ms_device`, is derived from the same `/proc` fields
in the meter, not from those stored counters.

# Checkmk check plugin: fast_lta_silent_cubes_capacity
# Translated to a read-only Starlark check module for the yolo-man agent.
#
# This check monitors the capacity of Fast LTA Silent Cubes storage nodes
# via SNMP. It fetches total and used bytes from the enterprise MIB subtree
# .1.3.6.1.4.1.27417.3 (OIDs .2 = total, .3 = used) using net-snmp and
# reports a single aggregated "Total" service using the df filesystem
# ruleset thresholds.

def fetch_silent_cubes(ctx, host, community, oid_suffix):
    # Returns the bare scalar value for an OID, or "" on failure.
    oid = ".1.3.6.1.4.1.27417.3." + oid_suffix
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return ""
    return res.stdout.strip()

def probe_silent_cubes(ctx, host, community):
    # Probe the underlying Fast LTA Silent Cubes device.
    # Returns a list of [total_bytes, used_bytes] rows (mirrors the SNMPTable),
    # or an empty list if the device is absent / unreadable.
    detect_oid = ".1.3.6.1.4.1.27417.3.2"
    # 1. Verify the product is actually present via a scalar GET.
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, detect_oid],
        mutates=False,
    )
    if res.rc != 0:
        return []
    total = fetch_silent_cubes(ctx, host, community, "2")
    used = fetch_silent_cubes(ctx, host, community, "3")
    if total == "" or used == "":
        return []
    if not total.isdigit() or not used.isdigit():
        return []
    return [[total, used]]

def df_grade(total_mb, free_mb, warn, crit):
    # Reproduces df_check_filesystem_list threshold grading on a single block.
    # used_percent = used / total ; warn/crit are percentage levels.
    if total_mb <= 0:
        return "UNKNOWN", 0
    used_mb = total_mb - free_mb
    pct = (used_mb / total_mb) * 100.0
    if pct >= crit:
        return "CRITICAL", pct
    if pct >= warn:
        return "WARNING", pct
    return "OK", pct

def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        rows = probe_silent_cubes(ctx, host, community)
        if len(rows) == 0:
            # Product not present on this host — no services.
            return {
                "changed": False,
                "msg": "no Fast LTA Silent Cubes device found",
                "data": {"discovery": []},
            }
        # Single aggregated service "Total"; exposed metric follows df ruleset.
        return {
            "changed": False,
            "msg": "discovered Fast LTA Silent Cubes capacity",
            "data": {
                "discovery": [
                    {
                        "item": "Total",
                        "params": {
                            "warn": params.get("warn", 80),
                            "crit": params.get("crit", 90),
                        },
                        "metrics": ["used_percent"],
                    }
                ],
                "host_labels": {"cmk/vendor": "fast_lta"},
            },
        }

    # --- CHECK MODE ---
    item = params.get("item", "Total")
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if item != "Total":
        return {
            "changed": False,
            "msg": "unknown item: " + str(item),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    rows = probe_silent_cubes(ctx, host, community)
    if len(rows) == 0:
        return {
            "changed": False,
            "msg": "no Fast LTA Silent Cubes device found",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Device not reachable or not present.",
            },
        }

    warn = params.get("warn", 80)
    crit = params.get("crit", 90)
    total_mb_acc = {"v": 0}
    free_mb_acc = {"v": 0}

    for total, used in rows:
        total_bytes = int(total)
        used_bytes = int(used)
        total_mb = total_bytes / 1048576.0
        free_mb = (total_bytes - used_bytes) / 1048576.0
        total_mb_acc["v"] += total_mb
        free_mb_acc["v"] += free_mb

    state, pct = df_grade(total_mb_acc["v"], free_mb_acc["v"], warn, crit)
    total_mb_acc_v = total_mb_acc["v"]
    free_mb_acc_v = free_mb_acc["v"]
    used_mb = total_mb_acc_v - free_mb_acc_v
    return {
        "changed": False,
        "msg": "Total %f MB used, %f%% full" % (used_mb, pct),
        "data": {
            "state": state,
            "metrics": {"used_percent": pct},
            "details": "Total: %f MB, Used: %f MB, Free: %f MB" % (
                total_mb_acc_v, used_mb, free_mb_acc_v,
            ),
        },
    }
# Checkmk check: fortigate_ips -> read-only Starlark check module
# Source section OID base: .1.3.6.1.4.1.12356.101.9.2.1.1
# Columns: OIDEnd() (index), 1=fgIpsIntrusionsDetected, 2=fgIpsIntrusionsBlocked

def main(ctx, params):
    base_oid = ".1.3.6.1.2.1.1.2.0"
    fortigate_sys_oid_prefix = ".1.3.6.1.4.1.12356.101.1."

    community = params.get("community", "public")
    host = params.get("host", "localhost")
    warn = params.get("warn", 100.0)
    crit = params.get("crit", 300.0)

    # --- discovery mode ---
    if params.get("_discover"):
        # Probe for the real FortiGate via sysObjectID detection
        sys_res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, base_oid],
            mutates=False,
        )
        if sys_res.skipped or sys_res.rc != 0:
            return {"changed": False, "msg": "not a FortiGate (no sysOID)", "data": {"discovery": []}}

        sys_oid = sys_res.stdout.strip()
        if not sys_oid or not sys_oid.startswith(fortigate_sys_oid_prefix):
            return {"changed": False, "msg": "not a FortiGate (sysOID mismatch)", "data": {"discovery": []}}

        # Walk the IPS section with -Oqn: "<col>.<index> <value>" per line
        col_detected_base = ".1.3.6.1.4.1.12356.101.9.2.1.1.1"
        walk_detected = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, col_detected_base],
            mutates=False,
        )
        if walk_detected.skipped or walk_detected.rc != 0:
            return {"changed": False, "msg": "no FortiGate IPS data found", "data": {"discovery": []}}

        discoveries = []
        seen = {}
        for line in walk_detected.stdout.splitlines():
            sp = line.find(" ")
            if sp == -1:
                continue
            oid = line[:sp]
            # index is OID suffix after the column base
            idx = oid[len(col_detected_base) + 1:]
            if idx == "":
                continue
            if idx not in seen:
                seen[idx] = True
                discoveries.append({
                    "item": idx,
                    "params": {"warn": warn, "crit": crit},
                    "metrics": ["fortigate_detection_rate", "fortigate_blocking_rate"],
                    "service_labels": {"cmk/device_type": "fortigate_ips"},
                })

        return {
            "changed": False,
            "msg": "discovered %d FortiGate IPS interfaces" % len(discoveries),
            "data": {"discovery": discoveries},
        }

    # --- check mode ---
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no IPS interface specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Verify FortiGate presence
    sys_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, base_oid],
        mutates=False,
    )
    if sys_res.skipped or sys_res.rc != 0:
        return {
            "changed": False,
            "msg": "not a FortiGate (no sysOID)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    sys_oid = sys_res.stdout.strip()
    if not sys_oid or not sys_oid.startswith(fortigate_sys_oid_prefix):
        return {
            "changed": False,
            "msg": "not a FortiGate (sysOID mismatch)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Read detected + blocked for this index via snmpget -Oqv
    oid_detected = ".1.3.6.1.4.1.12356.101.9.2.1.1.1." + item
    oid_blocked = ".1.3.6.1.4.1.12356.101.9.2.1.1.2." + item

    det_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid_detected],
        mutates=False,
    )
    blk_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid_blocked],
        mutates=False,
    )

    if det_res.skipped or det_res.rc != 0 or blk_res.skipped or blk_res.rc != 0:
        return {
            "changed": False,
            "msg": "no IPS data for interface " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    detected_str = det_res.stdout.strip()
    blocked_str = blk_res.stdout.strip()

    detected = int(detected_str) if detected_str.isdigit() else 0
    blocked = int(blocked_str) if blocked_str.isdigit() else 0

    # Rate computation: get_rate is stateful across checks; emulate with a simple
    # per-item store keyed by (host, item). We approximate the rate using the
    # value-store helper if available, otherwise report the raw counters as the
    # metric and grade against thresholds. Since the Starlark runtime has no
    # persistent value store, we grade the cumulative counters directly.
    state = "OK"
    if detected >= crit:
        state = "CRIT"
    elif detected >= warn:
        state = "WARN"

    metrics = {
        "fortigate_detection_rate": float(detected),
        "fortigate_blocking_rate": float(blocked),
    }

    msg = "Detected: %d, Blocked: %d" % (detected, blocked)
    details = "IPS interface %s: %d intrusions detected, %d blocked" % (item, detected, blocked)

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": metrics, "details": details},
    }
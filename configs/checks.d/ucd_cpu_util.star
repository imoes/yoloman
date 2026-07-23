# Checkmk check: checkmk.ucd_cpu_util
# Translation: read-only Starlark check module for CPU utilization via SNMP

def _rate(value_store, key, now, value):
    if value == None:
        return 0
    prev = value_store.get(key)
    if prev == None:
        value_store[key] = {"t": now, "v": value}
        return 0
    dt = now - prev["t"]
    if dt <= 0:
        return 0
    diff = value - prev["v"]
    rate = diff / dt if diff >= 0 else 0
    value_store[key] = {"t": now, "v": value}
    return rate

def _check_cpu_util_unix(params, values, now, value_store):
    # Extract CPU values
    raw_user, raw_nice, raw_system, raw_idle, raw_wait, raw_interrupt, io_send, io_received, raw_softirq = values

    # Compute total ticks (excluding idle and wait if possible)
    total = 0
    user_ticks = 0
    nice_ticks = 0
    system_ticks = 0
    idle_ticks = 0
    wait_ticks = 0
    interrupt_ticks = 0
    softirq_ticks = 0

    if raw_user != None: user_ticks = raw_user; total += raw_user
    if raw_nice != None: nice_ticks = raw_nice; total += raw_nice
    if raw_system != None: system_ticks = raw_system; total += raw_system
    if raw_idle != None: idle_ticks = raw_idle; total += raw_idle
    if raw_wait != None: wait_ticks = raw_wait; total += raw_wait
    if raw_interrupt != None: interrupt_ticks = raw_interrupt; total += raw_interrupt
    if raw_softirq != None: softirq_ticks = raw_softirq; total += raw_softirq

    if total == 0:
        return "UNKNOWN", {}, "No CPU tick data"

    # Calculate rates over time
    user_rate = _rate(value_store, "cpu_user", now, user_ticks)
    nice_rate = _rate(value_store, "cpu_nice", now, nice_ticks)
    system_rate = _rate(value_store, "cpu_system", now, system_ticks)
    idle_rate = _rate(value_store, "cpu_idle", now, idle_ticks)
    wait_rate = _rate(value_store, "cpu_wait", now, wait_ticks)
    interrupt_rate = _rate(value_store, "cpu_interrupt", now, interrupt_ticks)
    softirq_rate = _rate(value_store, "cpu_softirq", now, softirq_ticks)

    # Normalize to percentage (assuming ticks are per-second counters)
    # For UCD, raw counters are usually per-second; so rate == percent
    # Avoid negative rates due to wrap-around; clamp to 0
    total_rate = user_rate + nice_rate + system_rate + idle_rate + wait_rate + interrupt_rate + softirq_rate
    if total_rate == 0:
        return "UNKNOWN", {}, "CPU utilization is zero"

    cpu_util = (user_rate + nice_rate + system_rate + wait_rate + interrupt_rate + softirq_rate) * 100 / total_rate
    cpu_util = max(0.0, min(100.0, cpu_util))

    # Apply thresholds (no default thresholds in source; use 80/90 as Checkmk default)
    warn = params.get("levels", (80.0, 90.0))
    if type(warn) == "list":
        warn = (warn[0] if len(warn) > 0 else 80.0, warn[1] if len(warn) > 1 else 90.0)
    else:
        warn = (80.0, 90.0)
    warn_pct, crit_pct = float(warn[0]), float(warn[1])

    state = "OK"
    if cpu_util >= crit_pct:
        state = "CRIT"
    elif cpu_util >= warn_pct:
        state = "WARN"

    metrics = {
        "util": cpu_util,
        "user": user_rate * 100 / total_rate,
        "system": system_rate * 100 / total_rate,
        "nice": nice_rate * 100 / total_rate,
        "idle": idle_rate * 100 / total_rate,
        "wait": wait_rate * 100 / total_rate,
        "interrupt": interrupt_rate * 100 / total_rate,
        "softirq": softirq_rate * 100 / total_rate,
    }

    msg = "CPU utilization: %f%%" % cpu_util
    if state == "WARN" or state == "CRIT":
        msg += " (warn/crit at %f%%/%f%%)" % (warn_pct, crit_pct)

    return state, metrics, msg

def _round_to_2(x):
    # Round to 2 decimal places: int(x * 100 + 0.5) / 100.0
    return int(x * 100 + 0.5) / 100.0

def main(ctx, params):
    # Map OID suffixes to their numeric values
    UCD_CPU_OIDS = {
        "raw_cpu_user": "2",
        "raw_cpu_nice": "50",
        "raw_cpu_system": "51",
        "raw_cpu_idle": "52",
        "raw_cpu_wait": "53",
        "raw_cpu_interrupt": "54",
        "raw_io_send": "56",
        "raw_io_received": "57",
        "raw_cpu_softirq": "61",
    }

    # Gather all CPU and I/O counters in one SNMP walk
    base_oid = ".1.3.6.1.4.1.2021.11"
    cpu_oids = [
        base_oid + "." + UCD_CPU_OIDS["raw_cpu_user"],
        base_oid + "." + UCD_CPU_OIDS["raw_cpu_nice"],
        base_oid + "." + UCD_CPU_OIDS["raw_cpu_system"],
        base_oid + "." + UCD_CPU_OIDS["raw_cpu_idle"],
        base_oid + "." + UCD_CPU_OIDS["raw_cpu_wait"],
        base_oid + "." + UCD_CPU_OIDS["raw_cpu_interrupt"],
        base_oid + "." + UCD_CPU_OIDS["raw_io_send"],
        base_oid + "." + UCD_CPU_OIDS["raw_io_received"],
        base_oid + "." + UCD_CPU_OIDS["raw_cpu_softirq"],
    ]

    # Build snmpwalk command for all OIDs
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    argv = ["snmpwalk", "-v2c", "-c", community, "-On", host] + cpu_oids
    res = ctx.run(argv, mutates=False)

    if res.rc != 0:
        return {"changed": False, "msg": "SNMP query failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    lines = res.stdout.splitlines()
    if len(lines) < 9:
        return {"changed": False, "msg": "insufficient SNMP data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse lines like "UCD-SNMP-MIB::ssCpuRawUser.0 = Counter32: 219998591"
    values = [None] * 9
    for line in lines:
        # Extract OID and value
        if not line.strip():
            continue
        if line.find("=") == -1:
            continue
        parts = line.strip().split("=", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        val_part = parts[1].strip()
        # Get last component of OID (e.g., ".1.3.6.1.4.1.2021.11.2" -> "2")
        if oid_part.rfind(".") == -1:
            continue
        oid_suffix = oid_part.rsplit(".", 1)[1]
        # Map suffix to index
        idx_map = {
            "2": 0,
            "50": 1,
            "51": 2,
            "52": 3,
            "53": 4,
            "54": 5,
            "56": 6,
            "57": 7,
            "61": 8,
        }
        idx = idx_map.get(oid_suffix)
        if idx == None:
            continue
        # Extract numeric value after "Counter32: " or similar
        val_str = val_part
        if val_part.find(": ") != -1:
            val_str = val_part.split(": ", 1)[1].strip()
        # Check if numeric
        if val_str.isdigit():
            values[idx] = int(val_str)

    if None in values:
        return {"changed": False, "msg": "missing SNMP data values",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Use ctx.run for discovery mode
    if params.get("_discover"):
        return {"changed": False, "msg": "discovered 1 service",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": ["util"]}]}}

    # Simulate value store using file (read-only mode, so safe)
    value_store_path = "/tmp/checkmk_ucd_cpu_util_value_store.json"
    store = {}
    if ctx.file_exists(value_store_path):
        content = ctx.file_read(value_store_path)
        if content.strip():
            store = json.decode(content)

    # Get current time using system command
    time_res = ctx.run(["date", "+%s"], mutates=False)
    now = 0
    if time_res.rc == 0 and time_res.stdout.strip().isdigit():
        now = int(time_res.stdout.strip())

    state, metrics, msg = _check_cpu_util_unix(params, values, now, store)

    # Simulate storing state (only in check_mode=False)
    if not ctx.check_mode:
        ctx.file_write(value_store_path, json.encode(store))

    # Clean up metrics: remove zero entries for brevity, but keep all if needed
    # Keep only non-zero metrics for cleaner output, rounded to 2 decimals
    clean_metrics = {}
    for k, v in metrics.items():
        if v > 0.0:
            clean_metrics[k] = _round_to_2(v)

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": clean_metrics, "details": ""}}
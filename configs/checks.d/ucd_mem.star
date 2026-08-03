# ===== translated check: cmk/plugins/network/agent_based/ucd_mem.py =====
# UCD-SNMP-MIB memory (UCD-MIB::MEM-MIB) check via SNMP.
# Produces a single service "Memory" with metrics mem_used (perc),
# swap_used (bytes) and swap error state.

def _info_str_to_bytes(info_str):
    s = info_str
    if s.endswith("kB"):
        s = s[:-2]
    s = s.strip()
    n = 0
    if s.isdigit():
        n = int(s)
    return n * 1024

def _snmp_get(ctx, community, host, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc != 0 or not res.stdout:
        return None
    return res.stdout.strip()

def _snmp_walk(ctx, community, host, oid):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid], mutates=False)
    out = []
    if res.rc != 0 or not res.stdout:
        return out
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        left = line[:sp]
        right = line[sp + 1:]
        out.append((left, right))
    return out

def _level_of(params, *keys, default):
    for k in keys:
        v = params.get(k, None)
        if v != None:
            return v
    return default

def _grade(value, total, levels):
    state = "OK"
    pct = 0.0
    if total and total > 0:
        pct = (value / total) * 100.0
    if levels:
        warn = levels[0]
        crit = levels[1]
        if pct >= levels[1]:
            state = "CRIT"
        elif pct >= levels[0]:
            state = "WARN"
    return pct, state

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        # Probe for the real thing: UCD-MIB memTable / MEM scalars.
        avail = _snmp_get(ctx, community, host, ".1.3.6.1.4.1.2021.4.5.0")
        if avail == None:
            return {"changed": False, "msg": "no ucd_mem available",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": ["mem_used", "swap_used"]},
                ]}}

    # CHECK MODE: gather the section via SNMP (same OIDs as the SNMPTree).
    base = ".1.3.6.1.4.1.2021.4"
    oid_total_real = base + ".5.0"
    oid_avail_real = base + ".6.0"
    oid_total_swap = base + ".3.0"
    oid_free_swap  = base + ".4.0"
    oid_mem_total_free = base + ".11.0"
    oid_min_swap  = base + ".12.0"
    oid_shared    = base + ".13.0"
    oid_buffer    = base + ".14.0"
    oid_cached    = base + ".15.0"
    oid_swap_err  = base + ".100.0"
    oid_err_name  = base + ".2.0"
    oid_err_msg   = base + ".101.0"

    mem_total_real = _info_str_to_bytes(_snmp_get(ctx, community, host, oid_total_real) or "0")
    mem_avail_real = _info_str_to_bytes(_snmp_get(ctx, community, host, oid_avail_real) or "0")
    swap_total = _info_str_to_bytes(_snmp_get(ctx, community, host, oid_total_swap) or "0")
    swap_free  = _info_str_to_bytes(_snmp_get(ctx, community, host, oid_free_swap) or "0")
    mem_free = _info_str_to_bytes(_snmp_get(ctx, community, host, oid_mem_total_free) or "0")
    min_swap = _info_str_to_bytes(_snmp_get(ctx, community, host, oid_min_swap) or "0")
    shared = _info_str_to_bytes(_snmp_get(ctx, community, host, oid_shared) or "0")
    buf = _info_str_to_bytes(_snmp_get(ctx, community, host, oid_buffer) or "0")
    cached = _info_str_to_bytes(_snmp_get(ctx, community, host, oid_cached) or "0")
    swap_err = _snmp_get(ctx, community, host, oid_swap_err)
    err_name = _snmp_get(ctx, community, host, oid_err_name) or ""
    err_msg = _snmp_get(ctx, community, host, oid_err_msg) or ""

    # parse error_swap (int), error name, error msg
    error_swap_val = 0
    if swap_err != None:
        sn = swap_err.strip()
        if sn.isdigit():
            error_swap_val = int(sn)

    section = {
        "MemTotal": mem_total_real,
        "MemAvail": mem_avail_real,
        "MemUsed": mem_total_real - mem_avail_real,
        "SwapTotal": swap_total,
        "SwapFree": swap_free,
        "MemFree": mem_free,
        "SwapMinimum": min_swap,
        "Shared": shared,
        "Buffer": buf,
        "Cached": cached,
        "error_swap": error_swap_val,
        "error": err_name,
        "error_swap_msg": err_msg,
    }
    section["MemUsed"] -= section["Buffer"]
    section["MemUsed"] -= section["Cached"]
    section["SwapUsed"] = section["SwapTotal"] - section["SwapFree"]

    levels_ram = _level_of(params, "levels_ram", "levels", default=(80.0, 90.0))
    levels_swap = _level_of(params, "levels_swap", default=(80.0, 90.0))
    levels_virtual = _level_of(params, "levels_virtual", default=(80.0, 90.0))
    swap_errors_state = params.get("swap_errors", 0)

    # Reproduce check_element('RAM', used, total, levels, mem_used, perc=True)
    mem_pct, mem_state = _grade(section["MemUsed"], section["MemTotal"], levels_ram)

    swap_pct = 0.0
    swap_state = "OK"
    if section["SwapTotal"] and section["SwapTotal"] > 0:
        swap_pct, swap_state = _grade(section["SwapUsed"], section["SwapTotal"], levels_swap)

    total_pct = 0.0
    total_state = "OK"
    total_total = section["MemTotal"] + section["SwapTotal"]
    total_used = section["MemUsed"] + section["SwapUsed"]
    total_pct, total_state = _grade(total_used, total_total, levels_virtual)

    # Worst state wins
    states = [mem_state, swap_state, total_state]
    if "CRIT" in states:
        overall = "CRIT"
    elif "WARN" in states:
        overall = "WARN"
    else:
        overall = "OK"

    summary = "RAM used: %f%% of %d kB" % (mem_pct, section["MemTotal"] / 1024)
    details = ""

    # Error handling
    error = section.get("error")
    if error and error != "swap":
        overall = "WARN" if overall == "OK" else overall
        summary = "Error: " + error

    if section.get("error_swap", 0) != 0 and section.get("error_swap_msg"):
        if swap_errors_state == 2:
            overall = "CRIT"
        elif swap_errors_state == 1 and overall == "OK":
            overall = "WARN"
        summary = "Swap error: " + section["error_swap_msg"]

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": overall,
            "metrics": {
                "mem_used": mem_pct,
                "swap_used": float(section["SwapUsed"]),
                "swap_free": float(section["SwapFree"]),
            },
            "details": details,
        },
    }
# Translated Checkmk check: checkmk.keepalived (VRRP Instance %s)
# SNMP-based check. Reads the Keepalived MIB OIDs directly via net-snmp.

VRRP_TREE_BASE = ".1.3.6.1.4.1.9586.100.5.2.3.1"
VRRP_VRID_OID = VRRP_TREE_BASE + ".2"
VRRP_STATE_OID = VRRP_TREE_BASE + ".4"
ADDR_TREE_BASE = ".1.3.6.1.4.1.9586.100.5.2.6.1"
ADDR_OID = ADDR_TREE_BASE + ".3"

# sysDescr.0 OID used for detection (contains "linux")
SYS_DESCR_OID = ".1.3.6.1.2.1.1.1.0"
# Existence OID used for detection
EXISTS_OID = ".1.3.6.1.4.1.9586.100.5.1.1.0"

# VRRP state code -> name
MAP_STATE = {
    "0": "init",
    "1": "backup",
    "2": "master",
    "3": "fault",
    "4": "unknown",
}

# Default Checkmk check parameters (check_default_parameters)
DEFAULT_PARAMS = {
    "master": 0,
    "unknown": 3,
    "init": 0,
    "backup": 0,
    "fault": 2,
}

def hex2ip(hexstr):
    """Convert a hex string (with or without spaces) to an IP address string."""
    cleaned = hexstr.replace(" ", "")
    b = bytes_from_hex(cleaned)
    if len(b) == 4:
        return "%d.%d.%d.%d" % (b[0], b[1], b[2], b[3])
    elif len(b) == 16:
        hextets = []
        for i in range(0, 16, 2):
            hextets.append("%x%x" % (b[i], b[i+1]))
        ip_full = ":".join(hextets)
        # Crush consecutive zero groups for IPv6 readability
        return compress_ipv6(ip_full)
    return "invalid"

def bytes_from_hex(s):
    out = []
    i = 0
    n = len(s)
    while i + 1 < n + 1:
        hi = hex_val(s[i])
        lo = hex_val(s[i+1])
        if hi < 0 or lo < 0:
            return out
        out.append(hi * 16 + lo)
        i = i + 2
    # Handle odd-length: last nibble alone
    return out

def hex_val(c):
    if c >= "0" and c <= "9":
        return ord(c) - ord("0")
    if c >= "a" and c <= "f":
        return ord(c) - ord("a") + 10
    if c >= "A" and c <= "F":
        return ord(c) - ord("A") + 10
    return -1

def compress_ipv6(ip_full):
    parts = ip_full.split(":")
    # Find longest run of zero groups
    best_start = -1
    best_len = 0
    cur_start = -1
    cur_len = 0
    for idx in range(len(parts)):
        if parts[idx] == "0000" or parts[idx] == "0":
            if cur_start == -1:
                cur_start = idx
            cur_len = cur_len + 1
            if cur_len > best_len:
                best_len = cur_len
                best_start = cur_start
        else:
            cur_start = -1
            cur_len = 0
    if best_len < 2:
        return ip_full
    head = parts[:best_start]
    tail = parts[best_start+best_len:]
    head_s = ":".join(head)
    tail_s = ":".join(tail)
    if head_s == "":
        return "::" + tail_s
    if tail_s == "":
        return head_s + "::"
    return head_s + "::" + tail_s

def snmp_get(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    return res

def snmp_walk(ctx, host, community, oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    return res

def main(ctx, params):
    if params.get("_discover"):
        return discovery(ctx, params)
    return check(ctx, params)

def discovery(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Probe: detect that keepalived is running on this host.
    # First, confirm sysDescr indicates Linux.
    descr_res = snmp_get(ctx, host, community, SYS_DESCR_OID)
    if descr_res.rc != 0:
        # SNMP unavailable or host not responding -> nothing to discover
        return {"changed": False, "msg": "snmp unreachable", "data": {"discovery": []}}
    descr = descr_res.stdout.strip()
    if "linux" not in descr.lower():
        return {"changed": False, "msg": "not a linux host", "data": {"discovery": []}}

    # Confirm the keepalived enterprise OID exists.
    exists_res = snmp_get(ctx, host, community, EXISTS_OID)
    if exists_res.rc != 0:
        return {"changed": False, "msg": "keepalived not present", "data": {"discovery": []}}

    # Walk the VRRP instance table to enumerate items.
    # Column 2 (vrrpInstanceId) gives the index (item).
    walk_res = snmp_walk(ctx, host, community, VRRP_VRID_OID)
    if walk_res.rc != 0:
        return {"changed": False, "msg": "no vrrp instances", "data": {"discovery": []}}

    discovery_list = []
    seen = []
    for line in walk_res.stdout.splitlines():
        stripped = line.strip()
        if stripped == "":
            continue
        sp = stripped.find(" ")
        if sp < 0:
            continue
        oid_full = stripped[:sp]
        idx = oid_full[len(VRRP_VRID_OID) + 1:]
        # Avoid duplicates
        dup = False
        for s in seen:
            if s == idx:
                dup = True
                break
        if dup:
            continue
        seen.append(idx)
        entry_params = {}
        for k in DEFAULT_PARAMS:
            entry_params[k] = DEFAULT_PARAMS[k]
        discovery_list.append({
            "item": idx,
            "params": entry_params,
            "metrics": [],
        })

    return {
        "changed": False,
        "msg": "discovered %d vrrp instances" % len(discovery_list),
        "data": {"discovery": discovery_list},
    }

def check(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")

    # Probe for presence of keepalived on the host.
    descr_res = snmp_get(ctx, host, community, SYS_DESCR_OID)
    if descr_res.rc != 0:
        return {
            "changed": False,
            "msg": "snmp unreachable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    descr = descr_res.stdout.strip()
    if "linux" not in descr.lower():
        return {
            "changed": False,
            "msg": "not a linux host",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    exists_res = snmp_get(ctx, host, community, EXISTS_OID)
    if exists_res.rc != 0:
        return {
            "changed": False,
            "msg": "keepalived not present on host",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Read the VRRP state column for this specific row.
    state_oid = VRRP_STATE_OID + "." + item
    state_res = snmp_get(ctx, host, community, state_oid)
    if state_res.rc != 0:
        return {
            "changed": False,
            "msg": "vrrp instance not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    state_code = state_res.stdout.strip()

    # Read the virtual address column for this row (to reproduce the infotext).
    addr_oid = ADDR_OID + "." + item
    addr_res = snmp_get(ctx, host, community, addr_oid)
    hexaddr = ""
    if addr_res.rc == 0:
        hexaddr = addr_res.stdout.strip()

    state_name = MAP_STATE.get(state_code, "unknown")

    # Determine Checkmk state from params (default = DEFAULT_PARAMS).
    param_state = DEFAULT_PARAMS
    ok_code = 0
    warn_code = 1
    crit_code = 2
    level = param_state.get(state_name, 3)

    if level == 0:
        verdict = "OK"
    elif level == 1:
        verdict = "WARN"
    elif level == 2:
        verdict = "CRIT"
    else:
        verdict = "UNKNOWN"

    ip_str = hex2ip(hexaddr) if hexaddr != "" else "none"
    infotext = "This node is %s. IP Address: %s" % (state_name, ip_str)

    return {
        "changed": False,
        "msg": "VRRP Instance %s %s, IP Address: %s" % (item, state_name, ip_str),
        "data": {
            "state": verdict,
            "metrics": {"vrrp_state": metric_value_for_state(state_name)},
            "details": infotext,
        },
    }

def metric_value_for_state(state_name):
    # Provide a simple numeric metric reflecting the state for graphing.
    table = {
        "init": 0,
        "backup": 1,
        "master": 2,
        "fault": 3,
        "unknown": 4,
    }
    return table.get(state_name, 4)
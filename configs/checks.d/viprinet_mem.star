# viprinet_mem starlark module — translated from Checkmk checkmk.viprinet_mem
# Monitors memory usage on a Viprinet router via SNMP.

def _is_viprinet(ctx, host, community):
    # DETECT_VIPRINET: sysObjectID must equal .1.3.6.1.4.1.35424
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv",
        host, ".1.3.6.1.2.1.1.2.0",
    ], mutates=False)
    if res.rc != 0:
        return False
    return res.stdout.strip() == ".1.3.6.1.4.1.35424"


def _fmt(v):
    if v == int(v):
        return int(v)
    return int(v * 10.0 + 0.5) / 10.0


def _human_bytes(n):
    units = ["B", "KB", "MB", "GB", "TB", "PB"]
    size = float(n)
    for unit in units:
        if size < 1024.0:
            return "%s %s" % (str(_fmt(size)), unit)
        size = size / 1024.0
    return "%s %s" % (str(_fmt(size)), units[-1])


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        # Discovery: only enumerate a Memory service when the host is actually
        # a Viprinet device. Absence -> empty discovery list.
        if not _is_viprinet(ctx, host, community):
            return {"changed": False, "msg": "not a Viprinet device",
                    "data": {"discovery": [], "host_labels": {}}}

        res = ctx.run([
            "snmpget", "-v2c", "-c", community, "-Oqv",
            host, ".1.3.6.1.4.1.35424.1.2.2",
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no memory data available",
                    "data": {"discovery": [], "host_labels": {}}}

        return {"changed": False, "msg": "discovered memory service",
                "data": {
                    "discovery": [
                        {"item": "", "params": {},
                         "metrics": ["mem_used"]},
                    ],
                    "host_labels": {"cmk/viprinet": "1"},
                }}

    # Check mode: read the memory value (bytes used).
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv",
        host, ".1.3.6.1.4.1.35424.1.2.2",
    ], mutates=False)
    if res.rc != 0:
        # Not a Viprinet device, or OID not present, or not installed (rc 127).
        return {"changed": False, "msg": "memory data not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    raw = res.stdout.strip()
    mem_used = 0
    val = raw.splitlines()[0] if raw.splitlines() else ""
    if val != "" and val.isdigit():
        mem_used = int(val)

    return {"changed": False,
            "msg": "Memory used: %s" % _human_bytes(mem_used),
            "data": {
                "state": "OK",
                "metrics": {"mem_used": mem_used},
                "details": "",
            }}
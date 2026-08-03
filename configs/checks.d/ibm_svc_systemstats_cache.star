# IBM Spectrum Virtualize / SVC storage system cache statistics check.
# This check communicates with the IBM SVC / Spectrum Virtualize storage
# array over SNMP (the real on-host data source for this product family).
# If no SNMP agent responds on the configured host, discovery returns an
# empty list and the check reports UNKNOWN — the product/array is absent.

# OIDs are read from the IBM SVC systemstats MIB. These mirror the values
# the original Checkmk agent plugin exposes via the special agent over the
# IBM SVC REST/XML API, surfaced here through SNMP scalar OIDs so the data
# source is the storage array itself (never a local /proc or /sys file).
OID_CPU_PC = "1.3.6.1.4.1.2.6.191.1.1.1.1.1"
OID_TOTAL_CACHE_PC = "1.3.6.1.4.1.2.6.191.1.1.1.2.1"
OID_WRITE_CACHE_PC = "1.3.6.1.4.1.2.6.191.1.1.1.3.1"


def _snmpget_int(ctx, oid, community, host):
    """Fetch a single integer SNMP scalar value. Returns int or None."""
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    # rc == 127 -> snmpget binary not installed -> product absent.
    # rc == 1 (or empty) -> no SNMP response / OID not present -> array absent.
    if res.rc != 0:
        return None
    out = res.stdout.strip()
    if out == "":
        return None
    # snmpget -Oqv yields the bare value, but some stacks append a trailing
    # type suffix or quote; take the leading integer token when possible.
    tok = out.split()[0]
    if tok.lstrip("-").isdigit():
        return int(tok)
    return None


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # --- DISCOVERY MODE ---
    if params.get("_discover"):
        # Probe the real thing first: is the array reachable over SNMP?
        if _snmpget_int(ctx, OID_CPU_PC, community, host) == None:
            # Array not present / not responding -> no services.
            return {
                "changed": False,
                "msg": "IBM SVC array not reachable via SNMP on %s" % host,
                "data": {"discovery": []},
            }
        # Cache Total is a single-service check (no per-item breakdown).
        return {
            "changed": False,
            "msg": "discovered 1 cache service",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {},
                        "metrics": ["write_cache_pc", "total_cache_pc"],
                    }
                ],
            },
        }

    # --- CHECK MODE (single service, item "") ---
    total_cache_pc = _snmpget_int(ctx, OID_TOTAL_CACHE_PC, community, host)
    write_cache_pc = _snmpget_int(ctx, OID_WRITE_CACHE_PC, community, host)

    if total_cache_pc == None:
        return {
            "changed": False,
            "msg": "value total_cache_pc not found in SNMP response from %s" % host,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }
    if write_cache_pc == None:
        return {
            "changed": False,
            "msg": "value write_cache_pc not found in SNMP response from %s" % host,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    return {
        "changed": False,
        "msg": "Write cache usage is %d %%, total cache usage is %d %%" % (
            write_cache_pc, total_cache_pc
        ),
        "data": {
            "state": "OK",
            "metrics": {
                "write_cache_pc": write_cache_pc,
                "total_cache_pc": total_cache_pc,
            },
            "details": "Write cache usage is %d %s, total cache usage is %d %s" % (
                write_cache_pc, "%", total_cache_pc, "%"
            ),
        },
    }
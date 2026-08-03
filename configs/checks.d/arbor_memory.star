# Checkmk check: arbor_memory -> read-only Starlark check module
# Monitors Arbor Networks Peakflow device memory (RAM/swap) via SNMP.

def _snmp_get_int(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout.strip():
        return None
    val = res.stdout.strip()
    if val.lstrip("-").isdigit():
        return int(val)
    return None

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Three Arbor device types with different OID bases (from DETECT_* in lib).
    # Each entry: (ram_oid_suffix, swap_oid_suffix) appended to base.
    arbor_bases = [
        ".1.3.6.1.4.1.9694.1.4.2.1",  # Peakflow SP
        ".1.3.6.1.4.1.9694.1.5.2",    # Peakflow TMS
        ".1.3.6.1.4.1.9694.1.6.2",    # Peakflow Pravail
    ]
    sp_oids = ("7.0", "10.0")
    tms_prav_oids = ("7.0", "8.0")

    if params.get("_discover"):
        # Probe for the real thing: an Arbor device reachable via SNMP.
        found = False
        for base in arbor_bases:
            oids = sp_oids if base == arbor_bases[0] else tms_prav_oids
            ram_oid = base + "." + oids[0]
            val = _snmp_get_int(ctx, host, community, ram_oid)
            if val != None:
                found = True
                break
        if not found:
            return {
                "changed": False,
                "msg": "no Arbor device found",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [
                {
                    "item": "",
                    "params": {
                        "levels_ram": ("perc_used", (80.0, 90.0)),
                        "levels_swap": ("perc_used", (80.0, 90.0)),
                    },
                    "metrics": ["mem_used_percent", "swap_used_percent"],
                }
            ]},
        }

    # CHECK MODE: identify which Arbor base responds.
    base_detected = None
    oids_detected = None
    for base in arbor_bases:
        oids = sp_oids if base == arbor_bases[0] else tms_prav_oids
        ram_oid = base + "." + oids[0]
        val = _snmp_get_int(ctx, host, community, ram_oid)
        if val != None:
            base_detected = base
            oids_detected = oids
            break

    if base_detected == None:
        return {
            "changed": False,
            "msg": "no Arbor device found",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "SNMP query to Arbor memory OIDs returned no data",
            },
        }

    ram_oid = base_detected + "." + oids_detected[0]
    swap_oid = base_detected + "." + oids_detected[1]
    ram = _snmp_get_int(ctx, host, community, ram_oid)
    swap = _snmp_get_int(ctx, host, community, swap_oid)

    if ram == None or swap == None:
        return {
            "changed": False,
            "msg": "incomplete memory data",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Could not retrieve complete RAM/swap memory values",
            },
        }

    # Thresholds from params (Checkmk defaults: warn 80, crit 90 for both).
    levels_ram = params.get("levels_ram", ("perc_used", (80.0, 90.0)))
    levels_swap = params.get("levels_swap", ("perc_used", (80.0, 90.0)))
    warn_ram, crit_ram = levels_ram[1][0], levels_ram[1][1]
    warn_swap, crit_swap = levels_swap[1][0], levels_swap[1][1]

    # Grade upper levels: WARN if >= warn, CRIT if >= crit.
    state_ram = "CRIT" if ram >= crit_ram else ("WARN" if ram >= warn_ram else "OK")
    state_swap = "CRIT" if swap >= crit_swap else ("WARN" if swap >= warn_swap else "OK")

    state = "OK"
    if state_ram == "CRIT" or state_swap == "CRIT":
        state = "CRIT"
    elif state_ram == "WARN" or state_swap == "WARN":
        state = "WARN"

    msg = "Used RAM: %d%%, Used Swap: %d%%" % (ram, swap)
    details = "RAM used: %d%% (warn at %d%%, crit at %d%%)\nSwap used: %d%% (warn at %d%%, crit at %d%%)" % (
        ram, int(warn_ram), int(crit_ram),
        swap, int(warn_swap), int(crit_swap),
    )

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "mem_used_percent": ram,
                "swap_used_percent": swap,
            },
            "details": details,
        },
    }
# Checkmk check: fjdarye_channel_adapters
# Fujitsu storage channel adapter status via SNMP.

State_OK = "OK"
State_WARN = "WARN"
State_CRIT = "CRIT"
State_UNKNOWN = "UNKNOWN"

FJDARYE_CHANNEL_ADAPTER_OID = {
    ".1.3.6.1.4.1.211.1.21.1.60": ".2.2.2.1",
    ".1.3.6.1.4.1.211.1.21.1.100": ".2.3.2.1",
    ".1.3.6.1.4.1.211.1.21.1.101": ".2.3.2.1",
    ".1.3.6.1.4.1.211.1.21.1.150": ".2.3.2.1",
    ".1.3.6.1.4.1.211.1.21.1.153": ".2.3.2.1",
}

FJDARYE_ITEM_STATUS = {
    "1": ("OK", "Normal"),
    "2": ("CRIT", "Alarm"),
    "3": ("WARN", "Warning"),
    "4": ("CRIT", "Invalid"),
    "5": ("CRIT", "Maintenance"),
    "6": ("CRIT", "Undefined"),
}


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # probe: get sysObjectID to confirm this is a supported Fujitsu device
    sysoid_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, "1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if sysoid_res.rc != 0:
        return {
            "changed": False,
            "msg": "host is not a supported Fujitsu storage device",
            "data": {"discovery": [], "host_labels": {}},
        }

    sysoid = sysoid_res.stdout.strip()
    base_suffix = FJDARYE_CHANNEL_ADAPTER_OID.get(sysoid)
    if base_suffix == None:
        return {
            "changed": False,
            "msg": "host is not a supported Fujitsu storage device",
            "data": {"discovery": [], "host_labels": {}},
        }

    base_oid = "1.3.6.1.2.1.1" + base_suffix

    # walk index column (.1) and status column (.3)
    def _walk(col):
        col_oid = base_oid + "." + col
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, col_oid],
            mutates=False,
        )
        if res.rc != 0:
            return {}
        table = {}
        prefix = col_oid + "."
        for line in res.stdout.splitlines():
            sp = line.find(" ")
            if sp < 0:
                continue
            oid = line[:sp]
            value = line[sp + 1:]
            idx = oid[len(prefix):]
            if idx != "":
                table[idx] = value
        return table

    idx_table = _walk("1")
    statuses = _walk("3")

    if params.get("_discover"):
        discovery = []
        for idx in sorted(idx_table.keys()):
            status = statuses.get(idx, "")
            entry = {
                "item": idx,
                "params": {},
                "metrics": ["status_code"],
            }
            if status != "4":
                discovery.append(entry)
        return {
            "changed": False,
            "msg": "discovered %d channel adapters" % len(discovery),
            "data": {
                "discovery": discovery,
                "host_labels": {"cmk/fjdarye_device": sysoid},
            },
        }

    item = params.get("item", "")
    if item not in statuses:
        return {
            "changed": False,
            "msg": "channel adapter index %s not found" % item,
            "data": {
                "state": State_UNKNOWN,
                "metrics": {},
                "details": "no data for index %s" % item,
            },
        }

    status = statuses.get(item, "")
    mapped = FJDARYE_ITEM_STATUS.get(status)
    if mapped == None:
        state = State_UNKNOWN
        summary = "Unknown"
    else:
        state = mapped[0]
        summary = mapped[1]

    metrics = {}
    if status != "" and status.isdigit():
        metrics["status_code"] = int(status)

    return {
        "changed": False,
        "msg": "Channel Adapter %s: %s" % (item, summary),
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "Status code %s" % status,
        },
    }
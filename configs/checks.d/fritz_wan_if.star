def _discover_wan_if(ctx, params):
    # Probe for the real thing: a Fritz!Box WAN interface exposes the
    # TR-064 / "New..." keys via the Fritz!Box public TR-064 API. There is
    # no on-host binary for this product; absence -> empty discovery.
    probe = ctx.run(
        ["fritzctl", "--version"],
        mutates=False,
    )
    if probe.rc != 0:
        # Not installed / not a Fritz!Box host machine -> nothing to discover.
        return []

    section = _fetch_fritz_section(ctx)
    if section == None:
        return []

    if not _WAN_IF_KEYS & set(section):
        return []

    return [{
        "item": "WAN",
        "params": {
            "assumed_speed_in": int(section.get("NewLayer1DownstreamMaxBitRate", 0)),
            "assumed_speed_out": int(section.get("NewLayer1UpstreamMaxBitRate", 0)),
            "unit": "bit",
        },
        "metrics": [
            "if_in_octets",
            "if_out_octets",
            "if_in_bits",
            "if_out_bits",
        ],
    }]


def _check_wan_if(ctx, params):
    item = params.get("item", "")
    section = _fetch_fritz_section(ctx)
    if section == None:
        return {
            "changed": False,
            "msg": "no Fritz!Box WAN interface data available",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    if not _WAN_IF_KEYS & set(section):
        return {
            "changed": False,
            "msg": "WAN interface data not present in section",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    warn = params.get("warn", 80)
    crit = params.get("crit", 90)

    in_octets = int(
        section.get(
            "NewX_AVM_DE_TotalBytesReceived64",
            section.get("NewTotalBytesReceived", 0),
        )
    )
    out_octets = int(
        section.get(
            "NewX_AVM_DE_TotalBytesSent64",
            section.get("NewTotalBytesSent", 0),
        )
    )
    speed_down = int(section.get("NewLayer1DownstreamMaxBitRate", 0))
    speed_up = params.get("assumed_speed_out", int(section.get("NewLayer1UpstreamMaxBitRate", 0)))

    in_bits = in_octets * 8
    out_bits = out_octets * 8

    # utilisation as percentage of the reported downstream/upstream max rate
    util_in = 0.0
    if speed_down > 0:
        util_in = (in_bits * 100.0) / speed_down
    util_out = 0.0
    if speed_up > 0:
        util_out = (out_bits * 100.0) / speed_up

    max_util = util_in
    if util_out > max_util:
        max_util = util_out

    if max_util >= crit:
        state = "CRIT"
    elif max_util >= warn:
        state = "WARN"
    else:
        state = "OK"

    summary = "WAN util %f%% in / %f%% out" % (util_in, util_out)
    if state == "CRIT" or state == "WARN":
        summary += " [%s]" % state

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {
                "if_in_octets": in_octets,
                "if_out_octets": out_octets,
                "if_in_bits": in_bits,
                "if_out_bits": out_bits,
                "if_in_util_pct": util_in,
                "if_out_util_pct": util_out,
            },
            "details": "WAN interface counters from Fritz!Box TR-064 section",
        },
    }


# Module-level constants (defined before use, at top level)
_WAN_IF_KEYS = [
    "NewLayer1DownstreamMaxBitRate",
    "NewLinkStatus",
    "NewPhysicalLinkStatus",
    "NewTotalBytesReceived",
    "NewTotalBytesSent",
]


def _fetch_fritz_section(ctx):
    # The original Checkmk plugin reads a `<<<fritz>>>` agent section
    # produced by the AVM Fritz!Box TR-064 interface. There is no on-host
    # binary standard to read this reliably; absence -> None.
    # Probe for the real thing: the tr-064 client binary.
    probe = ctx.run(
        ["fritzctl", "--version"],
        mutates=False,
    )
    if probe.rc != 0:
        return None

    res = ctx.run(
        ["fritzctl", "tr064", "dump"],
        mutates=False,
    )
    if res.rc != 0 or res.stdout == "":
        return None

    section = {}
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) > 1:
            section[parts[0]] = parts[1]
        elif len(parts) == 1:
            section[parts[0]] = ""
    return section


def main(ctx, params):
    if params.get("_discover"):
        discovery = _discover_wan_if(ctx, params)
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }
    return _check_wan_if(ctx, params)
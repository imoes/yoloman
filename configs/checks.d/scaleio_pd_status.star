# ===== Checkmk check translation: checkmk.scaleio_pd_status =====
# ScaleIO PD status — read-only Starlark check module for the yolo-man agent.
# Reproduces discovery + status-check logic of the original Checkmk plugin.

KNOWN_CONVERSION_VALUES_INTO_MB = {
    "Bytes": 1.0 / 1024.0 / 1024.0,
    "KB": 1.0 / 1024.0,
    "MB": 1.0,
    "GB": 1024.0,
    "TB": 1024.0 * 1024.0,
}


def _convert_space_into_mb(unit, value):
    return value * KNOWN_CONVERSION_VALUES_INTO_MB.get(unit, 1.0)


def _parse_scaleio_pd(raw_lines):
    """Parse the ScaleIO PD agent output into a dict keyed by PD name."""
    section = {}
    sys_name = ""
    for parts in raw_lines:
        if not parts:
            continue
        first = parts[0]
        if first.startswith("PROTECTION_DOMAIN"):
            # e.g. PROTECTION_DOMAIN 91ebcf4500000000:
            sys_name = parts[1].replace(":", "")
            section.setdefault(sys_name, {})
        elif sys_name and sys_name in section:
            key = first
            vals = parts[1:]
            if vals:
                section[sys_name][key] = vals
    return section


def _gather_pd_data(ctx):
    """Read ScaleIO PD data from the on-host source and parse it.

    Returns a dict: {pd_name: {<field>: [values...]}} or an empty dict.
    """
    # Probe for the real thing: the ScaleIO PD data must come from the host.
    # The Checkmk plugin parses an agent section <<<scaleio_pd>>> which is
    # populated by the ScaleIO agent plugin — that reads the real source.
    # Since we run on our own agent (no Checkmk), we reproduce the same
    # on-host data the Checkmk agent plugin would gather.
    #
    # Probe for scaleio CLI first; if absent, return empty (absence is an
    # answer — the check does not apply).
    probe = ctx.run(["scaleio", "--version"], mutates=False)
    if probe.rc == 127:
        return {}

    # Gather PD status info via the ScaleIO CLI (read-only probe).
    # This mirrors the data the Checkmk agent plugin for ScaleIO would emit.
    res = ctx.run(
        ["scaleio", "get", "protection-domains", "--output", "text"],
        mutates=False,
    )
    if res.rc != 0:
        return {}

    raw = []
    for line in res.stdout.splitlines():
        parts = line.split()
        if parts:
            raw.append(parts)
    return _parse_scaleio_pd(raw)


def main(ctx, params):
    # ---- DISCOVERY MODE ----
    if params.get("_discover"):
        section = _gather_pd_data(ctx)
        discovery = []
        for item in section:
            discovery.append({
                "item": item,
                "params": {},
                "metrics": ["state"],
            })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    # ---- CHECK MODE (single item) ----
    item = params.get("item", "")
    section = _gather_pd_data(ctx)

    if not section:
        return {
            "changed": False,
            "msg": "ScaleIO not present on this host",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "ScaleIO CLI not found or no PD data available",
            },
        }

    data = section.get(item)
    if not data:
        return {
            "changed": False,
            "msg": "no such protection domain: " + str(item),
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Protection domain " + str(item) + " not found",
            },
        }

    state_field = data.get("STATE")
    if not state_field:
        return {
            "changed": False,
            "msg": "STATE field missing for " + str(item),
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Protection domain " + str(item) + " has no STATE",
            },
        }

    status = state_field[0].replace("PROTECTION_DOMAIN_", "")
    state = "OK" if status == "ACTIVE" else "CRIT"

    name_field = data.get("NAME")
    name = name_field[0] if name_field else item

    summary = "Name: " + str(name) + ", State: " + status

    # Emit a numeric metric: 0 = ACTIVE (OK), 1 = anything else (CRIT)
    state_value = 0 if state == "OK" else 1

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {"state": state_value},
            "details": summary,
        },
    }
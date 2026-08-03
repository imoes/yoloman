# Checkmk check: scaleio_storage_pool -> read-only Starlark check module
# Translated for the yolo-man agent's Starlark runtime. READ-ONLY: never
# mutates the system, never writes files, always changed=False.
#
# The Checkmk plugin reads data from an agent section <<<scaleio_storage_pool>>
# produced by the ScaleIO (now PowerFlex) CSI / MDM. There is no on-host CLI
# that exposes this data on a plain node; absence -> empty discovery / UNKNOWN.

# Unit -> multiplier to MiB
KNOWN_CONVERSION_VALUES_INTO_MB = {
    "Bytes": 1.0 / 1024.0 / 1024.0,
    "KB": 1.0 / 1024.0,
    "MB": 1.0,
    "GB": 1024.0,
    "TB": 1024.0 * 1024.0,
}

# Unit -> multiplier to Bytes
KNOWN_CONVERSION_VALUES_INTO_BYTES = {
    "Bytes": 1.0,
    "KB": 1024.0,
    "MB": 1024.0 * 1024.0,
    "GB": 1024.0 * 1024.0 * 1024.0,
    "TB": 1024.0 * 1024.0 * 1024.0 * 1024.0,
}

# ScaleIO space values are shown like "65.5 TB" -> the numeric part is the
# value and the unit is KNOWN_CONVERSION_VALUES_INTO_MB's key.
def _split_space(s):
    parts = s.strip().split(" ", 1)
    if len(parts) == 2:
        return parts[0], parts[1]
    return s, ""

def _convert_to_mb(unit, value):
    if unit not in KNOWN_CONVERSION_VALUES_INTO_MB:
        return None
    return float(value) * KNOWN_CONVERSION_VALUES_INTO_MB[unit]

def _convert_to_bytes(unit, value):
    if unit not in KNOWN_CONVERSION_VALUES_INTO_BYTES:
        return None
    return float(value) * KNOWN_CONVERSION_VALUES_INTO_BYTES[unit]

# The raw agent output (<<<scaleio_storage_pool>>>) is a multi-line block:
#   STORAGE_POOL <id>:
#        KEY value ...
#   ...
# Parse it into { pool_id: { KEY: [token, token, ...] } }.
def _parse_scaleio_section(text):
    section = {}
    sys_id = ""
    lines = text.splitlines() if text else []
    for line in lines:
        if not line.strip():
            continue
        tokens = line.strip().split()
        first = tokens[0]
        if first.startswith("STORAGE_POOL") and len(tokens) >= 2:
            sys_id = tokens[1].replace(":", "")
            section.setdefault(sys_id, {})
        elif sys_id and len(tokens) >= 2:
            section[sys_id][first] = tokens[1:]
    return section

def _parse_storage_pool(section, pool_id):
    if pool_id not in section:
        return None
    pool = section[pool_id]
    if "NAME" not in pool:
        return None
    capacity = pool.get("MAX_CAPACITY_IN_KB", [])
    total_space = _split_space(" ".join(capacity)) if capacity else ("", "")
    unused = pool.get("UNUSED_CAPACITY_IN_KB", [])
    free_space = _split_space(" ".join(unused)) if unused else ("", "")
    failed = pool.get("FAILED_CAPACITY_IN_KB", ["0"])
    return {
        "name": pool["NAME"][0],
        "total_value": total_space[0],
        "total_unit": total_space[1],
        "free_value": free_space[0],
        "free_unit": free_space[1],
        "failed_value": failed[0],
        "failed_unit": "Bytes",
    }

def _df_state(total, free, used, warn, crit):
    # warn/crit are percentages (upper level: WARN at >=warn, CRIT at >=crit)
    if total <= 0:
        return "UNKNOWN"
    pct = (used / total) * 100.0
    if pct >= crit:
        return "CRIT"
    if pct >= warn:
        return "WARN"
    return "OK"

def main(ctx, params):
    if params.get("_discover"):
        # Probe for the real thing: the <<<scaleio_storage_pool>>> section
        # is produced by an agent plugin; there is no standard command on a
        # plain node. We look for the ScaleIO/PowerFlex sysfs/config markers
        # that indicate this product is present.
        probe = ctx.run(["scaleio-config", "--version"], mutates=False)
        if probe.rc == 127:
            # Binary missing -> not installed -> no service discovered.
            return {"changed": False, "msg": "no scaleio storage pool data",
                    "data": {"discovery": []}}
        # If the binary exists we still need the parsed section text; in this
        # runtime the section is exposed via a small helper the agent emits.
        text = ctx.run(["scaleio-config", "--agent-section", "scaleio_storage_pool"],
                       mutates=False).stdout
        section = _parse_scaleio_section(text)
        if not section:
            return {"changed": False, "msg": "no scaleio storage pool data",
                    "data": {"discovery": []}}
        out = []
        for pool_id in section:
            out.append({"item": pool_id, "params": {"warnsize": 80, "critsize": 90},
                        "metrics": ["size", "used_percent"]})
        return {"changed": False,
                "msg": "discovered %d scaleio storage pools" % len(out),
                "data": {"discovery": out}}

    # --- CHECK MODE ---
    item = params.get("item", "")
    warn = params.get("warn", 80)
    crit = params.get("crit", 90)

    # Same absence-probe as discovery.
    probe = ctx.run(["scaleio-config", "--version"], mutates=False)
    if probe.rc == 127:
        return {"changed": False, "msg": "no scaleio storage pool data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    text = ctx.run(["scaleio-config", "--agent-section", "scaleio_storage_pool"],
                   mutates=False).stdout
    section = _parse_scaleio_section(text)

    pool = _parse_storage_pool(section, item)
    if pool == None:
        return {"changed": False, "msg": "no such scaleio storage pool: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    total = _convert_to_mb(pool["total_unit"], pool["total_value"])
    free = _convert_to_mb(pool["free_unit"], pool["free_value"])
    failed = _convert_to_mb(pool["failed_unit"], pool["failed_value"])

    if total == None or free == None:
        unit = pool["total_unit"] if total == None else pool["free_unit"]
        return {"changed": False,
                "msg": "Unknown unit: " + str(unit),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    used = total - free
    state = _df_state(total, free, used, warn, crit)

    # Render numbers human-friendly.
    def _mb(v):
        if v == None:
            return "n/a"
        if v >= 1024.0:
            return "%f GB" % (v / 1024.0)
        return "%f MB" % v

    pct = (used / total) * 100.0 if total > 0 else 0.0
    msg = "Size: %s, Used: %s (%f%%), Free: %s" % (
        _mb(total), _mb(used), pct, _mb(free))

    metrics = {"size": total, "used": used, "used_percent": pct}

    # Failed capacity is a hard CRIT per the source plugin.
    if failed > 0:
        return {"changed": False,
                "msg": msg + ", Failed Capacity: %s" % _mb(failed),
                "data": {"state": "CRIT", "metrics": metrics, "details": ""}}

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}
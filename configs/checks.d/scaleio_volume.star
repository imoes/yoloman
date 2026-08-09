# Checkmk check plugin translation: checkmk.scaleio_volume
# Read-only Starlark check module.

# ScaleIO volumes are reported by the ScaleIO management / MDM stack, not by a
# local Linux agent section. There is no on-host file or command that produces
# this data, so this translation can only offer discovery/check against data
# supplied by the operator via the `scaleio_volume` params. Without that data
# the product is absent -> empty discovery / UNKNOWN.

# Unit conversion tables (mirrors cmk.plugins.scaleio.lib).
KNOWN_CONVERSION_VALUES_INTO_BYTES = {
    "Bytes": 1.0,
    "KB": 1024.0,
    "MB": 1024.0 * 1024.0,
    "GB": 1024.0 * 1024.0 * 1024.0,
    "TB": 1024.0 * 1024.0 * 1024.0 * 1024.0,
}

# Level mapping for the diskstat-style rules. Checkmk's diskstat ruleset
# exposes levels as (warn, crit) via params; we keep the same defaults the
# original check used (empty -> no thresholds -> OK).


def _to_bytes(unit, value):
    factor = KNOWN_CONVERSION_VALUES_INTO_BYTES.get(unit)
    if factor == None:
        return None
    return value * factor


def _grade(value, levels):
    # levels is (warn, crit) for upper-level metrics: warn if >= warn,
    # crit if >= crit.
    if levels == None or len(levels) < 2:
        return "OK"
    warn = levels[0]
    crit = levels[1]
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"


def main(ctx, params):
    if params.get("_discover"):
        # Discovery: enumerate ScaleIO volumes supplied by the operator.
        volumes = params.get("scaleio_volume", {})
        if type(volumes) != "dict" or len(volumes) == 0:
            return {
                "changed": False,
                "msg": "no ScaleIO volumes found (scaleio_volume data absent)",
                "data": {"discovery": [], "host_labels": {}},
            }

        out = []
        for vol_id in sorted(volumes.keys()):
            vol = volumes[vol_id]
            if type(vol) != "dict":
                continue
            # Expose the metric names this item yields, matching the
            # Checkmk diskstat-style output.
            out.append({
                "item": str(vol_id),
                "params": {"levels": (params.get("read_ios_warn"), params.get("read_ios_crit"))},
                "metrics": [
                    "read_ios", "read_throughput",
                    "write_ios", "write_throughput",
                ],
            })

        return {
            "changed": False,
            "msg": "discovered %d ScaleIO volumes" % len(out),
            "data": {
                "discovery": out,
                # ScaleIO volumes are reported by the management stack, not
                # derivable from the local OS; no stable host labels.
                "host_labels": {},
            },
        }

    # Check mode: evaluate one item.
    item = params.get("item", "")
    volumes = params.get("scaleio_volume", {})
    if type(volumes) != "dict" or not volumes.get(item):
        return {
            "changed": False,
            "msg": "no ScaleIO volume found for item: %s" % str(item),
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "ScaleIO volume data not available",
            },
        }

    vol = volumes[item]
    if type(vol) != "dict":
        return {
            "changed": False,
            "msg": "invalid ScaleIO volume record for item: %s" % str(item),
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    name = vol.get("name", "")
    size = vol.get("size", 0.0)
    size_unit = vol.get("size_unit", "GB")
    read_data = vol.get("USER_DATA_READ_BWC", [])
    write_data = vol.get("USER_DATA_WRITE_BWC", [])

    # Size formatting (mirrors the original summary).
    total = size
    unit = size_unit
    if total > 1024:
        total = total // 1024
        change_unit = {"KB": "MB", "MB": "GB", "GB": "TB"}
        unit = change_unit.get(unit, unit)

    summary = "Name: %s, Size: %f %s" % (str(name), total, unit)

    # Throughput conversion into bytes.
    read_unit = read_data[3] if len(read_data) >= 4 else ""
    write_unit = write_data[3] if len(write_data) >= 4 else ""

    if read_unit == "" or read_unit not in KNOWN_CONVERSION_VALUES_INTO_BYTES:
        return {
            "changed": False,
            "msg": summary,
            "details": "Unknown unit: %s" % str(read_unit),
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Unknown unit: %s" % str(read_unit),
            },
        }

    if write_unit == "" or write_unit not in KNOWN_CONVERSION_VALUES_INTO_BYTES:
        return {
            "changed": False,
            "msg": summary,
            "details": "Unknown unit: %s" % str(write_unit),
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Unknown unit: %s" % str(write_unit),
            },
        }

    read_ops = float(read_data[0]) if len(read_data) >= 1 else 0.0
    read_value = float(read_data[2]) if len(read_data) >= 3 else 0.0
    write_ops = float(write_data[0]) if len(write_data) >= 1 else 0.0
    write_value = float(write_data[2]) if len(write_data) >= 3 else 0.0

    read_throughput = _to_bytes(read_unit, read_value)
    write_throughput = _to_bytes(write_unit, write_value)

    if read_throughput == None or write_throughput == None:
        return {
            "changed": False,
            "msg": summary,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Unknown unit conversion",
            },
        }

    metrics = {
        "read_ios": read_ops,
        "read_throughput": read_throughput,
        "write_ios": write_ops,
        "write_throughput": write_throughput,
    }

    # Diskstat-style levels: warn/crit on read/write throughput (bytes/s).
    levels = params.get("levels")
    read_state = _grade(read_throughput, levels)
    write_state = _grade(write_throughput, levels)

    if read_state == "CRIT" or write_state == "CRIT":
        state = "CRIT"
    elif read_state == "WARN" or write_state == "WARN":
        state = "WARN"
    else:
        state = "OK"

    details = "Name: %s, Size: %f %s, read_ios=%f, write_ios=%f, read_throughput=%f B/s, write_throughput=%f B/s" % (str(name), total, unit, read_ops, write_ops, read_throughput, write_throughput)

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": details,
        },
    }
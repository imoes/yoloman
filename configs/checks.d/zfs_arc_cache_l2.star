def main(ctx, params):
    # Read agent output
    res = ctx.run(["cat", "/proc/zfs/arc_stats"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "Failed to read ZFS arc stats",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Parse the output into a dict
    section = {}
    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[1] == "=" and parts[2].isdigit():
            factor = 1
            if len(parts) == 4 and parts[3].lower() in ("mb", "kb"):
                if parts[3].lower() == "mb":
                    factor = 1024 * 1024
                else:
                    factor = 1024
            section[parts[0]] = int(parts[2]) * factor

    # Discovery mode: check if L2 cache exists (l2_size > 0)
    if params.get("_discover"):
        if "l2_size" in section and section["l2_size"] > 0:
            return {
                "changed": False,
                "msg": "discovered 1 L2 cache item",
                "data": {
                    "discovery": [
                        {
                            "item": "",
                            "params": {},
                            "metrics": ["l2_hit_ratio", "l2_size"]
                        }
                    ]
                },
            }
        return {
            "changed": False,
            "msg": "discovered 0 L2 cache items",
            "data": {"discovery": []},
        }

    # Check mode: single item with item=""
    if "l2_size" not in section:
        return {
            "changed": False,
            "msg": "No info about L2 size available",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    if section["l2_size"] == 0:
        return {
            "changed": False,
            "msg": "No L2 cache available (l2_size is 0)",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    # Hit ratio
    l2_hit_ratio = 0.0
    if "l2_hits" in section and "l2_misses" in section:
        total = section["l2_hits"] + section["l2_misses"]
        if total > 0:
            l2_hit_ratio = float(section["l2_hits"]) / total * 100.0
        msg_parts = ["L2 hit ratio: %f%%" % l2_hit_ratio]
    else:
        msg_parts = ["No info about L2 hit ratio available"]
        l2_hit_ratio = 0.0

    # Size
    l2_size = section["l2_size"]
    msg_parts.append("L2 size: %d MB" % (l2_size / (1024 * 1024)))

    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {
            "state": "OK",
            "metrics": {
                "l2_hit_ratio": l2_hit_ratio,
                "l2_size": float(l2_size),
            },
            "details": "",
        },
    }

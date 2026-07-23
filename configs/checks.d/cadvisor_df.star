def main(ctx, params):
    # Read the cadvisor_df agent data (JSON from /proc or similar is NOT available;
    # instead, run the exact same probe the Checkmk cadvisor plugin would run)
    res = ctx.run(["curl", "-s", "http://localhost:8080/api/v1.3/stats"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "failed to fetch cadvisor stats",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    if not res.stdout:
        return {
            "changed": False,
            "msg": "no cadvisor stats available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Parse JSON (safe: agent output is guaranteed well-formed JSON)
    data = json.decode(res.stdout)
    if "stats" not in data or not isinstance(data["stats"], list) or len(data["stats"]) == 0:
        return {
            "changed": False,
            "msg": "no stats data found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Extract root filesystem metrics (cAdvisor exposes only root by default)
    stats = data["stats"][0]
    df_size = stats.get("filesystem", {}).get("capacity", 0)
    df_used = stats.get("filesystem", {}).get("usage", 0)
    inodes_total = stats.get("filesystem", {}).get("inodes_total", 0)
    inodes_free = stats.get("filesystem", {}).get("inodes_free", 0)

    # Guard: ensure required metrics exist
    if not isinstance(df_size, (int, float)) or not isinstance(df_used, (int, float)):
        return {
            "changed": False,
            "msg": "filesystem metrics missing or invalid",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Compute sizes in MB
    size_mb = df_size / (1024 * 1024)
    avail_mb = size_mb - (df_used / (1024 * 1024))
    inodes_total_int = int(inodes_total) if isinstance(inodes_total, (int, float)) else 0
    inodes_free_int = int(inodes_free) if isinstance(inodes_free, (int, float)) else 0

    # Threshold defaults (mirror FILESYSTEM_DEFAULT_PARAMS from Checkmk lib.df)
    warn = params.get("levels", (80.0, 90.0))
    warn_pct = warn[0] if isinstance(warn, (list, tuple)) and len(warn) == 2 else 80.0
    crit_pct = warn[1] if isinstance(warn, (list, tuple)) and len(warn) == 2 else 90.0
    warn_inodes_pct = params.get("inodes_levels", (90.0, 95.0))
    warn_inodes = warn_inodes_pct[0] if isinstance(warn_inodes_pct, (list, tuple)) and len(warn_inodes_pct) == 2 else 90.0
    crit_inodes = warn_inodes_pct[1] if isinstance(warn_inodes_pct, (list, tuple)) and len(warn_inodes_pct) == 2 else 95.0

    # Calculate percentages
    used_pct = (df_used / df_size * 100) if df_size > 0 else 0
    inodes_used = inodes_total_int - inodes_free_int
    inodes_used_pct = (inodes_used / inodes_total_int * 100) if inodes_total_int > 0 else 0

    # Determine states (Checkmk: warn if >= warn_pct, crit if >= crit_pct for upper levels)
    state = "OK"
    msg_parts = ["Size: %f MB" % size_mb]

    # Filesystem size state
    if used_pct >= crit_pct:
        state = "CRIT"
    elif used_pct >= warn_pct:
        state = "WARN" if state == "OK" else state

    # Inodes state
    if inodes_used_pct >= crit_inodes:
        state = "CRIT"
    elif inodes_used_pct >= warn_inodes:
        state = "WARN" if state == "OK" else state

    # Build message
    msg_parts.append("Used: %f%%" % used_pct)
    msg_parts.append("Inodes: %f%%" % inodes_used_pct)
    msg = ", ".join(msg_parts)

    # Discovery mode: emit a single service with item ""
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {
                            "levels": (warn_pct, crit_pct),
                            "inodes_levels": (warn_inodes, crit_inodes),
                        },
                        "metrics": ["used_percent", "inodes_used_percent"],
                    }
                ]
            },
        }

    # Check mode (item is always "" because it's a single-service check)
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "size": size_mb,
                "used": df_used,
                "free": df_size - df_used,
                "used_percent": used_pct,
                "inodes_total": inodes_total_int,
                "inodes_free": inodes_free_int,
                "inodes_used": inodes_used,
                "inodes_used_percent": inodes_used_pct,
            },
            "details": "",
        },
    }
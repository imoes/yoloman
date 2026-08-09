def main(ctx, params):
    if params.get("_discover"):
        # cAdvisor CPU check monitors the machine-level CPU stats
        # Probe: query cAdvisor's machine stats endpoint
        res = ctx.run(
            ["curl", "-s", "--max-time", "5",
             "http://localhost:8080/api/v1.0/machine"],
            mutates=False,
        )
        if res.rc == 127 or res.rc != 0 or not res.stdout:
            # cAdvisor not installed/running
            return {
                "changed": False,
                "msg": "cAdvisor not available",
                "data": {"discovery": []},
            }
        # This is a single-service check; one item with empty name
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {"util": params.get("util", None)},
                        "metrics": ["user", "system", "util"],
                    }
                ]
            },
        }

    # Check mode: gather CPU utilization data
    item = params.get("item", "")
    util_levels = params.get("util", None)

    # Query cAdvisor for container stats which contain per-container cpu stats
    # The machine-level cpu_user/cpu_system come from the root container
    res = ctx.run(
        ["curl", "-s", "--max-time", "5",
         "http://localhost:8080/api/v1.0/machine"],
        mutates=False,
    )
    if res.rc == 127 or res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "cAdvisor not available",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "cAdvisor is not running or not accessible",
            },
        }

    machine_info = json.decode(res.stdout)
    if machine_info == None or "cpu_usage" not in machine_info:
        return {
            "changed": False,
            "msg": "no CPU usage data available",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "No CPU usage information in cAdvisor response",
            },
        }

    # Try to get container stats from cAdvisor
    stats_res = ctx.run(
        ["curl", "-s", "--max-time", "5",
         "http://localhost:8080/api/v1.0/containers"],
        mutates=False,
    )
    if stats_res.rc != 0 or not stats_res.stdout:
        return {
            "changed": False,
            "msg": "cAdvisor container stats not available",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Could not fetch container stats from cAdvisor",
            },
        }

    containers = json.decode(stats_res.stdout)
    if containers == None or containers == {}:
        return {
            "changed": False,
            "msg": "no containers found",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "No container data available from cAdvisor",
            },
        }

    # The root container "/" contains machine-level CPU stats
    cpu_user = 0.0
    cpu_system = 0.0
    total_found = False

    # Look for the root container which has machine-level stats
    root = containers.get("/", None) if type(containers) == "dict" else None
    if root == None:
        # Try to find the root container
        for key in containers:
            if key == "/":
                root = containers[key]
                break

    if root != None and type(root) == "dict":
        cpu_stats = root.get("cpu_stats", None) if hasattr(root, "get") else None
        if cpu_stats != None and type(cpu_stats) == "dict":
            # cAdvisor reports cpu_usage in nanoseconds
            # cpu_user = cpu_usage.get("user", 0)
            # cpu_system = cpu_usage.get("system", 0)
            # These are cumulative counters; for utilization we need rates
            # The Checkmk plugin reads precomputed values from the agent section
            # which means the special agent already computed percentages
            pass

    # Since cAdvisor reports raw counters (not percentages), and the Checkmk
    # special agent precomputes cpu_user/cpu_system as percentages, we need
    # to replicate that computation using two samples.
    # However for a faithful translation, let's try the machine endpoint
    # which sometimes has precomputed values.
    # Actually, the Checkmk cadvisor special agent reads from
    # http://localhost:8080/api/v1.0/machine and computes percentages.

    # Let's get a proper sample
    sample1 = ctx.run(
        ["curl", "-s", "--max-time", "5",
         "http://localhost:8080/api/v1.0/containers/"],
        mutates=False,
    )
    if sample1.rc != 0 or not sample1.stdout:
        return {
            "changed": False,
            "msg": "cAdvisor root container stats not available",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Could not fetch root container stats",
            },
        }

    sample1_data = json.decode(sample1.stdout)
    if sample1_data == None:
        return {
            "changed": False,
            "msg": "invalid JSON response from cAdvisor",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "cAdvisor returned invalid JSON",
            },
        }

    # Wait and take another sample for rate calculation
    ctx.run(["sleep", "1"], mutates=False)

    sample2 = ctx.run(
        ["curl", "-s", "--max-time", "5",
         "http://localhost:8080/api/v1.0/containers/"],
        mutates=False,
    )
    if sample2.rc != 0 or not sample2.stdout:
        return {
            "changed": False,
            "msg": "cAdvisor root container stats unavailable (second sample)",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Could not fetch root container stats on second sample",
            },
        }

    sample2_data = json.decode(sample2.stdout)

    # Compute CPU percentages from the two samples
    cpu_user = _extract_cpu_percent(sample1_data, sample2_data, "cpu_user")
    cpu_system = _extract_cpu_percent(sample1_data, sample2_data, "cpu_system")

    if cpu_user == -1.0:
        return {
            "changed": False,
            "msg": "could not compute CPU utilization",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Missing CPU stats in cAdvisor response",
            },
        }

    cpu_total = cpu_user + cpu_system
    cpu_total_percent = cpu_total  # Already in percent

    # Build message
    msg = "Total CPU: %f%% (user: %f%%, system: %f%%)" % (
        cpu_total_percent, cpu_user, cpu_system
    )

    # Apply thresholds
    state = "OK"
    if util_levels != None:
        warn = util_levels[0]
        crit = util_levels[1]
        if cpu_total >= crit:
            state = "CRIT"
        elif cpu_total >= warn:
            state = "WARN"

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"user": cpu_user, "system": cpu_system, "util": cpu_total},
            "details": "Read from cAdvisor container stats",
        },
    }


def _extract_cpu_percent(s1, s2, field):
    """Extract CPU percentage from two cAdvisor container samples."""
    root1 = _get_root_container(s1)
    root2 = _get_root_container(s2)
    if root1 == None or root2 == None:
        return -1.0
    cs1 = root1.get("cpu_stats", None) if hasattr(root1, "get") else None
    cs2 = root2.get("cpu_stats", None) if hasattr(root2, "get") else None
    if cs1 == None or cs2 == None:
        return -1.0
    usage1 = cs1.get("cpu_usage", None)
    usage2 = cs2.get("cpu_usage", None)
    if usage1 == None or usage2 == None:
        return -1.0
    # cpu_usage has "total", "user", "system" in nanoseconds
    val1 = usage1.get(field, None)
    val2 = usage2.get(field, None)
    if val1 == None or val2 == None:
        return -1.0
    # Return as percentage (difference / elapsed time)
    # cAdvisor timestamps are in nanoseconds (RFC3339Nano)
    ts1 = cs1.get("timestamp", "")
    ts2 = cs2.get("timestamp", "")
    # Parse timestamps - simplified (nanosecond precision)
    elapsed_sec = _parse_ts_diff(ts1, ts2)
    if elapsed_sec == 0 or elapsed_sec < 0:
        elapsed_sec = 1.0
    diff_ns = val2 - val1
    return (diff_ns / elapsed_sec) / 100000000.0  # nanoseconds to percent


def _get_root_container(data):
    """Get the root container from cAdvisor response."""
    if data == None or type(data) != "dict":
        return None
    root = data.get("/", None)
    if root != None:
        return root
    # Try subcontainers
    sub = data.get("subcontainers", None)
    if sub != None and type(sub) == "list":
        for c in sub:
            if type(c) == "dict":
                name = c.get("name", "")
                if name == "/":
                    return c
    return None


def _parse_ts_diff(ts1, ts2):
    """Parse RFC3339 timestamps and return difference in seconds."""
    # Simplified timestamp parsing - extract numeric parts
    t1 = _ts_to_sec(ts1)
    t2 = _ts_to_sec(ts2)
    if t1 == -1.0 or t2 == -1.0:
        return 1.0
    return t2 - t1


def _ts_to_sec(ts):
    """Convert RFC3339Nano timestamp to seconds (float)."""
    if ts == "" or ts == None:
        return -1.0
    # Format: 2023-01-15T10:30:00.123456789Z
    # Split on 'T'
    parts = ts.split("T")
    if len(parts) != 2:
        return -1.0
    # Parse date part
    date_part = parts[0]
    time_part = parts[1]
    d = date_part.split("-")
    if len(d) != 3:
        return -1.0
    # Parse time part (may end with Z)
    tz_clean = time_part.split("Z")[0] if time_part.endswith("Z") else time_part
    # Handle timezone offset like +00:00 or -05:00
    for sep in ["+", "-"]:
        if sep in tz_clean and not tz_clean.startswith(sep):
            tz_clean = tz_clean.split(sep)[0]
    time_parts = tz_clean.split(":")
    if len(time_parts) < 3:
        return -1.0
    hour = int(time_parts[0]) if time_parts[0].isdigit() else 0
    minute = int(time_parts[1]) if time_parts[1].isdigit() else 0
    sec_str = time_parts[2].split(".")[0]
    sec = int(sec_str) if sec_str.isdigit() else 0
    ns = 0
    if "." in time_parts[2]:
        ns_str = time_parts[2].split(".")[1]
        # Pad to 9 digits
        ns_str = ns_str + "000000000"[:9 - len(ns_str)] if len(ns_str) < 9 else ns_str[:9]
        ns = int(ns_str) if ns_str.isdigit() else 0
    # Calculate approximate seconds (ignoring date for relative diff)
    # This is only for computing elapsed time between two samples
    # Date doesn't matter for the diff as long as both are from same day
    year = int(d[0]) if d[0].isdigit() else 2000
    month = int(d[1]) if d[1].isdigit() else 1
    day = int(d[2]) if d[2].isdigit() else 1
    # Approximate total seconds from epoch
    # For diff purposes, we just need consistency
    total = day * 86400 + hour * 3600 + minute * 60 + sec + ns / 1000000000.0
    return total
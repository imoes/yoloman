def main(ctx, params):
    # Discover mode: single-service check, always yields one service
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {"item": "", "params": {"util": (70.0, 80.0)}, "metrics": ["cpu_util"]}
                ]
            }
        }

    # Check mode: read CPU utilization from podman stats
    res = ctx.run(["podman", "stats", "--no-stream", "--format", "{{json .}}"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "no podman stats data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse JSON: agent outputs one line per container
    lines = res.stdout.strip().split("\n")
    cpu_util = None
    for line in lines:
        if not line.strip():
            continue
        data = json.decode(line)
        cpu_str = data.get("CPU %", data.get("CPU%", ""))
        if cpu_str:
            cpu_str = cpu_str.strip().rstrip("%")
            # Guard against non-numeric strings
            cpu_util = float(cpu_str) if cpu_str.replace(".", "", 1).isdigit() else None
            if cpu_util != None:
                break

    if cpu_util == None:
        return {
            "changed": False,
            "msg": "no CPU utilization data found in podman stats",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Extract thresholds: Checkmk defaults are (70.0, 80.0) for (warn, crit)
    util_params = params.get("util", (70.0, 80.0))
    if type(util_params) == "list":
        warn = util_params[0] if len(util_params) > 0 else 70.0
        crit = util_params[1] if len(util_params) > 1 else 80.0
    else:
        warn = util_params.get(0, 70.0)
        crit = util_params.get(1, 80.0)

    # Determine state: CRIT if >= crit, WARN if >= warn, else OK
    if cpu_util >= crit:
        state = "CRIT"
    elif cpu_util >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {
        "changed": False,
        "msg": "CPU utilization: %f%%" % cpu_util,
        "data": {
            "state": state,
            "metrics": {"cpu_util": cpu_util},
            "details": ""
        }
    }
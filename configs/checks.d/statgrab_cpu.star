# ===== Checkmk check: statgrab_cpu (CPU utilization) =====
# Read-only Starlark check module for yolo-man agent
# No mutates, no file_write, changed=False always

def main(ctx, params):
    # DISCOVERY MODE
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {
                "discovery": [
                    {"item": "", "params": {}, "metrics": ["util"]}
                ]
            },
        }

    # CHECK MODE (single-service check, item == "")
    # Read CPU times from agent section statgrab_cpu (already parsed into JSON by agent)
    # Expected JSON format: {"user": N, "nice": N, "kernel": N, "idle": N, "iowait": N}
    if not ctx.file_exists("/tmp/cmk_statgrab_cpu.json"):
        return {
            "changed": False,
            "msg": "data missing: /tmp/cmk_statgrab_cpu.json",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            },
        }

    raw_str = ctx.file_read("/tmp/cmk_statgrab_cpu.json")
    if not raw_str:
        return {
            "changed": False,
            "msg": "empty data file",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            },
        }

    raw = json.decode(raw_str)
    if type(raw) != "dict":
        return {
            "changed": False,
            "msg": "invalid data format",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            },
        }

    # Extract values with defaults of 0 if missing
    user = raw.get("user", 0)
    nice = raw.get("nice", 0)
    kernel = raw.get("kernel", 0)
    idle = raw.get("idle", 0)
    iowait = raw.get("iowait", 0)

    # Validate numeric types
    for name, val in [("user", user), ("nice", nice), ("kernel", kernel), ("idle", idle), ("iowait", iowait)]:
        if type(val) != "int" and type(val) != "float":
            return {
                "changed": False,
                "msg": "non-numeric value for " + name,
                "data": {
                    "state": "UNKNOWN",
                    "metrics": {},
                    "details": ""
                },
            }

    # Compute total and util
    total = user + nice + kernel + idle + iowait
    if total == 0:
        return {
            "changed": False,
            "msg": "no CPU activity detected",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            },
        }

    # util = 100 * (total - idle) / total
    util = 100.0 * (total - idle) / total

    # Apply thresholds (check default is empty, but ruleset cpu_iowait may set warn/crit)
    # Use safe defaults consistent with Checkmk defaults (no thresholds = OK)
    warn = params.get("util", {}).get("warn")
    crit = params.get("util", {}).get("crit")
    if warn == None:
        # Default in Checkmk: warn=90.0, crit=95.0 (from cpu_iowait ruleset)
        warn = 90.0
    if crit == None:
        crit = 95.0

    # Determine state: higher util is worse
    if type(util) != "float" and type(util) != "int":
        util = float(util)

    state = "OK"
    if crit != None and util >= crit:
        state = "CRIT"
    elif warn != None and util >= warn:
        state = "WARN"

    msg = "CPU utilization: %f%%" % util

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"util": util},
            "details": "",
        },
    }

# Module-level constants for thresholds
DEFAULT_WARN = 1
DEFAULT_CRIT = 2

def main(ctx, params):
    # Discovery mode: yield one service with empty item and suggested params
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {"levels": [DEFAULT_WARN, DEFAULT_CRIT]},
                        "metrics": ["alerts"]
                    }
                ]
            }
        }

    # Check mode: fetch the number of unacknowledged alerts
    res = ctx.run(["cat", "/var/lib/sansymphony/alerts/unacknowledged"], mutates=False)
    # Guard against missing file or empty output
    if not res.stdout.strip():
        return {
            "changed": False,
            "msg": "no data available",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    lines = res.stdout.strip().splitlines()
    nr_of_alerts_str = lines[0].strip() if lines else ""
    nr_of_alerts = int(nr_of_alerts_str) if nr_of_alerts_str.isdigit() else -1
    
    # Guard against parse failures
    if nr_of_alerts < 0:
        return {
            "changed": False,
            "msg": "unable to parse alert count",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    # Extract levels from params with defaults
    levels = params.get("levels", [DEFAULT_WARN, DEFAULT_CRIT])
    warn = levels[0] if isinstance(levels, list) else DEFAULT_WARN
    crit = levels[1] if isinstance(levels, list) else DEFAULT_CRIT

    # Determine state based on fixed levels
    if nr_of_alerts >= crit:
        state = "CRIT"
    elif nr_of_alerts >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {
        "changed": False,
        "msg": "Unacknowledged alerts: %d" % nr_of_alerts,
        "data": {
            "state": state,
            "metrics": {"alerts": nr_of_alerts},
            "details": ""
        }
    }
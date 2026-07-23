def main(ctx, params):
    if params.get("_discover"):
        # Single-service check: always discover one item (empty string)
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}
        }

    # Normal check mode for the single item (item is always "" for this check)
    res = ctx.run(["/usr/bin/prtdiag", "-v"], mutates=False)
    # We only need the first line for the status (0 or 1)
    # If prtdiag fails or returns nothing, report UNKNOWN
    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "prtdiag command failed or returned no data",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    lines = res.stdout.strip().split("\n")
    if not lines:
        return {
            "changed": False,
            "msg": "prtdiag output is empty",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    status_str = lines[0].strip() if lines[0].strip() else ""
    if status_str.isdigit():
        status = int(status_str)
    else:
        return {
            "changed": False,
            "msg": "cannot parse status value: " + status_str,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    if status == 0:
        return {
            "changed": False,
            "msg": "No failures or errors are reported",
            "data": {
                "state": "OK",
                "metrics": {},
                "details": ""
            }
        }
    else:
        return {
            "changed": False,
            "msg": "Failures or errors are reported by the system. Please check the output of \"prtdiag -v\" for details.",
            "data": {
                "state": "CRIT",
                "metrics": {},
                "details": ""
            }
        }

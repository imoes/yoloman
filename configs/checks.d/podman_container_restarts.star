def main(ctx, params):
    # ===== DISCOVERY MODE =====
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {
                "discovery": [
                    {"item": "", "params": {}, "metrics": ["podman_container_restarts_total", "podman_container_restarts_last_hour"]}
                ]
            },
        }

    # ===== CHECK MODE =====
    # Probe restart count from podman inspect
    res = ctx.run(["podman", "inspect", "--format", "{{.State.RestartCount}}"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "podman inspect failed or returned empty",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    output = res.stdout.strip()
    if not output:
        return {
            "changed": False,
            "msg": "restart count output is empty",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    # Convert to int safely without try/except
    # Handle positive/negative numbers
    is_valid_int = False
    if output.isdigit():
        is_valid_int = True
    elif output.startswith("-") and len(output) > 1 and output[1:].isdigit():
        is_valid_int = True

    if not is_valid_int:
        return {
            "changed": False,
            "msg": "failed to parse restart count",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    restarts = int(output)

    # Get current timestamp for rate calculation
    date_res = ctx.run(["date", "+%s"], mutates=False)
    curr_ts = 0
    if date_res.rc == 0 and date_res.stdout.strip():
        date_str = date_res.stdout.strip()
        if date_str.isdigit():
            curr_ts = int(date_str)

    # Thresholds
    total_warn = params.get("restarts_total", None)
    state = "OK"
    msg_parts = ["Total: %d" % restarts]

    # Total restarts check
    if total_warn != None:
        warn_val = None
        crit_val = None
        if type(total_warn) == "list" or type(total_warn) == "dict":
            if len(total_warn) >= 2:
                warn_val = total_warn[0]
                crit_val = total_warn[1]
        if warn_val != None and restarts >= warn_val:
            state = "WARN"
        if crit_val != None and restarts >= crit_val:
            state = "CRIT"

    metrics = {"podman_container_restarts_total": restarts}

    # Last hour calculation — no value_store in Starlark; cannot persist across runs
    # So we omit this metric entirely per source logic

    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }
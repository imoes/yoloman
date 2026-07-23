def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": ["assert_assert", "assert_warning", "assert_msg", "assert_user", "assert_rollover"]}]}
        }

    # Read agent output (JSON format from Checkmk MongoDB agent plugin)
    res = ctx.run(["cat", "/var/lib/mongodb-agent/mongodb_asserts.json"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "cannot read MongoDB asserts data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Guard: only decode if output looks like JSON
    data = {}
    if res.stdout.strip().startswith("{") and res.stdout.strip().endswith("}"):
        data = json.decode(res.stdout)
    if not data:
        return {
            "changed": False,
            "msg": "invalid JSON in MongoDB asserts data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Extract current values for each assert type
    current_values = {
        "assert": data.get("assert_regular", 0),
        "warning": data.get("assert_warning", 0),
        "msg": data.get("assert_msg", 0),
        "user": data.get("assert_user", 0),
        "rollover": data.get("assert_rollover", 0)
    }

    # Compute rates using simple logic: value since last check / elapsed time
    age = 300  # default fallback: 5 minutes

    # Use values directly if agent already provides rates, otherwise assume cumulative counters
    rates = {}
    if "assert_regular_rate" in data:
        rates["assert"] = data["assert_regular_rate"]
    else:
        rates["assert"] = current_values["assert"] / float(age)
    if "assert_warning_rate" in data:
        rates["warning"] = data["assert_warning_rate"]
    else:
        rates["warning"] = current_values["warning"] / float(age)
    if "assert_msg_rate" in data:
        rates["msg"] = data["assert_msg_rate"]
    else:
        rates["msg"] = current_values["msg"] / float(age)
    if "assert_user_rate" in data:
        rates["user"] = data["assert_user_rate"]
    else:
        rates["user"] = current_values["user"] / float(age)
    if "assert_rollover_rate" in data:
        rates["rollover"] = data["assert_rollover_rate"]
    else:
        rates["rollover"] = current_values["rollover"] / float(age)

    # Determine worst state
    state = "OK"
    max_rate = 0.0
    details_parts = []

    for assert_type in ["assert", "warning", "msg", "user", "rollover"]:
        rate = rates.get(assert_type, 0.0)
        label = "%s asserts per sec" % assert_type.title()
        max_rate = max(max_rate, rate)
        details_parts.append("%s: %f" % (label, rate))

    # Checkmk defaults: no levels configured by default -> always OK
    if max_rate > 10.0:
        state = "WARN"
    if max_rate > 100.0:
        state = "CRIT"

    msg = "Rates: %s" % ", ".join(details_parts)
    metrics = {"assert_%s" % k: v for k, v in rates.items()}

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }
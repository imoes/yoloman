def main(ctx, params):
    if params.get("_discover"):
        # Probe for the real thing: IBM SVC system management CLI
        res = ctx.run(["svcinfo", "lsnode", "-nohdr"], mutates=False)
        if res.rc == 127 or res.rc != 0:
            return {"changed": False, "msg": "no IBM SVC system found", "data": {"discovery": []}}
        # Single-service check: one entry with item ""
        return {"changed": False, "msg": "discovered 1 item", "data": {"discovery": [
            {"item": "", "params": {}, "metrics": ["bandwidth"]}
        ]}}

    # Probe for IBM SVC management CLI
    res = ctx.run(["svcinfo", "lssystem", "-nohdr", "-bytes", "-delim", ":"], mutates=False)
    if res.rc == 127 or res.rc != 0:
        return {"changed": False, "msg": "IBM SVC system not found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse the output - lines are colon-delimited key:value pairs
    data = {}
    for line in res.stdout.splitlines():
        if ":" in line:
            idx = line.find(":")
            key = line[:idx]
            val = line[idx+1:]
            data[key] = val

    # Build the message from specific keys
    message = ""
    for key in ["name", "location", "code_level", "email_contact_location"]:
        if key in data:
            if message != "":
                message += ", "
            message += "%s: %s" % (key, data[key])

    # Extract bandwidth as a metric if available
    metrics = {}
    if "bandwidth" in data:
        bw = data["bandwidth"]
        metric_val = _parse_bandwidth(bw)
        if metric_val != None:
            metrics["bandwidth"] = metric_val

    if not message:
        message = "IBM SVC system info"

    return {"changed": False, "msg": message, "data": {"state": "OK", "metrics": metrics, "details": ""}}


def _parse_bandwidth(s):
    # Parse bandwidth values like "2500" or "2500MB" etc.
    if not s:
        return None
    # Strip non-digit suffix for simple numeric extraction
    digits = ""
    for ch in s:
        if ch.isdigit() or ch == "." or ch == "-":
            digits += ch
        else:
            break
    if digits and digits.replace(".", "").replace("-", "").isdigit():
        return float(digits)
    return None
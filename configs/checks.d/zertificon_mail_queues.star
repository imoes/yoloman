def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {
                "discovery": [{
                    "item": "",
                    "params": {},
                    "metrics": [
                        "mail_queue_postfix_total",
                        "mail_queue_incoming_length",
                        "mail_queue_active_length",
                        "mail_queue_deferred_length",
                        "mail_queue_hold_length",
                        "mail_queue_drop_length",
                        "mail_queue_z1_messenger"
                    ]
                }]
            },
        }

    # Check mode - SNMP probe
    res = ctx.run([
        "snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
        ".1.3.6.1.4.1.2021.8.1.100.5",
        ".1.3.6.1.4.1.2021.8.1.100.6",
        ".1.3.6.1.4.1.2021.8.1.100.7",
        ".1.3.6.1.4.1.2021.8.1.100.8",
        ".1.3.6.1.4.1.2021.8.1.100.9",
        ".1.3.6.1.4.1.2021.8.1.100.10",
        ".1.3.6.1.4.1.2021.8.1.100.17"
    ], mutates=False)

    if res.rc != 0 or res.stdout == "":
        return {
            "changed": False,
            "msg": "SNMP query failed or returned empty output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse SNMP values (format: OID = INTEGER:value)
    values = []
    for line in res.stdout.splitlines():
        if line.find("=") != -1:
            val_str = line.rsplit(":", 1)[-1].strip()
            if val_str.isdigit():
                values.append(int(val_str))
            else:
                # Non-numeric fallback: try extracting digits only
                digits = ""
                for c in val_str:
                    if c.isdigit():
                        digits = digits + str(c)
                if digits != "":
                    values.append(int(digits))
                else:
                    values.append(0)
        else:
            values.append(0)

    # Ensure we have exactly 7 values
    while len(values) < 7:
        values.append(0)
    if len(values) > 7:
        values = values[:7]

    postfix = values[0]
    incoming = values[1]
    active = values[2]
    deferred = values[3]
    hold = values[4]
    maildrop = values[5]
    z1 = values[6]

    # Metric names mapping
    metric_info = [
        ("postfix", "mail_queue_postfix_total", postfix),
        ("incoming", "mail_queue_incoming_length", incoming),
        ("active", "mail_queue_active_length", active),
        ("deferred", "mail_queue_deferred_length", deferred),
        ("hold", "mail_queue_hold_length", hold),
        ("maildrop", "mail_queue_drop_length", maildrop),
        ("z1", "mail_queue_z1_messenger", z1),
    ]

    # Determine worst state and build message
    state = "OK"
    details_parts = []
    metrics = {}

    for param_key, metric_name, value in metric_info:
        levels = params.get(param_key)
        if levels != None:
            warn_val = levels[0]
            crit_val = levels[1]
            if value >= crit_val:
                state = "CRIT"
            elif value >= warn_val and state != "CRIT":
                state = "WARN"
        metrics[metric_name] = value

    # Build details string
    for param_key, metric_name, value in metric_info:
        details_parts.append("%s: %d" % (metric_name, value))

    return {
        "changed": False,
        "msg": ", ".join(details_parts),
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        },
    }

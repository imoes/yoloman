def main(ctx, params):
    # Discovery mode: yield exactly one service (single-service check)
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}
        }

    # Check mode: fetch SNMP data for tape library info
    oids = [
        ".1.3.6.1.4.1.20884.1.1",
        ".1.3.6.1.4.1.20884.1.2",
        ".1.3.6.1.4.1.20884.1.3",
        ".1.3.6.1.4.1.20884.1.4"
    ]
    values = ctx.snmp_get(oids)

    # Validate response
    if values == None or len(values) != 4:
        return {
            "changed": False,
            "msg": "SNMP data missing or incomplete",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    names = ["Vendor", "Product ID", "Serial Number", "Software Revision"]
    summary_parts = []
    for i in range(4):
        value = values[i]
        name = names[i]
        if value != None and value != "":
            summary_parts.append("%s: %s" % (name, str(value)))
        else:
            summary_parts.append("%s: <empty>" % name)

    return {
        "changed": False,
        "msg": ", ".join(summary_parts),
        "data": {
            "state": "OK",
            "metrics": {},
            "details": ""
        }
    }

def main(ctx, params):
    # Discovery mode: single-service check, yield one service if printer is present
    if params.get("_discover"):
        res = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.2.1.25.3.5.1.1.1"], mutates=False)
        # Check if any output exists (presence of the OID indicates a Zebra device)
        if res.rc == 0 and res.stdout.strip():
            # Also validate it's a Zebra device by checking sysDescr (.1.3.6.1.2.1.1.1.0)
            desc_res = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.2.1.1.1.0"], mutates=False)
            if desc_res.rc == 0 and "zebra" in desc_res.stdout.lower():
                return {
                    "changed": False,
                    "msg": "discovered 1 service",
                    "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}
                }
        return {
            "changed": False,
            "msg": "discovered 0 services",
            "data": {"discovery": []}
        }

    # Check mode: fetch current printer status from the same OID
    res = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.2.1.25.3.5.1.1.1"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "unable to retrieve printer status",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Extract the status code from the output (format: .1.3.6.1.2.1.25.3.5.1.1.1 = INTEGER: X)
    line = res.stdout.splitlines()[0] if res.stdout.splitlines() else ""
    # Look for an INTEGER assignment
    idx = line.find("INTEGER:")
    if idx == -1:
        return {
            "changed": False,
            "msg": "unable to parse printer status",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    status_str = line[idx + len("INTEGER:"):].strip()
    if not status_str.isdigit():
        return {
            "changed": False,
            "msg": "invalid printer status value",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    zebra_status = int(status_str)

    if zebra_status == 3:
        state = "OK"
        msg = "Printer is online and ready for the next print job"
    elif zebra_status == 4:
        state = "OK"
        msg = "Printer is printing"
    elif zebra_status == 5:
        state = "OK"
        msg = "Printer is warming up"
    elif zebra_status == 1:
        state = "CRIT"
        msg = "Printer is offline"
    else:
        state = "UNKNOWN"
        msg = "Unknown printer status"

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"status": zebra_status},
            "details": ""
        }
    }

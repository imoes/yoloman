def main(ctx, params):
    host = params.get("host", params.get("_host", "localhost"))
    port = params.get("port")
    service = params.get("service")
    check_version = params.get("check_version", False)
    check_address = params.get("check_address", ("no", None))

    if port == None:
        fail("port is required")
    if service == None:
        fail("service is required")

    if params.get("_discover"):
        if check_version or isinstance(check_address, tuple) and check_address[0] == "yes":
            return {
                "changed": False,
                "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "uniserv_" + service, "params": {},
                     "metrics": ["response_time"]}
                ]},
            }
        return {
            "changed": False,
            "msg": "discovered 0 items",
            "data": {"discovery": []},
        }

    item = params.get("item", "")
    args = [host, str(port), service]
    metrics = {}
    details_lines = []
    states = []

    base_cmd = ["nc", "-z", "-w", "5", host, str(port)]
    conn = ctx.run(base_cmd, mutates=False)
    if conn.rc != 0:
        return {
            "changed": False,
            "msg": "cannot connect to uniserv on " + host + ":" + str(port),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if check_version:
        res = ctx.run(["nc", "-w", "5", host, str(port)], input_data=" ".join(args + ["VERSION"]), mutates=False)
        if res.rc == 0:
            ver = res.stdout.strip()
            metrics["version"] = len(ver)
            details_lines.append("Version: " + ver)
            states.append("OK")
        else:
            states.append("CRIT")
            details_lines.append("Version check failed: " + res.stderr.strip())

    if isinstance(check_address, tuple) and check_address[0] == "yes" and len(check_address) > 1 and check_address[1] != None:
        addr = check_address[1]
        addr_args = args + ["ADDRESS", addr.get("street", ""), str(addr.get("street_no", "")), addr.get("city", ""), addr.get("search_regex", "")]
        addr_str = " ".join(addr_args)
        res2 = ctx.run(["nc", "-w", "5", host, str(port)], input_data=addr_str, mutates=False)
        if res2.rc == 0:
            addr_val = res2.stdout.strip()
            metrics["address"] = len(addr_val)
            details_lines.append("Address: " + addr_val)
            states.append("OK")
        else:
            states.append("CRIT")
            details_lines.append("Address check failed: " + res2.stderr.strip())

    if len(states) == 0:
        return {
            "changed": False,
            "msg": "no checks configured",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if "CRIT" in states:
        state = "CRIT"
    elif "WARN" in states:
        state = "WARN"
    else:
        state = "OK"

    return {
        "changed": False,
        "msg": "; ".join(details_lines) if len(details_lines) > 0 else "uniserv check",
        "data": {"state": state, "metrics": metrics, "details": "\n".join(details_lines)},
    }
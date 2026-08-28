def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["find", "/usr/sap", "-maxdepth", "3", "-name", "hostname", "-type", "f"], mutates=False)
        items = []
        if res.rc == 0 and res.stdout != "":
            for f in res.stdout.splitlines():
                f = f.strip()
                if f == "":
                    continue
                path_parts = f.split("/")
                if len(path_parts) >= 6 and path_parts[0] == "" and path_parts[1] == "usr" and path_parts[2] == "sap":
                    sid = path_parts[3]
                    instance = path_parts[4]
                    if sid.startswith("HDB") or sid.startswith("HDB") or sid.startswith("HD"):
                        items.append({
                            "item": sid + "_" + instance,
                            "params": {},
                            "metrics": [],
                        })
        if len(items) == 0:
            bin_res = ctx.run(["which", "hdbnsutil"], mutates=False)
            if bin_res.rc == 0:
                return {"changed": False, "msg": "SAP HANA installed but no live instances found", "data": {"discovery": []}}
            return {"changed": False, "msg": "SAP HANA not installed", "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered %d SAP HANA instances" % len(items), "data": {"discovery": items}}

    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "no SAP HANA instance specified", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    parts = item.split("_")
    if len(parts) < 2:
        return {"changed": False, "msg": "invalid item format", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sid = parts[0]
    instance = parts[1]
    instance_path = "/usr/sap/" + sid + "/" + instance + "/hostname"
    if not ctx.file_exists(instance_path):
        return {"changed": False, "msg": item + ": path not found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    content = ctx.file_read(instance_path)
    lines = content.splitlines()
    if len(lines) < 2:
        return {"changed": False, "msg": item + ": insufficient data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    status_line = lines[0]
    status_parts = status_line.split(":")
    if len(status_parts) < 2:
        return {"changed": False, "msg": item + ": malformed status line", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    status_code = status_parts[1].strip()
    statuses = {
        "0": "Error getting processes",
        "1": "Error getting processes",
        "2": "Timeout",
        "3": "OK",
        "4": "All processes stopped",
    }
    status_desc = statuses.get(status_code, "Error getting processes")
    if status_desc != "OK":
        return {"changed": False, "msg": item + ": " + status_desc, "data": {"state": "CRIT", "metrics": {}, "details": ""}}

    details = []
    # BY INDEX: a Starlark string is NOT iterable, so `for p in lines[2:]:`
    # raises "string value is not iterable" at RUNTIME — on the very line that parses a
    # number out of device output. The stub validator only sees it when its empty-output
    # run happens to reach here, which is why nine shipped checks carried it.
    for _i_p in range(2, len(lines)):
        p = lines[_i_p]
        p = p.strip()
        if p == "":
            continue
        details.append(p)
    details_str = " | ".join(details) if details else "no processes listed"

    return {"changed": False, "msg": item + ": " + status_desc, "data": {"state": "OK", "metrics": {}, "details": details_str}}
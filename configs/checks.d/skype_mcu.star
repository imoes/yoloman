def main(ctx, params):
    # Discovery mode: detect which MCU tables exist and return services for each
    if params.get("_discover"):
        res = ctx.run([
            "wmic", "/namespace:\\\\root\\webadm path win32_perfformatdata",
            "get", "objectname,instancename,rawvalue", "/format:csv"
        ], mutates=False)
        tables = set()
        for line in res.stdout.splitlines():
            parts = line.strip().split(",")
            if len(parts) >= 2:
                objname = parts[0].strip()
                for prefix in [
                    "LS:DATAMCU - MCU Health And Performance",
                    "LS:AVMCU - MCU Health And Performance",
                    "LS:AsMcu - MCU Health And Performance",
                    "LS:ImMcu - MCU Health And Performance"
                ]:
                    if objname.startswith(prefix):
                        tables.add(prefix)
                        break
        discovery = []
        for table in sorted(tables):
            discovery.append({
                "item": table,
                "params": {},
                "metrics": []
            })
        return {
            "changed": False,
            "msg": "discovered %d MCU services" % len(discovery),
            "data": {"discovery": discovery}
        }

    # Check mode: read MCU health state for the item
    item = params.get("item", "")
    if not item:
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Map item to WMI objectname and state column
    wmi_objname_map = {
        "LS:DATAMCU - MCU Health And Performance": ("LS:DATAMCU - MCU Health And Performance", "DATAMCU - MCU Health State"),
        "LS:AVMCU - MCU Health And Performance": ("LS:AVMCU - MCU Health And Performance", "AVMCU - MCU Health State"),
        "LS:AsMcu - MCU Health And Performance": ("LS:AsMcu - MCU Health And Performance", "ASMCU - MCU Health State"),
        "LS:ImMcu - MCU Health And Performance": ("LS:ImMcu - MCU Health And Performance", "IMMCU - MCU Health State")
    }
    wmi_objname, state_col = wmi_objname_map.get(item, ("", ""))
    if not wmi_objname:
        return {
            "changed": False,
            "msg": "unknown item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Query WMI for health state
    # We use a WMI query targeting the specific performance data object
    query = 'SELECT RawValue FROM Win32_PerfFormattedData_' + wmi_objname.replace(" ", "_").replace(":", "").replace("-", "")
    res = ctx.run([
        "wmic", "path", query, "get", "RawValue", "/format:value"
    ], mutates=False)

    state_text = "unknown"
    for line in res.stdout.splitlines():
        if "RawValue=" in line:
            value = line.split("=")[1].strip()
            if value == "0":
                state_text = "Normal"
            elif value == "1":
                state_text = "Loaded"
            elif value == "2":
                state_text = "Full"
            elif value == "3":
                state_text = "Unavailable"
            break

    if state_text == "unknown":
        return {
            "changed": False,
            "msg": "could not determine health state for " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    if state_text == "Normal":
        state = "OK"
    elif state_text in ("Loaded", "Full"):
        state = "WARN"
    else:
        state = "CRIT"

    return {
        "changed": False,
        "msg": item + ": " + state_text,
        "data": {"state": state, "metrics": {}, "details": ""}
    }
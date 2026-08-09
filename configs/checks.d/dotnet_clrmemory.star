def main(ctx, params):
    # Checkmk dotnet_clrmemory check — read-only, no mutations
    # Data source: Windows WMI query for DotNetCLRMemory class (Name="_Global_")
    # Agent output format: <<<dotnet_clrmemory:sep(44)>>>
    #   Header: AllocatedBytesPersec,Caption,...,PercentTimeinGC,...,Name,...
    #   Values: numeric fields separated by comma, Name="_Global_" for total instance

    # Discovery mode: enumerate items (only _Global_ is relevant)
    if params.get("_discover"):
        res = ctx.run(["wmic", "path", "DotNetCLRMemory", "get", "AllocatedBytesPersec,Description,FinalizationSurvivors,Frequency_Object,Name,PercentTimeinGC,PercentTimeinGC_Base,Timestamp_Object,Timestamp_Sys100NS", "/value"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "WMI query failed", "data": {"discovery": []}}

        # Parse /value output into key-value pairs per instance
        lines = res.stdout.splitlines()
        items = []
        current = {}
        for line in lines:
            line = line.strip()
            if not line:
                if current and current.get("Name") == "_Global_":
                    items.append({"item": "", "params": {"upper": [10.0, 15.0]}, "metrics": ["percent"]})
                current = {}
                continue
            if "=" in line:
                k, v = line.split("=", 1)
                current[k.strip()] = v.strip()
        if current and current.get("Name") == "_Global_":
            items.append({"item": "", "params": {"upper": [10.0, 15.0]}, "metrics": ["percent"]})

        return {"changed": False, "msg": "discovered %d DotNet CLR Memory items" % len(items),
                "data": {"discovery": items}}

    # Check mode: process the _Global_ instance
    # Item should be "" for this check
    res = ctx.run(["wmic", "path", "DotNetCLRMemory", "get", "PercentTimeinGC,PercentTimeinGC_Base", "/value"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "no DotNet CLR Memory data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    lines = res.stdout.splitlines()
    values = {}
    for line in lines:
        line = line.strip()
        if "=" in line:
            k, v = line.split("=", 1)
            k = k.strip()
            v = v.strip()
            if v != "":
                values[k] = v

    measure_str = values.get("PercentTimeinGC")
    base_str = values.get("PercentTimeinGC_Base")

    if measure_str == None or base_str == None:
        return {"changed": False, "msg": "missing PercentTimeinGC or PercentTimeinGC_Base", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    measure = int(measure_str)
    base_int = int(base_str)

    # Handle negative base (unsigned 32-bit representation)
    if base_int < 0:
        base_int += 1 << 32

    if base_int == 0:
        average = 0.0
    else:
        average = (measure * 100.0) / float(base_int)

    # Thresholds from params; Checkmk default is (10.0, 15.0)
    upper_levels = params.get("upper", (10.0, 15.0))
    warn = upper_levels[0]
    crit = upper_levels[1]

    if average >= crit:
        state = "CRIT"
    elif average >= warn:
        state = "WARN"
    else:
        state = "OK"

    # Format message like Checkmk: "Time spent in Garbage Collection: 12.3%"
    msg = "Time spent in Garbage Collection: %f%%" % average

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"percent": average}, "details": ""}}

def _grade_mcu_health(value, label):
    # _MCU_HEALTH: "0"=OK Normal, "1"=WARN Loaded, "2"=WARN Full, "3"=CRIT Unavailable
    mapping = {
        "0": ("OK", "Normal"),
        "1": ("WARN", "Loaded"),
        "2": ("WARN", "Full"),
        "3": ("CRIT", "Unavailable"),
    }
    entry = mapping.get(value, ("CRIT", "unknown (" + str(value) + ")"))
    state = entry[0]
    text = entry[1]
    return state, label + ": " + text

def main(ctx, params):
    if params.get("_discover"):
        # Probe for the real thing: Skype for Business Server on a Windows host.
        # This check reads WMI performance counters — only available on Windows
        # with the SfB server role. Check if wmic is usable (Samba wmic on Linux
        # can query remote Windows; check for local WMI availability).
        wmic = ctx.run(["which", "wmic"], mutates=False)
        if wmic.rc != 0 or wmic.stdout.strip() == "":
            return {"changed": False, "msg": "Skype for Business not detected",
                    "data": {"discovery": []}}
        # Even with wmic, we need a Windows host. No host parameter means we
        # can only check localhost — and localhost is not a SfB server on Linux.
        return {"changed": False, "msg": "Skype for Business not detected",
                "data": {"discovery": []}}

    item = params.get("item", "")

    # Try to gather MCU health via WMI. On a Linux host, this is not available.
    # The four tables monitored:
    #   LS:DATAMCU - MCU Health And Performance
    #   LS:AVMCU - MCU Health And Performance
    #   LS:AsMcu - MCU Health And Performance
    #   LS:ImMcu - MCU Health And Performance
    tables = [
        ("DATAMCU", "LS:DATAMCU - MCU Health And Performance", "DATAMCU - MCU Health State"),
        ("AVMCU", "LS:AVMCU - MCU Health And Performance", "AVMCU - MCU Health State"),
        ("ASMCU", "LS:AsMcu - MCU Health And Performance", "ASMCU - MCU Health State"),
        ("IMMCU", "LS:ImMcu - MCU Health And Performance", "IMMCU - MCU Health State"),
    ]

    wmic = ctx.run(["wmic", "WIN32_PerfFormattedData_*"], mutates=False)
    if wmic.rc != 0:
        return {"changed": False,
                "msg": "no Skype for Business MCU health data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # If wmic is not available at all, report UNKNOWN
    if wmic.rc == 127:
        return {"changed": False,
                "msg": "wmic not installed; no Skype for Business MCU health data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    results = []
    worst = "OK"
    details = []
    for short, table_name, column in tables:
        res = ctx.run(["wmic", table_name, "get", column], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            results.append(short + ": no data")
            details.append(table_name + ": no data")
        else:
            # Extract the value (last non-empty line)
            lines = [l for l in res.stdout.splitlines() if l.strip()]
            value = lines[-1].strip() if lines else ""
            state, text = _grade_mcu_health(value, short)
            results.append(text)
            details.append(table_name + ": " + text)
            if state == "CRIT":
                worst = "CRIT"
            elif state == "WARN" and worst != "CRIT":
                worst = "WARN"

    return {"changed": False,
            "msg": "; ".join(results),
            "data": {"state": worst, "metrics": {},
                     "details": "\n".join(details)}}
def main(ctx, params):
    if params.get("_discover"):
        # windows_multipath is a Windows-only check; data comes from the
        # Windows MPIO subsystem (active path count) which has no
        # Linux equivalent. Probe for the real source first.
        probe = ctx.run(["powershell", "-NoProfile", "-Command",
                         "Get-WinEvent -LogName 'Microsoft-Windows-MPIO/Operational' -MaxEvents 1 -ErrorAction SilentlyContinue"],
                        mutates=False)
        # rc == 127 => not Windows / MPIO absent
        if probe.rc == 127 or not probe.stdout:
            return {"changed": False, "msg": "no windows multipath data available",
                    "data": {"discovery": [], "host_labels": {}}}
        # If we got data, try to get the active path count via a
        # Windows-style source. The Checkmk source reads a single integer
        # (active path count) from the windows_multipath agent section.
        # Without the Checkmk agent on Windows we cannot reproduce this
        # reliably on Linux; if not Windows, treat as absent.
        facts = ctx.facts()
        if facts.get("os_family") != "windows":
            return {"changed": False, "msg": "no windows multipath data available",
                    "data": {"discovery": [], "host_labels": {}}}
        # On Windows: attempt to read active paths count via WMI
        wmi = ctx.run(["powershell", "-NoProfile", "-Command",
                       "(Get-WmiObject -Namespace root\\microsoft\\windows\\mpio -Class MSFT_PhysicalDisk -ErrorAction SilentlyContinue | Where-Object {$_.IsMultipathed -eq $true} | Measure-Object).Count"],
                      mutates=False)
        if wmi.rc != 0 or not wmi.stdout.strip():
            return {"changed": False, "msg": "no windows multipath data available",
                    "data": {"discovery": [], "host_labels": {}}}
        count_str = wmi.stdout.strip()
        if not count_str.isdigit():
            return {"changed": False, "msg": "no windows multipath data available",
                    "data": {"discovery": [], "host_labels": {}}}
        num_active = int(count_str)
        if num_active > 0:
            return {"changed": False,
                    "msg": "discovered 1 item",
                    "data": {"discovery": [
                        {"item": "", "params": {"active_paths": num_active},
                         "metrics": ["active_paths"]}
                    ], "host_labels": {}}}
        return {"changed": False, "msg": "no active multipath paths",
                "data": {"discovery": [], "host_labels": {}}}

    # CHECK MODE
    facts = ctx.facts()
    if facts.get("os_family") != "windows":
        return {"changed": False, "msg": "windows multipath not available on this host",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "host is not Windows or MPIO is not installed"}}

    item = params.get("item", "")
    wmi = ctx.run(["powershell", "-NoProfile", "-Command",
                   "(Get-WmiObject -Namespace root\\microsoft\\windows\\mpio -Class MSFT_PhysicalDisk -ErrorAction SilentlyContinue | Where-Object {$_.IsMultipathed -eq $true} | Measure-Object).Count"],
                  mutates=False)
    if wmi.rc != 0 or not wmi.stdout.strip():
        return {"changed": False, "msg": "windows multipath data not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "could not query Windows MPIO active paths"}}

    count_str = wmi.stdout.strip()
    num_active = int(count_str) if count_str.isdigit() else 0

    levels = params.get("active_paths", 4)
    if type(levels) == "list":
        # tuple form: (num_paths, warn_pct, crit_pct) - translated as list
        if len(levels) == 3:
            _num_paths, warn_pct, crit_pct = levels[0], levels[1], levels[2]
            warn_num = float(warn_pct) / 100.0 * num_active
            crit_num = float(crit_pct) / 100.0 * num_active
            if num_active < crit_num:
                state = "CRIT"
            elif num_active < warn_num:
                state = "WARN"
            else:
                state = "OK"
            extra = " (warn/crit below %d/%d)" % (int(warn_num), int(crit_num))
        else:
            state = "OK"
            extra = ""
    else:
        expected = int(levels) if str(levels).isdigit() else 4
        if num_active < expected:
            state = "CRIT"
        elif num_active > expected:
            state = "WARN"
        else:
            state = "OK"
        extra = " Expected: %d" % expected

    return {"changed": False,
            "msg": "Paths active: %d%s" % (num_active, extra),
            "data": {"state": state, "metrics": {"active_paths": num_active}, "details": ""}}
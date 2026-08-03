def main(ctx, params):
    if params.get("_discover"):
        # Probe for 3ware controller tools (tw_cli or /proc/mpt) to ensure
        # this check is applicable to the host.
        res = ctx.run(["tw_cli", "show"], mutates=False)
        if res.rc == 127 and not ctx.file_exists("/proc/mpt2sas"):
            # 3ware utility not installed and no 3ware proc interface present
            return {"changed": False, "msg": "no 3ware controller found",
                    "data": {"discovery": []}}

        # Gather the real underlying 3ware data via tw_cli if available
        if res.rc == 0 and res.stdout != "":
            out = []
            lines = res.stdout.splitlines()
            # tw_cli output is variable; we attempt a heuristic parse for unit/port info
            for line in lines:
                parts = line.split()
                if len(parts) >= 6:
                    port = parts[0]
                    status = parts[1]
                    if status == "NOT-PRESENT":
                        continue
                    out.append({"item": port, "params": {},
                                "metrics": ["disk_status"]})
            return {"changed": False, "msg": "discovered %d 3ware disks" % len(out),
                    "data": {"discovery": out}}

        # Fallback: read the /proc/mpt interface if available
        if ctx.file_exists("/proc/mpt2sas") or ctx.file_exists("/proc/mptctl"):
            content = ctx.file_read("/proc/mpt2sas") if ctx.file_exists("/proc/mpt2sas") else ctx.file_read("/proc/mptctl")
            lines = content.splitlines()
            out = []
            for line in lines:
                parts = line.split()
                if len(parts) >= 6:
                    port = parts[0]
                    status = parts[1]
                    if status == "NOT-PRESENT":
                        continue
                    out.append({"item": port, "params": {},
                                "metrics": ["disk_status"]})
            return {"changed": False, "msg": "discovered %d 3ware disks" % len(out),
                    "data": {"discovery": out}}

        return {"changed": False, "msg": "no 3ware data source available",
                "data": {"discovery": []}}

    # CHECK MODE for a single item
    item = params.get("item", "")

    # Determine the real data source (tw_cli output already captured, or /proc)
    content = ""
    tw_res = ctx.run(["tw_cli", "show"], mutates=False)
    if tw_res.rc == 0 and tw_res.stdout != "":
        content = tw_res.stdout
    elif ctx.file_exists("/proc/mpt2sas"):
        content = ctx.file_read("/proc/mpt2sas")
    elif ctx.file_exists("/proc/mptctl"):
        content = ctx.file_read("/proc/mptctl")
    else:
        return {"changed": False,
                "msg": "3ware controller tools not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    lines = content.splitlines()
    found = False
    for line in lines:
        parts = line.split()
        if len(parts) >= 6 and parts[0] == item:
            found = True
            status = parts[1]
            unit_type = parts[2]
            size = parts[3]
            size_type = parts[4]
            disk_type = parts[5]
            model = parts[-1]
            infotext = "%s (unit: %s, size: %s,%s, type: %s, model: %s)" % (
                status, unit_type, size, size_type, disk_type, model)
            if status in ["OK", "VERIFYING"]:
                state = "OK"
            elif status in ["SMART_FAILURE"]:
                state = "WARN"
            elif status in ["NOT-PRESENT"]:
                state = "UNKNOWN"
            else:
                state = "CRIT"
            return {"changed": False,
                    "msg": "disk status is " + infotext,
                    "data": {"state": state,
                             "metrics": {"disk_status": 0 if state == "OK" else 1},
                             "details": ""}}
    if not found:
        return {"changed": False,
                "msg": "disk " + item + " not found in agent output",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
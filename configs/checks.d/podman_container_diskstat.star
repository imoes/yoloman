def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["podman", "info", "--format", "{{.Version}}"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no podman found", "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 items", "data": {"discovery": [{"item": "SUMMARY", "params": {}, "metrics": ["read_ios", "write_ios"]}]}}

    item = params.get("item", "")
    res = ctx.run(["podman", "stats", "--no-stream", "--format", "{{.Name}} {{.BlockIn}} {{.BlockOut}}"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "podman not available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    lines = res.stdout.splitlines()
    found_read = 0
    found_write = 0
    found = False
    for line in lines:
        f = line.split()
        if len(f) >= 3:
            if f[0] == item or item == "SUMMARY":
                found_read += int(f[1]) if f[1].isdigit() else 0
                found_write += int(f[2]) if f[2].isdigit() else 0
                found = True

    if not found:
        return {"changed": False, "msg": "no io data found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    warn_read = params.get("warn_read_ios")
    crit_read = params.get("crit_read_ios")
    warn_write = params.get("warn_write_ios")
    crit_write = params.get("crit_write_ios")

    state = "OK"
    if crit_read != None and found_read >= crit_read:
        state = "CRIT"
    if crit_write != None and found_write >= crit_write:
        state = "CRIT"
    if state == "OK":
        if warn_read != None and found_read >= warn_read:
            state = "WARN"
        if warn_write != None and found_write >= warn_write:
            state = "WARN"

    msg = "Read: %d IOPS, Write: %d IOPS" % (found_read, found_write)
    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": {"read_ios": found_read, "write_ios": found_write}, "details": ""}}
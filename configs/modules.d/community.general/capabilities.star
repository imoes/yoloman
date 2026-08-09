def main(ctx, params):
    capability = params["capability"].strip().lower()
    path = params["path"].strip()
    state = params.get("state", "present")

    OPS = ("=", "-", "+")

    def parse_cap(cap, op_required=True):
        opind = -1
        for i in range(len(OPS)):
            if OPS[i] in cap:
                opind = cap.find(OPS[i])
                break
        if opind == -1:
            if op_required:
                fail("Couldn't find operator (one of: =, -, +)")
            else:
                return (cap, None, None)
        op = cap[opind]
        parts = cap.split(op, 1)
        cap_name = parts[0]
        flags = parts[1] if len(parts) > 1 else ""
        return (cap_name, op, flags)

    def getcap(path):
        res = ctx.run(["getcap", "-v", path])
        if res.rc != 0 or res.stderr != "":
            fail("Unable to get capabilities of " + path + ": " + res.stderr)
        stdout = res.stdout.strip()
        if stdout == path:
            return []
        if " =" in stdout:
            # older libcap output format
            cap_str = stdout.split(" =", 1)[1].strip()
        else:
            # newer libcap output format
            cap_str = stdout.split(" ", 1)[1].strip() if len(stdout.split(" ", 1)) > 1 else ""
        if not cap_str:
            return []
        caps = cap_str.split()
        rval = []
        for cap in caps:
            cap = cap.lower()
            if "," in cap:
                cap_group = cap.split(",")
                last = cap_group[-1]
                cap_name, op, flags = parse_cap(last)
                for subcap in cap_group:
                    rval.append((subcap, op, flags))
            else:
                rval.append(parse_cap(cap))
        return rval

    def setcap(path, caps):
        caps_str = " ".join(["".join(cap) for cap in caps])
        cmd = ["setcap", "'" + caps_str + "'", path]
        res = ctx.run(cmd, mutates=True)
        if res.rc != 0:
            fail("Unable to set capabilities of " + path + ": " + res.stderr)
        return res.stdout

    # Parse capability and get current state
    capability_tup = parse_cap(capability, op_required=(state == "present"))
    current_caps = getcap(path)

    if state == "present":
        if capability_tup not in current_caps:
            if ctx.check_mode:
                return {"changed": True, "msg": "capabilities changed"}
            else:
                # Remove existing capability with same name if exists (different op/flags)
                current_caps = [c for c in current_caps if c[0] != capability_tup[0]]
                current_caps.append(capability_tup)
                setcap(path, current_caps)
                return {"changed": True, "msg": "capabilities changed"}
        else:
            return {"changed": False, "msg": "capabilities already set"}
    elif state == "absent":
        cap_name = capability_tup[0]
        caps_list = [c[0] for c in current_caps]
        if cap_name in caps_list:
            if ctx.check_mode:
                return {"changed": True, "msg": "capabilities changed"}
            else:
                current_caps = [c for c in current_caps if c[0] != cap_name]
                setcap(path, current_caps)
                return {"changed": True, "msg": "capabilities changed"}
        else:
            return {"changed": False, "msg": "capability not present"}

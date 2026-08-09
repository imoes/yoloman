def main(ctx, params):
    vg = params["vg"]
    lv = params["lv"]
    lv_type = params.get("lv_type", "jfs2")
    size = params.get("size")
    opts = params.get("opts", "")
    copies = params.get("copies", 1)
    policy = params.get("policy", "maximum")
    state = params.get("state", "present")
    pvs = params.get("pvs", [])

    # Convert policy to mklv flag
    lv_policy = "x" if policy == "maximum" else "m"

    # Build pvs string for mklv command
    pv_list = " ".join(pvs)

    # Determine if check mode (dry-run)
    test_opt = "echo " if ctx.check_mode else ""

    # Check required commands exist
    lsvg_path = ctx.run(["which", "lsvg"], ok_codes=[0, 1])
    if lsvg_path.rc != 0:
        fail("Command 'lsvg' not found")
    lslv_path = ctx.run(["which", "lslv"], ok_codes=[0, 1])
    if lslv_path.rc != 0:
        fail("Command 'lslv' not found")

    # Get VG info
    vg_cmd = [lsvg_path.stdout.strip(), vg]
    vg_res = ctx.run(vg_cmd)
    if vg_res.rc != 0:
        if state == "absent":
            return {"changed": False, "msg": "Volume group %s does not exist." % vg}
        fail("Volume group %s does not exist." % vg)

    # Parse VG info (simplified parsing)
    vg_lines = vg_res.stdout.splitlines()
    this_vg = {}
    for line in vg_lines:
        if "VOLUME GROUP:" in line:
            parts = line.split()
            if len(parts) >= 3:
                this_vg["name"] = parts[2]
        elif "TOTAL PP" in line and "(s)" in line:
            idx = line.find("TOTAL PP:") + len("TOTAL PP:")
            pp_total = line[idx:].strip().split()[0]
            this_vg["size"] = int(pp_total) if pp_total.isdigit() else 0
        elif "PP SIZE:" in line:
            idx = line.find("PP SIZE:") + len("PP SIZE:")
            pp_size_str = line[idx:].strip().split()[0]
            this_vg["pp_size"] = int(pp_size_str) if pp_size_str.isdigit() else 16
        elif "FREE PP" in line and "(s)" in line:
            idx = line.find("FREE PP:") + len("FREE PP:")
            pp_free = line[idx:].strip().split()[0]
            this_vg["free"] = int(pp_free) if pp_free.isdigit() else 0

    if "pp_size" not in this_vg:
        this_vg["pp_size"] = 16

    # Calculate lv_size if size is given
    lv_size = 0
    if size != None:
        unit = size[-1].upper()
        units = ["M", "G", "T"]
        if unit not in units:
            fail("No valid size unit specified. Use M, G, or T.")
        if unit == "M":
            multiplier = 1
        elif unit == "G":
            multiplier = 1024
        elif unit == "T":
            multiplier = 1024 * 1024
        else:
            fail("No valid size unit specified. Use M, G, or T.")
        lv_size = int(size[:-1]) * multiplier
        # Round up to next pp_size multiple
        pp_size = this_vg.get("pp_size", 16)
        rounded = pp_size * ((lv_size + pp_size - 1) // pp_size)
        lv_size = rounded

    # Get LV info
    lslv_cmd = [lslv_path.stdout.strip(), lv]
    lv_res = ctx.run(lslv_cmd, ok_codes=[0, 1])
    this_lv = None
    if lv_res.rc == 0:
        # Parse lslv output
        lv_lines = lv_res.stdout.splitlines()
        parsed = {}
        for line in lv_lines:
            if "LOGICAL VOLUME:" in line and "VOLUME GROUP:" in line:
                parts = line.split()
                for i, p in enumerate(parts):
                    if p == "LOGICAL" and i + 1 < len(parts) and parts[i + 1] == "VOLUME:":
                        parsed["name"] = parts[i + 2]
                    if p == "VOLUME" and i + 1 < len(parts) and parts[i + 1] == "GROUP:":
                        parsed["vg"] = parts[i + 2]
            elif "LPs:" in line:
                idx = line.find("LPs:") + len("LPs:")
                lps_str = line[idx:].strip().split()[0]
                parsed["lps"] = int(lps_str) if lps_str.isdigit() else 0
            elif "PP SIZE:" in line:
                idx = line.find("PP SIZE:") + len("PP SIZE:")
                pp_size_line = line[idx:].strip().split()[0]
                parsed["pp_size"] = int(pp_size_line) if pp_size_line.isdigit() else 16
            elif "INTER-POLICY:" in line:
                idx = line.find("INTER-POLICY:") + len("INTER-POLICY:")
                policy_val = line[idx:].strip()
                parsed["policy"] = policy_val
        if "name" in parsed:
            parsed["size"] = parsed.get("lps", 0) * parsed.get("pp_size", 16)
            this_lv = parsed

    # State logic
    if state == "present" and size == None:
        if this_lv == None:
            fail("No size given for creating logical volume %s." % lv)

    if this_lv == None:
        if state == "present":
            # Check free space
            if size != None and lv_size > this_vg.get("free", 0):
                fail("Not enough free space in volume group %s: %s MB free." % (
                    this_vg.get("name", vg), this_vg.get("free", 0)))

            # Create logical volume
            mklv_path = ctx.run(["which", "mklv"], ok_codes=[0, 1])
            if mklv_path.rc != 0:
                fail("Command 'mklv' not found")

            # Build command
            cmd_parts = [test_opt + "mklv", "-t", lv_type, "-y", lv, "-c", str(copies), "-e", lv_policy]
            if opts != "":
                cmd_parts.extend(opts.split())
            cmd_parts.extend([vg, str(int(lv_size)) + "M", pv_list])
            res = ctx.run(cmd_parts)
            if res.rc == 0:
                return {"changed": True, "msg": "Logical volume %s created." % lv}
            if res.skipped:
                return {"changed": True, "msg": "would create logical volume %s" % lv}
            fail("Creating logical volume %s failed: %s" % (lv, res.stderr))
        else:
            # state == 'absent', LV doesn't exist
            return {"changed": False, "msg": "Logical Volume %s does not exist." % lv}
    else:
        if state == "absent":
            # Remove logical volume
            rmlv_path = ctx.run(["which", "rmlv"], ok_codes=[0, 1])
            if rmlv_path.rc != 0:
                fail("Command 'rmlv' not found")

            res = ctx.run([rmlv_path.stdout.strip(), "-f", this_lv["name"]])
            if res.rc == 0:
                return {"changed": True, "msg": "Logical volume %s deleted." % lv}
            if res.skipped:
                return {"changed": True, "msg": "would delete logical volume %s" % lv}
            fail("Failed to remove logical volume %s: %s" % (lv, res.stderr))
        else:
            # Change policy if different
            if this_lv.get("policy") != policy:
                chlv_path = ctx.run(["which", "chlv"], ok_codes=[0, 1])
                if chlv_path.rc != 0:
                    fail("Command 'chlv' not found")
                res = ctx.run([chlv_path.stdout.strip(), "-e", lv_policy, this_lv["name"]])
                if res.rc == 0:
                    return {"changed": True, "msg": "Logical volume %s policy changed: %s." % (lv, policy)}
                if res.skipped:
                    return {"changed": True, "msg": "would change policy for logical volume %s" % lv}
                fail("Failed to change logical volume %s policy: %s" % (lv, res.stderr))

            # Check vg
            if this_lv.get("vg") != vg:
                fail("Logical volume %s already exists in volume group %s." % (lv, this_lv.get("vg")))

            # Handle size
            if size == None:
                return {"changed": False, "msg": "Logical volume %s already exists." % lv}

            current_size = this_lv.get("size", 0)
            if int(lv_size) > current_size:
                extendlv_path = ctx.run(["which", "extendlv"], ok_codes=[0, 1])
                if extendlv_path.rc != 0:
                    fail("Command 'extendlv' not found")
                delta = int(lv_size) - current_size
                res = ctx.run([extendlv_path.stdout.strip(), lv, "%sM" % delta])
                if res.rc == 0:
                    return {"changed": True, "msg": "Logical volume %s size extended to %sMB." % (lv, lv_size)}
                if res.skipped:
                    return {"changed": True, "msg": "would extend logical volume %s to %sMB" % (lv, lv_size)}
                fail("Unable to resize %s to %sMB: %s" % (lv, lv_size, res.stderr))
            elif int(lv_size) < current_size:
                fail("No shrinking of Logical Volume %s permitted. Current size: %s MB" % (lv, current_size))
            else:
                return {"changed": False, "msg": "Logical volume %s size is already %sMB." % (lv, current_size)}

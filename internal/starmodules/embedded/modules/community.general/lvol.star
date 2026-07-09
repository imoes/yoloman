def main(ctx, params):
    vg = params["vg"]
    lv = params.get("lv")
    size = params.get("size")
    opts = params.get("opts")
    state = params.get("state", "present")
    force = params.get("force", False)
    shrink = params.get("shrink", True)
    active = params.get("active", True)
    resizefs = params.get("resizefs", False)
    thinpool = params.get("thinpool")
    snapshot = params.get("snapshot")
    pvs_list = params.get("pvs", [])

    # Validation: require lv or thinpool
    if not lv and not thinpool:
        fail("lv or thinpool must be specified")
    if lv and thinpool and not snapshot:
        fail("Cannot specify both lv and thinpool when not creating a snapshot")

    # Helper to parse LVM version (using --version output)
    ver_res = ctx.run(["lvm", "version"])
    if ver_res.rc != 0:
        fail("Failed to get LVM version: " + ver_res.stderr)
    version_str = ver_res.stdout
    # Look for "LVM version:" line
    version_line = ""
    for line in version_str.splitlines():
        if "LVM version:" in line:
            version_line = line
            break
    if not version_line:
        fail("Failed to parse LVM version from output")
    # Extract numbers: "LVM version: 2.03.11 (2022-02-16)"
    parts = version_line.split(":")
    if len(parts) < 2:
        fail("Failed to parse LVM version from: " + version_line)
    ver_text = parts[1].strip()
    # Find first three dot-separated numbers. Real `lvm version` prints e.g.
    # "2.03.31(2) (2025-02-27)" — strip any "(...)" build suffix before the
    # digit check, or the parens make isdigit() fail (found via live test).
    ver_nums = []
    for seg in ver_text.split():
        core = seg.split("(")[0]
        if core.count(".") == 2 and core.replace(".", "").isdigit():
            major, minor, patch = core.split(".")
            ver_nums = [int(major), int(minor), int(patch)]
            break
    if not ver_nums:
        fail("Failed to parse LVM version numbers from: " + version_line)
    version_found = (ver_nums[0] * 1000 * 1000) + (ver_nums[1] * 1000) + ver_nums[2]
    version_yesopt = (2 * 1000 * 1000) + (2 * 1000) + 99
    yesopt = "--yes" if version_found >= version_yesopt else ""

    # Handle check_mode flag
    test_opt = " --test" if ctx.check_mode else ""

    # Parse size string for operators and units
    size_operator = None
    size_percent = None
    size_whole = None
    size_opt = "L"
    size_unit = "m"

    if size:
        if size.startswith("+"):
            size_operator = "+"
            size = size[1:]
        elif size.startswith("-"):
            size_operator = "-"
            size = size[1:]

        if "%" in size:
            percent_part = size.split("%", 1)
            size_percent = int(percent_part[0])
            if size_percent > 100:
                fail("Size percentage cannot be larger than 100%")
            size_whole = percent_part[1]
            if size_whole == "ORIGIN" and not snapshot:
                fail("Percentage of ORIGIN supported only for snapshot volumes")
            elif size_whole not in ["VG", "PVS", "FREE", "ORIGIN"]:
                fail("Specify extents as a percentage of VG|PVS|FREE|ORIGIN")
            size_opt = "l"
            size_unit = ""

        if "%" not in size:
            last_char = size[-1].lower()
            if last_char in "bskmgtpe":
                size_unit = last_char
                size = size[:-1]
            # Validate numeric part
            float(size)
            # Ensure size string starts with digit or dot (e.g., .5 is allowed)
            if not size[0].isdigit() and size[0] != ".":
                fail("Bad size specification: " + params.get("size"))

    # Build pvs string
    pvs_str = ""
    if pvs_list:
        pvs_str = " ".join(pvs_list)

    # Helper to call vgs and parse output
    def get_vg_info():
        vgs_cmd = ["vgs", "--noheadings", "--nosuffix", "-o", "vg_name,size,free,vg_extent_size", "--units", size_unit.lower(), "--separator", ";", vg]
        res = ctx.run(vgs_cmd)
        if res.rc != 0:
            fail("Failed to get volume group info: " + res.stderr)
        vgs_data = res.stdout
        lines = [l.strip() for l in vgs_data.splitlines() if l.strip()]
        if not lines:
            fail("No volume group data returned")
        parts = lines[0].split(";")
        if len(parts) < 4:
            fail("Invalid vgs output format")
        return {
            "name": parts[0],
            "size": float(parts[1]),
            "free": float(parts[2]),
            "ext_size": float(parts[3])
        }

    # Helper to call lvs and parse output
    def get_lv_info():
        lvs_cmd = ["lvs", "-a", "--noheadings", "--nosuffix", "-o", "lv_name,size,lv_attr", "--units", size_unit.lower(), "--separator", ";", vg]
        res = ctx.run(lvs_cmd)
        if res.rc != 0:
            fail("Failed to get logical volume info: " + res.stderr)
        lvs_data = res.stdout
        result = []
        for line in [l.strip() for l in lvs_data.splitlines() if l.strip()]:
            parts = line.split(";")
            if len(parts) < 3:
                continue
            name_raw = parts[0].replace("[", "").replace("]", "")
            attr = parts[2]
            result.append({
                "name": name_raw,
                "size": float(parts[1]),
                "active": (len(attr) > 4 and attr[4] == "a"),
                "thinpool": (len(attr) > 0 and attr[0] == "t"),
                "thinvol": (len(attr) > 0 and attr[0] == "V"),
            })
        return result

    # Check volume group exists
    this_vg = get_vg_info()

    # Get existing LVs
    lvs_list = get_lv_info()

    # Determine which LV to check
    check_lv = lv if lv else thinpool
    if snapshot:
        check_lv = snapshot
        # Verify snapshot origin exists
        found_origin = False
        for test_lv in lvs_list:
            if test_lv["name"] == lv or test_lv["name"] == thinpool:
                if not test_lv["thinpool"] and not thinpool:
                    found_origin = True
                    break
                else:
                    fail("Snapshots of thin pool LVs are not supported.")
        if not found_origin:
            fail("Snapshot origin LV " + (lv or thinpool) + " does not exist in volume group " + vg + ".")

    # Find current LV
    this_lv = None
    for test_lv in lvs_list:
        if test_lv["name"] in (check_lv, check_lv.rsplit("/", 1)[-1]):
            this_lv = test_lv
            break

    changed = False
    msg = ""

    if this_lv == None:
        if state == "present":
            # Require size for non-thinvolume-snapshot cases
            if (lv or thinpool) and not size:
                if lv and snapshot:
                    # Allow omitting size for thin snapshot
                    is_thin_snapshot = False
                    for test_lv in lvs_list:
                        if test_lv["name"] == lv and test_lv["thinvol"]:
                            is_thin_snapshot = True
                            break
                    if not is_thin_snapshot:
                        fail("No size given.")
                else:
                    fail("No size given.")

            # Build create command
            lvcreate_cmd = ["lvcreate"]

            if snapshot:
                lvcreate_cmd.append("-s")
                lvcreate_cmd.append("-n")
                lvcreate_cmd.append(snapshot)
                if size:
                    lvcreate_cmd.extend(["-L" if size_opt == "L" else "-l", size + size_unit])
                lvcreate_cmd.append(vg + "/" + lv)
            elif thinpool and lv:
                if size_opt == "l":
                    fail("Thin volume sizing with percentage not supported.")
                lvcreate_cmd.extend(["-n", lv, "-V", size + size_unit])
                lvcreate_cmd.extend(["-T", vg + "/" + thinpool])
            elif thinpool and not lv:
                lvcreate_cmd.extend(["-T", vg + "/" + thinpool, "-L" if size_opt == "L" else "-l", size + size_unit])
            else:
                lvcreate_cmd.extend(["-n", lv])
                lvcreate_cmd.extend(["-L" if size_opt == "L" else "-l", size + size_unit])
                if opts:
                    lvcreate_cmd.append(opts)
                lvcreate_cmd.append(vg)
                if pvs_str:
                    lvcreate_cmd.append(pvs_str)

            # Prepend flags
            if yesopt:
                idx = lvcreate_cmd.index("lvcreate") + 1
                lvcreate_cmd.insert(idx, yesopt)
            if test_opt:
                idx = lvcreate_cmd.index("lvcreate") + 1
                lvcreate_cmd.insert(idx, test_opt)

            res = ctx.run(lvcreate_cmd)
            if res.rc == 0:
                changed = True
            else:
                fail("Creating logical volume failed: " + res.stderr)
        else:
            # State absent and LV does not exist → idempotent
            return {"changed": False, "msg": "Logical volume does not exist"}
    else:
        if state == "absent":
            if not force:
                fail("No removal of logical volume " + this_lv["name"] + " without force=true.")
            lvremove_cmd = ["lvremove", "--force", vg + "/" + this_lv["name"]]
            if test_opt:
                lvremove_cmd.insert(1, test_opt)
            res = ctx.run(lvremove_cmd)
            if res.rc == 0:
                return {"changed": True, "msg": "Removed logical volume " + this_lv["name"]}
            fail("Failed to remove logical volume " + this_lv["name"] + ": " + res.stderr)
        elif not size:
            # No change needed if size not provided and LV exists
            pass
        else:
            # Resize logic
            tool = None
            size_free = this_vg["free"]
            size_requested = None

            if size_opt == "l":
                if size_whole == "VG" or size_whole == "PVS":
                    size_requested = (size_percent * this_vg["size"]) / 100
                else:  # FREE or ORIGIN (treated similarly for sizing)
                    size_requested = (size_percent * this_vg["free"]) / 100

                if size_operator == "+":
                    size_requested += this_lv["size"]
                elif size_operator == "-":
                    size_requested = this_lv["size"] - size_requested

                # Round down to extent size
                size_requested -= (size_requested % this_vg["ext_size"])

                if this_lv["size"] < size_requested:
                    if size_free >= (size_requested - this_lv["size"]):
                        tool = "lvextend"
                    else:
                        fail("Logical volume " + this_lv["name"] + " could not be extended. " +
                             "Not enough free space left (" + str(size_requested - this_lv["size"]) +
                             size_unit + " required / " + str(size_free) + size_unit + " available)")
                elif shrink and this_lv["size"] > size_requested + this_vg["ext_size"]:
                    if size_requested < 1:
                        fail("No shrinking of " + this_lv["name"] + " to 0 permitted.")
                    if not force:
                        fail("No shrinking of " + this_lv["name"] + " without force=true")
                    tool = "lvreduce"
            else:
                # Absolute size
                size_requested = float(size)
                if size_operator == "+":
                    size_requested += this_lv["size"]
                elif size_operator == "-":
                    size_requested = this_lv["size"] - size_requested

                if size_requested > this_lv["size"]:
                    tool = "lvextend"
                elif shrink and size_requested < this_lv["size"]:
                    if size_requested == 0:
                        fail("No shrinking of " + this_lv["name"] + " to 0 permitted.")
                    if not force:
                        fail("No shrinking of " + this_lv["name"] + " without force=true")
                    tool = "lvreduce"

            if tool:
                cmd_args = [tool]
                if test_opt:
                    cmd_args.append(test_opt.strip())
                if resizefs:
                    cmd_args.append("--resizefs")
                if size_operator:
                    cmd_args.extend(["-" + size_opt, size_operator + size + size_unit])
                else:
                    cmd_args.extend(["-" + size_opt, size + size_unit])
                cmd_args.append(vg + "/" + this_lv["name"])
                if pvs_str:
                    cmd_args.append(pvs_str)

                if tool == "lvreduce":
                    cmd_args.append("--force")

                res = ctx.run(cmd_args)
                if res.rc == 0:
                    changed = True
                elif "matches existing size" in res.stderr or "matches existing size" in res.stdout:
                    return {"changed": False, "msg": "Size already matches"}
                elif "not larger than existing size" in res.stderr or "not larger than existing size" in res.stdout:
                    return {"changed": False, "msg": "Original size is larger than requested size"}
                else:
                    fail("Unable to resize " + this_lv["name"] + " to " + size + size_unit + ": " + res.stderr)
            else:
                # No tool needed — size already correct
                pass

    # Handle active state
    if this_lv != None:
        lvchange_cmd = ["lvchange"]
        if active:
            lvchange_cmd.append("-ay")
        else:
            lvchange_cmd.append("-an")
        lvchange_cmd.append(vg + "/" + this_lv["name"])

        res = ctx.run(lvchange_cmd)
        if res.rc != 0:
            fail("Failed to set active state for " + this_lv["name"] + ": " + res.stderr)

        # Determine if active state changed
        if active != this_lv["active"]:
            changed = True

    return {"changed": changed, "msg": msg}

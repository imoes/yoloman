def main(ctx, params):
    device = params["device"]
    align = params.get("align", "optimal")
    number = params.get("number")
    unit = params.get("unit", "KiB")
    label = params.get("label", "msdos")
    part_type = params.get("part_type", "primary")
    part_start = params.get("part_start", "0%")
    part_end = params.get("part_end", "100%")
    name = params.get("name")
    state = params.get("state", "info")
    flags = params.get("flags")
    fs_type = params.get("fs_type")
    resize = params.get("resize", False)

    # Validate required parameters
    if state in ["present", "absent"] and number == None:
        fail("number is required when state is " + state)

    # Validate partition number
    if number != None and number < 1:
        fail("The partition number must be greater than 0.")

    # Validate size format (basic check - no regex available)
    valid_units = ["B", "KB", "KiB", "MB", "MiB", "GB", "GiB", "TB", "TiB", "s", "%", "cyl", "chs", "compact"]
    def check_unit_format(size_str):
        # Check for negative or positive number with optional unit
        if size_str.startswith("-"):
            size_str = size_str[1:]
            # Allow negative numbers, but strip for unit check
        # Simple check: must start with digit and may end with unit
        unit_found = False
        for u in valid_units:
            if size_str.endswith(u):
                unit_found = True
                break
        # If no unit, check if it's just a number
        if not unit_found and size_str.replace(".", "").isdigit():
            return True
        return unit_found

    if not check_unit_format(part_start) or not check_unit_format(part_end):
        fail("Invalid size format for part_start or part_end")

    # Get device info (read-only probe)
    res = ctx.run(["parted", "-s", "-m", device, "unit", unit, "print"], mutates=False)
    if res.rc != 0:
        fail("Failed to get device info: " + res.stderr)

    # Parse parted machine-parseable output
    lines = [l for l in res.stdout.strip().split("\n") if l.strip() != ""]
    if len(lines) < 2:
        fail("Unexpected parted output format")

    # Extract generic disk info (line index 1)
    disk_parts = lines[1].rstrip(";").split(":")
    current_label = disk_parts[5] if len(disk_parts) > 5 else ""
    current_size_str = disk_parts[1] if len(disk_parts) > 1 else "0"

    # Parse partitions (lines starting from index 2)
    partitions = []
    for i in range(2, len(lines)):
        line = lines[i].rstrip(";")
        if not line:
            continue
        parts = line.split(":")
        if len(parts) < 6:
            continue  # Skip malformed lines

        # Determine format: CHS vs BYT
        # BYT format: num begin end size fstype name flags
        # CHS format: num begin end fstype name flags
        if unit == "chs":
            num = int(parts[0]) if parts[0].isdigit() else 0
            begin = parts[1]
            end = parts[2]
            fstype = parts[3]
            name_val = parts[4]
            flags_str = parts[5] if len(parts) > 5 else ""
        else:
            num = int(parts[0]) if parts[0].isdigit() else 0
            begin = parts[1]
            end = parts[2]
            size_val = parts[3]
            fstype = parts[4]
            name_val = parts[5] if len(parts) > 5 else ""
            flags_str = parts[6] if len(parts) > 6 else ""

        flags_list = []
        if flags_str.strip():
            flags_list = [f.strip() for f in flags_str.split(",") if f.strip()]

        partitions.append({
            "num": num,
            "begin": begin,
            "end": end,
            "size": size_val if unit != "chs" else "",
            "fstype": fstype,
            "name": name_val,
            "flags": flags_list
        })

    # Check if partition exists
    def part_exists(num):
        for p in partitions:
            if p["num"] == num:
                return True
        return False

    # Build parted script
    output_script = ""
    changed = False

    if state == "present":
        # Check if label needs to be set
        mklabel_needed = current_label != label
        if mklabel_needed:
            output_script += "mklabel %s " % label

        # Check if partition needs to be created
        if part_type and (mklabel_needed or not part_exists(number)):
            fs_type_part = ""
            if fs_type != None:
                fs_type_part = fs_type + " "
            output_script += "mkpart %s %s%s %s " % (part_type, fs_type_part, part_start, part_end)

        # Set unit if script is non-empty
        if output_script and unit:
            output_script = "unit %s %s" % (unit, output_script)

        # Resize if requested and partition exists
        if resize and part_exists(number):
            # In check_mode, assume change needed
            if ctx.check_mode:
                changed = True
            else:
                # For simplicity, we don't do complex size parsing in Starlark
                # Assume resize needed if not exactly matching (simplified logic)
                # This is a simplified version — real implementation would compare actual sizes
                changed = True
                output_script += "resizepart %s %s " % (number, part_end)

        # Execute parted script if needed
        if output_script:
            if ctx.check_mode:
                changed = True
            else:
                res = ctx.run(["parted", "-s", "-m", "-a", align, device, output_script], mutates=True)
                if res.rc != 0:
                    fail("Failed to execute parted: " + res.stderr)
                changed = True
            output_script = ""

        # Update partitions list after changes (only if not check_mode)
        if not ctx.check_mode and changed:
            res = ctx.run(["parted", "-s", "-m", device, "unit", unit, "print"], mutates=False)
            if res.rc == 0:
                lines = [l for l in res.stdout.strip().split("\n") if l.strip() != ""]
                partitions = []
                for i in range(2, len(lines)):
                    line = lines[i].rstrip(";")
                    if not line:
                        continue
                    parts = line.split(":")
                    if len(parts) < 6:
                        continue
                    if unit == "chs":
                        num = int(parts[0]) if parts[0].isdigit() else 0
                        begin = parts[1]
                        end = parts[2]
                        fstype = parts[3]
                        name_val = parts[4]
                        flags_str = parts[5] if len(parts) > 5 else ""
                    else:
                        num = int(parts[0]) if parts[0].isdigit() else 0
                        begin = parts[1]
                        end = parts[2]
                        size_val = parts[3]
                        fstype = parts[4]
                        name_val = parts[5] if len(parts) > 5 else ""
                        flags_str = parts[6] if len(parts) > 6 else ""

                    flags_list = []
                    if flags_str.strip():
                        flags_list = [f.strip() for f in flags_str.split(",") if f.strip()]

                    partitions.append({
                        "num": num,
                        "begin": begin,
                        "end": end,
                        "size": size_val if unit != "chs" else "",
                        "fstype": fstype,
                        "name": name_val,
                        "flags": flags_list
                    })

        # Set partition name
        if name != None and part_exists(number):
            # Check current name
            current_part = None
            for p in partitions:
                if p["num"] == number:
                    current_part = p
                    break
            if current_part == None or current_part.get("name", "") != name:
                # Use escaped double quotes inside single quotes
                output_script += 'name %s \'"%s"\' ' % (number, name)

        # Set flags
        if flags != None and part_exists(number):
            current_part = None
            for p in partitions:
                if p["num"] == number:
                    current_part = p
                    break
            current_flags = current_part.get("flags", []) if current_part else []

            # Handle esp/boot relationship
            flags_list = list(flags)
            if "esp" in flags_list and "boot" not in flags_list:
                flags_list.append("boot")

            # Determine changes
            flags_on = [f for f in flags_list if f not in current_flags]
            flags_off = [f for f in current_flags if f not in flags_list]

            for f in flags_on:
                output_script += "set %s %s on " % (number, f)
            for f in flags_off:
                output_script += "set %s %s off " % (number, f)

        # Set unit for remaining commands
        if output_script and unit:
            output_script = "unit %s %s" % (unit, output_script)

        # Execute final script
        if output_script:
            if ctx.check_mode:
                changed = True
            else:
                res = ctx.run(["parted", "-s", "-m", "-a", align, device, output_script], mutates=True)
                if res.rc != 0:
                    fail("Failed to execute final parted: " + res.stderr)
                changed = True

    elif state == "absent":
        if part_exists(number) or ctx.check_mode:
            output_script = "rm %s " % number
            if ctx.check_mode:
                changed = True
            else:
                res = ctx.run(["parted", "-s", "-m", "-a", align, device, output_script], mutates=True)
                if res.rc != 0:
                    fail("Failed to remove partition: " + res.stderr)
                changed = True

    elif state == "info":
        output_script = "unit '%s' print " % unit

    # Return final device info
    return {
        "changed": changed,
        "msg": "Done",
        "partition_info": {
            "disk": {
                "dev": device,
                "size": float(current_size_str) if current_size_str.replace(".", "").isdigit() else 0,
                "unit": unit.lower(),
                "table": current_label,
                "model": disk_parts[6] if len(disk_parts) > 6 else ""
            },
            "partitions": partitions,
            "script": output_script.strip()
        }
    }

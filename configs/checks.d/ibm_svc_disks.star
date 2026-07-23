def _parse_disks(string_table):
    dflt_header = [
        "id",
        "status",
        "error_sequence_number",
        "use",
        "tech_type",
        "capacity",
        "mdisk_id",
        "mdisk_name",
        "member_id",
        "enclosure_id",
        "slot_id",
        "auto_manage",
        "drive_class_id",
    ]
    parsed = []
    for line in string_table:
        if len(line) < 1:
            continue
        if line[0] in ["id", "node_id", "mdisk_id", "enclosure_id"]:
            # header line encountered - use it
            dflt_header = line
        elif line[0] != "command not found":
            # skip header row entries and "command not found"
            row = dict(zip(dflt_header[1:], line[1:]))
            parsed.append(row)
    return parsed


def _render_disksize(bytes_val):
    # Simplified disksize rendering (GB/TB/EB)
    if bytes_val >= 1024 * 1024 * 1024 * 1024 * 1024 * 1024:
        return "%f EB" % (bytes_val / (1024.0 * 1024.0 * 1024.0 * 1024.0 * 1024.0 * 1024.0))
    elif bytes_val >= 1024 * 1024 * 1024 * 1024 * 1024:
        return "%f PB" % (bytes_val / (1024.0 * 1024.0 * 1024.0 * 1024.0 * 1024.0))
    elif bytes_val >= 1024 * 1024 * 1024 * 1024:
        return "%f TB" % (bytes_val / (1024.0 * 1024.0 * 1024.0 * 1024.0))
    else:
        return "%f GB" % (bytes_val / (1024.0 * 1024.0 * 1024.0))


def _render_percent(val):
    return "%f%%" % val


def _check_filer_disks(disks, params):
    disks_in_state = {"prefailed": [], "failed": [], "offline": [], "spare": []}
    total_capacity = 0.0

    for disk in disks:
        total_capacity += float(disk.get("capacity", 0.0))
        state = disk.get("state", "")
        if state in disks_in_state:
            disks_in_state[state].append(disk)

    # Build metrics and results
    results = []
    metrics = {"total_disk_capacity": total_capacity, "total_disks": len(disks), "failed_disks": 0}

    # Total raw capacity
    results.append("Total raw capacity: %s" % _render_disksize(total_capacity))

    # Total disks (excluding unavailable)
    unavail_disks = len(disks_in_state["prefailed"]) + len(disks_in_state["failed"]) + len(disks_in_state["offline"])
    results.append("Total disks: %d" % (len(disks) - unavail_disks))

    # Spare disks with levels
    spare_disks = len(disks_in_state["spare"])
    spare_levels = params.get("number_of_spare_disks")
    if spare_levels != None:
        warn, crit = spare_levels
        if spare_disks <= crit:
            state = "CRIT"
        elif spare_disks <= warn:
            state = "WARN"
        else:
            state = "OK"
        results.append("Spare disks: %d" % spare_disks)
        metrics["spare_disks"] = spare_disks

    # Parity disks
    parity_disks = [d for d in disks if d.get("type") == "parity"]
    prefailed_parity = [d for d in parity_disks if d.get("state") == "prefailed"]
    if parity_disks:
        info_text = "%d parity disks" % len(parity_disks)
        if prefailed_parity:
            info_text += " (%d prefailed)" % len(prefailed_parity)
        results.append(info_text)

    # Failed disks
    failed_count = unavail_disks
    results.append("Failed disks: %d" % failed_count)
    metrics["failed_disks"] = failed_count

    # Data/parity disk details
    for name, disk_type in [("Data", "data"), ("Parity", "parity")]:
        total_type_disks = [d for d in disks if d.get("type") == disk_type]
        prefailed_disks = [d for d in total_type_disks if d.get("state") == "prefailed"]
        if total_type_disks:
            info_text = "%d %s disks" % (len(total_type_disks), name.lower())
            if prefailed_disks:
                info_text += " (%d prefailed)" % len(prefailed_disks)
            results.append(info_text)
            if prefailed_disks:
                identifiers = [str(d.get("identifier", "")) for d in prefailed_disks]
                results.append("%s Disk Details: %s" % (name, " / ".join(identifiers)))

    # Ratio checks for failed/offline disks
    for disk_state, ratio_levels in [("failed", params["failed_spare_ratio"]), ("offline", params["offline_spare_ratio"])]:
        info_texts = [str(d.get("identifier", "")) for d in disks_in_state[disk_state]]
        if info_texts:
            results.append("%s Disk Details: %s" % (disk_state.capitalize(), " / ".join(info_texts)))
            total_with_spare = len(disks_in_state[disk_state]) + len(disks_in_state["spare"])
            ratio = 0.0
            if total_with_spare > 0:
                ratio = float(len(disks_in_state[disk_state])) / total_with_spare * 100.0
            warn_ratio, crit_ratio = ratio_levels
            if ratio >= crit_ratio:
                results.append("Too many %s disks: %s" % (disk_state, _render_percent(ratio)))
            elif ratio >= warn_ratio:
                results.append("Too many %s disks: %s" % (disk_state, _render_percent(ratio)))
            # We only report notice-only metrics in Checkmk, but for Starlark return we just include them as-is
            metrics["%s_ratio" % disk_state] = ratio

    return results, metrics


def main(ctx, params):
    # Attempt to read local SVC data via lsdisk command
    res = ctx.run(["lsdisk", "-auth", "-noheadings", "-sep", ":"], mutates=False)
    if res.rc != 0:
        # If lsdisk fails, try alternative: svcstat -auth -noheadings lsdisk
        res2 = ctx.run(["svcstat", "-auth", "-noheadings", "lsdisk", "-sep", ":"], mutates=False)
        if res2.rc != 0:
            return {"changed": False, "msg": "unable to retrieve disk data (lsdisk/svcstat failed)",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        res = res2

    # Parse agent section
    raw_table = []
    for line in res.stdout.splitlines():
        # Handle the case where output may have trailing colons (empty fields)
        fields = line.rstrip(":").split(":")
        # Filter empty fields caused by trailing colons
        fields = [f if f != "" else "" for f in fields]
        raw_table.append(fields)

    # Parse into structured section
    section = _parse_disks(raw_table)

    # Discovery mode: yield a single service (check is always "Disk Summary")
    if params.get("_discover"):
        return {"changed": False, "msg": "discovered 1 service",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": ["total_disk_capacity", "total_disks", "spare_disks", "failed_disks"]}]}}
    
    # Check mode: process item "" (only one service)
    item = params.get("item", "")
    if item != "":
        return {"changed": False, "msg": "only one service exists ('Disk Summary')",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Prepare disk list with identifier and capacity
    disks = []
    for data in section:
        status = data.get("status", "")
        use = data.get("use", "")
        capacity_str = data.get("capacity", "")

        disk = {}
        disk["identifier"] = "Enclosure: %s, Slot: %s, Type: %s" % (
            data.get("enclosure_id", ""),
            data.get("slot_id", ""),
            data.get("tech_type", "")
        )

        # Parse capacity to bytes
        capacity = 0.0
        cap_str = capacity_str.strip()
        if cap_str.endswith("GB"):
            capacity = float(cap_str[:-2]) * 1024 * 1024 * 1024
        elif cap_str.endswith("TB"):
            capacity = float(cap_str[:-2]) * 1024 * 1024 * 1024 * 1024
        elif cap_str.endswith("PB"):
            capacity = float(cap_str[:-2]) * 1024 * 1024 * 1024 * 1024 * 1024
        disk["capacity"] = capacity

        # Determine state from use and status
        state = use
        if status == "offline" and use != "failed":
            state = "offline"
        disk["state"] = state
        disk["type"] = ""  # Type not available for SVC disks

        disks.append(disk)

    # Extract params with Checkmk defaults
    failed_spare_ratio = params.get("failed_spare_ratio", (1.0, 50.0))
    offline_spare_ratio = params.get("offline_spare_ratio", (1.0, 50.0))
    number_of_spare_disks = params.get("number_of_spare_disks", None)

    # Build params dict for _check_filer_disks
    check_params = {
        "failed_spare_ratio": failed_spare_ratio,
        "offline_spare_ratio": offline_spare_ratio,
        "number_of_spare_disks": number_of_spare_disks,
    }

    # Run the check logic
    results, metrics = _check_filer_disks(disks, check_params)

    # Determine worst state
    state = "OK"
    for line in results:
        if "CRIT" in line or "failed" in line.lower():
            # Use simple heuristic: if any ratio exceeded CRIT, mark CRIT
            if "Too many failed disks" in line or "Too many offline disks" in line:
                if "%" in line:
                    idx = line.find("%")
                    if idx > 0 and idx < len(line):
                        # Extract digits before %
                        val_str = line[idx-2:idx]
                        if val_str.isdigit():
                            val = float(val_str)
                            if val >= failed_spare_ratio[1] or val >= offline_spare_ratio[1]:
                                state = "CRIT"
                                break

    # Check metrics for ratio levels to determine worst state
    if "failed_ratio" in metrics:
        if metrics["failed_ratio"] >= failed_spare_ratio[1]:
            state = "CRIT"
        elif metrics["failed_ratio"] >= failed_spare_ratio[0] and state != "CRIT":
            state = "WARN"
    if "offline_ratio" in metrics:
        if metrics["offline_ratio"] >= offline_spare_ratio[1]:
            state = "CRIT"
        elif metrics["offline_ratio"] >= offline_spare_ratio[0] and state != "CRIT":
            state = "WARN"

    return {
        "changed": False,
        "msg": results[0] if results else "No data",
        "data": {
            "state": state,
            "metrics": metrics,
            "details": " / ".join(results[1:]) if results else "",
        },
    }
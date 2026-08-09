def _render_disksize(bytes_val):
    if bytes_val >= 1024 * 1024 * 1024 * 1024 * 1024:
        return "%f EB" % (bytes_val / (1024 * 1024 * 1024 * 1024 * 1024))
    if bytes_val >= 1024 * 1024 * 1024 * 1024:
        return "%f PB" % (bytes_val / (1024 * 1024 * 1024 * 1024))
    if bytes_val >= 1024 * 1024 * 1024:
        return "%f TB" % (bytes_val / (1024 * 1024 * 1024))
    if bytes_val >= 1024 * 1024:
        return "%f GB" % (bytes_val / (1024 * 1024))
    return "%f MB" % (bytes_val / 1024)


def _is_numeric(s):
    if s == None or s == "":
        return False
    body = str(s).strip()
    if body == "":
        return False
    if body.startswith("-"):
        body = body[1:]
    elif body.startswith("+"):
        body = body[1:]
    if body.find(".") == -1:
        return body.isdigit()
    parts = body.split(".")
    if len(parts) == 2:
        return (parts[0] == "" or parts[0].isdigit()) and (parts[1] == "" or parts[1].isdigit())
    return False


def _safe_float(s):
    if s == None or s == "":
        return 0.0
    body = str(s).strip()
    if body == "":
        return 0.0
    sign = 1.0
    if body.startswith("-"):
        sign = -1.0
        body = body[1:]
    elif body.startswith("+"):
        body = body[1:]
    if body.find(".") == -1:
        if body.isdigit():
            return sign * float(int(body))
        return 0.0
    parts = body.split(".")
    if len(parts) == 2:
        left_ok = parts[0] == "" or parts[0].isdigit()
        right_ok = parts[1] == "" or parts[1].isdigit()
        if left_ok and right_ok:
            left = int(parts[0]) if parts[0] != "" else 0
            right_str = parts[1]
            right = 0.0
            if right_str != "":
                divisor = 10
                for i in range(1, len(right_str)):
                    divisor = divisor * 10
                right = int(right_str) / divisor
            return sign * (float(left) + right)
    return 0.0


def _parse_capacity_str(capacity):
    cap = capacity.strip()
    if cap.endswith("GB"):
        num = cap[:-2]
        return _safe_float(num) * 1024 * 1024 * 1024
    if cap.endswith("TB"):
        num = cap[:-2]
        return _safe_float(num) * 1024 * 1024 * 1024 * 1024
    if cap.endswith("PB"):
        num = cap[:-2]
        return _safe_float(num) * 1024 * 1024 * 1024 * 1024 * 1024
    if cap.endswith("MB"):
        num = cap[:-2]
        return _safe_float(num) * 1024 * 1024
    return 0.0


def _is_capacity_str(s):
    if s == None or s == "":
        return False
    body = str(s).strip()
    return body.endswith("GB") or body.endswith("TB") or body.endswith("PB") or body.endswith("MB")


def _grade_level(value, levels, direction="upper"):
    if levels == None:
        return "OK"
    if type(levels) != "list":
        return "OK"
    if len(levels) < 2:
        return "OK"
    warn = levels[0]
    crit = levels[1]
    if direction == "upper":
        if value >= crit:
            return "CRIT"
        if value >= warn:
            return "WARN"
    else:
        if value <= crit:
            return "CRIT"
        if value <= warn:
            return "WARN"
    return "OK"


def _probe_svc_availability(ctx, host, community):
    test_res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv",
        host, ".1.3.6.1.2.1.1.1.0"
    ], mutates=False)
    if test_res.rc == 127:
        return (False, "not installed: snmpget")
    if test_res.rc != 0:
        return (False, "no IBM SVC found at " + host)
    sys_descr = test_res.stdout.strip().lower()
    if sys_descr.find("ibm") < 0 and sys_descr.find("svc") < 0:
        return (False, "host does not appear to be an IBM SVC")
    return (True, "")


def _fetch_disk_table(ctx, host, community):
    disk_table_base = ".1.3.6.1.4.1.2.6.191.1.4.2.1"
    columns = [
        (disk_table_base + ".3", "status"),
        (disk_table_base + ".4", "use"),
        (disk_table_base + ".5", "capacity"),
        (disk_table_base + ".11", "mdisk_name"),
        (disk_table_base + ".7", "member_id"),
        (disk_table_base + ".8", "enclosure_id"),
        (disk_table_base + ".9", "slot_id"),
        (disk_table_base + ".10", "tech_type"),
    ]
    rows = {}
    for col_oid, col_name in columns:
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community,
            "-Oqn", host, col_oid
        ], mutates=False)
        if res.rc == 127:
            return None
        if res.rc != 0:
            return None
        if res.stdout == "":
            continue
        for line in res.stdout.splitlines():
            space_idx = line.find(" ")
            if space_idx < 0:
                continue
            oid_part = line[:space_idx]
            value_part = line[space_idx + 1:]
            idx = oid_part[len(col_oid) + 1:]
            if idx not in rows:
                rows[idx] = {}
            rows[idx][col_name] = value_part
    disks = []
    for idx in sorted(rows.keys()):
        disks.append(rows[idx])
    return disks


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    if params.get("_discover"):
        avail, msg = _probe_svc_availability(ctx, host, community)
        if not avail:
            return {
                "changed": False,
                "msg": msg,
                "data": {"discovery": [], "host_labels": {}}
            }
        disks = _fetch_disk_table(ctx, host, community)
        if disks == None:
            return {
                "changed": False,
                "msg": "failed to query IBM SVC disk table at " + host,
                "data": {"discovery": [], "host_labels": {}}
            }
        if len(disks) == 0:
            return {
                "changed": False,
                "msg": "no disks discovered on IBM SVC at " + host,
                "data": {
                    "discovery": [],
                    "host_labels": {"cmk/ibm_svc": "true"}
                }
            }
        return {
            "changed": False,
            "msg": "discovered IBM SVC disk summary (" + str(len(disks)) + " disks)",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {
                            "failed_spare_ratio": (1.0, 50.0),
                            "offline_spare_ratio": (1.0, 50.0),
                            "number_of_spare_disks": None,
                        },
                        "metrics": [
                            "total_disk_capacity",
                            "total_disks",
                            "spare_disks",
                            "failed_disks",
                        ],
                    }
                ],
                "host_labels": {"cmk/ibm_svc": "true"},
            }
        }
    
    avail, msg = _probe_svc_availability(ctx, host, community)
    if not avail:
        return {
            "changed": False,
            "msg": "IBM SVC not available: " + msg,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": msg,
            }
        }
    
    disks = _fetch_disk_table(ctx, host, community)
    if disks == None:
        return {
            "changed": False,
            "msg": "failed to query IBM SVC at " + host,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "SNMP query to " + host + " failed",
            }
        }
    
    if len(disks) == 0:
        return {
            "changed": False,
            "msg": "no disks found on IBM SVC",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "No disk entries returned from IBM SVC SNMP query",
            }
        }
    
    parsed_disks = []
    for data in disks:
        status = data.get("status", "")
        use = data.get("use", "")
        capacity_str = data.get("capacity", "0")
        disk = {}
        disk["identifier"] = (
            "Enclosure: " + str(data.get("enclosure_id", "")) +
            ", Slot: " + str(data.get("slot_id", "")) +
            ", Type: " + str(data.get("tech_type", ""))
        )
        if _is_capacity_str(capacity_str):
            disk["capacity"] = _parse_capacity_str(capacity_str)
        else:
            cap_val = _safe_float(capacity_str)
            disk["capacity"] = cap_val * 1024 * 1024 * 1024
        if status == "offline" and use != "failed":
            disk["state"] = "offline"
        else:
            disk["state"] = use
        disk["type"] = ""
        parsed_disks.append(disk)
    
    disks_in_state = {
        "prefailed": [],
        "failed": [],
        "offline": [],
        "spare": [],
    }
    total_capacity = 0.0
    for disk in parsed_disks:
        total_capacity += float(disk.get("capacity", 0))
        state_val = disk["state"]
        for what in disks_in_state:
            if state_val == what:
                disks_in_state[what].append(disk)
    
    metrics = {}
    metrics["total_disk_capacity"] = int(total_capacity)
    metrics["total_disks"] = len(parsed_disks)
    
    unavail_disks = (
        len(disks_in_state["prefailed"])
        + len(disks_in_state["failed"])
        + len(disks_in_state["offline"])
    )
    metrics["failed_disks"] = unavail_disks
    
    spare_disks = len(disks_in_state["spare"])
    metrics["spare_disks"] = spare_disks
    
    worst_state = "OK"
    
    failed_spare_ratio = params.get("failed_spare_ratio", (1.0, 50.0))
    offline_spare_ratio = params.get("offline_spare_ratio", (1.0, 50.0))
    number_of_spare_disks = params.get("number_of_spare_disks")
    
    if number_of_spare_disks != None:
        spare_state = _grade_level(spare_disks, number_of_spare_disks, "lower")
        if spare_state == "CRIT":
            worst_state = "CRIT"
        elif spare_state == "WARN" and worst_state == "OK":
            worst_state = "WARN"
    
    summary_parts = []
    summary_parts.append("Total raw capacity: " + _render_disksize(total_capacity))
    summary_parts.append("Total disks: " + str(len(parsed_disks) - unavail_disks))
    summary_parts.append("Failed disks: " + str(unavail_disks))
    
    details_lines = []
    details_lines.append("Total raw capacity: " + _render_disksize(total_capacity))
    details_lines.append("Total disks: " + str(len(parsed_disks)))
    
    parity_disks = [d for d in parsed_disks if d["type"] == "parity"]
    if len(parity_disks) > 0:
        prefailed_parity = [d for d in parity_disks if d["state"] == "prefailed"]
        details_lines.append("Parity disks: " + str(len(parity_disks)) + " (" + str(len(prefailed_parity)) + " prefailed)")
    
    for disk_state, ratio_levels in [
        ("failed", failed_spare_ratio),
        ("offline", offline_spare_ratio),
    ]:
        if len(disks_in_state[disk_state]) > 0:
            count = len(disks_in_state[disk_state])
            denom = count + len(disks_in_state["spare"])
            if denom > 0:
                ratio = float(count) / float(denom) * 100
                state_label = _grade_level(ratio, ratio_levels, "upper")
                details_lines.append(
                    disk_state.capitalize() + " disks: " + str(count) +
                    " (" + str(len(disks_in_state["spare"])) + " spares) - ratio: " +
                    "%f%%" % ratio + " [" + state_label + "]"
                )
    
    for name, disk_type in [("Data", "data"), ("Parity", "parity")]:
        total_type_disks = [d for d in parsed_disks if d["type"] == disk_type]
        prefailed_disks = [d for d in total_type_disks if d["state"] == "prefailed"]
        if len(total_type_disks) > 0:
            info_text = str(len(total_type_disks)) + " disks"
            if len(prefailed_disks) > 0:
                info_text += " (" + str(len(prefailed_disks)) + " prefailed)"
            details_lines.append(name + " Disk Details: " + info_text)
            if len(prefailed_disks) > 0:
                identifiers = []
                for d in prefailed_disks:
                    identifiers.append(str(d["identifier"]))
                details_lines.append(name + " Disk Details: " + " / ".join(identifiers))
    
    summary = ", ".join(summary_parts)
    details = "\n".join(details_lines)
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": worst_state,
            "metrics": metrics,
            "details": details,
        }
    }
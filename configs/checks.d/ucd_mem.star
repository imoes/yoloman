UCD_MEM_BASE = ".1.3.6.1.4.1.2021.4"
UCD_MEM_OIDS = [
    "5",  # memTotalReal
    "6",  # memAvailReal
    "3",  # memTotalSwap
    "4",  # memAvailSwap
    "11",  # MemTotalFree
    "12",  # memMinimumSwap
    "13",  # memShared
    "14",  # memBuffer
    "15",  # memCached
    "100",  # memSwapError
    "2",  # memErrorName
    "101",  # smemSwapErrorMsg
]

def _info_str_to_bytes(s):
    s = s.strip()
    if s.endswith("kB"):
        s = s[:-2].strip()
    if s == "" or not (s.isdigit() or (s.startswith("-") and s[1:].isdigit())):
        return None
    if s.startswith("-"):
        return -int(s[1:]) * 1024
    return int(s) * 1024

def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {
                            "levels_ram": ("perc_used", (80.0, 90.0)),
                            "levels_swap": None,
                            "levels_virtual": None,
                            "swap_errors": 0
                        },
                        "metrics": [
                            "mem_used",
                            "mem_used_percent",
                            "swap_used",
                            "swap_used_percent",
                            "total_used",
                            "total_used_percent"
                        ]
                    }
                ]
            }
        }

    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    oid_list = ",".join([UCD_MEM_BASE + "." + oid for oid in UCD_MEM_OIDS])
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, oid_list], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "SNMP error"
            }
        }

    lines = res.stdout.splitlines() if res.stdout else []
    oid_values = []
    for line in lines:
        parts = line.split(" = ", 1)
        if len(parts) == 2:
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            suffix_parts = oid_part.rsplit(".", 1)
            if len(suffix_parts) == 2 and suffix_parts[1].isdigit():
                oid_values.append((suffix_parts[0], suffix_parts[1], value_part))

    value_map = {}
    for base_oid, suffix, value in oid_values:
        if base_oid == UCD_MEM_BASE:
            value_map[suffix] = value

    mem_total_str = value_map.get("5", "")
    mem_avail_str = value_map.get("6", "")
    swap_total_str = value_map.get("3", "")
    swap_avail_str = value_map.get("4", "")
    mem_total_free_str = value_map.get("11", "")
    swap_minimum_str = value_map.get("12", "")
    mem_shared_str = value_map.get("13", "")
    mem_buffer_str = value_map.get("14", "")
    mem_cached_str = value_map.get("15", "")
    swap_error_str = value_map.get("100", "")
    error_name_str = value_map.get("2", "")
    swap_error_msg_str = value_map.get("101", "")

    mem_total = _info_str_to_bytes(mem_total_str)
    mem_avail = _info_str_to_bytes(mem_avail_str)
    
    swap_total = _info_str_to_bytes(swap_total_str) if swap_total_str else None
    swap_free = _info_str_to_bytes(swap_avail_str) if swap_avail_str else None

    if mem_total == None or mem_avail == None:
        return {
            "changed": False,
            "msg": "Invalid memory data",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Could not parse memory values"
            }
        }

    mem_used = mem_total - mem_avail
    mem_total_free = _info_str_to_bytes(mem_total_free_str) if mem_total_free_str else None
    swap_minimum = _info_str_to_bytes(swap_minimum_str) if swap_minimum_str else None
    mem_shared = _info_str_to_bytes(mem_shared_str) if mem_shared_str else None
    mem_buffer = _info_str_to_bytes(mem_buffer_str) if mem_buffer_str else None
    mem_cached = _info_str_to_bytes(mem_cached_str) if mem_cached_str else None

    if mem_buffer != None:
        mem_used -= mem_buffer
    if mem_cached != None:
        mem_used -= mem_cached

    swap_used = None
    if swap_total != None and swap_free != None:
        swap_used = swap_total - swap_free

    total_total = None
    total_used = None
    if swap_total != None:
        total_total = mem_total + swap_total
        if swap_used != None:
            total_used = mem_used - swap_used

    swap_error = 0
    if swap_error_str.isdigit() or (swap_error_str.startswith("-") and swap_error_str[1:].isdigit()):
        swap_error = int(swap_error_str)

    error_name = error_name_str.strip()
    swap_error_msg = swap_error_msg_str.strip()

    levels_ram = params.get("levels_ram") or params.get("levels", ("perc_used", (80.0, 90.0)))
    levels_swap = params.get("levels_swap")
    levels_virtual = params.get("levels_virtual")
    swap_errors_state = int(params.get("swap_errors", 0))

    state = "OK"
    details_parts = []

    if error_name and error_name != "swap":
        state = "WARN"
        details_parts.append("Error: " + error_name)

    mem_used_percent = (float(mem_used) / float(mem_total) * 100.0) if mem_total > 0 else 0.0

    if levels_ram:
        level_type = levels_ram[0]
        level_values = levels_ram[1] if len(levels_ram) > 1 else (80.0, 90.0)
        if level_type == "perc_used":
            warn = level_values[0]
            crit = level_values[1]
            if mem_used_percent >= crit:
                state = "CRIT"
                details_parts.append("RAM CRIT: %f%% used (warning at %f%%, critical at %f%%)" % (mem_used_percent, warn, crit))
            elif mem_used_percent >= warn:
                if state == "OK":
                    state = "WARN"
                details_parts.append("RAM WARN: %f%% used (warning at %f%%)" % (mem_used_percent, warn))
            else:
                details_parts.append("RAM: %f%% used" % mem_used_percent)

    if swap_total and swap_used != None:
        swap_used_percent = (float(swap_used) / float(swap_total) * 100.0) if swap_total > 0 else 0.0

        if levels_swap:
            level_type = levels_swap[0]
            level_values = levels_swap[1] if len(levels_swap) > 1 else (80.0, 90.0)
            if level_type == "perc_used":
                warn = level_values[0]
                crit = level_values[1]
                if swap_used_percent >= crit:
                    state = "CRIT"
                    details_parts.append("Swap CRIT: %f%% used (warning at %f%%, critical at %f%%)" % (swap_used_percent, warn, crit))
                elif swap_used_percent >= warn:
                    if state == "OK":
                        state = "WARN"
                    details_parts.append("Swap WARN: %f%% used (warning at %f%%)" % (swap_used_percent, warn))
                else:
                    details_parts.append("Swap: %f%% used" % swap_used_percent)
        else:
            details_parts.append("Swap: %f%% used" % swap_used_percent)

    if total_total and total_used != None:
        total_used_percent = (float(total_used) / float(total_total) * 100.0) if total_total > 0 else 0.0

        if levels_virtual:
            level_type = levels_virtual[0]
            level_values = levels_virtual[1] if len(levels_virtual) > 1 else (80.0, 90.0)
            if level_type == "perc_used":
                warn = level_values[0]
                crit = level_values[1]
                if total_used_percent >= crit:
                    state = "CRIT"
                    details_parts.append("Total virtual memory CRIT: %f%% used (warning at %f%%, critical at %f%%)" % (total_used_percent, warn, crit))
                elif total_used_percent >= warn:
                    if state == "OK":
                        state = "WARN"
                    details_parts.append("Total virtual memory WARN: %f%% used (warning at %f%%)" % (total_used_percent, warn))
                else:
                    details_parts.append("Total virtual memory: %f%% used" % total_used_percent)
        else:
            details_parts.append("Total virtual memory: %f%% used" % total_used_percent)

    if swap_error != 0 and swap_error_msg:
        state = "WARN" if swap_errors_state == 0 else "CRIT"
        details_parts.append("Swap error: " + swap_error_msg)

    metrics = {
        "mem_used": mem_used,
        "mem_used_percent": mem_used_percent
    }
    if swap_total and swap_used != None:
        metrics["swap_used"] = swap_used
        metrics["swap_used_percent"] = swap_used_percent
    if total_total and total_used != None:
        metrics["total_used"] = total_used
        metrics["total_used_percent"] = total_used_percent

    msg = "; ".join(details_parts) if details_parts else "Memory usage normal"

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }
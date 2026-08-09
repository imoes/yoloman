def _parse_smartctl_output(text):
    """Parse smartctl text output into a structured dict for NVMe."""
    data = {}
    lines = text.split("\n")
    for line in lines:
        parts = line.split(":", 1)
        if len(parts) == 2:
            key = parts[0].strip()
            val = parts[1].strip()
            data[key] = val
    return data

def _parse_smart_log(text):
    """Parse 'smartctl -l smart-log' output for NVMe SMART log fields."""
    result = {}
    lines = text.split("\n")
    current_key = None
    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        if ":" in stripped:
            parts = stripped.split(":", 1)
            key = parts[0].strip()
            val = parts[1].strip()
            result[key] = val
        elif current_key and stripped:
            result[current_key] = result.get(current_key, "") + " " + stripped
    return result

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        # Probe: is smartctl installed?
        probe = ctx.run(["smartctl", "--version"], mutates=False)
        if probe.rc == 127:
            return {"changed": False, "msg": "smartctl not installed", "data": {"discovery": []}}
        if probe.rc != 0:
            return {"changed": False, "msg": "smartctl not available", "data": {"discovery": []}}
        
        # Scan for devices
        scan = ctx.run(["smartctl", "--scan"], mutates=False)
        if scan.rc != 0:
            return {"changed": False, "msg": "no devices found", "data": {"discovery": []}}
        
        discovery = []
        for line in scan.stdout.splitlines():
            if not line.strip():
                continue
            # Format: /dev/nvme0n1 -d nvme # ...
            if "/dev/nvme" not in line:
                continue
            dev = line.split()[0]
            # Verify it's NVMe
            identify = ctx.run(["smartctl", "-i", dev], mutates=False)
            if identify.rc != 0:
                continue
            id_data = _parse_smartctl_output(identify.stdout)
            dev_name = id_data.get("Device Model", "") or id_data.get("Device", "") or dev
            model = id_data.get("Model Family", "")
            if not model:
                model = id_data.get("Model Family", "")
            serial = id_data.get("Serial Number", "")
            
            # Check if NVMe health log is available
            health = ctx.run(["smartctl", "-H", dev], mutates=False)
            if health.rc != 0:
                continue
            
            # Verify NVMe
            if "NVMe" not in health.stdout and "nvme" not in health.stdout.lower():
                continue
            
            labels = {
                "cmk/smart/type": "NVMe",
                "cmk/smart/device": dev,
            }
            if model:
                labels["cmk/smart/model"] = model
            if serial:
                labels["cmk/smart/serial"] = serial
            
            # Stats service
            discovery.append({
                "item": "smart_stats_" + dev,
                "params": {
                    "levels_critical_warning": ("discovered_value", None),
                    "levels_media_errors": ("discovered_value", None),
                    "levels_available_spare": ("threshold", None),
                    "levels_spare_percentage_used": ("no_levels", None),
                    "levels_error_information_log_entries": ("no_levels", None),
                    "levels_data_units_read": ("no_levels", None),
                    "levels_data_units_written": ("no_levels", None),
                },
                "metrics": [
                    "uptime", "harddrive_power_cycles", "nvme_critical_warning",
                    "nvme_media_and_data_integrity_errors", "nvme_available_spare",
                    "nvme_spare_percentage_used", "nvme_error_information_log_entries",
                    "nvme_data_units_read", "nvme_data_units_written",
                ],
                "service_labels": labels,
            })
            
            # Temperature service
            discovery.append({
                "item": "smart_temp_" + dev,
                "params": {"levels": (35.0, 40.0)},
                "metrics": ["temperature"],
                "service_labels": labels,
            })
        
        return {
            "changed": False,
            "msg": "discovered %d NVMe smart services" % len(discovery),
            "data": {"discovery": discovery},
        }
    
    # Check mode
    item = params.get("item", "")
    check_type = params.get("check_type", "")
    warn = params.get("warn", 35.0)
    crit = params.get("crit", 40.0)
    
    # Probe smartctl
    probe = ctx.run(["smartctl", "--version"], mutates=False)
    if probe.rc == 127:
        return {
            "changed": False,
            "msg": "smartctl not installed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Parse the device from item
    # item is like "smart_stats_/dev/nvme0n1" or "smart_temp_/dev/nvme0n1"
    dev = ""
    is_temp = False
    is_stats = False
    if item.startswith("smart_temp_"):
        is_temp = True
        dev = item[len("smart_temp_"):]
    elif item.startswith("smart_stats_"):
        is_stats = True
        dev = item[len("smart_stats_"):]
    else:
        dev = item
    
    if not dev:
        return {
            "changed": False,
            "msg": "no device specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Gather NVMe health data
    # For NVMe, we use smartctl -a (which gives us the full info including temp)
    # and smartctl -l smart-log (for the extended stats)
    smart_out = ctx.run(["smartctl", "-a", dev], mutates=False)
    if smart_out.rc != 0:
        return {
            "changed": False,
            "msg": "cannot read SMART data for %s" % dev,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    output = smart_out.stdout.lower()
    
    # Parse temperature
    temp_val = None
    for line in smart_out.stdout.splitlines():
        if "temperature:" in line.lower():
            # Look for temperature line
            parts = line.split(":")
            for part in parts:
                part = part.strip()
                # Remove unit suffix
                num_str = part.replace("C", "").replace("celsius", "").strip()
                if num_str.isdigit():
                    temp_val = int(num_str)
                    break
            if temp_val != None:
                break
        elif "temperature" in line.lower() and ":" in line:
            # Alternative format
            idx = line.lower().find("temperature")
            rest = line[idx:]
            if ":" in rest:
                val_part = rest.split(":")[1].strip()
                num_str = val_part.replace("C", "").strip()
                if num_str and num_str.split()[0].replace("C", "").strip().isdigit():
                    temp_val = int(num_str.split()[0].replace("C", "").strip())
    
    # Parse power on hours
    power_on_hours = None
    for line in smart_out.stdout.splitlines():
        lower_line = line.lower()
        if "power_on_hours" in lower_line or "power on hours" in lower_line:
            parts = line.split(":")
            if len(parts) >= 2:
                val = parts[1].strip().split()[0]
                if val.isdigit():
                    power_on_hours = int(val)
                    break
    
    # Parse power cycles
    power_cycles = None
    for line in smart_out.stdout.splitlines():
        lower_line = line.lower()
        if "power_cycle_count" in lower_line or "power cycles" in lower_line:
            parts = line.split(":")
            if len(parts) >= 2:
                val = parts[1].strip().split()[0]
                if val.isdigit():
                    power_cycles = int(val)
                    break
    
    if is_temp:
        if temp_val == None:
            return {
                "changed": False,
                "msg": "no temperature reading available for %s" % dev,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        
        state = "CRIT" if temp_val >= crit else ("WARN" if temp_val >= warn else "OK")
        metrics = {"temperature": temp_val}
        msg = "%s temperature: %d C" % (dev, temp_val)
        return {
            "changed": False,
            "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": smart_out.stdout},
        }
    
    if is_stats or check_type == "stats":
        metrics = {}
        details_lines = []
        max_state = 0  # 0=OK, 1=WARN, 2=CRIT
        
        # Power on time (uptime)
        if power_on_hours != None:
            uptime_seconds = power_on_hours * 3600
            metrics["uptime"] = uptime_seconds
            details_lines.append("Powered on: %d hours" % power_on_hours)
        
        # Power cycles
        if power_cycles != None:
            metrics["harddrive_power_cycles"] = float(power_cycles)
            details_lines.append("Power cycles: %d" % power_cycles)
        
        # Parse critical warning
        critical_warning = None
        for line in smart_out.stdout.splitlines():
            lower_line = line.lower()
            if "critical_warning" in lower_line:
                parts = line.split(":")
                if len(parts) >= 2:
                    val = parts[1].strip().split()[0]
                    if val.isdigit():
                        critical_warning = int(val)
                        break
        
        if critical_warning != None:
            metrics["nvme_critical_warning"] = float(critical_warning)
            # Check against discovered or levels
            crit_w_levels = params.get("levels_critical_warning", ("discovered_value", None))
            level_type = crit_w_levels[0]
            level_data = crit_w_levels[1]
            
            if level_type == "discovered_value":
                discovered = params.get("critical_warning", None)
                if discovered != None and critical_warning > discovered:
                    max_state = max(max_state, 2)
                    details_lines.append("Critical warning: %d (discovered: %d) (!!)" % (critical_warning, discovered))
                else:
                    details_lines.append("Critical warning: %d" % critical_warning)
            elif level_type == "levels_upper" and level_data != None:
                warn_val = level_data[0]
                crit_val = level_data[1]
                if critical_warning >= crit_val:
                    max_state = max(max_state, 2)
                elif critical_warning >= warn_val:
                    max_state = max(max_state, 1)
                details_lines.append("Critical warning: %d" % critical_warning)
        
        # Parse media errors
        media_errors = None
        for line in smart_out.stdout.splitlines():
            lower_line = line.lower()
            if "media_errors" in lower_line:
                parts = line.split(":")
                if len(parts) >= 2:
                    val = parts[1].strip().split()[0]
                    if val.isdigit():
                        media_errors = int(val)
                        break
        
        if media_errors != None:
            metrics["nvme_media_and_data_integrity_errors"] = float(media_errors)
            med_levels = params.get("levels_media_errors", ("discovered_value", None))
            level_type = med_levels[0]
            level_data = med_levels[1]
            
            if level_type == "discovered_value":
                discovered = params.get("media_errors", None)
                if discovered != None and media_errors > discovered:
                    max_state = max(max_state, 2)
                    details_lines.append("Media errors: %d (discovered: %d) (!!)" % (media_errors, discovered))
                else:
                    details_lines.append("Media errors: %d" % media_errors)
            elif level_type == "levels_upper" and level_data != None:
                warn_val = level_data[0]
                crit_val = level_data[1]
                if media_errors >= crit_val:
                    max_state = max(max_state, 2)
                elif media_errors >= warn_val:
                    max_state = max(max_state, 1)
                details_lines.append("Media errors: %d" % media_errors)
        
        # Parse available spare
        available_spare = None
        available_spare_threshold = None
        for line in smart_out.stdout.splitlines():
            lower_line = line.lower()
            if "available_spare" in lower_line and "threshold" not in lower_line:
                parts = line.split(":")
                if len(parts) >= 2:
                    val = parts[1].strip().split()[0]
                    num_str = val.replace("%", "")
                    if num_str and (num_str.replace(".", "").isdigit()):
                        available_spare = int(num_str)
                        break
            elif "available_spare" in lower_line and "threshold" in lower_line:
                parts = line.split(":")
                if len(parts) >= 2:
                    val = parts[1].strip().split()[0]
                    num_str = val.replace("%", "")
                    if num_str and (num_str.replace(".", "").isdigit()):
                        available_spare_threshold = int(num_str)
                        break
        
        if available_spare != None:
            metrics["nvme_available_spare"] = float(available_spare)
            spare_param = params.get("levels_available_spare", ("threshold", None))
            level_data = spare_param[1]
            
            if level_data == None:
                # Use discovered threshold
                if available_spare_threshold != None:
                    warn_val = available_spare_threshold
                    crit_val = available_spare_threshold
                else:
                    warn_val = 0
                    crit_val = 0
            else:
                parsed = level_data
                if type(parsed) == "list":
                    warn_val = parsed[0]
                    crit_val = parsed[1]
                else:
                    warn_val = parsed
                    crit_val = parsed
            
            if available_spare <= crit_val:
                max_state = max(max_state, 2)
            elif available_spare <= warn_val:
                max_state = max(max_state, 1)
            details_lines.append("Available spare: %s%%" % str(available_spare))
        
        # Parse percentage used
        percentage_used = None
        for line in smart_out.stdout.splitlines():
            lower_line = line.lower()
            if "percentage_used" in lower_line:
                parts = line.split(":")
                if len(parts) >= 2:
                    val = parts[1].strip().split()[0]
                    num_str = val.replace("%", "")
                    if num_str and num_str.isdigit():
                        percentage_used = int(num_str)
                        break
        
        if percentage_used != None:
            metrics["nvme_spare_percentage_used"] = float(percentage_used)
            pct_levels = params.get("levels_spare_percentage_used", ("no_levels", None))
            level_data = pct_levels[1]
            if level_data != None and type(level_data) == "list":
                warn_val = level_data[0]
                crit_val = level_data[1]
                if percentage_used >= crit_val:
                    max_state = max(max_state, 2)
                elif percentage_used >= warn_val:
                    max_state = max(max_state, 1)
            details_lines.append("Percentage used: %d%%" % percentage_used)
        
        # Parse error information log entries
        err_log_entries = None
        for line in smart_out.stdout.splitlines():
            lower_line = line.lower()
            if "error_information_log_entries" in lower_line:
                parts = line.split(":")
                if len(parts) >= 2:
                    val = parts[1].strip().split()[0]
                    if val.isdigit():
                        err_log_entries = int(val)
                        break
        
        if err_log_entries != None:
            metrics["nvme_error_information_log_entries"] = float(err_log_entries)
            err_levels = params.get("levels_error_information_log_entries", ("no_levels", None))
            level_data = err_levels[1]
            if level_data != None and type(level_data) == "list":
                warn_val = level_data[0]
                crit_val = level_data[1]
                if err_log_entries >= crit_val:
                    max_state = max(max_state, 2)
                elif err_log_entries >= warn_val:
                    max_state = max(max_state, 1)
            details_lines.append("Error information log entries: %d" % err_log_entries)
        
        # Parse data units read
        data_units_read = None
        for line in smart_out.stdout.splitlines():
            lower_line = line.lower()
            if "data_units_read" in lower_line:
                parts = line.split(":")
                if len(parts) >= 2:
                    val = parts[1].strip().split()[0]
                    val_clean = val.replace(",", "")
                    if val_clean.isdigit():
                        data_units_read = int(val_clean)
                        break
        
        if data_units_read != None:
            read_bytes = data_units_read * 512000
            metrics["nvme_data_units_read"] = float(read_bytes)
            read_levels = params.get("levels_data_units_read", ("no_levels", None))
            level_data = read_levels[1]
            if level_data != None and type(level_data) == "list":
                warn_val = level_data[0]
                crit_val = level_data[1]
                if read_bytes >= crit_val:
                    max_state = max(max_state, 2)
                elif read_bytes >= warn_val:
                    max_state = max(max_state, 1)
            details_lines.append("Data units read: %d" % data_units_read)
        
        # Parse data units written
        data_units_written = None
        for line in smart_out.stdout.splitlines():
            lower_line = line.lower()
            if "data_units_written" in lower_line:
                parts = line.split(":")
                if len(parts) >= 2:
                    val = parts[1].strip().split()[0]
                    val_clean = val.replace(",", "")
                    if val_clean.isdigit():
                        data_units_written = int(val_clean)
                        break
        
        if data_units_written != None:
            write_bytes = data_units_written * 512000
            metrics["nvme_data_units_written"] = float(write_bytes)
            write_levels = params.get("levels_data_units_written", ("no_levels", None))
            level_data = write_levels[1]
            if level_data != None and type(level_data) == "list":
                warn_val = level_data[0]
                crit_val = level_data[1]
                if write_bytes >= crit_val:
                    max_state = max(max_state, 2)
                elif write_bytes >= warn_val:
                    max_state = max(max_state, 1)
            details_lines.append("Data units written: %d" % data_units_written)
        
        state_str = ["OK", "WARN", "CRIT"][min(max_state, 2)]
        msg = "%s: %s" % (dev, "; ".join(details_lines)) if details_lines else "SMART stats for %s (no data)" % dev
        
        return {
            "changed": False,
            "msg": msg,
            "data": {"state": state_str, "metrics": metrics, "details": smart_out.stdout},
        }
    
    # Default: if item doesn't match known patterns, handle as stats
    # Fallback - treat as stats check
    if power_on_hours == None and power_cycles == None and temp_val == None:
        return {
            "changed": False,
            "msg": "no SMART data could be parsed for %s" % dev,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Default to stats behavior
    metrics = {}
    state_str = "OK"
    msg = "SMART stats for %s" % dev
    
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state_str, "metrics": metrics, "details": smart_out.stdout},
    }
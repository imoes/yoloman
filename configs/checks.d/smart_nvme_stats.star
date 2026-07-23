# ===== translated check module: smart_nvme_stats =====

# Helper to convert seconds to human-readable timespan (Checkmk render.timespan equivalent)
def _format_timespan(seconds):
    seconds = int(seconds)
    if seconds < 60:
        return "%d s" % seconds
    elif seconds < 3600:
        mins = seconds // 60
        secs = seconds % 60
        return "%d m %d s" % (mins, secs) if secs > 0 else "%d m" % mins
    elif seconds < 86400:
        hours = seconds // 3600
        mins = (seconds % 3600) // 60
        return "%d h %d m" % (hours, mins)
    else:
        days = seconds // 86400
        hours = (seconds % 86400) // 3600
        return "%d d %d h" % (days, hours)

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["smartctl", "-a", "-j", "/dev/sda"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "smartctl command failed",
                    "data": {"discovery": []}}
        if not res.stdout:
            return {"changed": False, "msg": "no output from smartctl",
                    "data": {"discovery": []}}
        # Attempt JSON decode with simple guard
        data = json.decode(res.stdout)
        if data == None:
            return {"changed": False, "msg": "could not parse JSON",
                    "data": {"discovery": []}}

        devices = {}
        if type(data) != "dict" or data.get("devices") == None or type(data.get("devices")) != "list":
            return {"changed": False, "msg": "no device data found",
                    "data": {"discovery": []}}

        for dev in data.get("devices"):
            if type(dev) != "dict" or dev.get("smartctl") == None:
                continue
            smart_status = dev.get("smart_status")
            if type(smart_status) != "dict" or not smart_status.get("passed", False):
                continue
            if dev.get("nvme") == None or type(dev.get("nvme")) != "dict":
                continue
            nvme = dev.get("nvme")
            health = nvme.get("smart_health_information_log")
            if type(health) != "dict":
                continue

            serial_number = dev.get("serial_number", "")
            model_number = dev.get("model_number", "")
            device_name = dev.get("device", {}).get("name", "unknown")

            item = model_number
            if item == "":
                item = serial_number
            if item == "":
                item = device_name

            parameters = {
                "critical_warning": health.get("critical_warning", 0),
                "media_errors": health.get("media_errors", 0),
            }

            devices[item] = {"item": item, "parameters": parameters,
                             "labels": {
                                 "cmk/smart/type": "NVMe",
                                 "cmk/smart/device": device_name,
                                 "cmk/smart/model": model_number,
                                 "cmk/smart/serial": serial_number,
                             },
                             "metrics": ["uptime", "power_cycles", "nvme_critical_warning",
                                         "nvme_media_and_data_integrity_errors",
                                         "nvme_available_spare", "nvme_spare_percentage_used",
                                         "nvme_error_information_log_entries",
                                         "nvme_data_units_read", "nvme_data_units_written"]}

        out = []
        for key in devices:
            d = devices[key]
            out.append({"item": d["item"], "params": d["parameters"], "metrics": d["metrics"]})
        return {"changed": False, "msg": "discovered %d NVMe devices" % len(out),
                "data": {"discovery": out}}

    # ----- check mode -----
    item = params.get("item", "")
    res = ctx.run(["smartctl", "-a", "-j", "/dev/sda"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "smartctl command failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not res.stdout:
        return {"changed": False, "msg": "no output from smartctl",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = json.decode(res.stdout)
    if data == None:
        return {"changed": False, "msg": "could not parse JSON",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if type(data) != "dict" or data.get("devices") == None or type(data.get("devices")) != "list":
        return {"changed": False, "msg": "no device data found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    dev_data = None
    for dev in data.get("devices"):
        if type(dev) != "dict" or dev.get("smartctl") == None:
            continue
        smart_status = dev.get("smart_status")
        if type(smart_status) != "dict" or not smart_status.get("passed", False):
            continue
        if dev.get("nvme") == None or type(dev.get("nvme")) != "dict":
            continue
        nvme = dev.get("nvme")
        health = nvme.get("smart_health_information_log")
        if type(health) != "dict":
            continue

        model_number = dev.get("model_number", "")
        serial_number = dev.get("serial_number", "")
        device_name = dev.get("device", {}).get("name", "unknown")
        check_item = model_number
        if check_item == "":
            check_item = serial_number
        if check_item == "":
            check_item = device_name

        if check_item == item:
            dev_data = {"device": dev, "health": health}
            break

    if dev_data == None:
        return {"changed": False, "msg": "no such NVMe device: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    health = dev_data["health"]
    metrics = {}
    details_parts = []
    state_overall = "OK"

    # 1) uptime (power_on_hours)
    power_on_hours = health.get("power_on_hours", 0)
    uptime_seconds = power_on_hours * 3600
    render_func = _format_timespan
    label = "Powered on"
    metrics["uptime"] = uptime_seconds
    details_parts.append("%s: %s" % (label, render_func(uptime_seconds)))

    # 2) power_cycles
    power_cycles = health.get("power_cycles", 0)
    metrics["harddrive_power_cycles"] = power_cycles
    details_parts.append("Power cycles: %d" % power_cycles)

    # 3) critical_warning
    critical_warning = health.get("critical_warning", 0)
    discovered_value = params.get("critical_warning")
    levels_critical_warning = params.get("levels_critical_warning", ("discovered_value", None))
    if levels_critical_warning[0] == "discovered_value":
        if discovered_value != None and critical_warning > discovered_value:
            state_overall = "CRIT"
            details_parts.append("Critical warning: %d (during discovery: %d) (!!)" % (critical_warning, discovered_value))
        else:
            details_parts.append("Critical warning: %d" % critical_warning)
    else:
        warn, crit = levels_critical_warning[1]
        if critical_warning >= crit:
            state_overall = "CRIT"
        elif critical_warning >= warn:
            state_overall = "WARN"
        details_parts.append("Critical warning: %d" % critical_warning)
    metrics["nvme_critical_warning"] = critical_warning

    # 4) media_errors
    media_errors = health.get("media_errors", 0)
    discovered_media_errors = params.get("media_errors", 0)
    levels_media_errors = params.get("levels_media_errors", ("discovered_value", None))
    if levels_media_errors[0] == "discovered_value":
        if discovered_media_errors != None and media_errors > discovered_media_errors:
            state_overall = "CRIT"
            details_parts.append("Media and data integrity errors: %d (during discovery: %d) (!!)" % (media_errors, discovered_media_errors))
        else:
            details_parts.append("Media and data integrity errors: %d" % media_errors)
    else:
        warn, crit = levels_media_errors[1]
        if media_errors >= crit:
            state_overall = "CRIT"
        elif media_errors >= warn:
            state_overall = "WARN"
        details_parts.append("Media and data integrity errors: %d" % media_errors)
    metrics["nvme_media_and_data_integrity_errors"] = media_errors

    # 5) available_spare
    available_spare = health.get("available_spare", 0)
    available_spare_threshold = health.get("available_spare_threshold", 0)
    levels_available_spare = params.get("levels_available_spare", ("threshold", None))
    if levels_available_spare[0] == "threshold":
        levels_lower = ("fixed", (available_spare_threshold, available_spare_threshold))
    else:
        levels_lower = levels_available_spare[1]
    if levels_lower != None and levels_lower[0] == "fixed":
        warn, crit = levels_lower[1]
        if available_spare <= crit:
            state_overall = "CRIT"
        elif available_spare <= warn:
            state_overall = "WARN"
    details_parts.append("Available spare: %d%%" % available_spare)
    metrics["nvme_available_spare"] = available_spare

    # 6) percentage_used
    percentage_used = health.get("percentage_used", 0)
    levels_spare_percentage_used = params.get("levels_spare_percentage_used", ("no_levels", None))
    if levels_spare_percentage_used[0] == "fixed":
        warn, crit = levels_spare_percentage_used[1]
        if percentage_used >= crit:
            state_overall = "CRIT"
        elif percentage_used >= warn:
            state_overall = "WARN"
    details_parts.append("Percentage used: %d%%" % percentage_used)
    metrics["nvme_spare_percentage_used"] = percentage_used

    # 7) error_information_log_entries
    num_err_log_entries = health.get("num_err_log_entries", 0)
    levels_error_information_log_entries = params.get("levels_error_information_log_entries", ("no_levels", None))
    if levels_error_information_log_entries[0] == "fixed":
        warn, crit = levels_error_information_log_entries[1]
        if num_err_log_entries >= crit:
            state_overall = "CRIT"
        elif num_err_log_entries >= warn:
            state_overall = "WARN"
    details_parts.append("Error information log entries: %d" % num_err_log_entries)
    metrics["nvme_error_information_log_entries"] = num_err_log_entries

    # 8) data_units_read
    data_units_read = health.get("data_units_read", 0)
    data_units_read_bytes = data_units_read * 512000
    metrics["nvme_data_units_read"] = data_units_read_bytes

    # 9) data_units_written
    data_units_written = health.get("data_units_written", 0)
    data_units_written_bytes = data_units_written * 512000
    metrics["nvme_data_units_written"] = data_units_written_bytes

    # Build details
    details = ", ".join(details_parts)
    return {"changed": False,
            "msg": details,
            "data": {"state": state_overall, "metrics": metrics, "details": details}}
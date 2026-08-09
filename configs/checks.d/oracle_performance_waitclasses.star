# Constants for Oracle waitclasses (from constants module)
ORACLE_WAITCLASSES = [
    {"name": "Application", "id": "application"},
    {"name": "Availability", "id": "availability"},
    {"name": "Cluster", "id": "cluster"},
    {"name": "Commit", "id": "commit"},
    {"name": "Concurrency", "id": "concurrency"},
    {"name": "Configuration", "id": "configuration"},
    {"name": "Idle", "id": "idle"},
    {"name": "Network", "id": "network"},
    {"name": "Other", "id": "other"},
    {"name": "Scheduler", "id": "scheduler"},
    {"name": "System I/O", "id": "system_io"},
    {"name": "User I/O", "id": "user_io"},
]

def main(ctx, params):
    # Discovery mode: enumerate all Oracle instances from agent output
    if params.get("_discover"):
        res = ctx.run(["cat", "/proc/oracle_performance"], mutates=False)
        instances = []
        seen = {}
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.split("|")
            if len(parts) < 2:
                continue
            item = parts[0]
            # Skip entries not related to sys_wait_class (index 1 must be "sys_wait_class")
            if parts[1] != "sys_wait_class":
                continue
            # Avoid duplicates
            if item not in seen:
                seen[item] = True
                instances.append({
                    "item": item,
                    "params": {},
                    "metrics": []
                })

        metrics = []
        for wc in ORACLE_WAITCLASSES:
            for suffix in ["waited", "waited_fg"]:
                metrics.append("oracle_wait_class_%s_%s" % (wc["id"], suffix))
        metrics.extend(["oracle_wait_class_total", "oracle_wait_class_total_fg"])

        for inst in instances:
            inst["metrics"] = list(metrics)

        return {"changed": False, "msg": "discovered %d instances" % len(instances),
                "data": {"discovery": instances}}

    # Check mode: process one instance
    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "no item provided",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Read the agent data
    res = ctx.run(["cat", "/proc/oracle_performance"], mutates=False)
    data = {}
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.split("|")
        if len(parts) < 2:
            continue
        inst = parts[0]
        if inst != item:
            continue
        section = parts[1]
        if section == "sys_wait_class":
            if len(parts) < 3:
                continue
            wc_name = parts[2]
            # Collect all waitclass data into a dict keyed by waitclass name
            if "sys_wait_class" not in data:
                data["sys_wait_class"] = {}
            # Parse the remaining fields: [waitclass] + [idle] + [waited] + [waited_fg] + [others]
            # Based on original: index 1 is waited (index in original data array), 3 is waited_fg
            # Original indices: waitdata[1] = waited, waitdata[3] = waited_fg
            # Let's parse the fields after waitclass name
            if len(parts) >= 6:
                val1 = parts[3]
                val2 = parts[4]
                val3 = parts[5]
                # Check if values are numeric (allowing decimal points)
                is_num1 = val1.replace('.', '').replace('-', '').isdigit() if val1 else False
                is_num2 = val2.replace('.', '').replace('-', '').isdigit() if val2 else False
                is_num3 = val3.replace('.', '').replace('-', '').isdigit() if val3 else False
                
                idle = float(val1) if is_num1 else 0.0
                waited = float(val2) if is_num2 else 0.0
                waited_fg = float(val3) if is_num3 else 0.0
                
                # Store as [idle, waited, ???, waited_fg] to match original indices
                data["sys_wait_class"][wc_name] = [idle, waited, 0.0, waited_fg]

    # Check if data is available
    if "sys_wait_class" not in data:
        return {"changed": False, "msg": "no waitclass data for %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Process waitclasses
    total_waited_sum = 0.0
    total_waited_sum_fg = 0.0

    metrics_dict = {}
    infotexts = []

    for wc in ORACLE_WAITCLASSES:
        waitdata = data["sys_wait_class"].get(wc["name"])
        if waitdata == None:
            continue

        waited = waitdata[1] if len(waitdata) > 1 else 0.0
        waited_fg = waitdata[3] if len(waitdata) > 3 else 0.0

        # Rate calculation: we don't have get_rate here, so assume these are cumulative
        # In a real implementation we'd need to track previous values in a file or similar.
        # For this translation, we treat the values as rates directly (approximation)
        rate = waited / 100.0
        rate_fg = waited_fg / 100.0

        metric_start = "oracle_wait_class_%s" % wc["id"]
        for suffix, val, label_suffix in [
            ("waited", rate, "wait class"),
            ("waited_fg", rate_fg, "wait class (FG)")
        ]:
            metric_name = "%s_%s" % (metric_start, suffix)
            metrics_dict[metric_name] = val
            infotexts.append("%s %s: %f/s" % (wc["name"], label_suffix, val))

        total_waited_sum += rate
        total_waited_sum_fg += rate_fg

    # Add totals
    metrics_dict["oracle_wait_class_total"] = total_waited_sum
    metrics_dict["oracle_wait_class_total_fg"] = total_waited_sum_fg

    # Determine state: Checkmk check uses check_levels, which defaults to OK if no thresholds
    state = "OK"

    return {
        "changed": False,
        "msg": "Total waited: %f/s, Total waited (FG): %f/s" % (total_waited_sum, total_waited_sum_fg),
        "data": {
            "state": state,
            "metrics": metrics_dict,
            "details": "; ".join(infotexts) if infotexts else "",
        }
    }
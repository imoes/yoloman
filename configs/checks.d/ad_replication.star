# Checkmk check: checkmk.ad_replication
# Translated to Starlark for the yolo-man agent
# Monitors Active Directory replication status via repadmin /showrepl or samba-tool

def main(ctx, params):
    if params.get("_discover"):
        return discovery(ctx, params)
    return check(ctx, params)

def parse_line(line):
    normalized = line.replace(",CN=", ";CN=").replace(",DC=", ";DC=")
    return normalized.split(",")

def discovery(ctx, params):
    sections = gather_sections(ctx)
    if not sections:
        return {"changed": False, "msg": "No AD replication data available", "data": {"discovery": []}}

    items = []
    seen = []
    for section in sections:
        for line in section["lines"]:
            parts = parse_line(line)
            if len(parts) == 11:
                source_site = parts[4]
                source_dc = parts[5]
            elif len(parts) == 10:
                source_site = parts[3]
                source_dc = parts[4]
            else:
                continue

            if parts[0] == "showrepl_INFO":
                entry = "%s/%s" % (source_site, source_dc)
                if entry not in seen:
                    seen.append(entry)
                    items.append({
                        "item": entry,
                        "params": {"failure_levels": (15, 20)},
                        "metrics": ["failures"]
                    })

    return {"changed": False, "msg": "Discovered %d items" % len(items), "data": {"discovery": items}}

def check(ctx, params):
    sections = gather_sections(ctx)
    if not sections:
        return {"changed": False, "msg": "No AD replication data available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    item = params.get("item", "")
    max_failures_warn, max_failures_crit = params.get("failure_levels", (15, 20))
    status = 0
    long_output = []
    found_line = False
    count_failures = 0
    count_failed_repl = 0

    for section in sections:
        for line in section["lines"]:
            parts = parse_line(line)
            if len(parts) not in [10, 11]:
                continue

            if len(parts) == 11:
                (_, _, _, naming_context, source_site, source_dc, _, num_failures, time_last_failure, time_last_success, status_last_failure) = parts
            else:
                (_, _, naming_context, source_site, source_dc, _, num_failures, time_last_failure, time_last_success, status_last_failure) = parts

            if parts[0] == "showrepl_INFO" and "%s/%s" % (source_site, source_dc) == item:
                found_line = True
                failure_count = int(num_failures) if num_failures.isdigit() else 0

                if failure_count > max_failures_warn or failure_count > max_failures_crit:
                    if failure_count > max_failures_crit:
                        status = 2
                        state_marker = "(!!)"
                    else:
                        status = 1
                        state_marker = "(!)"

                    count_failures += failure_count
                    count_failed_repl += 1
                    long_output.append(
                        "%s/%s replication of context %s reached the threshold of maximum failures (%s)%s" 
                        % (source_site, source_dc, naming_context, max_failures_warn, state_marker)
                    )

                if time_last_failure and time_last_success and len(time_last_failure) > 2 and len(time_last_success) > 2:
                    if time_last_failure > time_last_success:
                        status = 2
                        count_failures += 1
                        count_failed_repl += 1
                        long_output.append(
                            "%s/%s replication of context %s failed (Last success: %s, Last failure: %s, Num failures: %s, Status: %s)(!!)"
                            % (source_site, source_dc, naming_context, time_last_success, time_last_failure, num_failures, status_last_failure)
                        )

    if not found_line:
        return {"changed": False, "msg": "%s not found" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    metrics = {"failures": count_failures}

    if status == 0:
        return {"changed": False, "msg": "All replications are OK.", "data": {"state": "OK", "metrics": metrics, "details": "\n".join(long_output)}}
    
    summary = "Replications with failures: %d, Total failures: %d" % (count_failed_repl, count_failures)

    return {"changed": False, "msg": summary, "data": {"state": state_name(status), "metrics": metrics, "details": "\n".join(long_output)}}

def gather_sections(ctx):
    repadmin_res = ctx.run(["repadmin", "/showrepl"], mutates=False)
    if repadmin_res.rc == 0:
        return parse_repadmin(repadmin_res.stdout)

    samba_res = ctx.run(["samba-tool", "drs", "showrepl"], mutates=False)
    if samba_res.rc == 0:
        return parse_samba(samba_res.stdout)

    return []

def parse_repadmin(output):
    sections = []
    current_lines = []
    in_repl_info = False

    for line in output.splitlines():
        stripped = line.strip()
        if not stripped:
            if current_lines:
                sections.append({"source": "repadmin", "lines": current_lines})
                current_lines = []
            continue

        if "Destination DC" in line and "Naming Context" in line:
            in_repl_info = True
            continue

        if in_repl_info:
            current_lines.append(stripped)

    if current_lines:
        sections.append({"source": "repadmin", "lines": current_lines})

    for section in sections:
        section["lines"] = ["showrepl_INFO," + line if not line.startswith("showrepl_INFO") else line for line in section["lines"]]

    return sections

def parse_samba(output):
    sections = []
    current_lines = []

    for line in output.splitlines():
        stripped = line.strip()
        if not stripped:
            if current_lines:
                sections.append({"source": "samba-tool", "lines": current_lines})
                current_lines = []
            continue

        parts = stripped.split("|")
        if len(parts) >= 8:
            reformatted = "showrepl_INFO,%s,%s,%s,%s,%s,%s,%d,%s,%s,%s" % (
                parts[0], parts[1], parts[2], parts[3], parts[4], parts[5], 
                int(parts[6]) if parts[6].isdigit() else 0, 
                parts[7] if len(parts) > 7 else "0",
                parts[8] if len(parts) > 8 else "",
                parts[9] if len(parts) > 9 else ""
            )
            current_lines.append(reformatted)

    if current_lines:
        sections.append({"source": "samba-tool", "lines": current_lines})

    return sections

def state_name(num):
    if num == 0:
        return "OK"
    elif num == 1:
        return "WARN"
    elif num == 2:
        return "CRIT"
    else:
        return "UNKNOWN"
def main(ctx, params):
    # Discovery mode: produce the single service (no per-item breakdown)
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {"naildown_dc": False, "naildown_resources": False},
                        "metrics": []
                    }
                ]
            },
        }

    # Check mode: one service only (item is always "")
    item = params.get("item", "")
    if item != "":
        return {
            "changed": False,
            "msg": "no item expected for this check",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Gather data via crm_mon -r -o xml
    res = ctx.run(["crm_mon", "-r", "-o", "xml"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "failed to run crm_mon: " + res.stderr.strip(),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Parse XML manually (no xml module)
    out = res.stdout.strip()
    if not out:
        return {
            "changed": False,
            "msg": "empty output from crm_mon",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Extract key fields by regex-like string scans
    # Last updated
    lu_idx = out.find("Last updated:")
    last_updated_str = ""
    if lu_idx != -1:
        # Find the newline after the timestamp
        eol = out.find("\n", lu_idx)
        if eol == -1:
            eol = len(out)
        last_updated_str = out[lu_idx:eol].strip()
        # Extract the timestamp part after "Last updated:"
        ts_start = last_updated_str.find(":")
        if ts_start != -1:
            last_updated_str = last_updated_str[ts_start + 1:].strip()
        else:
            last_updated_str = ""
    last_updated = _parse_timestamp(last_updated_str) if last_updated_str else None

    # Current DC
    dc_idx = out.find("Current DC:")
    dc = ""
    if dc_idx != -1:
        eol = out.find("\n", dc_idx)
        if eol == -1:
            eol = len(out)
        line = out[dc_idx:eol].strip()
        # "Current DC: hostname (uuid)"
        parts = line.split("Current DC:")
        if len(parts) >= 2:
            after = parts[1].strip()
            dc = after.split()[0] if after else ""

    # Nodes configured
    num_nodes = _extract_number(out, "Nodes configured:")
    # Resources configured
    num_resources = _extract_number(out, "Resources configured:")

    # Failed actions: look for "Failed actions:" section
    fa_idx = out.find("Failed actions:")
    failed_actions = []
    if fa_idx != -1:
        rest = out[fa_idx:]
        # Split by lines and process
        for line in rest.splitlines()[1:]:
            stripped = line.strip()
            # Stop at next top-level section (starts with whitespace but not indented like resources)
            if stripped.startswith("Node:") or stripped.startswith("Full list of resources:") or stripped.startswith("Clone Set:") or stripped.startswith("Resource Group:") or stripped.startswith("Master/Slave Set:"):
                break
            # Only collect lines that start with '*' (failed action markers)
            if stripped.startswith("*"):
                # Strip leading '* '
                fa = stripped[2:].strip()
                if fa:
                    failed_actions.append(fa)

    # Parse resources into a dict (name -> list of resource lines)
    resources = _parse_resources_xml(out)

    # Apply thresholds and checks (matching Checkmk logic)
    max_age = params.get("max_age", 60)
    date_res = ctx.run(["date", "+%s"], mutates=False)
    now = int(date_res.stdout.strip()) if date_res.stdout.strip().isdigit() else 0
    state = "OK"
    summary_parts = []

    # Check freshness
    if last_updated != None:
        delta = now - last_updated
        if delta > max_age:
            state = "CRIT"
            summary_parts.append("Ignoring reported data (Status output too old: %s)" % _timespan(delta))

    # Check DC
    expected_dc = params.get("dc")
    if expected_dc != None:
        if dc != expected_dc:
            state = "CRIT"
            summary_parts.append("DC: %s (Expected %s)" % (dc if dc else "unknown", expected_dc))
        else:
            summary_parts.append("DC: %s" % dc)
    else:
        summary_parts.append("DC: %s" % (dc if dc else "unknown"))

    # Check nodes
    exp_nodes = params.get("num_nodes")
    if exp_nodes != None and num_nodes != None:
        if num_nodes != exp_nodes:
            state = "CRIT"
            summary_parts.append("Nodes: %d (Expected %d)" % (num_nodes, exp_nodes))
        else:
            summary_parts.append("Nodes: %d" % num_nodes)

    # Check resources
    exp_res = params.get("num_resources")
    if exp_res != None and num_resources != None:
        if num_resources != exp_res:
            state = "CRIT"
            summary_parts.append("Resources: %d (Expected %d)" % (num_resources, exp_res))
        else:
            summary_parts.append("Resources: %d" % num_resources)

    # Show failed actions (if enabled)
    show_failed = params.get("show_failed_actions", False)
    if show_failed and failed_actions:
        for fa in failed_actions:
            summary_parts.append("Failed: %s" % fa)

    summary = ", ".join(summary_parts) if summary_parts else "Status unknown"
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }


# Helper: parse timestamp like "Thu Jul  1 07:48:19 2010" without try/except
def _parse_timestamp(s):
    if not s:
        return None
    # Normalize double space to single (e.g., "Jul  1" -> "Jul 1")
    s = " ".join(s.split())
    parts = s.split()
    if len(parts) != 7:
        return None
    wday, month, day, time_str, year = parts[0], parts[1], parts[2], parts[3], parts[6]
    # Validate day and year as integers
    if not day.isdigit() or not year.isdigit():
        return None
    day_int = int(day)
    year_int = int(year)
    # Validate time format h:m:s
    time_parts = time_str.split(":")
    if len(time_parts) != 3:
        return None
    for tp in time_parts:
        if not tp.isdigit():
            return None
    # Map months
    months = {"Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6,
              "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12}
    month_num = months.get(month)
    if month_num == None:
        return None
    # Compute days since epoch
    days_before_month = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
    is_leap = (year_int % 4 == 0 and year_int % 100 != 0) or (year_int % 400 == 0)
    if is_leap and month_num > 2:
        days_before = days_before_month[month_num - 1] + 1
    else:
        days_before = days_before_month[month_num - 1]
    y = year_int - 1970
    leap_years = (y + 1) // 4 - (y + 99) // 100 + (y + 399) // 400
    days = y * 365 + leap_years + days_before + day_int - 1
    # Seconds
    h = int(time_parts[0])
    m = int(time_parts[1])
    sec = int(time_parts[2])
    return days * 86400 + h * 3600 + m * 60 + sec


# Helper: extract integer after a header (e.g., "Nodes configured: 2")
def _extract_number(s, header):
    idx = s.find(header)
    if idx == -1:
        return None
    rest = s[idx + len(header):].strip()
    # Take the first token that looks like an integer
    tokens = rest.split()
    for tok in tokens:
        if tok.isdigit():
            return int(tok)
    return None


# Helper: format timespan like render.timespan
def _timespan(seconds):
    seconds = int(seconds)
    m = seconds // 60
    s = seconds - m * 60
    h = m // 60
    m = m - h * 60
    d = h // 24
    h = h - d * 24
    if d > 0:
        return "%d day%s, %d:%d:%d" % (d, "s" if d > 1 else "", h, m, s)
    if h > 0:
        return "%d:%d:%d" % (h, m, s)
    if m > 0:
        return "%d:%d" % (m, s)
    return "%d seconds" % seconds


# Helper: parse resources from crm_mon xml
def _parse_resources_xml(xml):
    # Very simple extraction: look for <resource ...> or <group ...> tags
    res = {}
    # Split into lines for easier scanning
    for line in xml.splitlines():
        stripped = line.strip()
        if "<resource " in stripped or "<group " in stripped:
            # Extract name
            name = ""
            if 'resource "' in stripped:
                name = stripped.split('resource "')[1].split('"')[0]
            elif 'group "' in stripped:
                name = stripped.split('group "')[1].split('"')[0]
            if not name:
                continue
            # Extract state
            state = ""
            if 'resource_state="' in stripped:
                state = stripped.split('resource_state="')[1].split('"')[0]
            elif 'group_state="' in stripped:
                state = stripped.split('group_state="')[1].split('"')[0]
            # Extract node
            node = ""
            if 'node="' in stripped:
                node = stripped.split('node="')[1].split('"')[0]
            elif 'target_node="' in stripped:
                node = stripped.split('target_node="')[1].split('"')[0]
            if not state:
                state = "Unknown"
            if not node:
                node = "Unknown"
            # Format like Checkmk: ["<name>", "<class>", "<state>", "<node>"]
            res_cls = "OCF" if "ocf:" in stripped else "Unknown"
            res[name] = [[name, res_cls, state, node]]
    return res
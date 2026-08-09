# Heartbeat CRM resources — read-only Checkmk translation
# Monitors ClusterLabs/Pacemaker CRM resources via `crm_mon` output.

def _strip_type_tag(s):
    idx = s.find(": ")
    if idx == -1:
        return s.strip()
    rest = s[idx+2:].strip()
    if len(rest) >= 2 and rest[0] == "\"" and rest[-1] == "\"":
        rest = rest[1:-1]
    return rest


def _parse_for_error(first_line):
    low = first_line.lower()
    if low.startswith("critical") or low.startswith("error:") or "connection to cluster failed" in low:
        return first_line
    return None


def _title(title):
    return title.split(":", 1)[0]


def _sanitise_line(line):
    if len(line) == 0:
        return line
    leading = line[0]
    if leading == "_*":
        return line[1:]
    if leading != "_":
        return line
    if len(line) > 1 and line[1] == "*":
        out = list(line[2:])
        out.insert(0, "_")
        return out
    return line


def _parse_last_updated(line_tokens, month_map):
    if line_tokens.count("Last") > 1:
        idx = line_tokens.index("Last", 1)
        line_tokens = line_tokens[:idx]
    # tokens: ["Last", "updated:", "Tue", "Sep", "8", "10:36:12", "2020"]
    if len(line_tokens) < 7:
        return None
    day_s = line_tokens[2]
    mon_s = line_tokens[3]
    time_s = line_tokens[4]
    year_s = line_tokens[5]
    hh, mm, ss = time_s.split(":")
    month = month_map.get(mon_s)
    if month == None:
        return None
    return None


def _parse_crm_output(raw, month_map):
    raw = _strip_type_tag(raw)
    raw_lines = [l for l in raw.splitlines() if l.strip() != ""]
    if not raw_lines:
        return None

    first_err = _parse_for_error(raw_lines[0])
    if first_err != None:
        return {"error": first_err, "last_updated": None, "dc": None,
                "num_nodes": None, "num_resources": None,
                "resources": {}, "failed_actions": []}

    lines = []
    for rl in raw_lines:
        parts = rl.split()
        lines.append(_sanitise_line(parts))

    KNOWN_RESOURCES_HEADERS_LOWER = ["full list of resources:"]
    KNOWN_FAILED = ["failed actions:", "failed resource actions:", "failed fencing actions:"]

    positions_resources = []
    positions_failed = []
    for j in range(len(lines)):
        l = lines[j]
        txt = " ".join(l).lower()
        if txt in KNOWN_RESOURCES_HEADERS_LOWER:
            positions_resources.append(j)
        if txt in KNOWN_FAILED:
            positions_failed.append(j)

    general_end = len(lines)
    res_start = None
    fail_start = None
    if len(positions_resources) > 0:
        res_start = positions_resources[0]
        general_end = res_start
    if len(positions_failed) > 0:
        fail_start = positions_failed[0]
        if res_start == None:
            general_end = fail_start
        else:
            general_end = fail_start

    general = lines[0:general_end]
    resources_lines = []
    failed_lines = []
    if res_start != None:
        resources_lines = lines[res_start+1:]
    if fail_start != None:
        failed_lines = lines[fail_start+1:]
        if res_start != None:
            resources_lines = lines[res_start+1:fail_start]

    last_updated = None
    dc = None
    num_nodes = None
    num_resources = None
    for line in general:
        line_txt = " ".join(line)
        title = _title(line_txt)
        if title == "Last updated":
            last_updated = _parse_last_updated(line, month_map)
        elif title == "Current DC":
            if len(line) >= 3:
                dc = line[2]
        elif "nodes and" in line_txt and "resources configured" in line_txt:
            if len(line) > 0 and line[0].isdigit():
                num_nodes = int(line[0])
            if len(line) > 3 and line[3].isdigit():
                num_resources = int(line[3])
        elif "nodes configured" in line_txt.lower():
            if len(line) > 0 and line[0].isdigit():
                num_nodes = int(line[0])
        elif ("resources configured" in line_txt.lower() or
              "resource instances configured" in line_txt.lower()):
            if len(line) > 0 and line[0].isdigit():
                num_resources = int(line[0])

    resources = {}
    current_resource = ""
    mode = "single"
    for parts in resources_lines:
        line_txt = " ".join(parts)
        if line_txt.startswith("Resource Group:"):
            current_resource = _title(parts[2]) if len(parts) > 2 else ""
            resources[current_resource] = []
            mode = "resourcegroup"
        elif line_txt.startswith("Clone Set:"):
            current_resource = _title(parts[2]) if len(parts) > 2 else ""
            resources[current_resource] = []
            mode = "masterslaveset" if "(promotable)" in parts[-1] else "cloneset"
        elif line_txt.startswith("Master/Slave Set:"):
            current_resource = _title(parts[2]) if len(parts) > 2 else ""
            resources[current_resource] = []
            mode = "masterslaveset"
        elif len(parts) > 0 and parts[0] == "_":
            if mode == "resourcegroup" and current_resource != "":
                resources[current_resource].append(parts[1:])
            elif mode == "cloneset" and current_resource != "":
                if len(parts) > 1 and parts[1] == "Started:":
                    tail = ", ".join(parts[3:-1]) if len(parts) > 3 else ""
                    resources[current_resource].append([current_resource, "Clone", "Started", tail])
            elif mode == "masterslaveset" and current_resource != "":
                if len(parts) > 1 and parts[1] == "Masters:":
                    resources[current_resource].append([current_resource, "Master", "Started", parts[3] if len(parts) > 3 else ""])
                if len(parts) > 1 and parts[1] == "Slaves:":
                    resources[current_resource].append([current_resource, "Slave", "Started", parts[3] if len(parts) > 3 else ""])
        else:
            if len(parts) > 0:
                resources[parts[0]] = [parts]

    failed_actions = []
    joined_line = ""
    for part_list in failed_lines:
        part = " ".join(part_list)
        if part.startswith("*"):
            if joined_line != "":
                failed_actions.append(joined_line)
            joined_line = part[2:]
        elif part.startswith("_ ") or part.startswith("  "):
            joined_line += part[1:]
        else:
            if joined_line != "":
                failed_actions.append(joined_line)
            joined_line = part
    if joined_line != "":
        failed_actions.append(joined_line)

    return {
        "error": None,
        "last_updated": last_updated,
        "dc": dc,
        "num_nodes": num_nodes,
        "num_resources": num_resources,
        "resources": resources,
        "failed_actions": failed_actions,
    }


def main(ctx, params):
    month_map = {
        "Jan": "01", "Feb": "02", "Mar": "03", "Apr": "04",
        "May": "05", "Jun": "06", "Jul": "07", "Aug": "08",
        "Sep": "09", "Oct": "10", "Nov": "11", "Dec": "12",
    }

    if params.get("_discover"):
        res = ctx.run(["crm_mon", "-1", "-r", "--failures"], mutates=False)
        if res.rc != 0 or res.stdout == "":
            return {"changed": False, "msg": "no crm_mon output available", "data": {"discovery": []}}
        section = _parse_crm_output(res.stdout, month_map)
        if section == None or section["error"] != None:
            return {"changed": False, "msg": "no CRM data parsed", "data": {"discovery": []}}

        discovery = []
        for name in section["resources"].keys():
            discovery.append({"item": name, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d CRM resources" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    if item == "":
        res = ctx.run(["crm_mon", "-1", "-r", "--failures"], mutates=False)
        if res.rc != 0 or res.stdout == "":
            return {"changed": False, "msg": "crm_mon not available or no data",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        section = _parse_crm_output(res.stdout, month_map)
        if section == None:
            return {"changed": False, "msg": "could not parse CRM output",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

        if section["error"] != None:
            return {"changed": False, "msg": section["error"],
                    "data": {"state": "CRIT", "metrics": {}, "details": ""}}

        max_age = float(params.get("max_age", 60))
        metrics = {}
        last_updated = section["last_updated"]
        if last_updated != None:
            dres = ctx.run(["date", "+%s"], mutates=False)
            now_ts = float(dres.stdout.strip()) if dres.rc == 0 else 0.0
            delta = now_ts - last_updated
            metrics["last_updated_delta"] = delta
            if (delta) > max_age:
                return {"changed": False, "msg": "Ignoring reported data (Status output too old)",
                        "data": {"state": "CRIT", "metrics": metrics, "details": "delta=%s" % delta}}

        dc = section["dc"]
        num_nodes = section["num_nodes"]
        num_resources = section["num_resources"]
        details_parts = []
        if dc != None:
            details_parts.append("DC: " + str(dc))
        if num_nodes != None:
            details_parts.append("Nodes: %d" % num_nodes)
        if num_resources != None:
            details_parts.append("Resources: %d" % num_resources)
        details = "; ".join(details_parts)

        expected_dc = params.get("dc")
        if expected_dc != None and dc != None and dc != expected_dc:
            return {"changed": False, "msg": "DC: %s (Expected %s)" % (dc, expected_dc),
                    "data": {"state": "CRIT", "metrics": metrics, "details": details}}

        exp_nodes = params.get("num_nodes")
        if exp_nodes != None and num_nodes != None:
            if num_nodes != exp_nodes:
                return {"changed": False, "msg": "Nodes: %d (Expected %d)" % (num_nodes, exp_nodes),
                        "data": {"state": "CRIT", "metrics": metrics, "details": details}}

        exp_resources = params.get("num_resources")
        if exp_resources != None and num_resources != None:
            if num_resources != exp_resources:
                return {"changed": False, "msg": "Resources: %d (Expected %d)" % (num_resources, exp_resources),
                        "data": {"state": "CRIT", "metrics": metrics, "details": details}}

        failed = section["failed_actions"]
        if failed:
            msg = "DC: " + str(dc) if dc != None else "DC: unknown"
            for a in failed:
                msg = msg + "; Failed: " + a
            return {"changed": False, "msg": msg,
                    "data": {"state": "WARN", "metrics": metrics, "details": details}}

        msg_parts = []
        if dc != None:
            msg_parts.append("DC: " + str(dc))
        else:
            msg_parts.append("DC: unknown")
        if num_nodes != None:
            msg_parts.append("Nodes: %d" % num_nodes)
        if num_resources != None:
            msg_parts.append("Resources: %d" % num_resources)
        msg = "; ".join(msg_parts)
        return {"changed": False, "msg": msg,
                "data": {"state": "OK", "metrics": metrics, "details": details}}

    res = ctx.run(["crm_mon", "-1", "-r", "--failages"], mutates=False)
    if res.rc != 0 or res.stdout == "":
        return {"changed": False, "msg": "crm_mon not available or no data for item " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    section = _parse_crm_output(res.stdout, month_map)
    if section == None:
        return {"changed": False, "msg": "could not parse CRM output",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    resources = section["resources"].get(item)
    if resources == None:
        return {"changed": False, "msg": "no such CRM resource: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if section["error"] != None:
        return {"changed": False, "msg": section["error"],
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}

    if len(resources) == 0:
        return {"changed": False, "msg": "No resources found",
                "data": {"state": "OK", "metrics": {}, "details": ""}}

    expected_node = params.get("expected_node")
    monitoring_state_if_unmanaged = int(params.get("monitoring_state_if_unmanaged_nodes", 1))
    show_failed = params.get("show_failed_actions", False)

    details_parts = []
    unmanaged_nodes = set()
    worst_state = "OK"
    msg = ""

    for resource in resources:
        rline = " ".join([str(x) for x in resource])
        details_parts.append(rline)

        if len(resource) in (3, 4) and resource[2] != "Started":
            worst_state = "CRIT"
            if msg == "":
                msg = 'Resource is in state "%s"' % resource[2]
            continue

        if len(resource) <= 3:
            continue

        current_node = resource[3]
        if (expected_node != None and expected_node != current_node and
                len(resource) > 1 and resource[1] not in ("Slave", "Clone")):
            worst_state = "CRIT"
            if msg == "":
                msg = "Expected node: %s" % expected_node
        if len(rline) > 0 and "(unmanaged)" in rline:
            unmanaged_nodes.add(current_node)

    if len(unmanaged_nodes) > 0:
        state_map = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}
        s = state_map.get(monitoring_state_if_unmanaged, "WARN")
        if s == "CRIT":
            worst_state = "CRIT"
        elif s == "WARN" and worst_state == "OK":
            worst_state = "WARN"
        if msg == "":
            msg = "Unmanaged nodes: " + ", ".join(sorted(unmanaged_nodes))
        else:
            msg = msg + "; Unmanaged nodes: " + ", ".join(sorted(unmanaged_nodes))

    if show_failed:
        for action in section["failed_actions"]:
            worst_state = "WARN" if worst_state == "OK" else worst_state
            if msg == "":
                msg = "Failed: " + action
            else:
                msg = msg + "; Failed: " + action

    if msg == "":
        msg = item + ": " + " ".join([str(x) for x in resources[0]])

    return {"changed": False, "msg": msg,
            "data": {"state": worst_state, "metrics": {}, "details": "\n".join(details_parts)}}
SAP_STATE_MAP = {0: "OK", 1: "OK", 2: "WARN", 3: "CRIT"}
STATE_ORDER = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}

def _safe_float(s):
    s = s.strip()
    check = s.lstrip("-")
    if not check:
        return 0.0
    parts = check.split(".")
    if len(parts) == 1 and parts[0].isdigit():
        return float(s)
    if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
        return float(s)
    return 0.0

def _parse_sap_data(raw):
    entries = []
    for line in raw.splitlines():
        fields = line.split("\t")
        if len(fields) < 6:
            continue
        sid = fields[0].strip()
        if not sid:
            continue
        state_str = fields[1].strip()
        state_int = int(state_str) if state_str.isdigit() else 0
        path = fields[3].strip()
        reading_raw = fields[4].strip()
        unit = fields[5].strip()
        output = " ".join(fields[6:]).strip() if len(fields) > 6 else ""
        state = SAP_STATE_MAP.get(state_int, "OK")
        reading = None if reading_raw == "-" else _safe_float(reading_raw)
        entries.append({
            "sid": sid,
            "state": state,
            "path": path,
            "reading": reading,
            "unit": unit,
            "output": output,
        })
    return entries

def _regex_match(pattern, text):
    # Simulates re.match (anchored at start, not at end); supports .* wildcards only.
    if not pattern or pattern == ".*":
        return True
    parts = pattern.split(".*")
    pos = 0
    first = True
    for part in parts:
        if not part:
            if first:
                first = False
            continue
        if first:
            if not text.startswith(part):
                return False
            pos = len(part)
            first = False
        else:
            idx = text.find(part, pos)
            if idx == -1:
                return False
            pos = idx + len(part)
    return True

def _patterns_match(path, exclusion, inclusion):
    if exclusion and _regex_match(exclusion, path):
        return False
    return _regex_match(inclusion, path)

def _groups_of_path(path, rules):
    # rules: list of (group_name, inclusion, exclusion)
    groups = []
    seen = set()
    for rule in rules:
        group_name = rule[0]
        inclusion = rule[1]
        exclusion = rule[2]
        if _patterns_match(path, exclusion, inclusion):
            if group_name not in seen:
                seen.add(group_name)
                groups.append(group_name)
    return groups

def _worst_state(a, b):
    if STATE_ORDER.get(a, 0) >= STATE_ORDER.get(b, 0):
        return a
    return b

def main(ctx, params):
    # SAP agent output is delivered as tab-separated lines (<<<sap:sep(9)>>> section).
    # Point data_file at a local cache written by your SAP agent plugin.
    data_file = params.get("data_file", "/var/cache/sap_agent/sap.txt")

    if not ctx.file_exists(data_file):
        if params.get("_discover"):
            return {
                "changed": False,
                "msg": "SAP data file not found: " + data_file,
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "SAP data file not found: " + data_file,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    raw = ctx.file_read(data_file)
    entries = _parse_sap_data(raw)

    if params.get("_discover"):
        # grouping_patterns: list of {group, inclusion, exclusion}
        grouping_patterns = params.get("grouping_patterns", [])
        sap_rules = []
        patterns_by_group = {}
        for p in grouping_patterns:
            group = p.get("group", "")
            inclusion = p.get("inclusion", ".*")
            exclusion = p.get("exclusion", "")
            sap_rules.append((group, inclusion, exclusion))
            if group not in patterns_by_group:
                patterns_by_group[group] = []
            patterns_by_group[group].append({"inclusion": inclusion, "exclusion": exclusion})

        seen = set()
        discovery = []
        for entry in entries:
            for group_name in _groups_of_path(entry["path"], sap_rules):
                if group_name not in seen:
                    seen.add(group_name)
                    discovery.append({
                        "item": group_name,
                        "params": {
                            "_group_relevant_patterns": patterns_by_group.get(group_name, []),
                        },
                        "metrics": ["count_ok", "count_crit"],
                    })

        return {
            "changed": False,
            "msg": "discovered %d SAP value groups" % len(discovery),
            "data": {"discovery": discovery},
        }

    # Check mode
    item = params.get("item", "")
    group_patterns = params.get("_group_relevant_patterns", [])

    if not group_patterns:
        return {
            "changed": False,
            "msg": "Rules not found. Please rediscover the services of this host",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    precompiled_rule = [
        (item, p.get("inclusion", ".*"), p.get("exclusion", ""))
        for p in group_patterns
    ]

    count_ok = 0
    count_crit = 0
    overall = "OK"
    detail_lines = []

    for entry in entries:
        if item in _groups_of_path(entry["path"], precompiled_rule):
            state = entry["state"]
            out = entry["output"] if entry["reading"] == None else ""
            if state != "OK":
                count_crit += 1
            else:
                count_ok += 1
            overall = _worst_state(overall, state)
            detail_lines.append(state + " " + entry["path"] + out)

    if not detail_lines:
        return {
            "changed": False,
            "msg": "no output about sap value groups in agent output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    return {
        "changed": False,
        "msg": "OK: %d Critical: %d" % (count_ok, count_crit),
        "data": {
            "state": overall,
            "metrics": {"count_ok": count_ok, "count_crit": count_crit},
            "details": "\n".join(detail_lines),
        },
    }
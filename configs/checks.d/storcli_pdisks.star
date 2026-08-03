# Checkmk check: checkmk.storcli_pdisks
# Translated to a read-only Starlark check module for the yolo-man agent.

_RAW_STATE_EXPANSIONS = {
    "ucapo": "Uncorrectable error to the cache",
    "ucapn": "Uncorrectable error to the cache during NVDIMM programming",
    "ucr": "Uncorrectable read error",
    "ucw": "Uncorrectable write error",
    "onln": "Online",
    "dgrd": "Drive Downgraded",
    "rbld": "Rebuild",
    "rsvd": "Reserved",
    "hots": "Hot spare",
    "ursg": "Unconfigured Raid (Good)",
    "ursh": "Unconfigured Raid (Bad)",
    "urgd": "Unconfigured (Good)",
    "urbd": "Unconfigured (Bad)",
    "shld": "Shld",
    "spun": "Spun up",
    "spdn": "Spun down",
    "untl": "Unconfigured (TLS failure)",
    "inmt": "In a degraded Media",
    "fori": "Foreign Raid (Good)",
    "forc": "Foreign RAID (Bad)",
    "foru": "Foreign Unconfigured",
    "gshl": "Global Spare in Ready state",
    "gshs": "Global Spare in Ready state (SSD)",
    "psh": "Passthrough",
    "sata": "SAT drive",
    "nvme": "NVMe drive",
    "ssd": "Solid State Drive",
    "hdd": "Hard Disk Drive",
}

_PDISKS_DEFAULTS = {
    "ucapo": 2,
    "ucapn": 2,
    "ucr": 2,
    "ucw": 2,
    "onln": 0,
    "dgrd": 1,
    "rbld": 0,
    "rsvd": 0,
    "hots": 0,
    "ursg": 0,
    "ursh": 2,
    "urgd": 0,
    "urbd": 2,
    "shld": 0,
    "spun": 0,
    "spdn": 0,
    "untl": 2,
    "inmt": 1,
    "fori": 0,
    "forc": 2,
    "foru": 0,
    "gshl": 0,
    "gshs": 0,
    "psh": 1,
    "sata": 0,
    "nvme": 0,
    "ssd": 0,
    "hdd": 0,
}

_SEV_MAP = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}


def _is_marker(marker, line):
    if len(line) == 1 and line[0]:
        s = line[0]
        return s.count(marker) == len(s)
    return False


def _is_table_marker(line):
    return _is_marker("-", line)


def _is_section_marker(line):
    return _is_marker("=", line)


def _parse_table(lines, name, idx_ref):
    table_header = lines[idx_ref[0]]
    idx_ref[0] = idx_ref[0] + 1
    idx_ref[0] = idx_ref[0] + 1
    table_body = []
    while idx_ref[0] < len(lines):
        cur = lines[idx_ref[0]]
        if _is_table_marker([cur]):
            idx_ref[0] = idx_ref[0] + 1
            break
        table_body.append(cur)
        idx_ref[0] = idx_ref[0] + 1
    return {"name": name, "header": table_header, "body": table_body}


def parse_tables(raw_lines):
    tables = []
    current_section = None
    idx_ref = [0]
    prev_line = ""
    while idx_ref[0] < len(raw_lines):
        line = raw_lines[idx_ref[0]]
        tokens = line.split()
        if _is_section_marker(tokens):
            current_section = prev_line.rstrip(": ").strip()
            idx_ref[0] = idx_ref[0] + 1
            if current_section:
                tables.append(_parse_table(raw_lines, current_section, idx_ref))
        else:
            prev_line = line
            idx_ref[0] = idx_ref[0] + 1
    return tables


def parse_storcli_pdisks(raw_text, controller_num):
    section = {}
    raw_lines = raw_text.split("\n")
    lines = [l for l in raw_lines if l.strip() != ""]
    tables = parse_tables(lines)
    for table in tables:
        if table["name"] != "Drive Information":
            continue
        header = table["header"].split()
        if header[:6] == ["EID:Slt", "PID", "State", "Status", "DG", "Size"]:
            for bline in table["body"]:
                cols = bline.split()
                if len(cols) < 7:
                    continue
                eid_and_slot = cols[0]
                device_id = cols[1]
                status = cols[4]
                size = cols[5]
                size_unit = cols[6]
                item_name = "C%d.%s-%s" % (controller_num, eid_and_slot, device_id)
                section[item_name] = {
                    "state": status,
                    "size": (float(size), size_unit),
                }
        else:
            for bline in table["body"]:
                cols = bline.split()
                if len(cols) < 6:
                    continue
                eid_and_slot = cols[0]
                device = cols[1]
                state = cols[2]
                size = cols[4]
                size_unit = cols[5]
                item_name = "C%d.%s-%s" % (controller_num, eid_and_slot, device)
                section[item_name] = {
                    "state": state,
                    "size": (float(size), size_unit),
                }
    return section


def _expand_abbreviation(abbr):
    if abbr in _RAW_STATE_EXPANSIONS:
        return _RAW_STATE_EXPANSIONS[abbr]
    return str(abbr)


def _probe_storcli(ctx, params):
    storcli = params.get("storcli_path", "/usr/local/bin/storcli64")
    v = ctx.run([storcli, "show"], mutates=False)
    if v.rc == 127:
        return None
    ctrl_lines = [l for l in v.stdout.split("\n") if l.strip().isdigit()]
    if len(ctrl_lines) == 0:
        ctrl_nums = [0]
    else:
        ctrl_nums = []
        for l in ctrl_lines:
            ctrl_nums.append(int(l.strip()))
    section = {}
    for c in ctrl_nums:
        res = ctx.run([storcli, "/c%d" % c, "/eall", "/sall", "show", "ALI"], mutates=False)
        if res.rc != 0:
            continue
        controller_section = parse_storcli_pdisks(res.stdout, c)
        for k in controller_section:
            section[k] = controller_section[k]
    return section


def main(ctx, params):
    if params.get("_discover"):
        section = _probe_storcli(ctx, params)
        if section == None or len(section) == 0:
            return {
                "changed": False,
                "msg": "storcli_pdisks: no physical disks discovered",
                "data": {"discovery": []},
            }
        discovery = []
        for item in section:
            disk = section[item]
            state = disk["state"].lower()
            defaults = params.get(state, _PDISKS_DEFAULTS.get(state, 3))
            discovery.append({
                "item": item,
                "params": {state: defaults},
                "metrics": ["size"],
            })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    section = _probe_storcli(ctx, params)
    if section == None:
        return {
            "changed": False,
            "msg": "storcli64 not installed or not reachable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    if item not in section:
        return {
            "changed": False,
            "msg": "no such physical disk: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    disk = section[item]
    size_value, size_unit = disk["size"]
    state_key = disk["state"].lower()
    severity = params.get(state_key, _PDISKS_DEFAULTS.get(state_key, 3))
    if not isinstance(severity, int):
        severity = 3
    state_str = _SEV_MAP.get(severity, "UNKNOWN")

    if state_str == "UNKNOWN":
        summary = "Disk State %s not known in parameters." % disk["state"]
        return {
            "changed": False,
            "msg": "Size: %s %s, %s" % (size_value, size_unit, summary),
            "data": {
                "state": "UNKNOWN",
                "metrics": {"size": size_value},
                "details": summary,
            },
        }

    expanded = _expand_abbreviation(disk["state"])
    summary = "Size: %s %s, Disk State: %s" % (size_value, size_unit, expanded)
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state_str,
            "metrics": {"size": size_value},
            "details": summary,
        },
    }
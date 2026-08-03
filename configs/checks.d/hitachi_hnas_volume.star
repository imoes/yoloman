# Starlark translation of Checkmk hitachi_hnas_volume (SNMP-based)
# Read-only: never mutates, always changed=False
#
# Data source is SNMP via net-snmp tools (the same MIB/variables the
# Checkmk SNMPSection reads). We probe for the product via sysObjectID
# detection (DETECT) before reporting anything.

# --- STATUS / STATE maps (mirrors cmk.plugins.hitachi_hnas.lib) ---

STATUS_MAP = {
    "1": "unformatted",
    "2": "mounted",
    "3": "formatted",
    "4": "needsChecking",
}

STATE_MAP = {
    "mounted": "OK",
    "unformatted": "WARN",
    "formatted": "WARN",
    "needsChecking": "CRIT",
}

# --- Helpers ---------------------------------------------------------

def _bytes_to_mb(b):
    "Convert a bytes value (or None) to MB, matching the python int(x)/1048576.0 logic."
    if b == None or b == "":
        return None
    return int(b) / 1048576.0

def _split_first_space(line):
    i = line.find(" ")
    if i == -1:
        return line, ""
    return line[:i], line[i+1:]

def _strip_type_tag(s):
    "Strip a leading '<TYPE>: ' produced by snmptranslate-style output."
    i = s.find(": ")
    if i == -1:
        return s
    return s[i+2:]

def _strip_quotes(s):
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        return s[1:-1]
    return s

# --- Product detection (DETECT) --------------------------------------

def _detect_hitachi_hnas(ctx, params):
    "Return True if this host exposes the Hitachi HNAS / BlueArc vendor tree."
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    # sysObjectID
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if res.rc != 0:
        return False
    oid = res.stdout.strip()
    if oid.startswith(".1.3.6.1.4.1.11096.6"):
        return True
    # HM800 reports linux as type -> also require existence of the HNAS volume table
    if oid.startswith(".1.3.6.1.4.1.8072.3.2.10"):
        chk = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.11096.6.1.1.1.3.5.2.1.1"], mutates=False)
        return chk.rc == 0 and len(chk.stdout.strip()) > 0
    return False

# --- SNMP table walks -------------------------------------------------

def _walk_volume_table(ctx, params):
    "Walk the physical volume table (BLUEARC-SERVER-MIB volumeEntry)."
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.4.1.11096.6.1.1.1.3.5.2.1"
    cols = {
        "1": "volumeSysDriveIndex",
        "3": "volumeLabel",
        "4": "volumeStatus",
        "5": "volumeCapacity",
        "6": "volumeFreeCapacity",
        "7": "volumeEnterpriseVirtualServer",
    }
    # Walk the whole table with -Oqn so each row is "<full-oid> <value>"
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base], mutates=False)
    if res.rc != 0:
        return []
    rows = {}
    order = []
    for line in res.stdout.splitlines():
        line = line.strip()
        if line == "":
            continue
        oid, value = _split_first_space(line)
        # oid looks like "<base>.<col>.<index>"; base ends right before ".<col>.<index>"
        suffix = oid[len(base):]
        if len(suffix) < 2 or suffix[0] != ".":
            continue
        suffix = suffix[1:]  # drop leading dot
        # first component is the column id
        parts = suffix.split(".")
        col = parts[0]
        index = ".".join(parts[1:])
        if col not in cols:
            continue
        if index not in rows:
            rows[index] = {}
            order.append(index)
        rows[index][cols[col]] = value
    out = []
    for index in order:
        r = rows[index]
        vol_id = r.get("volumeSysDriveIndex", "")
        label = r.get("volumeLabel", "")
        status_id = r.get("volumeStatus", "")
        size = r.get("volumeCapacity", "")
        avail = r.get("volumeFreeCapacity", "")
        evs = r.get("volumeEnterpriseVirtualServer", "")
        out.append({"index": index, "volume_sys_drive_index": vol_id, "label": label,
                    "status_id": status_id, "size": size, "avail": avail, "evs": evs})
    return out

def _walk_virtual_volume_table(ctx, params):
    "Walk virtualVolumeTitanEntry (OIDEnd, spanId, name)."
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.4.1.11096.6.2.1.2.1.2.1"
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base], mutates=False)
    if res.rc != 0:
        return []
    rows = {}
    order = []
    for line in res.stdout.splitlines():
        line = line.strip()
        if line == "":
            continue
        oid, value = _split_first_space(line)
        suffix = oid[len(base):]
        if len(suffix) < 2 or suffix[0] != ".":
            continue
        suffix = suffix[1:]
        parts = suffix.split(".")
        col = parts[0]
        index = ".".join(parts[1:])
        # col 1 = virtualVolumeTitanSpanId, 2 = virtualVolumeTitanName
        if col not in ("1", "2"):
            continue
        if index not in rows:
            rows[index] = {"span_id": "", "name": ""}
            order.append(index)
        if col == "1":
            rows[index]["span_id"] = value.replace("\"", "")
        else:
            rows[index]["name"] = value.replace("\"", "")
    out = []
    for index in order:
        out.append({"index": index, "oid_end": index, "name": rows[index]["name"],
                    "span_id": rows[index]["span_id"]})
    return out

def _walk_quota_table(ctx, params):
    "Walk BLUEARC-TITAN-MIB virtualVolumeTitanQuotasEntry."
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.4.1.11096.6.2.1.2.1.7.1"
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base], mutates=False)
    if res.rc != 0:
        return []
    rows = {}
    for line in res.stdout.splitlines():
        line = line.strip()
        if line == "":
            continue
        oid, value = _split_first_space(line)
        suffix = oid[len(base):]
        if len(suffix) < 2 or suffix[0] != ".":
            continue
        suffix = suffix[1:]
        parts = suffix.split(".")
        col = parts[0]
        index = ".".join(parts[1:])
        if index not in rows:
            rows[index] = {"target_type": "", "usage": "", "limit": ""}
        # col 3 = targetType, 4 = usage, 6 = usageLimit
        if col == "3":
            rows[index]["target_type"] = value
        elif col == "4":
            rows[index]["usage"] = value
        elif col == "6":
            rows[index]["limit"] = value
    out = []
    for index in rows:
        out.append({"oid_end": index, "target_type": rows[index]["target_type"],
                    "usage": rows[index]["usage"], "limit": rows[index]["limit"]})
    return out

# --- Parse functions (mirror cmk lib) ---------------------------------

def _parse_physical_volumes(volume_data):
    "Returns (map_label, volumes) as in the Checkmk lib."
    map_label = {}
    volumes = {}
    for r in volume_data:
        vol_id = r.get("volume_sys_drive_index", "")
        if vol_id == "" or vol_id == None:
            continue
        label = r.get("label", "")
        status_id = r.get("status_id", "")
        size = r.get("size", "")
        avail = r.get("avail", "")
        evs = r.get("evs", "")
        map_label[vol_id] = label
        volume = str(vol_id) + " " + label
        status = STATUS_MAP.get(status_id, "unidentified")
        size_mb = _bytes_to_mb(size)
        avail_mb = _bytes_to_mb(avail)
        volumes[volume] = (status, size_mb, avail_mb, evs)
    return map_label, volumes

def _quota_oid_end(phys_volume_id, virtual_volume_oid_end):
    "Reproduce the quota reference OID computation."
    parts = virtual_volume_oid_end.split(".")
    rest = parts[1:] + ["0"]
    return ".".join([phys_volume_id] + rest)

def _parse_virtual_volumes(map_label, virtual_volumes, quotas):
    parsed = {}
    map_quota_oid = {}
    for vv in virtual_volumes:
        oid_end = vv.get("oid_end", "")
        phys_volume_id = vv.get("span_id", "")
        name = vv.get("name", "")
        if phys_volume_id == "":
            continue
        phys_label = map_label.get(phys_volume_id, "")
        volume = name + " on " + phys_label
        parsed[volume] = (None, None)
        ref_oid_end = _quota_oid_end(phys_volume_id, oid_end)
        map_quota_oid[ref_oid_end] = volume
    for q in quotas:
        target_type = q.get("target_type", "")
        if target_type != "3":
            continue
        usage = q.get("usage", "")
        limit = q.get("limit", "")
        oid_end = q.get("oid_end", "")
        volume = map_quota_oid.get(oid_end)
        if volume == None:
            continue
        if usage and limit:
            size_mb = int(limit) / 1048576.0
            avail_mb = size_mb - int(usage) / 1048576.0
            parsed[volume] = (size_mb, avail_mb)
        else:
            parsed[volume] = (None, None)
    return parsed

# --- FILESYSTEM DEFAULT PARAMS (Checkmk filesystem ruleset defaults) --

FILESYSTEM_DEFAULT_PARAMS = {
    "group": "filesystem",
}

# Per-value warn/crit percentage defaults for df-style checks
DF_DEFAULT_WARN = 80.0
DF_DEFAULT_CRIT = 90.0

# --- Discovery helpers ------------------------------------------------

def _df_discovery(params, items):
    "Mirror df_discovery: return per-item discovery entries for each item."
    out = []
    for it in items:
        out.append({"item": it, "params": {"warn": DF_DEFAULT_WARN, "crit": DF_DEFAULT_CRIT},
                    "metrics": ["used_percent"]})
    return out

def _match_patterns(blocks_info, patterns):
    "Reproduce mountpoints_in_group: match item names against shell-style patterns."
    matched = []
    for name in blocks_info:
        for pat in patterns:
            if _glob_match(name, pat):
                matched.append(name)
    return matched

def _glob_match(text, pattern):
    "Minimal glob matcher supporting * ? [chars]."
    return _glob_match_rec(text, 0, pattern, 0)

def _glob_match_rec(text, ti, pattern, pi):
    while pi < len(pattern):
        c = pattern[pi]
        if c == "*":
            # collapse consecutive *
            if pi + 1 < len(pattern) and pattern[pi+1] == "*":
                pi = pi + 1
                continue
            # try to match rest at every position
            if pi + 1 == len(pattern):
                return True
            for k in range(ti, len(text)+1):
                if _glob_match_rec(text, k, pattern, pi+1):
                    return True
            return False
        elif c == "?":
            if ti >= len(text):
                return False
            ti = ti + 1
            pi = pi + 1
        else:
            if ti >= len(text) or text[ti] != c:
                return False
            ti = ti + 1
            pi = pi + 1
    return ti == len(text)

# --- Main -------------------------------------------------------------

def main(ctx, params):
    # Allow overriding host/community for SNMP
    params.setdefault("community", "public")
    params.setdefault("host", "localhost")

    is_virtual = params.get("_check", "") == "virtual"

    if params.get("_discover"):
        if not _detect_hitachi_hnas(ctx, params):
            return {"changed": False, "msg": "Hitachi HNAS not detected",
                    "data": {"discovery": []}}
        if not is_virtual:
            volumes = _walk_volume_table(ctx, params)
            map_label, parsed = _parse_physical_volumes(volumes)
            items = sorted(parsed.keys())
            return {"changed": False,
                    "msg": "discovered %d volumes" % len(items),
                    "data": {"discovery": _df_discovery(params, items)}}
        else:
            volumes = _walk_volume_table(ctx, params)
            vvs = _walk_virtual_volume_table(ctx, params)
            quotas = _walk_quota_table(ctx, params)
            map_label, _ = _parse_physical_volumes(volumes)
            parsed_vv = _parse_virtual_volumes(map_label, vvs, quotas)
            items = sorted(parsed_vv.keys())
            return {"changed": False,
                    "msg": "discovered %d virtual volumes" % len(items),
                    "data": {"discovery": _df_discovery(params, items)}}

    # --- CHECK MODE ---
    item = params.get("item", "")
    warn = params.get("warn", DF_DEFAULT_WARN)
    crit = params.get("crit", DF_DEFAULT_CRIT)

    # df-style used_percent grading (upper levels: warn if >= warn, crit if >= crit)
    def _grade_df(used_pct):
        used_pct = float(used_pct)
        if used_pct >= crit:
            return "CRIT"
        if used_pct >= warn:
            return "WARN"
        return "OK"

    if not _detect_hitachi_hnas(ctx, params):
        return {"changed": False, "msg": "Hitachi HNAS not detected",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if not is_virtual:
        volumes = _walk_volume_table(ctx, params)
        if not volumes:
            return {"changed": False, "msg": "no physical volumes found",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        map_label, parsed = _parse_physical_volumes(volumes)

        # df grading
        fslist_blocks = []
        blocks_info = {}
        for mount_point, (status, size_mb, avail_mb, evs) in parsed.items():
            fslist_blocks.append((mount_point, size_mb, avail_mb, 0))
            blocks_info[mount_point] = {"size_mb": size_mb, "avail_mb": avail_mb, "reserved_mb": 0}

        # patterns handling (like the check)
        patterns = params.get("patterns")
        if patterns and len(list(patterns)) > 0:
            matching = _match_patterns(blocks_info, patterns)
        else:
            matching = [item]

        if item not in parsed:
            return {"changed": False, "msg": "item not found: " + str(item),
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

        status, size_mb, avail_mb, evs = parsed[item]
        # df used_percent
        if size_mb == None or size_mb == 0:
            used_pct = 0.0
        else:
            used_pct = ((size_mb - avail_mb) / size_mb) * 100.0
        state = _grade_df(used_pct)

        # status grading (overrides df only for STATE_MAP keys)
        if status == "unidentified":
            summary = "Volume reports unidentified status"
            s = "CRIT"
        else:
            summary = "Status: " + status
            s = STATE_MAP.get(status, "OK")

        details = "used: %f%%" % used_pct
        return {"changed": False,
                "msg": "%s, %s, assigned to EVS %s" % (summary, details, evs),
                "data": {"state": s, "metrics": {"used_percent": used_pct}, "details": details}}
    else:
        volumes = _walk_volume_table(ctx, params)
        vvs = _walk_virtual_volume_table(ctx, params)
        quotas = _walk_quota_table(ctx, params)
        if not vvs:
            return {"changed": False, "msg": "no virtual volumes found",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        map_label, _ = _parse_physical_volumes(volumes)
        parsed_vv = _parse_virtual_volumes(map_label, vvs, quotas)

        blocks_info = {}
        for mount_point, (size_mb, avail_mb) in parsed_vv.items():
            blocks_info[mount_point] = {"size_mb": size_mb, "avail_mb": avail_mb, "reserved_mb": 0}

        patterns = params.get("patterns")
        if patterns and len(list(patterns)) > 0:
            matching = _match_patterns(blocks_info, patterns)
        else:
            matching = [item]

        if item not in parsed_vv:
            return {"changed": False, "msg": "item not found: " + str(item),
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

        size_mb, avail_mb = parsed_vv[item]
        if size_mb == None or avail_mb == None:
            return {"changed": False, "msg": "no quota size information",
                    "data": {"state": "OK", "metrics": {}, "details": ""}}

        if size_mb == 0:
            used_pct = 0.0
        else:
            used_pct = ((size_mb - avail_mb) / size_mb) * 100.0
        state = _grade_df(used_pct)
        details = "used: %f%%" % used_pct
        return {"changed": False,
                "msg": "%s, %s" % (item, details),
                "data": {"state": state, "metrics": {"used_percent": used_pct}, "details": details}}
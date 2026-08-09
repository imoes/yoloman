# scaleio_pd — ScaleIO Protection Domain capacity check (read-only Starlark)
# Reads the ScaleIO Management Data Server (MDS) REST API directly.
# No local /proc, no cmk, no agent section; the array lives on the network.

API_PATH = "/api/pes"
CAPACITY_KEY = "MAX_CAPACITY_IN_KB"
UNUSED_KEY = "UNUSED_CAPACITY_IN_KB"
STATE_KEY = "STATE"
NAME_KEY = "NAME"

# ScaleIO reports capacity like "65.5 TB (67059 GB)"; units we accept.
UNIT_TO_MB = {
    "Bytes": 1.0 / 1024.0 / 1024.0,
    "KB": 1.0 / 1024.0,
    "MB": 1.0,
    "GB": 1024.0,
    "TB": 1024.0 * 1024.0,
}

# FILESYSTEM_DEFAULT_PARAMS equivalent (Checkmk df ruleset defaults).
DEFAULT_FS_PARAMS = {
    "levels": (80.0, 90.0),
}


def _auth_token(ctx, params):
    base = "https://" + params.get("host", "localhost")
    port = params.get("port", 443)
    url = base + ":" + str(port) + "/api/login"
    user = params.get("username", "")
    pwd = params.get("password", "")
    if user == "" or pwd == "":
        return "", None
    res = ctx.run(
        ["curl", "-ksS", "-u", user + ":" + pwd, "-X", "POST", url],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout.strip():
        return "", None
    # The token endpoint returns the token as a bare string.
    return res.stdout.strip(), None


def _api_call(ctx, params, token, path):
    base = "https://" + params.get("host", "localhost")
    port = params.get("port", 443)
    url = base + ":" + str(port) + path
    headers = ["-H", "Accept-Type: application/json"]
    if token != "":
        headers = ["-H", "Accept-Type: application/json", "-H", "X-SDC-Auth-Token: " + token]
    res = ctx.run(
        ["curl", "-ksS"] + headers + [url],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout.strip():
        return None
    return json.decode(res.stdout)


def _extract_unit(cap_field):
    # cap_field looks like "65.5 TB (67059 GB)"; unit is the 4th token after split.
    if cap_field == "" or cap_field == None:
        return ""
    parts = cap_field.split(" ")
    # Find the unit token — it appears as the last parenthesized group's first token,
    # e.g. "(67059 GB)" -> unit is "GB".
    unit = ""
    if len(parts) > 3:
        unit = parts[3].strip("()")
    return unit


def _extract_value(cap_field):
    # cap_field looks like "65.5 TB (67059 GB)"; the inner numeric value is in index 2
    # after splitting: "65.5", "TB", "(67059", "GB)".
    if cap_field == "" or cap_field == None:
        return 0.0
    parts = cap_field.split(" ")
    if len(parts) < 3:
        return 0.0
    inner = parts[2].strip("(")
    if inner == "":
        return 0.0
    return float(inner)


def _parse_pd_fields(raw_list):
    """Convert a ScaleIO PD API record into the structured form the Checkmk
    plugin expects, mimicking the <<<scaleio_pd>>> key/value layout."""
    pds = {}
    for rec in raw_list:
        pd_id = rec.get("id", "")
        if pd_id == "":
            continue
        name = rec.get("name", "")
        state = rec.get("state", "")
        cap = rec.get("maxCapacityInKb", "")
        free = rec.get("unusedCapacityInKb", "")
        pds[pd_id] = {
            "ID": [pd_id],
            "NAME": [name],
            "STATE": [state],
            # ScaleIO API gives raw KB; synthesize the display string the plugin parses.
            "MAX_CAPACITY_IN_KB": ["0", "KB", str(cap), " (KB)"],
            "UNUSED_CAPACITY_IN_KB": ["0", "KB", str(free), " (KB)"],
        }
    return pds


def main(ctx, params):
    # --- probe for the real thing: the ScaleIO MDS API endpoint ---
    host = params.get("host", "localhost")
    port = params.get("port", 443)
    # Verify the MDS is reachable and the API responds.
    probe = ctx.run(
        ["curl", "-ksS", "-o", "/dev/null", "-w", "%{http_code}",
         "https://" + host + ":" + str(port) + API_PATH],
        mutates=False,
    )
    if probe.rc != 0:
        if params.get("_discover"):
            return {"changed": False, "msg": "ScaleIO MDS unreachable",
                    "data": {"discovery": [], "host_labels": {}}}
        return {"changed": False, "msg": "ScaleIO MDS unreachable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if params.get("_discover"):
        token, _ = _auth_token(ctx, params)
        data = _api_call(ctx, params, token, API_PATH)
        if data == None or type(data) != "list":
            return {"changed": False, "msg": "no ScaleIO protection domains found",
                    "data": {"discovery": []}}
        pds = _parse_pd_fields(data)
        out = []
        for pd_id, pd_data in pds.items():
            out.append({
                "item": pd_id,
                "params": dict(DEFAULT_FS_PARAMS),
                "metrics": ["used_percent", "used", "total"],
                "service_labels": {"scaleio_pd_name": pd_data["NAME"][0]},
            })
        return {"changed": False, "msg": "discovered %d items" % len(out),
                "data": {"discovery": out, "host_labels": {"cmk/scaleio_mds": "reachable"}}}

    item = params.get("item", "")
    token, _ = _auth_token(ctx, params)
    data = _api_call(ctx, params, token, API_PATH)
    if data == None or type(data) != "list":
        return {"changed": False, "msg": "no ScaleIO protection domains found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    pds = _parse_pd_fields(data)
    pd_data = pds.get(item, {})
    if len(pd_data) == 0:
        return {"changed": False, "msg": "no such protection domain: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    unit = _extract_unit(pd_data[CAPACITY_KEY][3]) if len(pd_data[CAPACITY_KEY]) > 3 else ""
    if unit not in UNIT_TO_MB:
        return {"changed": False, "msg": "Unknown unit: " + (unit if unit != "" else "(missing)"),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    total_mb = _extract_value(pd_data[CAPACITY_KEY][3]) * UNIT_TO_MB[unit]
    free_mb = _extract_value(pd_data[UNUSED_KEY][3]) * UNIT_TO_MB[unit]
    if total_mb == 0.0:
        return {"changed": False, "msg": "zero total capacity for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    used_mb = total_mb - free_mb
    used_percent = (used_mb / total_mb) * 100.0

    warn = 80.0
    crit = 90.0
    levels = params.get("levels", (warn, crit))
    if type(levels) == "list" or type(levels) == "tuple":
        warn = levels[0]
        crit = levels[1]
    elif type(levels) == "dict":
        warn = levels.get("used_percent", (80.0, 90.0))[0]
        crit = levels.get("used_percent", (80.0, 90.0))[1]

    state = "OK"
    if used_percent >= crit:
        state = "CRIT"
    elif used_percent >= warn:
        state = "WARN"

    msg = "%s: %f%% used (%f MB of %f MB)" % (item, used_percent, used_mb, total_mb)
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"used_percent": used_percent,
                                                 "used": used_mb, "total": total_mb},
                     "details": msg}}


def main(ctx, params):
    # --- probe for the ScaleIO MDS API endpoint ---
    host = params.get("host", "localhost")
    port = params.get("port", 443)
    # Verify the MDS is reachable before claiming any PD exists.
    probe = ctx.run(
        ["curl", "-ksS", "-o", "/dev/null", "-w", "%{http_code}",
         "https://" + host + ":" + str(port) + API_PATH],
        mutates=False,
    )
    if probe.rc != 0:
        if params.get("_discover"):
            return {"changed": False, "msg": "ScaleIO MDS unreachable",
                    "data": {"discovery": [], "host_labels": {}}}
        return {"changed": False, "msg": "ScaleIO MDS unreachable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if params.get("_discover"):
        token, _ = _auth_token(ctx, params)
        data = _api_call(ctx, params, token, API_PATH)
        if data == None or type(data) != "list":
            return {"changed": False, "msg": "no ScaleIO protection domains found",
                    "data": {"discovery": []}}
        pds = _parse_pd_fields(data)
        out = []
        for pd_id, pd_data in pds.items():
            out.append({
                "item": pd_id,
                "params": dict(DEFAULT_FS_PARAMS),
                "metrics": ["used_percent", "used", "total"],
                "service_labels": {"scaleio_pd_name": pd_data["NAME"][0]},
            })
        return {"changed": False, "msg": "discovered %d items" % len(out),
                "data": {"discovery": out, "host_labels": {"cmk/scaleio_mds": "reachable"}}}

    item = params.get("item", "")
    token, _ = _auth_token(ctx, params)
    data = _api_call(ctx, params, token, API_PATH)
    if data == None or type(data) != "list":
        return {"changed": False, "msg": "no ScaleIO protection domains found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    pds = _parse_pd_fields(data)
    pd_data = pds.get(item, {})
    if len(pd_data) == 0:
        return {"changed": False, "msg": "no such protection domain: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    unit = _extract_unit(pd_data[CAPACITY_KEY][3]) if len(pd_data[CAPACITY_KEY]) > 3 else ""
    if unit not in UNIT_TO_MB:
        return {"changed": False, "msg": "Unknown unit: " + (unit if unit != "" else "(missing)"),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    total_mb = _extract_value(pd_data[CAPACITY_KEY][3]) * UNIT_TO_MB[unit]
    free_mb = _extract_value(pd_data[UNUSED_KEY][3]) * UNIT_TO_MB[unit]
    if total_mb == 0.0:
        return {"changed": False, "msg": "zero total capacity for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    used_mb = total_mb - free_mb
    used_percent = (used_mb / total_mb) * 100.0

    warn = 80.0
    crit = 90.0
    levels = params.get("levels", (warn, crit))
    if type(levels) == "list" or type(levels) == "tuple":
        warn = levels[0]
        crit = levels[1]
    elif type(levels) == "dict":
        warn = levels.get("used_percent", (80.0, 90.0))[0]
        crit = levels.get("used_percent", (80.0, 90.0))[1]

    state = "OK"
    if used_percent >= crit:
        state = "CRIT"
    elif used_percent >= warn:
        state = "WARN"

    msg = "%s: %f%% used (%f MB of %f MB)" % (item, used_percent, used_mb, total_mb)
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"used_percent": used_percent,
                                                 "used": used_mb, "total": total_mb},
                     "details": msg}}
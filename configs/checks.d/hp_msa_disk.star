HEALTH_MAP = {
    "0": "OK",
    "1": "WARN",
    "2": "CRIT",
    "3": "UNKNOWN",
    "4": "UNKNOWN",
}

def _extract_property(block, prop_name):
    needle = 'name="' + prop_name + '"'
    idx = block.find(needle)
    if idx < 0:
        return ""
    gt = block.find(">", idx)
    if gt < 0:
        return ""
    lt = block.find("<", gt + 1)
    if lt < 0:
        return ""
    return block[gt + 1:lt].strip()

def _get_session_key(ctx, protocol, host, username, password):
    cred = username + "_" + password
    hash_res = ctx.run(
        ["python3", "-c",
         "import hashlib, sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())",
         cred],
        mutates=False,
    )
    if hash_res.rc != 0:
        return ""
    session_hash = hash_res.stdout.strip()
    if not session_hash:
        return ""
    login_url = "%s://%s/api/login/%s" % (protocol, host, session_hash)
    login_res = ctx.run(
        ["curl", "-s", "-k", "--max-time", "15", login_url],
        mutates=False,
    )
    if login_res.rc != 0:
        return ""
    return _extract_property(login_res.stdout, "session-key")

def _query_disks_xml(ctx, protocol, host, session_key):
    url = "%s://%s/api/show/disks" % (protocol, host)
    res = ctx.run(
        ["curl", "-s", "-k", "--max-time", "30",
         "-b", "sessionKey=" + session_key, url],
        mutates=False,
    )
    if res.rc != 0:
        return ""
    return res.stdout

def _parse_disks(xml):
    disks = []
    for part in xml.split("<OBJECT")[1:]:
        if 'basetype="drives"' not in part:
            continue
        end = part.find("</OBJECT>")
        block = part[:end] if end >= 0 else part
        durable_id = _extract_property(block, "durable-id")
        if not durable_id:
            continue
        disks.append({
            "id": durable_id,
            "health": _extract_property(block, "health"),
            "health_num": _extract_property(block, "health-numeric"),
            "reason": _extract_property(block, "health-reason"),
            "recommendation": _extract_property(block, "health-recommendation"),
        })
    return disks

def main(ctx, params):
    host = params.get("host", "localhost")
    username = params.get("username", "manage")
    password = params.get("password", "!manage")
    protocol = params.get("protocol", "https")

    session_key = _get_session_key(ctx, protocol, host, username, password)
    if session_key == "":
        msg = "cannot authenticate to HP MSA at " + host
        if params.get("_discover"):
            return {"changed": False, "msg": msg, "data": {"discovery": []}}
        return {"changed": False, "msg": msg,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    xml = _query_disks_xml(ctx, protocol, host, session_key)
    if xml == "":
        msg = "no response querying disks on " + host
        if params.get("_discover"):
            return {"changed": False, "msg": msg, "data": {"discovery": []}}
        return {"changed": False, "msg": msg,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    disks = _parse_disks(xml)

    if params.get("_discover"):
        discovery = [
            {"item": d["id"], "params": {}, "metrics": []}
            for d in disks
        ]
        return {
            "changed": False,
            "msg": "discovered %d disks" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    target = None
    for d in disks:
        if d["id"] == item:
            target = d
            break

    if target == None:
        return {
            "changed": False,
            "msg": "disk not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state = HEALTH_MAP.get(target["health_num"], "UNKNOWN")
    health_text = target["health"] if target["health"] else "Unknown"
    msg = "%s: %s" % (item, health_text)

    details_parts = []
    if target["reason"]:
        details_parts.append("Reason: " + target["reason"])
    if target["recommendation"]:
        details_parts.append("Recommendation: " + target["recommendation"])
    details = "; ".join(details_parts)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {},
            "details": details,
        },
    }
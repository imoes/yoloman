# hp_msa_psu.star — HP MSA Power Supply Health Check
# Translates: cmk/plugins/hp_msa/agent_based/hp_msa_psu.py (health sub-check)
# Data source: HP MSA HTTP API (JSON), endpoint /api/show/power-supplies
# Params: host (required), username (default: monitor), password (required),
#         verify_ssl (default: false), item (check mode), _discover (discovery mode)

HEALTH_STATE = {
    "0": "OK",
    "1": "WARN",
    "2": "CRIT",
}

def _md5hex(ctx, value):
    res = ctx.run(
        ["python3", "-c",
         "import hashlib, sys; print(hashlib.md5(sys.argv[1].encode()).hexdigest())",
         value],
        mutates=False,
    )
    if res.rc != 0:
        fail("md5hex requires python3: " + res.stderr)
    return res.stdout.strip()

def _msa_get(ctx, host, path, session_key, verify_ssl):
    if verify_ssl:
        args = ["curl", "-s", "-m", "30",
                "-H", "sessionKey: " + session_key,
                "-H", "dataType: json",
                "https://" + host + path]
    else:
        args = ["curl", "-k", "-s", "-m", "30",
                "-H", "sessionKey: " + session_key,
                "-H", "dataType: json",
                "https://" + host + path]
    return ctx.run(args, mutates=False)

def _build_session_key(ctx, username, password):
    md5_pw = _md5hex(ctx, password)
    return _md5hex(ctx, username + "_" + md5_pw)

def _api_error(raw):
    status_list = raw.get("status", [])
    if not status_list:
        return ""
    first = status_list[0]
    rc = first.get("return-code", 0)
    if rc != 0:
        return first.get("response", "API error (return-code %s)" % str(rc))
    return ""

def main(ctx, params):
    host = params.get("host", "")
    username = params.get("username", "monitor")
    password = params.get("password", "")
    verify_ssl = params.get("verify_ssl", False)

    if host == "":
        fail("host parameter is required")
    if password == "":
        fail("password parameter is required")

    session_key = _build_session_key(ctx, username, password)

    login_res = _msa_get(ctx, host, "/api/login/" + session_key, session_key, verify_ssl)
    if login_res.rc != 0:
        return {
            "changed": False,
            "msg": "HP MSA API unreachable: " + login_res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    psu_res = _msa_get(ctx, host, "/api/show/power-supplies", session_key, verify_ssl)
    if psu_res.rc != 0:
        return {
            "changed": False,
            "msg": "Failed to fetch PSU data: " + psu_res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    body = psu_res.stdout.strip() if psu_res.stdout else ""
    if not body or not body.startswith("{"):
        return {
            "changed": False,
            "msg": "Unexpected response from HP MSA API (not JSON)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    raw = json.decode(body)

    api_err = _api_error(raw)
    if api_err != "":
        return {
            "changed": False,
            "msg": "HP MSA API: " + api_err,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    psus = raw.get("power-supplies", [])
    if type(psus) != "list":
        psus = []

    if params.get("_discover"):
        found = []
        for psu in psus:
            durable_id = psu.get("durable-id", "")
            if durable_id == "":
                continue
            found.append({
                "item": durable_id,
                "params": {},
                "metrics": [],
            })
        return {
            "changed": False,
            "msg": "discovered %d power supplies" % len(found),
            "data": {"discovery": found},
        }

    item = params.get("item", "")
    target = None
    for psu in psus:
        if psu.get("durable-id", "") == item:
            target = psu
            break

    if target == None:
        return {
            "changed": False,
            "msg": "Power supply '%s' not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    health = target.get("health", "Unknown")
    health_num = str(target.get("health-numeric", "0"))
    health_reason = target.get("health-reason", "")
    health_rec = target.get("health-recommendation", "")
    status = target.get("status", "")
    psu_name = target.get("name", item)

    state = HEALTH_STATE.get(health_num, "CRIT")

    parts = [psu_name + ": " + health]
    if status and status != health:
        parts.append("Status: " + status)
    if health_reason:
        parts.append(health_reason)
    summary = ", ".join(parts)

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {},
            "details": health_rec,
        },
    }
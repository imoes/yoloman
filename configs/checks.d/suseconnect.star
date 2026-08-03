# suseconnect check — reads SUSE registration data from /etc/SUSEconnect and
# subscription data from `SUSEConnect` CLI, grading SLES license status.
# READ-ONLY: never mutates=True, never ctx.file_write, always changed=False.

def _parse_suseconnect_file(ctx, path):
    if not ctx.file_exists(path):
        return {}
    content = ctx.file_read(path)
    lines = content.splitlines()
    if len(lines) == 0:
        return {}
    first = lines[0].split(":")[0].strip()
    if first == "identifier":
        return _parse_pre_v15(lines)
    return _parse_v15(lines)

def _join_line(toks):
    return ":".join(toks).strip()

def _parse_header(h):
    inner = h[1:-1]
    fields = inner.split("/")
    keys = ["identifier", "version", "architecture"]
    out = {}
    for i in range(len(keys)):
        if i < len(fields):
            out[keys[i]] = fields[i]
        else:
            out[keys[i]] = ""
    return out

def _parse_v15(lines):
    map_keys = {
        "Regcode": "registration_code",
        "Starts at": "starts_at",
        "Expires at": "expires_at",
        "Status": "subscription_status",
        "Type": "subscription_type",
    }
    parsed = {}
    specs = {}
    pending_reg = False
    for raw in lines:
        toks = raw.split(":")
        toks = [t.strip() for t in toks]
        if len(toks) == 0 or toks[0] == "":
            continue
        if toks[0].startswith("(") and toks[0].endswith(")"):
            hdr = _parse_header(toks[0])
            specs = parsed.setdefault(hdr["identifier"], dict(hdr))
            pending_reg = True
            continue
        if pending_reg:
            specs["registration_status"] = _join_line(toks)
            pending_reg = False
            continue
        if len(toks) > 1:
            key = toks[0]
            if key in map_keys:
                specs[map_keys[key]] = _join_line(toks[1:])
    return parsed

def _parse_pre_v15(lines):
    map_keys = {
        "identifier": "identifier",
        "version": "version",
        "arch": "architecture",
        "status": "registration_status",
        "type": "subscription_type",
        "starts_at": "starts_at",
        "expires_at": "expires_at",
        "subscription_status": "subscription_status",
        "regcode": "registration_code",
    }
    parsed = {}
    for raw in lines:
        toks = raw.split(":")
        toks = [t.strip() for t in toks]
        if len(toks) == 0 or toks[0] == "":
            continue
        key = toks[0]
        if key in map_keys and len(toks) > 1:
            parsed[map_keys[key]] = _join_line(toks[1:])
    if "identifier" in parsed:
        return {parsed["identifier"]: parsed}
    return {}

def _get_data(section):
    for key in section:
        value = section[key]
        if "SLES" in key:
            return value
    return None

def _now_epoch(ctx):
    res = ctx.run(["date", "+%s"], mutates=False)
    if res.rc != 0:
        return None
    s = res.stdout.strip()
    if not s.isdigit():
        return None
    return int(s)

def _to_epoch(ctx, date_str):
    res = ctx.run(["date", "-d", date_str, "+%s"], mutates=False)
    if res.rc != 0:
        return None
    s = res.stdout.strip()
    if not s.isdigit():
        return None
    return int(s)

def _days_left(ctx, expires_at, now):
    epoch = _to_epoch(ctx, expires_at)
    if epoch == None or now == None:
        return None
    return float(epoch - now)

def _grade_days(days, days_left_param):
    warn = days_left_param[0]
    crit = days_left_param[1]
    if days == None:
        return "UNKNOWN"
    if days < crit:
        return "CRIT"
    if days < warn:
        return "WARN"
    return "OK"

def _normalize_cli(decoded):
    out = {}
    items = decoded if type(decoded) == "list" else [decoded]
    for entry in items:
        if type(entry) != "dict":
            continue
        ident = entry.get("identifier", entry.get("product", ""))
        if "SLES" not in str(ident):
            continue
        specs = {}
        specs["identifier"] = ident
        specs["version"] = str(entry.get("version", ""))
        specs["architecture"] = str(entry.get("arch", ""))
        if entry.get("register"):
            specs["registration_status"] = "Registered"
        else:
            specs["registration_status"] = "Not Registered"
        specs["subscription_status"] = str(entry.get("subscription_status", ""))
        specs["subscription_type"] = str(entry.get("subscription_type", ""))
        specs["registration_code"] = str(entry.get("regcode", ""))
        specs["starts_at"] = str(entry.get("starts_at", ""))
        specs["expires_at"] = str(entry.get("expires_at", ""))
        out[ident] = specs
    return out

def _gather_data(ctx):
    path = "/etc/SUSEconnect"
    if ctx.file_exists(path):
        return _parse_suseconnect_file(ctx, path)
    res = ctx.run(["SUSEConnect", "--status", "--json"], mutates=False)
    if res.rc == 0 and res.stdout.strip():
        decoded = json.decode(res.stdout.strip())
        return _normalize_cli(decoded)
    return {}

def main(ctx, params):
    if params.get("_discover"):
        data = _gather_data(ctx)
        if _get_data(data) == None:
            return {"changed": False, "msg": "no SLES registration found",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered SLES license",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": []}]}}

    data = _gather_data(ctx)
    specs = _get_data(data)
    if specs == None:
        return {"changed": False, "msg": "no SLES registration found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    parts = []
    states = []

    status_param = params.get("status", "Registered")
    sub_param = params.get("subscription_status", "ACTIVE")
    days_left_param = params.get("days_left", (14.0, 7.0))

    if "registration_status" in specs:
        state, infotext = "OK", "Status: %s" % specs["registration_status"]
        if status_param != "Ignore" and status_param != specs["registration_status"]:
            state = "CRIT"
        parts.append(infotext)
        states.append(state)

    if "subscription_status" in specs:
        state, infotext = "OK", "Subscription: %s" % specs["subscription_status"]
        if sub_param != "Ignore" and sub_param != specs["subscription_status"]:
            state = "CRIT"
        parts.append(infotext)
        states.append(state)

    if ("subscription_type" in specs and "registration_code" in specs
            and "starts_at" in specs and "expires_at" in specs):
        sub_type = specs["subscription_type"]
        reg_code = specs["registration_code"]
        starts_at = specs["starts_at"]
        expires_at = specs["expires_at"]
        parts.append("Subscription type: %s, Registration code: %s, Starts at: %s, Expires at: %s" % (sub_type, reg_code, starts_at, expires_at))
        now = _now_epoch(ctx)
        days = _days_left(ctx, expires_at, now)
        if days == None:
            states.append("UNKNOWN")
        elif days > 0:
            grade = _grade_days(days, days_left_param)
            states.append(grade)
        else:
            states.append("CRIT")

    overall = "OK"
    for st in states:
        if st == "CRIT":
            overall = "CRIT"
            break
        if st == "WARN" and overall != "CRIT":
            overall = "WARN"
        if st == "UNKNOWN":
            if overall not in ("CRIT", "WARN"):
                overall = "UNKNOWN"

    return {"changed": False, "msg": "; ".join(parts),
            "data": {"state": overall, "metrics": {}, "details": ""}}
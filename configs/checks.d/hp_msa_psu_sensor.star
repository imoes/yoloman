DEFAULT_LEVELS_12V_LOWER = (11.9, 11.8)
DEFAULT_LEVELS_12V_UPPER = (12.1, 12.2)
DEFAULT_LEVELS_5V_LOWER = (4.9, 4.8)
DEFAULT_LEVELS_5V_UPPER = (5.1, 5.2)
DEFAULT_LEVELS_33V_LOWER = (3.25, 3.20)
DEFAULT_LEVELS_33V_UPPER = (3.4, 3.45)

PSU_INDICATORS = ["dc12v", "dc5v", "dc33v", "dc12i", "dc5i", "dctemp"]

STATE_RANK = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}

def _parse_int(s):
    if not s:
        return 0
    neg = s.startswith("-")
    digits = s.lstrip("-")
    if not digits.isdigit():
        return 0
    v = int(digits)
    return -v if neg else v

def _login(ctx, host, username, password):
    res = ctx.run([
        "curl", "-sk", "--max-time", "10",
        "-u", username + ":" + password,
        "https://" + host + "/api/login",
    ], mutates=False)
    if res.rc != 0:
        return ""
    text = res.stdout
    search = 'name="response"'
    idx = text.find(search)
    if idx < 0:
        return ""
    tag_end = text.find(">", idx)
    if tag_end < 0:
        return ""
    tag_end += 1
    close = text.find("<", tag_end)
    if close <= tag_end:
        return ""
    return text[tag_end:close].strip()

def _fetch_psu_xml(ctx, host, session_key):
    res = ctx.run([
        "curl", "-sk", "--max-time", "15",
        "-H", "sessionKey: " + session_key,
        "https://" + host + "/api/show/power-supplies",
    ], mutates=False)
    if res.rc != 0:
        return ""
    return res.stdout

def _parse_psu_sections(xml_text):
    section = {}
    for obj_part in xml_text.split("<OBJECT")[1:]:
        if 'name="power-supplies"' not in obj_part:
            continue
        props = {}
        for pp in obj_part.split("<PROPERTY")[1:]:
            n_start = pp.find('name="')
            if n_start < 0:
                continue
            n_start += 6
            n_end = pp.find('"', n_start)
            if n_end < 0:
                continue
            prop_name = pp[n_start:n_end]
            v_start = pp.find(">")
            if v_start < 0:
                continue
            v_start += 1
            v_end = pp.find("<", v_start)
            if v_end < 0:
                continue
            props[prop_name] = pp[v_start:v_end].strip()
        item_name = props.get("name", "")
        if item_name:
            section[item_name] = props
    return section

def _worst(s1, s2):
    r1 = STATE_RANK.get(s1, 0)
    r2 = STATE_RANK.get(s2, 0)
    return s1 if r1 >= r2 else s2

def _check_voltage(value, label, lower_levels, upper_levels):
    lower_warn = lower_levels[0]
    lower_crit = lower_levels[1]
    upper_warn = upper_levels[0]
    upper_crit = upper_levels[1]
    if value <= lower_crit:
        state = "CRIT"
        hint = " (too low; crit at %f V)" % lower_crit
    elif value >= upper_crit:
        state = "CRIT"
        hint = " (too high; crit at %f V)" % upper_crit
    elif value <= lower_warn:
        state = "WARN"
        hint = " (too low; warn at %f V)" % lower_warn
    elif value >= upper_warn:
        state = "WARN"
        hint = " (too high; warn at %f V)" % upper_warn
    else:
        state = "OK"
        hint = ""
    return (state, "%s: %f V%s" % (label, value, hint))

def main(ctx, params):
    host = params.get("host", "localhost")
    username = params.get("username", "manage")
    password = params.get("password", "!manage")

    session_key = _login(ctx, host, username, password)
    if not session_key:
        if params.get("_discover"):
            return {
                "changed": False,
                "msg": "discovered 0 PSUs (login failed)",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "login failed for HP MSA at " + host,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    xml_text = _fetch_psu_xml(ctx, host, session_key)
    if not xml_text:
        if params.get("_discover"):
            return {
                "changed": False,
                "msg": "discovered 0 PSUs (fetch failed)",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "failed to fetch PSU data from " + host,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    section = _parse_psu_sections(xml_text)

    if params.get("_discover"):
        discovered = []
        for item_name in section:
            data = section[item_name]
            valid = False
            for ind in PSU_INDICATORS:
                if data.get(ind, "0") != "0":
                    valid = True
                    break
            if valid:
                discovered.append({
                    "item": item_name,
                    "params": {
                        "levels_12v_lower": DEFAULT_LEVELS_12V_LOWER,
                        "levels_12v_upper": DEFAULT_LEVELS_12V_UPPER,
                        "levels_5v_lower": DEFAULT_LEVELS_5V_LOWER,
                        "levels_5v_upper": DEFAULT_LEVELS_5V_UPPER,
                        "levels_33v_lower": DEFAULT_LEVELS_33V_LOWER,
                        "levels_33v_upper": DEFAULT_LEVELS_33V_UPPER,
                    },
                    "metrics": ["voltage_12v", "voltage_5v", "voltage_33v"],
                })
        return {
            "changed": False,
            "msg": "discovered %d PSUs" % len(discovered),
            "data": {"discovery": discovered},
        }

    item = params.get("item", "")
    data = section.get(item)
    if data == None:
        return {
            "changed": False,
            "msg": "PSU not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    levels_12v_lower = params.get("levels_12v_lower", DEFAULT_LEVELS_12V_LOWER)
    levels_12v_upper = params.get("levels_12v_upper", DEFAULT_LEVELS_12V_UPPER)
    levels_5v_lower = params.get("levels_5v_lower", DEFAULT_LEVELS_5V_LOWER)
    levels_5v_upper = params.get("levels_5v_upper", DEFAULT_LEVELS_5V_UPPER)
    levels_33v_lower = params.get("levels_33v_lower", DEFAULT_LEVELS_33V_LOWER)
    levels_33v_upper = params.get("levels_33v_upper", DEFAULT_LEVELS_33V_UPPER)

    dc12v = float(_parse_int(data.get("dc12v", "0"))) / 100.0
    dc5v = float(_parse_int(data.get("dc5v", "0"))) / 100.0
    dc33v = float(_parse_int(data.get("dc33v", "0"))) / 100.0

    state_12v, msg_12v = _check_voltage(dc12v, "12 V", levels_12v_lower, levels_12v_upper)
    state_5v, msg_5v = _check_voltage(dc5v, "5 V", levels_5v_lower, levels_5v_upper)
    state_33v, msg_33v = _check_voltage(dc33v, "3.3 V", levels_33v_lower, levels_33v_upper)

    overall = _worst(_worst(state_12v, state_5v), state_33v)
    summary = ", ".join([msg_12v, msg_5v, msg_33v])

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": overall,
            "metrics": {
                "voltage_12v": dc12v,
                "voltage_5v": dc5v,
                "voltage_33v": dc33v,
            },
            "details": "",
        },
    }
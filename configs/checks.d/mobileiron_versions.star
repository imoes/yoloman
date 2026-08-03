# MobileIron versions check — read-only Starlark check module for yolo-man agent
#
# Checkmk source: cmk/plugins/mobileiron/agent_based/mobileiron_versions.py
# Network-based special-agent check: data fetched over the MobileIron REST API.

DEFAULTS = {
    "patchlevel_unparsable": 0,
    "patchlevel_age": 7776000,
    "os_build_unparsable": 0,
    "os_age": 7776000,
    "ios_version_regexp": "",
    "android_version_regexp": "",
    "os_version_other": 0,
}

STATE_LABELS = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}
DAYS_IN_MONTH = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]


def _is_leap(year):
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0)


def _days_since_epoch(y, mo, d):
    days = 0
    for yr in range(1970, y):
        days = days + (366 if _is_leap(yr) else 365)
    for mi in range(1, mo):
        dim = DAYS_IN_MONTH[mi - 1]
        if mi == 2 and _is_leap(y):
            dim = 29
        days = days + dim
    days = days + (d - 1)
    return days * 86400


def _age_from_date(ctx, date_string):
    s = str(date_string)
    if len(s) >= 10:
        parts = s[:10].split("-")
        if len(parts) != 3:
            return None
        y_str, mo_str, d_str = parts
        if not (y_str.isdigit() and mo_str.isdigit() and d_str.isdigit()):
            return None
        start = _days_since_epoch(int(y_str), int(mo_str), int(d_str))
    else:
        return None
    res = ctx.run(["date", "+%s"], mutates=False)
    if res.rc != 0:
        return None
    now_s = res.stdout.strip()
    if not now_s.isdigit():
        return None
    now_epoch = int(now_s)
    return max(0, now_epoch - start)


def _grade_age(age, level_days, unparsable_state):
    if age == None:
        return unparsable_state
    if age >= level_days:
        return 2
    return 0


def _regex_match(pattern, text):
    special = False
    for c in [".", "*", "+", "?", "[", "]", "(", ")", "^", "$", "\\"]:
        if c in pattern:
            special = True
            break
    if not special:
        return pattern in text
    return pattern in text


def _os_version_check(section, user_regex):
    if not user_regex:
        return (0, "OS version: " + str(section.get("platform_version", "")))
    pv = str(section.get("platform_version", ""))
    match = _regex_match(user_regex, pv)
    if match:
        return (0, "OS version: " + pv)
    return (2, "OS version mismatch: " + pv)


def _section_from_device(dev):
    return {
        "os_build_version": dev.get("osBuildVersion"),
        "android_security_patch_level": dev.get("androidSecurityPatchLevel"),
        "platform_version": dev.get("platformVersion"),
        "client_version": dev.get("clientVersion"),
        "platform_type": dev.get("platformType"),
    }


def _fetch_devices(ctx, base_url, token):
    args = ["curl", "-fsSL", "-H", "Accept: application/json"]
    if token:
        args = args + ["-H", "Authorization: Bearer " + token]
    args.append(base_url)
    res = ctx.run(args, mutates=False)
    if res.rc != 0 or not res.stdout:
        return None
    data = json.decode(res.stdout)
    if type(data) == "dict" and "results" in data:
        return data["results"]
    if type(data) == "list":
        return data
    return None


def main(ctx, params):
    base_url = params.get("api_url", "")
    token = params.get("api_token", "")

    if params.get("_discover"):
        if not base_url:
            return {"changed": False, "msg": "no MobileIron API URL configured",
                    "data": {"discovery": []}}
        devices = _fetch_devices(ctx, base_url, token)
        if devices == None:
            return {"changed": False, "msg": "MobileIron API unreachable",
                    "data": {"discovery": []}}
        out = []
        for dev in devices:
            item = dev.get("deviceId") or dev.get("serialNumber") or dev.get("udid") or str(len(out))
            out.append({
                "item": str(item),
                "params": {k: params.get(k, DEFAULTS[k]) for k in DEFAULTS},
                "metrics": ["mobileiron_last_patched", "mobileiron_last_build"],
            })
        return {"changed": False, "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}

    if not base_url:
        return {"changed": False, "msg": "MobileIron API URL not configured",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    item = params.get("item", "")
    devices = _fetch_devices(ctx, base_url, token)
    if devices == None:
        return {"changed": False, "msg": "MobileIron API unreachable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    target = None
    for dev in devices:
        cand = dev.get("deviceId") or dev.get("serialNumber") or dev.get("udid")
        if str(cand) == str(item):
            target = dev
            break
    if target == None:
        return {"changed": False, "msg": "no such device: " + str(item),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    section = _section_from_device(target)
    metrics = {}
    details_parts = []

    cv = section.get("client_version")
    if cv:
        details_parts.append("Client version: " + str(cv))
    else:
        details_parts.append("Client version: unknown")

    patchlevel_age = params.get("patchlevel_age", DEFAULTS["patchlevel_age"])
    patchlevel_unparsable = params.get("patchlevel_unparsable", DEFAULTS["patchlevel_unparsable"])
    level_days = int(patchlevel_age)
    aspl = section.get("android_security_patch_level")
    state_patch = 0
    if aspl:
        age = _age_from_date(ctx, aspl)
        if age == None:
            state_patch = patchlevel_unparsable
            details_parts.append("Security patch level has an invalid date format: '" + str(aspl) + "'")
        else:
            state_patch = _grade_age(age, level_days, patchlevel_unparsable)
            metrics["mobileiron_last_patched"] = age
            details_parts.append("Security patch level is '" + str(aspl) + "'")

    os_age = params.get("os_age", DEFAULTS["os_age"])
    os_build_unparsable = params.get("os_build_unparsable", DEFAULTS["os_build_unparsable"])
    ob_level_days = int(os_age)
    obv = section.get("os_build_version")
    state_build = 0
    if obv:
        age_b = _age_from_date(ctx, obv)
        if age_b == None:
            state_build = os_build_unparsable
            details_parts.append("OS build version has an invalid date format: '" + str(obv) + "'")
        else:
            state_build = _grade_age(age_b, ob_level_days, os_build_unparsable)
            metrics["mobileiron_last_build"] = age_b
            details_parts.append("OS build version is '" + str(obv) + "'")

    pt = section.get("platform_type")
    state_os = 0
    if pt == "ANDROID":
        regex = params.get("android_version_regexp", DEFAULTS["android_version_regexp"])
        state_os, msg_os = _os_version_check(section, regex)
        details_parts.append(msg_os)
    elif pt == "IOS":
        regex = params.get("ios_version_regexp", DEFAULTS["ios_version_regexp"])
        state_os, msg_os = _os_version_check(section, regex)
        details_parts.append(msg_os)
    else:
        state_os = params.get("os_version_other", DEFAULTS["os_version_other"])
        details_parts.append("OS version: " + str(section.get("platform_version", "")))

    worst = 0
    if aspl:
        if state_patch > worst:
            worst = state_patch
    if state_build > worst:
        worst = state_build
    if state_os > worst:
        worst = state_os

    msg = "; ".join(details_parts)
    return {"changed": False, "msg": msg,
            "data": {"state": STATE_LABELS.get(worst, "UNKNOWN"),
                     "metrics": metrics,
                     "details": "\n".join(details_parts)}}
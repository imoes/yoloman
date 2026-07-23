DAYS_IN_MONTH = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

STATE_ORDER = {"OK": 0, "WARN": 1, "UNKNOWN": 2, "CRIT": 3}

def _is_leap(year):
    return (year % 4 == 0) and ((year % 100 != 0) or (year % 400 == 0))

def _dim(month, year):
    if month == 2 and _is_leap(year):
        return 29
    return DAYS_IN_MONTH[month - 1]

def _date_to_epoch(year, month, day):
    days = 0
    for y in range(1970, year):
        days += 366 if _is_leap(y) else 365
    for m in range(1, month):
        days += _dim(m, year)
    days += day - 1
    return days * 86400

def _parse_date(s):
    s = str(s)
    if len(s) >= 10 and s[4] == "-" and s[7] == "-":
        ys, ms, ds = s[0:4], s[5:7], s[8:10]
        if ys.isdigit() and ms.isdigit() and ds.isdigit():
            y, m, d = int(ys), int(ms), int(ds)
            if (1 <= m) and (m <= 12) and (1 <= d) and (d <= 31):
                return _date_to_epoch(y, m, d)
    if len(s) >= 6 and s[0:6].isdigit():
        y = 2000 + int(s[0:2])
        m, d = int(s[2:4]), int(s[4:6])
        if (1 <= m) and (m <= 12) and (1 <= d) and (d <= 31):
            return _date_to_epoch(y, m, d)
    return -1

def _int_to_state(n):
    if n == 2:
        return "CRIT"
    if n == 1:
        return "WARN"
    if n == 3:
        return "UNKNOWN"
    return "OK"

def _worse(a, b):
    return a if STATE_ORDER.get(a, 0) >= STATE_ORDER.get(b, 0) else b

def _str_val(d, key):
    v = d.get(key)
    return str(v) if v != None else ""

def _query_device(ctx, params):
    host        = params.get("host", "localhost")
    user        = params.get("user", "")
    password    = params.get("password", "")
    port        = str(params.get("port", 443))
    device_uuid = params.get("device_uuid", "")
    url = "https://%s:%s/api/v1/device/%s" % (host, port, device_uuid)
    res = ctx.run([
        "curl", "-sk", "--max-time", "30",
        "-u", user + ":" + password,
        "-H", "Accept: application/json",
        url,
    ], mutates=False)
    if res.rc != 0:
        return None
    body = res.stdout.strip()
    if not body or not body.startswith("{"):
        return None
    data = json.decode(body)
    if data == None:
        return None
    result = data.get("result")
    if result != None:
        hits = result.get("searchResults")
        if hits != None and len(hits) > 0:
            return hits[0]
        return result
    return data

def main(ctx, params):
    patchlevel_unparsable = params.get("patchlevel_unparsable", 0)
    patchlevel_age        = params.get("patchlevel_age", 7776000)
    os_build_unparsable   = params.get("os_build_unparsable", 0)
    os_age                = params.get("os_age", 7776000)
    ios_regexp            = params.get("ios_version_regexp", "")
    android_regexp        = params.get("android_version_regexp", "")
    os_version_other      = params.get("os_version_other", 0)

    if params.get("_discover"):
        dev = _query_device(ctx, params)
        if dev == None:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 items",
                "data": {"discovery": [{"item": "",
                    "params": {
                        "patchlevel_unparsable": 0,
                        "patchlevel_age": 7776000,
                        "os_build_unparsable": 0,
                        "os_age": 7776000,
                        "ios_version_regexp": "",
                        "android_version_regexp": "",
                        "os_version_other": 0,
                    },
                    "metrics": ["mobileiron_last_patched", "mobileiron_last_build"],
                }]}}

    ts_res = ctx.run(["date", "+%s"], mutates=False)
    now = 0
    if ts_res.rc == 0:
        ts = ts_res.stdout.strip()
        if ts.isdigit():
            now = int(ts)

    dev = _query_device(ctx, params)
    if dev == None:
        return {"changed": False, "msg": "MobileIron device data unavailable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    client_version   = _str_val(dev, "clientVersion")
    android_patch    = _str_val(dev, "androidSecurityPatchLevel")
    os_build         = _str_val(dev, "osBuildVersion")
    platform_version = _str_val(dev, "platformVersion")
    platform_type    = _str_val(dev, "platformType")

    state = "OK"
    summary_parts = ["Client version: " + (client_version if client_version else "unknown")]
    details_parts = []
    metrics = {}

    if android_patch:
        epoch = _parse_date(android_patch)
        if epoch < 0:
            state = _worse(state, _int_to_state(patchlevel_unparsable))
            summary_parts.append("Security patch level has an invalid date format: '%s'" % android_patch)
        else:
            age = (now - epoch) if now > epoch else 0
            metrics["mobileiron_last_patched"] = age
            label = "Security patch level is '%s'" % android_patch
            if age >= patchlevel_age:
                state = _worse(state, "CRIT")
                summary_parts.append(label + " (too old)")
            else:
                summary_parts.append(label)

    if os_build:
        epoch = _parse_date(os_build)
        if epoch < 0:
            state = _worse(state, _int_to_state(os_build_unparsable))
            details_parts.append("OS build version has an invalid date format: '%s'" % os_build)
        else:
            age = (now - epoch) if now > epoch else 0
            metrics["mobileiron_last_build"] = age
            details_parts.append("OS build version is '%s'" % os_build)
            if age >= os_age:
                state = _worse(state, "CRIT")

    if platform_type == "ANDROID":
        if android_regexp and str(platform_version).find(android_regexp) < 0:
            state = _worse(state, "CRIT")
            summary_parts.append("OS version mismatch: " + platform_version)
        else:
            details_parts.append("OS version: " + platform_version)
    elif platform_type == "IOS":
        if ios_regexp and str(platform_version).find(ios_regexp) < 0:
            state = _worse(state, "CRIT")
            summary_parts.append("OS version mismatch: " + platform_version)
        else:
            details_parts.append("OS version: " + platform_version)
    else:
        state = _worse(state, _int_to_state(os_version_other))
        summary_parts.append("OS version: " + platform_version)

    return {
        "changed": False,
        "msg": ", ".join(summary_parts),
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "\n".join(details_parts),
        },
    }
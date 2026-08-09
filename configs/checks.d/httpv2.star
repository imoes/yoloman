# Checkmk httpv2 active check → read-only Starlark check module
# Monitors HTTP/HTTPS endpoints by invoking curl and grading the response.

def _curl_cmd(params, item):
    args = ["curl", "-sS", "-o", "/dev/null", "-w", "%{http_code} %{time_total}"]
    args.append("-w")
    args.append(" %{ssl_verify_result}")
    args.append("--connect-timeout")
    args.append("10")
    args.append("--max-time")
    args.append("30")
    url = item
    args.append(url)
    return args


def main(ctx, params):
    if params.get("_discover"):
        endpoints = params.get("endpoints", [])
        if not endpoints or type(endpoints) != "list":
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}

        host_config = params.get("host_config", {})
        macros = host_config.get("macros", {})

        discovery = []
        for ep in endpoints:
            url = ep.get("url", "")
            settings = ep.get("settings", {})
            if type(settings) != "dict":
                settings = {}

            svc_name_desc = ep.get("service_name", {})
            name = svc_name_desc.get("name", url) if type(svc_name_desc) == "dict" else url
            prefix = svc_name_desc.get("prefix", "none") if type(svc_name_desc) == "dict" else "none"

            protocol = "HTTPS" if url.startswith("https://") else "HTTP"
            desc = ""
            if prefix == "auto":
                desc = protocol + " " + name
            elif prefix == "none":
                desc = name
            else:
                desc = name

            rt_levels = settings.get("response_time", None)
            warn = 2.0
            crit = 5.0
            if rt_levels != None and type(rt_levels) == "list" and len(rt_levels) == 2:
                if rt_levels[0] == "fixed":
                    lvls = rt_levels[1]
                    if type(lvls) == "list" and len(lvls) == 2:
                        warn = float(lvls[0])
                        crit = float(lvls[1])

            discovery.append({
                "item": url,
                "params": {"warn": warn, "crit": crit},
                "metrics": ["response_time", "status_code"],
            })

        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    # CHECK MODE
    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    url = item

    warn = params.get("warn", 2.0)
    crit = params.get("crit", 5.0)

    curl_args = ["-sS", "-o", "/dev/null", "-w", "%{http_code} %{time_total} %{ssl_verify_result}",
                 "--connect-timeout", "10", "--max-time", "30", url]

    res = ctx.run(["curl"] + curl_args, mutates=False)

    if res.rc == 127:
        return {"changed": False, "msg": "curl is not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if res.skipped:
        return {"changed": False, "msg": "would check " + url,
                "data": {"state": "OK", "metrics": {}, "details": ""}}

    if res.rc != 0:
        return {"changed": False, "msg": "curl failed: " + res.stderr.strip(),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stderr.strip()}}

    parts = res.stdout.strip().split()
    if len(parts) < 2:
        return {"changed": False, "msg": "no response from " + url,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stdout.strip()}}

    status_code = 0
    if parts[0].isdigit():
        status_code = int(parts[0])

    resp_time = 0.0
    if parts[1].replace(".", "").isdigit():
        resp_time = float(parts[1])

    metrics = {"response_time": resp_time, "status_code": status_code}

    details = "URL: %s, HTTP Status: %d, Response Time: %fs" % (url, status_code, resp_time)

    if status_code == 0:
        state = "UNKNOWN"
        msg = "no response from " + url
    elif status_code >= 400:
        state = "CRIT"
        msg = "%s returned HTTP %d" % (url, status_code)
    elif status_code >= 300:
        state = "WARN"
        msg = "%s returned HTTP %d (redirect)" % (url, status_code)
    else:
        if resp_time >= crit:
            state = "CRIT"
        elif resp_time >= warn:
            state = "WARN"
        else:
            state = "OK"
        msg = "%s: HTTP %d, %fs" % (url, status_code, resp_time)

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": metrics, "details": details},
    }
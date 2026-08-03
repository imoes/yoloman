def main(ctx, params):
    if params.get("_discover"):
        return discover(ctx, params)
    return check(ctx, params)


def discover(ctx, params):
    res = ctx.run(["citrixctx", "--version"], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "Citrix controller not installed",
                "data": {"discovery": []}}
    if res.rc != 0:
        return {"changed": False, "msg": "unable to determine Citrix controller state",
                "data": {"discovery": []}}
    state = query_active_site_services(ctx, params)
    if state == None:
        return {"changed": False, "msg": "no Citrix Active Site Services data",
                "data": {"discovery": []}}
    return {"changed": False, "msg": "discovered Citrix Active Site Services",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}}


def check(ctx, params):
    res = ctx.run(["citrixctx", "--version"], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "Citrix controller not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.rc != 0:
        return {"changed": False, "msg": "unable to determine Citrix controller state",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    services = query_active_site_services(ctx, params)
    if services == None:
        return {"changed": False, "msg": "No Citrix Active Site Services data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    txt = services if services else "No services"
    return {"changed": False, "msg": txt,
            "data": {"state": "OK", "metrics": {}, "details": ""}}


def query_active_site_services(ctx, params):
    res = ctx.run(["citrixctx", "list-siteservices"], mutates=False)
    if res.rc != 0:
        return None
    return strip_type_tag(res.stdout)


def strip_type_tag(s):
    idx = s.find(": ")
    if idx != -1:
        s = s[idx + 2:]
    s = s.strip()
    if len(s) >= 2 and s[0] == "\"" and s[len(s) - 1] == "\"":
        s = s[1:len(s) - 1]
    return s
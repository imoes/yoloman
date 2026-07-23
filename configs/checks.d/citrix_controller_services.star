def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/opt/citrix/agent/state"], mutates=False)
        section = parse_citrix_controller(res.stdout.splitlines() if res.stdout else [])
        if section.get("active_site_services") != None:
            return {
                "changed": False,
                "msg": "discovered 1 service",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": []}
                ]},
            }
        return {
            "changed": False,
            "msg": "discovered 0 services",
            "data": {"discovery": []},
        }

    # Check mode (non-discovery)
    res = ctx.run(["cat", "/opt/citrix/agent/state"], mutates=False)
    section = parse_citrix_controller(res.stdout.splitlines() if res.stdout else [])
    services = section.get("active_site_services")
    summary = services if services != None else "No services"
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": "OK",
            "metrics": {},
            "details": "",
        },
    }


def parse_citrix_controller(lines):
    section = {
        "active_site_services": None,
    }
    for line in lines:
        parts = line.strip().split(None, 1)
        if len(parts) < 1:
            continue
        key = parts[0]
        value = parts[1] if len(parts) > 1 else ""
        if key == "ActiveSiteServices":
            section["active_site_services"] = value
    return section

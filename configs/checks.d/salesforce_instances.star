_STATUS_MAP = {
    "OK": ("OK", "OK"),
    "MAJOR_INCIDENT_CORE": ("CRIT", "major incident core"),
    "MINOR_INCIDENT_CORE": ("WARN", "minor incident core"),
    "MAINTENANCE_CORE": ("OK", "maintenance core"),
    "INFORMATIONAL_CORE": ("OK", "informational core"),
    "MAJOR_INCIDENT_NONCORE": ("CRIT", "major incident noncore"),
    "MINOR_INCIDENT_NONCORE": ("WARN", "minor incident noncore"),
    "MAINTENANCE_NONCORE": ("OK", "maintenance noncore"),
    "INFORMATIONAL_NONCORE": ("OK", "informational noncore"),
}


def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/var/lib/check-mk-agent/local/salesforce_instances"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        section = {}
        for line in res.stdout.splitlines():
            if line.strip():
                if not json.decode(line).get("key"):
                    continue
                entry = json.decode(line)
                section.setdefault(entry["key"], entry)
        out = []
        for instance, attrs in section.items():
            if attrs.get("isActive"):
                out.append({"item": instance, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    res = ctx.run(["cat", "/var/lib/check-mk-agent/local/salesforce_instances"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "no data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    section = {}
    for line in res.stdout.splitlines():
        if line.strip():
            if not json.decode(line).get("key"):
                continue
            entry = json.decode(line)
            section.setdefault(entry["key"], entry)

    if item not in section:
        return {"changed": False, "msg": "instance not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = section[item]
    status = data.get("status")
    state, state_readable = _STATUS_MAP.get(status, ("UNKNOWN", "unknown[" + str(status) + "]"))

    summaries = ["Status: " + state_readable]
    for key, title in [
        ("environment", "Environment"),
        ("releaseNumber", "Release Number"),
        ("releaseVersion", "Release Version"),
    ]:
        if data.get(key):
            summaries.append(title + ": " + str(data[key]))

    return {"changed": False, "msg": ", ".join(summaries),
            "data": {"state": state, "metrics": {}, "details": ""}}
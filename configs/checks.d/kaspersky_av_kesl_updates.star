def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["kesl-control", "--status"], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []},
            }
        section = {}
        for line in res.stdout.splitlines():
            if ":" in line:
                k, v = line.split(":", 1)
                key = k.strip()
                value = v.strip()
                section[key] = value
        if section:
            return {
                "changed": False,
                "msg": "discovered 1 item",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
            }
        return {
            "changed": False,
            "msg": "discovered 0 items",
            "data": {"discovery": []},
        }

    res = ctx.run(["kesl-control", "--status"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "unable to query Kaspersky status",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    section = {}
    for line in res.stdout.splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            key = k.strip()
            value = v.strip()
            section[key] = value

    loaded_raw = section.get("Anti-virus databases loaded") or section.get("Application databases loaded")
    loaded = loaded_raw == "Yes"
    state = "OK" if loaded else "CRIT"
    msg_parts = ["Databases loaded: %s" % str(loaded)]

    release_date = section.get("Last release date of databases")
    if release_date != None and release_date != "":
        parts = release_date.split(" ")
        if len(parts) == 2:
            date_part = parts[0]
            time_part = parts[1]
            msg_parts.append("Database date: %s %s" % (date_part, time_part))

    records = section.get("Anti-virus database records")
    if records != None and records != "":
        msg_parts.append("Database records: %s" % records)

    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }
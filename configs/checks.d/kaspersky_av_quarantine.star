def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["which", "kesl"], mutates=False)
        if res.rc != 0:
            res = ctx.run(["which", "klnagchk"], mutates=False)
            if res.rc != 0:
                res = ctx.run(["which", "kav_main"], mutates=False)
                if res.rc != 0:
                    return {"changed": False, "msg": "no kaspersky av found",
                            "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": ["Objects"]}]}}

    item = params.get("item", "")

    res = ctx.run(["which", "kesl"], mutates=False)
    is_kesl = res.rc == 0
    if not is_kesl:
        res = ctx.run(["which", "klnagchk"], mutates=False)
        is_klnagchk = res.rc == 0
        if not is_klnagchk:
            res = ctx.run(["which", "kav_main"], mutates=False)
            is_kav = res.rc == 0
            if not is_kav:
                return {"changed": False,
                        "msg": "no kaspersky av found",
                        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    quarantine_file = "/var/log/kaspersky/kesl/quarantine"
    if ctx.file_exists(quarantine_file):
        content = ctx.file_read(quarantine_file)
    else:
        content = ""

    if content:
        section = {}
        for line in content.splitlines():
            parts = line.split(":", 1)
            if len(parts) == 2:
                section[parts[0].strip()] = parts[1].strip()
        if section:
            objects = 0
            if "Objects" in section:
                val = section["Objects"].strip()
                if val.isdigit():
                    objects = int(val)
            last_added = section.get("Last added", "unknown").strip()
            if objects > 0:
                state = "CRIT"
                summary = "%d Objects in Quarantine, Last added: %s" % (objects, last_added)
            else:
                state = "OK"
                summary = "No objects in Quarantine"
            return {"changed": False, "msg": summary,
                    "data": {"state": state,
                             "metrics": {"Objects": objects},
                             "details": ""}}

    res = ctx.run(["kesl", "status", "--quarantine"], mutates=False)
    if res.rc != 0:
        res = ctx.run(["klnagchk"], mutates=False)
        if res.rc != 0:
            return {"changed": False,
                    "msg": "could not retrieve quarantine data",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    section = {}
    for line in res.stdout.splitlines():
        stripped = line.strip()
        if ":" in stripped:
            parts = stripped.split(":", 1)
            section[parts[0].strip()] = parts[1].strip()

    if not section:
        return {"changed": False,
                "msg": "no quarantine data found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    objects = 0
    if "Objects" in section:
        val = section["Objects"].strip()
        if val.isdigit():
            objects = int(val)
    last_added = section.get("Last added", "unknown").strip()

    if objects > 0:
        state = "CRIT"
        summary = "%d Objects in Quarantine, Last added: %s" % (objects, last_added)
    else:
        state = "OK"
        summary = "No objects in Quarantine"

    return {"changed": False, "msg": summary,
            "data": {"state": state,
                     "metrics": {"Objects": objects},
                     "details": ""}}
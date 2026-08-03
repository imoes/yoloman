def main(ctx, params):
    if params.get("_discover"):
        # Probe for Informix presence via onstat
        res = ctx.run(["onstat", "-V"], mutates=False)
        if res.rc == 127 or res.rc != 0:
            return {"changed": False, "msg": "no informix found",
                    "data": {"discovery": []}}

        # Gather instances - onstat -d lists databases and dbspaces
        res = ctx.run(["onstat", "-d"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "onstat -d failed",
                    "data": {"discovery": []}}

        instances = []
        # Parse onstat -d output to find the current instance name
        for line in res.stdout.splitlines():
            if line.find(" Informix Server") != -1 and line.find("Code") != -1:
                # e.g. "myserver      Informix Server Version 14.10  Code..."
                parts = line.split()
                if len(parts) >= 1:
                    instances.append(parts[0])

        discovery = []
        levels = params.get("levels", (40, 70))
        for inst in instances:
            discovery.append({"item": inst, "params": {"levels": list(levels)},
                            "metrics": ["max_extents"]})

        return {"changed": False, "msg": "discovered %d informix instances" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")

    # Verify Informix is present
    res = ctx.run(["onstat", "-V"], mutates=False)
    if res.rc == 127 or res.rc != 0:
        return {"changed": False, "msg": "no informix instance found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Gather table extent data using onstat -pe (tbcleanup / extend info)
    # onstat -k lists tables; we use onstat -p to get partition/extents info
    # The most direct source for table extents is the informix system catalog
    # or onstat -d extended output, but the canonical source matching the
    # check plugin is parsing the informix table extents from onstat -pe
    #
    # We reproduce the same data structure: per database/table entry with
    # db, tab, extents, nrows fields

    res = ctx.run(["onstat", "-pe"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "onstat -pe failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    section = _parse_onstat_pe(res.stdout, item)
    if not section.get(item, []):
        return {"changed": False, "msg": "instance %s not found in extents data" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    max_extents = -1
    long_output = []
    for entry in section[item]:
        ext_val = entry.get("extents", "0")
        max_extents = max(max_extents, int(ext_val) if ext_val.isdigit() else 0)
        long_output.append("[%s/%s] Extents: %s, Rows: %s" %
                           (entry.get("db", ""), entry.get("tab", ""),
                            entry.get("extents", ""), entry.get("nrows", "")))

    levels = params.get("levels", (40, 70))
    warn = levels[0] if len(levels) > 0 else 40
    crit = levels[1] if len(levels) > 1 else 70

    state = "CRIT" if max_extents >= crit else ("WARN" if max_extents >= warn else "OK")

    return {"changed": False,
            "msg": "Maximal extents: %d" % max_extents,
            "data": {"state": state, "metrics": {"max_extents": max_extents},
                     "details": "\n".join(long_output)}}


def _parse_onstat_pe(stdout, target_instance):
    """Parse onstat -pe output into a section structure matching the Checkmk plugin.

    onstat -pe produces lines like:
      <db>/<tab>   extents   nrows
    prefixed by instance markers.
    """
    parsed = {}
    lines = stdout.splitlines()
    current_instance = target_instance

    if not current_instance:
        current_instance = ""

    parsed.setdefault(current_instance, [])
    entry = None
    current_db = ""
    current_tab = ""

    for line in lines:
        stripped = line.strip()
        if len(stripped) == 0:
            continue

        parts = stripped.split()
        if len(parts) >= 4:
            # Format: <db>/<tab> extents nrows <other>
            name = parts[0]
            if name.find("/") != -1:
                db_tab = name.split("/")
                current_db = db_tab[0]
                current_tab = db_tab[1] if len(db_tab) > 1 else ""
            else:
                current_db = name
                current_tab = ""

            entry = {
                "db": current_db,
                "tab": current_tab,
                "extents": parts[1] if len(parts) > 1 else "0",
                "nrows": parts[2] if len(parts) > 2 else "0",
            }
            parsed[current_instance].append(entry)

    return parsed
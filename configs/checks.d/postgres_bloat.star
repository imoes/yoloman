def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/var/lib/postgres/agent_bloat"], mutates=False)
        lines = res.stdout.splitlines()
        db_list = []
        in_database_section = False
        for line in lines:
            stripped = line.strip()
            if stripped == "[databases_start]":
                in_database_section = True
                continue
            if stripped == "[databases_end]":
                in_database_section = False
                continue
            if in_database_section and stripped:
                db_list.append(stripped)

        db_map = {}
        current_db = ""
        for line in lines:
            stripped = line.strip()
            if stripped == "[databases_start]":
                current_db = ""
                continue
            if stripped == "[databases_end]":
                current_db = ""
                continue
            if stripped.startswith("db;"):
                continue
            if stripped in db_list:
                current_db = stripped
                db_map[current_db] = []
                continue
            if current_db and stripped and not stripped.startswith("["):
                db_map[current_db].append(stripped)

        discovery = []
        for db_name, rows in db_map.items():
            if rows:
                discovery.append({
                    "item": db_name,
                    "params": {
                        "table_bloat_perc": (180.0, 200.0),
                        "index_bloat_perc": (180.0, 200.0),
                    },
                    "metrics": ["tablespace_wasted", "indexspace_wasted"],
                })
        return {
            "changed": False,
            "msg": "discovered %d databases" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    res = ctx.run(["cat", "/var/lib/postgres/agent_bloat"], mutates=False)
    lines = res.stdout.splitlines()

    # Build database list
    db_list = []
    in_database_section = False
    for line in lines:
        stripped = line.strip()
        if stripped == "[databases_start]":
            in_database_section = True
            continue
        if stripped == "[databases_end]":
            in_database_section = False
            continue
        if in_database_section and stripped:
            db_list.append(stripped)

    # Build database map
    db_map = {}
    current_db = ""
    for line in lines:
        stripped = line.strip()
        if stripped == "[databases_start]":
            current_db = ""
            continue
        if stripped == "[databases_end]":
            current_db = ""
            continue
        if stripped.startswith("db;"):
            continue
        if stripped in db_list:
            current_db = stripped
            db_map[current_db] = []
            continue
        if current_db and stripped and not stripped.startswith("["):
            db_map[current_db].append(stripped)

    database = db_map.get(item)
    if database == None or not database:
        return {
            "changed": False,
            "msg": "Login into database failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    table_bloat_perc = params.get("table_bloat_perc", (180.0, 200.0))
    index_bloat_perc = params.get("index_bloat_perc", (180.0, 200.0))
    table_bloat_abs = params.get("table_bloat_abs", (0, 0))
    index_bloat_abs = params.get("index_bloat_abs", (0, 0))

    table_perc_max = None
    table_abs_max = None
    index_perc_max = None
    index_abs_max = None

    table_abs_total = 0
    index_abs_total = 0

    show_levels = False

    for row in database:
        fields = row.split(";")
        if len(fields) < 20:
            continue
        tbloat_str = fields[7] if len(fields) > 7 else ""
        twasted_str = fields[8] if len(fields) > 8 else ""
        ibloat_str = fields[14] if len(fields) > 14 else ""
        iwasted_str = fields[16] if len(fields) > 16 else ""

        tbloat = float(tbloat_str) if tbloat_str.replace(".","").replace("-","").isdigit() else 0.0
        twasted = int(twasted_str) if twasted_str.replace("-","").isdigit() else 0
        ibloat = float(ibloat_str) if ibloat_str.replace(".","").replace("-","").isdigit() else 0.0
        iwasted = int(iwasted_str) if iwasted_str.replace("-","").isdigit() else 0

        table_abs_total += twasted
        index_abs_total += iwasted

        # Track maximums
        if table_perc_max == None or tbloat > float(table_perc_max["tbloat"]):
            table_perc_max = {"tbloat": str(tbloat), "tablename": fields[2]}
        if table_abs_max == None or twasted > int(table_abs_max["wastedbytes"]):
            table_abs_max = {"wastedbytes": str(twasted), "tablename": fields[2]}
        if index_perc_max == None or ibloat > float(index_perc_max["ibloat"]):
            index_perc_max = {"ibloat": str(ibloat), "tablename": fields[2]}
        if index_abs_max == None or iwasted > int(index_abs_max["wastedibytes"]):
            index_abs_max = {"wastedibytes": str(iwasted), "tablename": fields[2]}

        # Table bloat percentage
        warn_p, crit_p = table_bloat_perc
        if tbloat >= crit_p or tbloat >= warn_p:
            show_levels = True

        # Table bloat absolute
        warn_a, crit_a = table_bloat_abs
        if twasted >= crit_a or twasted >= warn_a:
            show_levels = True

        # Index bloat percentage
        warn_p_i, crit_p_i = index_bloat_perc
        if ibloat >= crit_p_i or ibloat >= warn_p_i:
            show_levels = True

        # Index bloat absolute
        warn_a_i, crit_a_i = index_bloat_abs
        if iwasted >= crit_a_i or iwasted >= warn_a_i:
            show_levels = True

    # Compute state
    if show_levels:
        state = "OK"
        for row in database:
            fields = row.split(";")
            if len(fields) < 20:
                continue
            tbloat_str = fields[7] if len(fields) > 7 else ""
            twasted_str = fields[8] if len(fields) > 8 else ""
            ibloat_str = fields[14] if len(fields) > 14 else ""
            iwasted_str = fields[16] if len(fields) > 16 else ""

            tbloat = float(tbloat_str) if tbloat_str.replace(".","").replace("-","").isdigit() else 0.0
            twasted = int(twasted_str) if twasted_str.replace("-","").isdigit() else 0
            ibloat = float(ibloat_str) if ibloat_str.replace(".","").replace("-","").isdigit() else 0.0
            iwasted = int(iwasted_str) if iwasted_str.replace("-","").isdigit() else 0

            warn_p, crit_p = table_bloat_perc
            warn_a, crit_a = table_bloat_abs
            warn_p_i, crit_p_i = index_bloat_perc
            warn_a_i, crit_a_i = index_bloat_abs

            if tbloat >= crit_p or twasted >= crit_a or ibloat >= crit_p_i or iwasted >= crit_a_i:
                state = "CRIT"
                break
            if state != "CRIT" and (tbloat >= warn_p or twasted >= warn_a or ibloat >= warn_p_i or iwasted >= warn_a_i):
                state = "WARN"
        return {
            "changed": False,
            "msg": "levels reported",
            "data": {"state": state, "metrics": {"tablespace_wasted": table_abs_total, "indexspace_wasted": index_abs_total}, "details": ""},
        }

    # No errors — show maximums and summary
    max_table_msg = ""
    max_index_msg = ""
    if table_perc_max and table_abs_max:
        max_table_msg = "Maximum table bloat at %s: %s%%, Maximum wasted table space at %s: %d bytes" % (
            table_perc_max["tablename"], str(float(table_perc_max["tbloat"])), table_abs_max["tablename"], int(table_abs_max["wastedbytes"])
        )
    if index_perc_max and index_abs_max:
        max_index_msg = "Maximum index bloat at %s: %s%%, Maximum wasted index space at %s: %d bytes" % (
            index_perc_max["tablename"], str(float(index_perc_max["ibloat"])), index_abs_max["tablename"], int(index_abs_max["wastedibytes"])
        )

    summary = max_table_msg + "; " + max_index_msg
    summary += "; Summary of top %d wasted tablespace: %d bytes" % (len(database), table_abs_total)
    summary += "; Summary of top %d wasted indexspace: %d bytes" % (len(database), index_abs_total)

    return {
        "changed": False,
        "msg": summary,
        "data": {"state": "OK", "metrics": {"tablespace_wasted": table_abs_total, "indexspace_wasted": index_abs_total}, "details": ""},
    }
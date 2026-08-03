def _format_age(seconds):
    if seconds == 0:
        return "0s"
    secs = int(seconds)
    days = secs // 86400
    secs = secs % 86400
    hours = secs // 3600
    secs = secs % 3600
    minutes = secs // 60
    secs = secs % 60
    parts = []
    if days > 0:
        parts.append("%dd" % days)
    if hours > 0:
        parts.append("%dh" % hours)
    if minutes > 0:
        parts.append("%dm" % minutes)
    parts.append("%ds" % secs)
    return " ".join(parts)

def _find_line(section, item):
    for line in section:
        if len(line) > 0 and line[0] == item:
            return line
    return None

def main(ctx, params):
    if params.get("_discover"):
        probe = ctx.run(["/usr/bin/orarecovery_probe"], mutates=False)
        if probe.rc != 0:
            return {"changed": False, "msg": "not installed", "data": {"discovery": []}}
        section = []
        if probe.stdout != "":
            for raw in probe.stdout.splitlines():
                fields = raw.split("|")
                if len(fields) > 0:
                    section.append(fields)
        items = []
        for line in section:
            if len(line) > 0:
                name = line[0]
                already = False
                for e in items:
                    if e["item"] == name:
                        already = True
                        break
                if not already:
                    items.append({"item": name, "params": {}, "metrics": ["checkpoint_age", "backup_age"]})
        return {"changed": False, "msg": "discovered %d items" % len(items),
                "data": {"discovery": items}}

    item = params.get("item", "")
    probe = ctx.run(["/usr/bin/orarecovery_probe"], mutates=False)
    if probe.rc != 0:
        return {"changed": False, "msg": "oracle recovery status probe not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "orarecovery_probe not installed"}}
    section = []
    if probe.stdout != "":
        for raw in probe.stdout.splitlines():
            fields = raw.split("|")
            if len(fields) > 0:
                section.append(fields)

    line = _find_line(section, item)
    if line == None:
        return {"changed": False, "msg": "login into database failed (item not found)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "No data for item " + item}}

    n = len(line)
    if n == 11:
        db_name = line[0]
        db_unique_name = line[1]
        database_role = line[2]
        open_mode = line[3]
        filenr = line[4]
        checkpoint_time = line[5]
        checkpoint_age = line[6]
        datafilestatus = line[7]
        recovery = line[8]
        fuzzy = line[9]
        checkpoint_change = line[10]
        backup_state = "unknown"
        backup_age = None
    elif n == 13:
        db_name = line[0]
        db_unique_name = line[1]
        database_role = line[2]
        open_mode = line[3]
        filenr = line[4]
        checkpoint_time = line[5]
        checkpoint_age = line[6]
        datafilestatus = line[7]
        recovery = line[8]
        fuzzy = line[9]
        checkpoint_change = line[10]
        backup_state = line[11]
        backup_age = line[12]
    else:
        return {"changed": False, "msg": ", ".join(line),
                "data": {"state": "CRIT", "metrics": {}, "details": "Malformed line"}}

    state = "OK"
    offlinecount = 0
    filemissingcount = 0
    oldest_checkpoint_age = None
    oldest_backup_age = -1
    backup_count = 0

    if backup_state == "ACTIVE":
        backup_count += 1
        if backup_age != None and backup_age != "":
            oldest_backup_age = max(int(backup_age), oldest_backup_age)

    if datafilestatus == "ONLINE":
        if backup_state == "FILE MISSING":
            filemissingcount += 1
        elif checkpoint_age != "" and checkpoint_age != None:
            ca = int(checkpoint_age)
            if oldest_checkpoint_age == None:
                oldest_checkpoint_age = ca
            else:
                oldest_checkpoint_age = max(oldest_checkpoint_age, ca)
    else:
        offlinecount += 1

    infotext = "%s database" % database_role.lower()
    metrics = {}
    levels_checkpoint = params.get("levels")
    levels_backup = params.get("backup_age")

    if oldest_checkpoint_age == None:
        infotext += ", no online datafiles found(!!)"
        state = "CRIT"
    elif oldest_checkpoint_age <= -1:
        infotext += ", oldest checkpoint is in the future %s, check the time on the server" % _format_age(oldest_checkpoint_age * -1)
        if state == "OK":
            state = "WARN"
    else:
        infotext += ", oldest Checkpoint %s ago" % _format_age(oldest_checkpoint_age)

    checkpoint_metric_value = oldest_checkpoint_age
    if checkpoint_metric_value == None:
        checkpoint_metric_value = 0

    skip_threshold = False
    if database_role == "PRIMARY" and db_name == "_MGMTDB" and db_unique_name == "_mgmtdb":
        skip_threshold = True
    if not levels_checkpoint:
        skip_threshold = True
    rdot = db_name.rfind(".")
    if rdot != -1 and db_name[rdot + 1:] == "PDB$SEED":
        skip_threshold = True

    if skip_threshold or not levels_checkpoint:
        metrics["checkpoint_age"] = checkpoint_metric_value
    else:
        warn_c, crit_c = levels_checkpoint
        if database_role == "PRIMARY":
            if oldest_checkpoint_age != None and oldest_checkpoint_age >= warn_c:
                infotext += "(!)"
                if state == "OK":
                    state = "WARN"
            metrics["checkpoint_age"] = checkpoint_metric_value
        else:
            metrics["checkpoint_age"] = checkpoint_metric_value
            if oldest_checkpoint_age != None:
                if oldest_checkpoint_age >= crit_c:
                    infotext += "(!!)"
                    state = "CRIT"
                elif oldest_checkpoint_age >= warn_c:
                    infotext += "(!)"
                    if state == "OK":
                        state = "WARN"
        infotext += " (warn/crit at %s/%s)" % (_format_age(warn_c), _format_age(crit_c))

    if offlinecount > 0:
        infotext += " %i datafiles offline(!!)" % offlinecount
        state = "CRIT"

    if filemissingcount > 0:
        infotext += " %i missing datafiles(!!)" % filemissingcount
        state = "CRIT"

    if oldest_backup_age > 0:
        infotext += " %i datafiles in backup mode oldest is %s" % (backup_count, _format_age(oldest_backup_age))
        if levels_backup:
            warn_b, crit_b = levels_backup
            infotext += " (warn/crit at %s/%s)" % (_format_age(warn_b), _format_age(crit_b))
            if oldest_backup_age >= crit_b:
                infotext += "(!!)"
                state = "CRIT"
            elif oldest_backup_age >= warn_b:
                infotext += "(!)"
                if state == "OK":
                    state = "WARN"
        metrics["backup_age"] = oldest_backup_age
    else:
        metrics["backup_age"] = 0

    return {"changed": False, "msg": infotext,
            "data": {"state": state, "metrics": metrics, "details": ""}}
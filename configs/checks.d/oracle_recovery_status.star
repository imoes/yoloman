# Oracle Recovery Status check module
# Translated from Checkmk plugin: cmk.plugins.oracle.agent_based.oracle_recovery_status

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/proc/oracle_recovery_status"], mutates=False)
        # Fallback if file doesn't exist; agent section typically comes from
        # <<<oracle_recovery_status:sep(124)>>>, so we expect a file with pipe-separated data.
        # If the file is unreadable, we assume no items found (standard practice).
        if not ctx.file_exists("/proc/oracle_recovery_status"):
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []},
            }
        lines = res.stdout.splitlines()
        items = []
        for line in lines:
            if line.strip():
                parts = line.split("|")
                if parts and parts[0]:
                    items.append({
                        "item": parts[0],
                        "params": {},
                        "metrics": ["checkpoint_age", "backup_age"],
                    })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(items),
            "data": {"discovery": items},
        }

    # Normal check mode: validate item
    item = params.get("item", "")
    if not item:
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Read agent data
    if not ctx.file_exists("/proc/oracle_recovery_status"):
        return {
            "changed": False,
            "msg": "oracle_recovery_status data not available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    res = ctx.run(["cat", "/proc/oracle_recovery_status"], mutates=False)
    lines = res.stdout.splitlines()

    state = "OK"
    offlinecount = 0
    filemissingcount = 0
    oldest_checkpoint_age = None
    oldest_backup_age = -1
    backup_count = 0
    database_role = ""
    db_name = ""
    db_unique_name = ""

    itemfound = False
    for line in lines:
        if not line.strip():
            continue
        parts = line.split("|")
        if len(parts) < 11:
            continue
        if parts[0] != item:
            continue
        itemfound = True

        if len(parts) == 11:
            db_name = parts[0]
            db_unique_name = parts[1]
            database_role = parts[2]
            _open_mode = parts[3]
            _filenr = parts[4]
            _checkpoint_time = parts[5]
            checkpoint_age_str = parts[6]
            datafilestatus = parts[7]
            _recovery = parts[8]
            _fuzzy = parts[9]
            _checkpoint_change = parts[10]

            backup_state = "unknown"

        elif len(parts) == 13:
            db_name = parts[0]
            db_unique_name = parts[1]
            database_role = parts[2]
            _open_mode = parts[3]
            _filenr = parts[4]
            _checkpoint_time = parts[5]
            checkpoint_age_str = parts[6]
            datafilestatus = parts[7]
            _recovery = parts[8]
            _fuzzy = parts[9]
            _checkpoint_change = parts[10]
            backup_state = parts[11]
            backup_age_str = parts[12]

        else:
            # Malformed line: report CRIT per original logic
            return {
                "changed": False,
                "msg": "malformed line: " + line,
                "data": {"state": "CRIT", "metrics": {}, "details": ""},
            }

        # Process backup age
        if backup_state == "ACTIVE":
            backup_count += 1
            if backup_age_str and backup_age_str.isdigit():
                backup_age = int(backup_age_str)
                oldest_backup_age = max(oldest_backup_age, backup_age)

        # Process checkpoint age and datafile status
        if datafilestatus == "ONLINE":
            if backup_state == "FILE MISSING":
                filemissingcount += 1
            elif checkpoint_age_str and checkpoint_age_str.isdigit():
                checkpoint_age = int(checkpoint_age_str)

                if oldest_checkpoint_age == None:
                    oldest_checkpoint_age = checkpoint_age
                else:
                    oldest_checkpoint_age = max(oldest_checkpoint_age, checkpoint_age)
        else:
            offlinecount += 1

    if not itemfound:
        return {
            "changed": False,
            "msg": "item not found in data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    infotext = "%s database" % (database_role.lower())

    if oldest_checkpoint_age == None:
        infotext += ", no online datafiles found(!!)"
        state = "CRIT"
    elif oldest_checkpoint_age <= -1:
        infotext += ", oldest checkpoint is in the future %d s(!), check the time on the server" % (-oldest_checkpoint_age)
        state = "WARN" if state != "CRIT" else state
    else:
        infotext += ", oldest Checkpoint %d s ago" % oldest_checkpoint_age

    warn = None
    crit = None
    if (
        (database_role == "PRIMARY" and db_name == "_MGMTDB" and db_unique_name == "_mgmtdb")
        or not params.get("levels")
    ) or db_name.rfind(".") >= 0 and db_name[db_name.rfind(".") + 1 :] == "PDB$SEED":
        # Ignore state checks for MGMTDB and PDB$SEED
        if oldest_checkpoint_age != None:
            checkpoint_age_metric = oldest_checkpoint_age
    else:
        warn, crit = params["levels"]
        if database_role == "PRIMARY":
            if oldest_checkpoint_age != None and oldest_checkpoint_age >= warn:
                infotext += "(!)"
                state = "WARN" if state != "CRIT" else state
            checkpoint_age_metric = oldest_checkpoint_age
        else:
            if oldest_checkpoint_age != None:
                checkpoint_age_metric = oldest_checkpoint_age

            if oldest_checkpoint_age != None:
                if oldest_checkpoint_age >= crit:
                    infotext += "(!!)"
                    state = "CRIT"
                elif oldest_checkpoint_age >= warn:
                    infotext += "(!)"
                    state = "WARN" if state != "CRIT" else state

            infotext += " (warn/crit at %d s/%d s)" % (warn, crit)

    if offlinecount > 0:
        infotext += " %d datafiles offline(!!)" % offlinecount
        state = "CRIT"

    if filemissingcount > 0:
        infotext += " %d missing datafiles(!!)" % filemissingcount
        state = "CRIT"

    if oldest_backup_age > 0:
        infotext += " %d datafiles in backup mode oldest is %d s" % (backup_count, oldest_backup_age)

        if params.get("backup_age"):
            backup_warn, backup_crit = params["backup_age"]
            infotext += " (warn/crit at %d s/%d s)" % (backup_warn, backup_crit)

            if oldest_backup_age >= backup_crit:
                infotext += "(!!)"
                state = "CRIT"
            elif oldest_backup_age >= backup_warn:
                infotext += "(!)"
                state = "WARN" if state != "CRIT" else state
        backup_age_metric = oldest_backup_age
    else:
        backup_age_metric = 0

    metrics = {}
    if "checkpoint_age_metric" in dir():
        metrics["checkpoint_age"] = checkpoint_age_metric
    metrics["backup_age"] = backup_age_metric

    return {
        "changed": False,
        "msg": infotext,
        "data": {"state": state, "metrics": metrics, "details": ""},
    }
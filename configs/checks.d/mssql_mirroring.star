MIRRORING_STATE = {
    0: "Suspended",
    1: "Disconnected",
    2: "Synchronizing",
    3: "Pending Failover",
    4: "Synchronized",
    5: "Not synchronized, failover not possible",
    6: "Synchronized, failover potentially possible",
}

WITNESS_STATE = {
    0: "Unknown",
    1: "Connected",
    2: "Disconnected",
}


def _get_mssql_mirroring_data(ctx):
    query = "SELECT serverproperty('ServerName') AS server_name, db.name AS database_name, ISNULL(CAST(dm.mirroring_state AS INT), -1) AS mirroring_state, ISNULL(dm.mirroring_state_desc, '') AS mirroring_state_desc, ISNULL(CAST(dm.mirroring_role AS INT), -1) AS mirroring_role, ISNULL(dm.mirroring_role_desc, '') AS mirroring_role_desc, ISNULL(CAST(dm.mirroring_safety_level AS INT), -1) AS mirroring_safety_level, ISNULL(dm.mirroring_safety_level_desc, '') AS mirroring_safety_level_desc, ISNULL(dm.mirroring_partner_name, '') AS mirroring_partner_name, ISNULL(dm.mirroring_partner_instance, '') AS mirroring_partner_instance, ISNULL(dm.mirroring_witness_name, '') AS mirroring_witness_name, ISNULL(CAST(dm.mirroring_witness_state AS INT), -1) AS mirroring_witness_state, ISNULL(dm.mirroring_witness_state_desc, '') AS mirroring_witness_state_desc FROM sys.database_mirroring dm RIGHT JOIN sys.databases db ON dm.database_id = db.database_id WHERE db.database_id > 4 AND db.state = 0 AND dm.mirroring_role_desc = 'PRINCIPAL' FOR JSON PATH"
    res = ctx.run(["sqlcmd", "-S", "localhost", "-E", "-Q", query, "-h", "-1", "-w", "1000"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return []
    data = json.decode(res.stdout)
    return data if type(data) == "list" else []


def main(ctx, params):
    if params.get("_discover"):
        data = _get_mssql_mirroring_data(ctx)
        items = []
        for entry in data:
            if type(entry) == "dict":
                db_name = entry.get("database_name", "")
                if db_name:
                    items.append({
                        "item": db_name,
                        "params": {
                            "mirroring_state_criticality": 0,
                            "mirroring_witness_state_criticality": 0,
                        },
                        "metrics": [],
                    })
        return {
            "changed": False,
            "msg": "discovered %d mirrored databases" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")
    if not item:
        return {
            "changed": False,
            "msg": "no database item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    data = _get_mssql_mirroring_data(ctx)
    mirroring_config = None
    for entry in data:
        if type(entry) == "dict" and entry.get("database_name") == item:
            mirroring_config = entry
            break

    if mirroring_config == None:
        return {
            "changed": False,
            "msg": "database not found: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    mirroring_state = mirroring_config.get("mirroring_state", -1)
    mirroring_witness_state = mirroring_config.get("mirroring_witness_state", -1)
    mirroring_state_criticality = params.get("mirroring_state_criticality", 0)
    mirroring_witness_state_criticality = params.get("mirroring_witness_state_criticality", 0)

    state = "OK"
    if mirroring_state != 4:
        if mirroring_state_criticality == 1:
            state = "WARN"
        elif mirroring_state_criticality == 2:
            state = "CRIT"

    witness_state = "OK"
    if mirroring_witness_state != 1:
        if mirroring_witness_state_criticality == 1:
            witness_state = "WARN"
        elif mirroring_witness_state_criticality == 2:
            witness_state = "CRIT"

    overall_state = "OK"
    if witness_state == "CRIT" or state == "CRIT":
        overall_state = "CRIT"
    elif witness_state == "WARN" or state == "WARN":
        overall_state = "WARN"

    msg_parts = []
    msg_parts.append("Principal: %s" % (mirroring_config.get("server_name") or ""))
    msg_parts.append("Mirror: %s" % (mirroring_config.get("mirroring_partner_instance") or ""))

    details = []
    details.append("Mirroring state: %s" % MIRRORING_STATE.get(mirroring_state, "Unknown"))
    details.append("Witness state: %s" % WITNESS_STATE.get(mirroring_witness_state, "Unknown"))
    details.append("Safety level: %s" % (mirroring_config.get("mirroring_safety_level_desc") or ""))
    details.append("Partner name: %s" % (mirroring_config.get("mirroring_partner_name") or ""))
    details.append("Witness name: %s" % (mirroring_config.get("mirroring_witness_name") or ""))

    return {
        "changed": False,
        "msg": "; ".join(msg_parts),
        "data": {
            "state": overall_state,
            "metrics": {},
            "details": "; ".join(details),
        },
    }
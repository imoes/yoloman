MSSQL_VERSION_MAPPING = {
    "8": "2000",
    "9": "2005",
    "10": "2008",
    "10.50": "2008R2",
    "11": "2012",
    "12": "2014",
    "13": "2016",
    "14": "2017",
    "15": "2019",
    "16": "2022",
    "17": "2025",
}


def _parse_prod_version(entry):
    parts = entry.split(".")
    major_version = parts[0]
    minor_version = parts[1] if len(parts) > 1 else ""
    version = MSSQL_VERSION_MAPPING.get(
        "%s.%s" % (major_version, minor_version),
        MSSQL_VERSION_MAPPING.get(major_version),
    )
    if version == None:
        return "unknown[%s]" % entry
    return "Microsoft SQL Server %s" % version


def _parse_section(raw_lines):
    parsed = {}
    for line in raw_lines:
        fields = line.split("|")
        if (
            len(fields) == 0
            or fields[0].startswith("ERROR:")
            or len(fields) < 2
            or fields[1] not in ["config", "state", "details"]
        ):
            continue

        if fields[0][:6] == "MSSQL_":
            instance_id = fields[0][6:]
        else:
            instance_id = fields[0]

        instance = parsed.setdefault(
            instance_id,
            {
                "state": "0",
                "error_msg": "Unable to connect to database (Agent reported no state)",
            },
        )

        if fields[1] == "config":
            instance["version_info"] = "%s - %s" % (fields[2], fields[3])
            instance["cluster_name"] = fields[4] if len(fields) > 4 else ""
            instance["config_version"] = fields[2]
            instance["config_edition"] = fields[3]
        elif fields[1] == "state":
            instance["state"] = fields[2] if len(fields) > 2 else "0"
            instance["error_msg"] = "|".join(fields[3:]) if len(fields) > 3 else ""
        elif fields[1] == "details":
            pv = _parse_prod_version(fields[2]) if len(fields) > 2 else "unknown"
            instance["prod_version_info"] = "%s (%s) (%s) - %s" % (
                pv, fields[3], fields[2], fields[4] if len(fields) > 4 else ""
            )
            instance["details_version"] = fields[2] if len(fields) > 2 else ""
            instance["details_product"] = pv
            instance["details_edition"] = fields[3] if len(fields) > 3 else ""
            instance["details_edition_long"] = fields[4] if len(fields) > 4 else ""

    return parsed


def _gather_raw(ctx):
    lines = []
    found = False

    # Probe for sqlcmd / osql CLI tool (the on-host source the special agent uses)
    probe = ctx.run(["which", "sqlcmd"], mutates=False)
    has_sqlcmd = probe.rc == 0

    if not has_sqlcmd:
        probe2 = ctx.run(["which", "osql"], mutates=False)
        has_osql = probe2.rc == 0
    else:
        has_osql = False

    if not has_sqlcmd and not has_osql:
        return lines, False

    # Enumerate instances: check the registry / running services for MSSQL instances
    # Use sqlcmd -Lc to list local instances (or osql -Lc)
    tool = "sqlcmd" if has_sqlcmd else "osql"

    # List local instances
    lst = ctx.run([tool, "-Lc"], mutates=False)
    if lst.rc != 0:
        # fall back: try to read from services
        pass
    else:
        for al in lst.stdout.splitlines():
            al = al.strip()
            if al == "":
                continue
            instance_id = al
            if instance_id == "MSSQLSERVER":
                instance_id = "MSSQL_MSSQLSERVER"
            else:
                instance_id = "MSSQL_" + instance_id

            # Get version info: SELECT @@VERSION (returns like "10.50.1600.1 ...")
            ver_q = ctx.run(
                [tool, "-S", al, "-Q", "SET NOCOUNT ON; SELECT @@VERSION", "-h", "-1", "-W"],
                mutates=False,
            )
            version_raw = ""
            if ver_q.rc == 0:
                version_raw = ver_q.stdout.strip()

            # Parse version: "Microsoft SQL Server 2008 ... - 10.50.1600.1 ..."
            prod_ver_entry = ""
            edition = ""
            if version_raw != "":
                # version_raw typically: "Microsoft SQL Server 2008 (SP2) (KB948198-E004) - 10.50.1600.1 (X64) ..."
                # Extract the numeric version token
                for tok in version_raw.split():
                    if tok[:1].isdigit() and "." in tok:
                        # might be "10.50.1600.1"
                        if tok.replace(".", "").replace("(", "").replace(")", "").isdigit():
                            prod_ver_entry = tok
                            break

                if prod_ver_entry == "":
                    for tok in version_raw.split():
                        if tok[:1].isdigit() and "." in tok:
                            prod_ver_entry = tok
                            break

            # Get edition
            edt_q = ctx.run(
                [tool, "-S", al, "-Q", "SET NOCOUNT ON; SELECT SERVERPROPERTY('Edition'), SERVERPROPERTY('ProductVersion')", "-h", "-1", "-W"],
                mutates=False,
            )
            if edt_q.rc == 0:
                parts = edt_q.stdout.strip().splitlines()
                if len(parts) > 0:
                    edition = parts[0]
                if prod_ver_entry == "" and len(parts) > 1:
                    prod_ver_entry = parts[1]

            config_version = prod_ver_entry
            if prod_ver_entry == "":
                config_version = "0.0.0.0"

            lines.append("%s|config|%s|%s|" % (instance_id, config_version, edition))

            # State: try connecting with a trivial query
            state_q = ctx.run(
                [tool, "-S", al, "-Q", "SET NOCOUNT ON; SELECT 1", "-h", "-1", "-W"],
                mutates=False,
            )
            state_val = "1" if state_q.rc == 0 else "0"
            err = ""
            if state_q.rc != 0:
                err = state_q.stderr.strip() if state_q.stderr != "" else "connection failed"

            lines.append("%s|state|%s|%s" % (instance_id, state_val, err))

            # Details
            details_ver = prod_ver_entry
            details_edition = edition
            details_edition_long = edition
            lines.append("%s|details|%s|%s|%s" % (instance_id, details_ver, details_edition, details_edition_long))

            found = True

    # Also check named pipes / default instance via services on Windows
    if not found:
        # On Windows, we might detect via sc query
        svcs = ctx.run(["sc", "query", "state=", "all"], mutates=False)
        if svcs.rc == 0:
            for ln in svcs.stdout.splitlines():
                bn = ln.strip()
                if bn.startswith("SERVICE_NAME:"):
                    name = bn.split(":", 1)[1].strip()
                    if name.startswith("MSSQL") and "$" not in name:
                        if name == "MSSQLSERVER":
                            iid = "MSSQL_MSSQLSERVER"
                        else:
                            iid = "MSSQL_" + name[len("MSSQL"):]
                        lines.append("%s|config|0.0.0.0|Unknown|" % iid)
                        lines.append("%s|state|0|Unable to connect via sqlcmd" % iid)
                        found = True

    return lines, found


def main(ctx, params):
    if params.get("_discover"):
        raw_lines, found = _gather_raw(ctx)
        if not found:
            return {
                "changed": False,
                "msg": "no MSSQL instance found",
                "data": {"discovery": [], "host_labels": {}},
            }

        section = _parse_section(raw_lines)
        discovery = []
        for instance_id in section:
            discovery.append({
                "item": instance_id,
                "params": {"map_connection_state": 2},
                "metrics": [],
            })

        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery, "host_labels": {}},
        }

    # Check mode
    item = params.get("item", "")
    raw_lines, _ = _gather_raw(ctx)
    section = _parse_section(raw_lines)
    instance = section.get(item)
    if instance == None or len(instance) == 0:
        return {
            "changed": False,
            "msg": "Database or necessary processes not running or login failed",
            "data": {
                "state": "CRIT",
                "metrics": {},
                "details": "",
            },
        }

    state = "CRIT"
    map_state = params.get("map_connection_state")
    if map_state != None:
        state = str(map_state)

    details = ""
    summaries = []

    if instance.get("state") == "0":
        # Failed to connect
        state_val = state
        summaries.append("Failed to connect to database (%s)" % instance.get("error_msg", ""))
    else:
        summaries.append("Version: %s" % instance.get("prod_version_info", instance.get("version_info", "")))
        if instance.get("cluster_name") != "" and instance.get("cluster_name") != None:
            summaries.append("Clustered as %s" % instance.get("cluster_name"))
        state_val = "OK"

    return {
        "changed": False,
        "msg": "; ".join(summaries),
        "data": {
            "state": state_val,
            "metrics": {},
            "details": details,
        },
    }
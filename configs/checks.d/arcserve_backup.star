# Translated Checkmk check: checkmk.arcserve_backup
# Monitors Arcserve Backup job results - read-only
# Data source: Arcserve backup job history from the Arcserve database

def _parse_arcserve_lines(output):
    """Parse Arcserve backup output into per-job backup info dicts.
    Mirrors parse_arcserve_backup from the Checkmk plugin."""
    unit_factor = {"kb": 1024, "mb": 1024 * 1024, "gb": 1024 * 1024 * 1024, "tb": 1024 * 1024 * 1024 * 1024}
    parsed = {}
    current_backup = None
    current_id = None

    lines = output.splitlines()
    for line in lines:
        if not line.strip():
            continue
        parts = line.split()

        if len(parts) >= 2 and parts[0] == "Job:":
            current_id = " ".join(parts[1:])
            current_backup = None

        if len(parts) >= 1 and parts[0] == "Beschreibung:":
            backup_id = " ".join(parts[1:])
            if backup_id.endswith("."):
                backup_id = backup_id[:-1]
            current_backup = {}
            current_backup["dirs"] = 0
            current_backup["files"] = 0
            current_backup["size"] = 0
            current_backup["result"] = ""
            parsed[backup_id] = current_backup

        if (len(parts) > 5 and parts[1] == "Verzeichnis(se)" and
            parts[3] == "Datei(en)" and parts[5].endswith(")")):
            if current_backup != None:
                dirs_str = parts[0].replace(".", "")
                files_str = parts[2].replace(".", "")
                size_str = parts[4].replace("(", "").replace(",", ".")
                unit_str = parts[5].replace(")", "").lower()
                current_backup["dirs"] = int(dirs_str) if dirs_str.isdigit() else 0
                current_backup["files"] = int(files_str) if files_str.isdigit() else 0
                if unit_str in unit_factor:
                    size_val = float(size_str) * unit_factor[unit_str]
                    current_backup["size"] = int(size_val)

        if len(parts) >= 2 and parts[0] == "Vorgang":
            if current_backup != None:
                result = " ".join(parts[1:])
                current_backup["result"] = result

    return parsed


def main(ctx, params):
    if params.get("_discover"):
        # Probe for Arcserve installation
        arcserve_dir = ctx.stat("/opt/Arcserve")
        if arcserve_dir == None or not arcserve_dir.get("is_dir", False):
            return {"changed": False, "msg": "Arcserve not installed", "data": {"discovery": []}}

        # Gather backup job data from the Arcserve backup database/export
        # The Checkmk agent plugin reads from the Arcserve backup system
        # We use the same data source: Arcserve's backup job history
        export_res = ctx.run(
            ["dbexport", "-d", "backup_db", "-t", "job_history"],
            mutates=False,
        )
        if export_res.rc != 0:
            # Try alternative: check for backup job output files
            backup_res = ctx.run(
                ["ls", "/opt/Arcserve/data/backup_jobs"],
                mutates=False,
            )
            if backup_res.rc != 0:
                return {"changed": False, "msg": "Arcserve installed but no backup jobs found",
                        "data": {"discovery": []}}

        discovery = []
        parsed = _parse_arcserve_lines(export_res.stdout)
        for backup_name in sorted(parsed.keys()):
            discovery.append({
                "item": backup_name,
                "params": {},
                "metrics": ["dirs", "files", "size"],
            })

        return {
            "changed": False,
            "msg": "discovered %d backup jobs" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")

    # Check mode: check one backup job
    # Re-gather the data for this specific item
    export_res = ctx.run(
        ["dbexport", "-d", "backup_db", "-t", "job_history"],
        mutates=False,
    )
    if export_res.rc != 0:
        return {
            "changed": False,
            "msg": "no backup job data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    parsed = _parse_arcserve_lines(export_res.stdout)
    backup = parsed.get(item)
    if backup == None:
        return {
            "changed": False,
            "msg": "no such backup job: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    metrics = {}
    if backup.get("dirs", 0) > 0:
        metrics["dirs"] = backup["dirs"]
    if backup.get("files", 0) > 0:
        metrics["files"] = backup["files"]
    if backup.get("size", 0) > 0:
        metrics["size"] = backup["size"]

    result_str = backup.get("result", "")

    if result_str.startswith("Sichern erfolgreich"):
        state = "OK"
    elif result_str.startswith("Sichern unvollst"):
        state = "WARN"
    elif result_str.startswith("Sichern konnte nicht durchg"):
        state = "CRIT"
    else:
        return {
            "changed": False,
            "msg": "Unknown result: " + result_str,
            "data": {"state": "UNKNOWN", "metrics": metrics, "details": ""},
        }

    msg = "Result: " + result_str
    if backup.get("dirs", 0) > 0:
        msg = msg + ", Directories: %d" % backup["dirs"]
    if backup.get("files", 0) > 0:
        msg = msg + ", Files: %d" % backup["files"]
    if backup.get("size", 0) > 0:
        msg = msg + ", Size: %d bytes" % backup["size"]

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": metrics, "details": ""},
    }
UNIT_FACTOR = {
    "kb": 1024,
    "mb": 1048576,
    "gb": 1073741824,
    "tb": 1099511627776,
}

DEFAULT_LOG = "C:\\Program Files\\CA\\ARCserve Backup\\LOG\\arcserve_backup_output.txt"

def _is_digits(s):
    if len(s) == 0:
        return False
    for c in s:
        if c not in "0123456789":
            return False
    return True

def _parse_size_bytes(size_tok, unit_tok):
    s = size_tok.replace("(", "").replace(",", ".")
    unit = unit_tok.replace(")", "").lower()
    dot_pos = s.find(".")
    if dot_pos >= 0:
        valid = _is_digits(s[:dot_pos]) and (dot_pos == len(s) - 1 or _is_digits(s[dot_pos + 1:]))
    else:
        valid = _is_digits(s)
    if not valid:
        return 0
    factor = UNIT_FACTOR.get(unit, 1)
    return int(float(s) * factor)

def _parse_jobs(content):
    jobs = {}
    current_name = None
    current_job = {}

    for raw_line in content.splitlines():
        parts = raw_line.strip().split()
        if len(parts) == 0:
            continue

        if parts[0] == "Beschreibung:":
            if current_name != None:
                jobs[current_name] = current_job
            name_parts = parts[1:-1] if len(parts) > 2 else parts[1:]
            name = " ".join(name_parts)
            if name.endswith("."):
                name = name[:-1]
            current_name = name
            current_job = {}

        elif (len(parts) > 5 and
              parts[1] == "Verzeichnis(se)" and
              parts[3] == "Datei(en)" and
              parts[5].endswith(")")):
            if current_name != None:
                dirs_raw = parts[0].replace(".", "")
                files_raw = parts[2].replace(".", "")
                dirs = int(dirs_raw) if _is_digits(dirs_raw) else 0
                files = int(files_raw) if _is_digits(files_raw) else 0
                size = _parse_size_bytes(parts[4], parts[5])
                current_job["dirs"] = dirs
                current_job["files"] = files
                current_job["size"] = size

        elif len(parts) > 1 and parts[0] == "Vorgang":
            if current_name != None:
                current_job["result"] = " ".join(parts[1:])

    if current_name != None:
        jobs[current_name] = current_job

    return jobs

def _fmt_bytes(n):
    if n >= 1099511627776:
        return "%f TB" % (float(n) / 1099511627776.0)
    if n >= 1073741824:
        return "%f GB" % (float(n) / 1073741824.0)
    if n >= 1048576:
        return "%f MB" % (float(n) / 1048576.0)
    if n >= 1024:
        return "%f KB" % (float(n) / 1024.0)
    return "%d B" % n

def main(ctx, params):
    log_file = params.get("log_file", DEFAULT_LOG)

    if params.get("_discover"):
        if not ctx.file_exists(log_file):
            return {"changed": False, "msg": "log file not found: " + log_file,
                    "data": {"discovery": []}}
        content = ctx.file_read(log_file)
        jobs = _parse_jobs(content)
        items = [{"item": name, "params": {}, "metrics": ["dirs", "files", "size"]}
                 for name in sorted(jobs)]
        return {"changed": False, "msg": "discovered %d backup jobs" % len(items),
                "data": {"discovery": items}}

    item = params.get("item", "")

    if not ctx.file_exists(log_file):
        return {"changed": False, "msg": "log file not found: " + log_file,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    content = ctx.file_read(log_file)
    jobs = _parse_jobs(content)

    backup = jobs.get(item)
    if backup == None:
        return {"changed": False, "msg": "backup job not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    metrics = {}
    summary_parts = []

    dirs = backup.get("dirs")
    if dirs != None:
        metrics["dirs"] = dirs
        summary_parts.append("Directories: %d" % dirs)

    files = backup.get("files")
    if files != None:
        metrics["files"] = files
        summary_parts.append("Files: %d" % files)

    size = backup.get("size")
    if size != None:
        metrics["size"] = size
        summary_parts.append("Size: " + _fmt_bytes(size))

    result = backup.get("result", "")

    if result.startswith("Sichern erfolgreich"):
        state = "OK"
    elif result.startswith("Sichern unvollst"):
        state = "WARN"
    elif result.startswith("Sichern konnte nicht durchgef"):
        state = "CRIT"
    else:
        return {"changed": False, "msg": "Unknown result: " + result,
                "data": {"state": "UNKNOWN", "metrics": metrics, "details": result}}

    summary_parts.append("Result: " + result)

    return {"changed": False, "msg": ", ".join(summary_parts),
            "data": {"state": state, "metrics": metrics, "details": result}}
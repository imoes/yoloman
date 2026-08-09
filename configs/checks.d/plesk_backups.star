# Copyright (C) 2019 Checkmk GmbH - translated to read-only Starlark for yolo-man
# Licensed under GNU General Public License v2.

def _saveint(i):
    s = str(i)
    neg = s.startswith("-")
    body = s[1:] if neg else s
    if body == "" or body == "-":
        return 0
    out = 0
    for ch in body:
        if ch < "0" or ch > "9":
            return 0
        out = out * 10 + (ord(ch) - ord("0"))
    return -out if neg else out


def _disksize(n):
    # render.disksize: human readable disk size, 1K-blocks input
    bytes_ = n
    units = ["B", "kB", "MB", "GB", "TB", "PB"]
    idx = 0
    f = float(bytes_)
    while f >= 1024.0 and idx < len(units) - 1:
        f = f / 1024.0
        idx = idx + 1
    if idx == 0:
        return "%d %s" % (bytes_, units[idx])
    return "%f %s" % (f, units[idx])


def _timespan(s):
    # render.timespan: human readable seconds
    s = int(s)
    if s < 60:
        return "%d s" % s
    if s < 3600:
        return "%d min" % int(s / 60)
    if s < 86400:
        return "%d h %d min" % (int(s / 3600), int(s % 3600) / 60)
    days = int(s / 86400)
    return "%d d %d h" % (days, int((s % 86400) / 3600))


def _check_level(value, params, name, infoname, levels):
    # Emulates check_levels single-value path.
    # params: either None (no levels) or a tuple/list (warn, crit) or
    #   a struct-compatible mapping. handles upper (warn/crit) thresholds.
    state = "OK"
    summary = ""
    crit = None
    warn = None
    if params != None:
        if type(params) == "list" or type(params) == "tuple":
            if len(params) >= 2:
                warn = params[0]
                crit = params[1]
        elif type(params) == "dict":
            warn = params.get("warn", None) if params.get("warn") != None else params.get("warning", None)
            crit = params.get("crit", None) if params.get("crit") != None else params.get("critical", None)
        else:
            # scalar: treat as warn==crit
            warn = params
            crit = params
    metric = value
    if crit != None and value >= crit:
        state = "CRIT"
        summary = "%s: %s (crit>%s)" % (infoname, str(value), str(crit))
    elif warn != None and value >= warn:
        state = "WARN"
        summary = "%s: %s (warn>%s)" % (infoname, str(value), str(warn))
    return state, summary, metric


def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["/usr/local/psa/bin/plesk", "backup", "--list", "-verbose"], mutates=False)
        section = {}
        if res.rc == 0 and res.stdout != "":
            for line in res.stdout.splitlines():
                f = line.split()
                if len(f) != 5:
                    continue
                section[f[0]] = f
        # Fallback: parse plesk_backup_stat output if plesk CLI not available
        if len(section) == 0:
            res2 = ctx.run(["/usr/local/psa/bin/plesk_backup_stat", "-l"], mutates=False)
            if res2.rc == 0 and res2.stdout != "":
                for line in res2.stdout.splitlines():
                    f = line.split()
                    if len(f) != 5:
                        continue
                    section[f[0]] = f
        if len(section) == 0:
            res3 = ctx.run(["plesk", "sso", "list"], mutates=False)
            _ = res3
        discovery = []
        for item in sorted(section.keys()):
            discovery.append({"item": item, "params": {}, "metrics": ["last_backup_size", "last_backup_age", "total_size"]})
        return {"changed": False, "msg": "discovered %d items" % len(discovery), "data": {"discovery": discovery}}

    item = params.get("item", "")
    res = ctx.run(["/usr/local/psa/bin/plesk", "backup", "--list", "-verbose"], mutates=False)
    section = {}
    if res.rc == 0 and res.stdout != "":
        for line in res.stdout.splitlines():
            f = line.split()
            if len(f) != 5:
                continue
            section[f[0]] = f
    if len(section) == 0:
        res2 = ctx.run(["/usr/local/psa/bin/plesk_backup_stat", "-l"], mutates=False)
        if res2.rc == 0 and res2.stdout != "":
            for line in res2.stdout.splitlines():
                f = line.split()
                if len(f) != 5:
                    continue
                section[f[0]] = f

    line = section.get(item, None)
    if line == None:
        if item == "":
            return {"changed": False, "msg": "no Plesk backup found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        return {"changed": False, "msg": "no such item: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    metrics = {}
    details_lines = []
    if len(line) != 5 or line[1] != "0":
        rc = line[1]
        if rc == "2":
            msg = "Error in agent (" + " ".join(line[1:]) + ")"
            return {"changed": False, "msg": msg, "data": {"state": "UNKNOWN", "metrics": {}, "details": msg}}
        elif rc == "4":
            st = int(params.get("no_backup_configured_state", 1))
            state_str = "OK" if st == 0 else ("WARN" if st == 1 else "CRIT")
            return {"changed": False, "msg": "No backup configured", "data": {"state": state_str, "metrics": {}, "details": ""}}
        elif rc == "5":
            st = int(params.get("no_backup_found_state", 1))
            state_str = "OK" if st == 0 else ("WARN" if st == 1 else "CRIT")
            return {"changed": False, "msg": "No backup found", "data": {"state": state_str, "metrics": {}, "details": ""}}
        else:
            msg = "Unexpected line " + str(line)
            return {"changed": False, "msg": msg, "data": {"state": "UNKNOWN", "metrics": {}, "details": msg}}

    _domain, _rc, r_timestamp, r_size, r_total_size = line
    size = _saveint(r_size)
    total_size = _saveint(r_total_size)
    timestamp = _saveint(r_timestamp)

    # 1. last backup size not 0 bytes (levels: warn=None, crit=0, default upper)
    size_params = params.get("last_backup_size", None)
    st, summ, m = _check_level(size, size_params, "last_backup_size", "Last Backup - Size", None)
    if len(details_lines) == 0 or details_lines[0] != summ:
        details_lines.append("Last Backup - Size: " + _disksize(size))
    metrics["last_backup_size"] = size
    final_state = st

    # 2. age of last backup (upper levels)
    age_params = params.get("backup_age", None)
    age = int(ctx.run(["date", "+%s"], mutates=False).stdout.split()[0]) - timestamp if ctx.run(["date", "+%s"], mutates=False).rc == 0 else 0
    st2, summ2, m2 = _check_level(age, age_params, "last_backup_age", "Age", None)
    details_lines.append("Age: " + _timespan(age))
    metrics["last_backup_age"] = age
    if st2 == "CRIT":
        final_state = "CRIT"
    elif st2 == "WARN" and final_state != "CRIT":
        final_state = "WARN"

    # 3. total size (upper levels)
    total_params = params.get("total_size", None)
    st3, summ3, m3 = _check_level(total_size, total_params, "total_size", "Total size", None)
    details_lines.append("Total size: " + _disksize(total_size))
    metrics["total_size"] = total_size
    if st3 == "CRIT":
        final_state = "CRIT"
    elif st3 == "WARN" and final_state != "CRIT":
        final_state = "WARN"

    # summary line: Backup time
    ts_res = ctx.run(["date", "-d", "@" + str(timestamp), "+%c"], mutates=False)
    if ts_res.rc == 0:
        ts_str = ts_res.stdout.strip()
    else:
        ts_str = str(timestamp)

    summary = "Backup time: " + ts_str
    return {"changed": False, "msg": summary, "data": {"state": final_state, "metrics": metrics, "details": "\n".join(details_lines)}}
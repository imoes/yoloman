def _lstrip(s):
    i = 0
    while i < len(s) and s[i] == " ":
        i = i + 1
    return s[i:]

def _parse_process_status(s):
    i = 0
    while i < len(s) and s[i] in "0123456789 ":
        i = i + 1
    out = ""
    j = i
    while j < len(s) and s[j] in " \t":
        j = j + 1
    out = s[i:].rstrip()
    return out

def _to_mb(size):
    s = size.replace(" ", "")
    if s.endswith("MB"):
        return int(float(s.replace("MB", "")))
    if s.endswith("GB"):
        return int(float(s.replace("GB", ""))) * 1024
    if s.endswith("TB"):
        return int(float(s.replace("TB", ""))) * 1024 * 1024
    if s.endswith("PB"):
        return int(float(s.replace("PB", ""))) * 1024 * 1024 * 1024
    if s.endswith("EB"):
        return int(float(s.replace("EB", ""))) * 1024 * 1024 * 1024 * 1024
    return int(float(s))

def _parse(section_text):
    parsed = {}
    for line in section_text.split("\n"):
        cols = line.split(":")
        if len(cols) > 1 and cols[0].startswith("Host   "):
            parsed["host"] = _lstrip(cols[1])
        elif len(cols) > 2 and cols[0].startswith("Start-Time   "):
            parsed["start_time"] = _lstrip(cols[1]) + ":" + cols[2]
        elif len(cols) > 1 and cols[0] == "Release":
            parsed["release"] = _lstrip(cols[1])
        elif len(cols) > 1 and cols[0].startswith("Status   "):
            parsed["libelle_status"] = _lstrip(cols[1])
        elif len(cols) > 3 and (cols[0].startswith("trdrecover   ") or cols[0].startswith("trdarchiver   ")):
            parsed["process"] = cols[0].rstrip()
            parsed["process_status"] = _parse_process_status(cols[3])
        elif len(cols) > 1 and cols[0].startswith("Archive-Dir total   "):
            parsed["arch_total_mb"] = _to_mb(cols[1].replace(" ", ""))
        elif len(cols) > 1 and cols[0].startswith("Archive-Dir free   "):
            parsed["arch_free_mb"] = _to_mb(cols[1].replace(" ", ""))
    return parsed

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["/usr/bin/libelle_business_shadow", "--info"], mutates=False)
        # Probe: checkmk agent output is the standard source; on our agent there is no
        # Checkmk. The real data source is the Libelle Business Shadow command itself.
        if res.rc == 127:
            return {"changed": False, "msg": "not installed", "data": {"discovery": [], "host_labels": {}}}
        if res.rc != 0:
            return {"changed": False, "msg": "probe failed", "data": {"discovery": [], "host_labels": {}}}
        parsed = _parse(res.stdout)
        items = []
        if "host" in parsed or "release" in parsed or "start_time" in parsed:
            items.append({"item": "", "params": {}, "metrics": []})
        if "libelle_status" in parsed:
            items.append({"item": "Status", "params": {}, "metrics": []})
        if "process" in parsed:
            items.append({"item": "Process", "params": {}, "metrics": []})
        if "arch_total_mb" in parsed and "arch_free_mb" in parsed:
            items.append({"item": "Archive Dir", "params": {}, "metrics": ["arch_used_mb", "arch_total_mb", "arch_used_percent"]})
        return {"changed": False, "msg": "discovered %d items" % len(items), "data": {"discovery": items, "host_labels": {}}}
    item = params.get("item", "")
    res = ctx.run(["/usr/bin/libelle_business_shadow", "--info"], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "not installed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.rc != 0:
        return {"changed": False, "msg": "probe failed: " + res.stderr, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    parsed = _parse(res.stdout)
    if item == "":
        message = "Libelle Business Shadow"
        if "host" in parsed:
            message += ", Host: " + parsed["host"]
        if "release" in parsed:
            message += ", Release: " + parsed["release"]
        if "start_time" in parsed:
            message += ", Start Time: " + parsed["start_time"]
        return {"changed": False, "msg": message, "data": {"state": "OK", "metrics": {}, "details": ""}}
    if item == "Status":
        if "libelle_status" in parsed:
            message = "Status is: " + parsed["libelle_status"]
            state = "OK" if parsed["libelle_status"] == "RUN" else "CRIT"
        else:
            message = "No information about libelle status found in agent output"
            state = "UNKNOWN"
        return {"changed": False, "msg": message, "data": {"state": state, "metrics": {}, "details": ""}}
    if item == "Process":
        if "process" in parsed:
            message = "Active Process is: " + parsed["process"] + ", Status: " + parsed["process_status"]
            state = "OK" if parsed["process_status"] == "RUN" else "CRIT"
        else:
            message = "No Active Process found!"
            state = "CRIT"
        return {"changed": False, "msg": message, "data": {"state": state, "metrics": {}, "details": ""}}
    if item == "Archive Dir":
        if "arch_total_mb" in parsed and "arch_free_mb" in parsed:
            total = parsed["arch_total_mb"]
            free = parsed["arch_free_mb"]
            used = total - free
            if total > 0:
                used_percent = used * 100 // total
            else:
                used_percent = 0
            warn = params.get("warn", 80)
            crit = params.get("crit", 90)
            if used_percent >= crit:
                state = "CRIT"
            elif used_percent >= warn:
                state = "WARN"
            else:
                state = "OK"
            message = "Archive Dir: " + str(used) + " MB of " + str(total) + " MB used (" + str(used_percent) + "%)"
            return {"changed": False, "msg": message, "data": {"state": state, "metrics": {"arch_used_mb": used, "arch_total_mb": total, "arch_used_percent": used_percent}, "details": ""}}
        return {"changed": False, "msg": "no archive dir information", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    return {"changed": False, "msg": "unknown item: " + str(item), "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
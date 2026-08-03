def main(ctx, params):
    if params.get("_discover"):
        # Probe for Libelle Business Shadow software
        res = ctx.run(["/opt/libelle/bin/trd", "status"], mutates=False)
        if res.rc == 127:
            return {"changed": False, "msg": "Libelle Business Shadow not installed",
                    "data": {"discovery": []}}
        if res.rc != 0:
            return {"changed": False, "msg": "Libelle status command failed",
                    "data": {"discovery": []}}
        
        # Check if we can parse a status
        status_found = _find_status(res.stdout)
        if status_found == None:
            return {"changed": False, "msg": "no libelle status found",
                    "data": {"discovery": []}}
        
        return {"changed": False, "msg": "discovered 1 service",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": []}
                ]}}
    
    # Check mode
    res = ctx.run(["/opt/libelle/bin/trd", "status"], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "Libelle Business Shadow not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.rc != 0:
        return {"changed": False, "msg": "failed to get libelle status",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    parsed = _parse_libelle_output(res.stdout)
    if parsed.get("libelle_status") == None:
        return {"changed": False, "msg": "No information about libelle status found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    status = parsed["libelle_status"]
    state = "OK" if status == "RUN" else "CRIT"
    msg = "Status is: %s" % status
    if parsed.get("host") != None:
        msg += ", Host: %s" % parsed["host"]
    
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {}, "details": ""}}


def _find_status(output):
    for line in output.splitlines():
        parts = line.split(":", 1)
        if len(parts) == 2:
            key = parts[0].strip()
            val = parts[1].strip()
            if key.startswith("Status") and val.startswith("Status") == False:
                return val
    return None


def _parse_libelle_output(output):
    parsed = {}
    for line in output.splitlines():
        parts = line.split(":", 1)
        if len(parts) == 2:
            key = parts[0].strip()
            val = parts[1].strip()
            if key == "Host":
                parsed["host"] = val
            elif key == "Release":
                parsed["release"] = val
            elif key.startswith("Start-Time"):
                parsed["start_time"] = val
            elif key.startswith("Status"):
                parsed["libelle_status"] = val
    return parsed
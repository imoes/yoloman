TRD_CANDIDATES = ["/opt/libelle/bin/trd", "/opt/libelle/trd"]

def _extract_status(s):
    tokens = s.strip().split()
    if len(tokens) == 0:
        return ""
    if len(tokens) >= 2 and tokens[0].isdigit():
        return tokens[-1]
    return tokens[0]

def _parse_trd_output(stdout):
    parsed = {}
    for line in stdout.splitlines():
        if ":" not in line:
            continue
        parts = line.split(":")
        k = parts[0]
        k_s = k.strip()
        if len(parts) > 3 and (k_s.startswith("trdrecover") or k_s.startswith("trdarchiver")):
            parsed["process"] = k.rstrip()
            parsed["process_status"] = _extract_status(parts[3])
        elif k_s.startswith("Status") and len(parts) > 1:
            parsed["libelle_status"] = parts[1].strip()
    return parsed

def main(ctx, params):
    trd_bin = None
    for p in TRD_CANDIDATES:
        if ctx.file_exists(p):
            trd_bin = p
            break

    if trd_bin == None:
        if params.get("_discover"):
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "Libelle TRD binary not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    res = ctx.run([trd_bin, "info"], mutates=False, ok_codes=[0, 1, 2])
    if not res.stdout:
        if params.get("_discover"):
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "trd info returned no output (rc=%d)" % res.rc,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stderr},
        }

    parsed = _parse_trd_output(res.stdout)

    if params.get("_discover"):
        if "process" in parsed:
            return {
                "changed": False,
                "msg": "discovered 1 items",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
            }
        return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}

    if "process" not in parsed:
        return {
            "changed": False,
            "msg": "No Active Process found!",
            "data": {"state": "CRIT", "metrics": {}, "details": ""},
        }

    proc = parsed["process"]
    status = parsed.get("process_status", "")
    state = "OK" if status == "RUN" else "CRIT"
    msg = "Active Process is: %s, Status: %s" % (proc, status)

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": {}, "details": ""},
    }
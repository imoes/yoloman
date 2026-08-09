# Translation of checkmk.libelle_business_shadow_archive_dir
# Libelle Business Shadow Archive Dir (filesystem-style) check,
# reproduced for the yolo-man Starlark runtime WITHOUT Checkmk installed.
#
# The original Checkmk agent plugin reads its data from a Libelle Business
# Shadow installation. There is no on-host "libelle_business_shadow" agent
# section available to the yolo-man agent, so the REAL data source is the
# Libelle install directory itself. We probe for it first and report absence
# honestly (empty discovery / UNKNOWN) rather than synthesising data.

def _to_mb(size):
    s = size.strip()
    s = s.replace(" ", "")
    if s.endswith("MB"):
        return int(float(s[:-2]))
    if s.endswith("GB"):
        return int(float(s[:-2])) * 1024
    if s.endswith("TB"):
        return int(float(s[:-2])) * 1024 * 1024
    if s.endswith("PB"):
        return int(float(s[:-2])) * 1024 * 1024 * 1024
    if s.endswith("EB"):
        return int(float(s[:-2])) * 1024 * 1024 * 1024 * 1024
    return int(float(s))

def _parse_libelle_info(text):
    parsed = {}
    lines = text.split("\n")
    for line in lines:
        cols = line.split()
        if len(cols) >= 2 and cols[0].startswith("Archive-Dir total"):
            parsed["arch_total_mb"] = _to_mb(cols[1])
        elif len(cols) >= 2 and cols[0].startswith("Archive-Dir free"):
            parsed["arch_free_mb"] = _to_mb(cols[1])
    return parsed

def _probe_libelle_install(ctx):
    home = ctx.stat("/opt/libelle")
    if home == None or not home.get("exists", False) or not home.get("is_dir", False):
        return None
    summary = ctx.stat("/opt/libelle/status.txt")
    if summary == None or not summary.get("exists", False):
        res = ctx.run(["ls", "-1", "/opt/libelle"], mutates=False)
        if res.rc != 0 or res.stdout == "":
            return None
        return ""
    return ctx.file_read("/opt/libelle/status.txt")

def main(ctx, params):
    if params.get("_discover"):
        text = _probe_libelle_install(ctx)
        if text == None:
            return {"changed": False, "msg": "no libelle installation found",
                    "data": {"discovery": []}}
        parsed = _parse_libelle_info(text)
        if "arch_total_mb" in parsed and "arch_free_mb" in parsed:
            entry = {
                "item": "Archive Dir",
                "params": {"warn": 70, "crit": 90},
                "metrics": ["used_percent"],
            }
            return {"changed": False, "msg": "discovered 1 item",
                    "data": {"discovery": [entry]}}
        return {"changed": False, "msg": "no archive dir sizing found",
                "data": {"discovery": []}}

    item = params.get("item", "")
    if item != "Archive Dir":
        return {"changed": False,
                "msg": "no such item: " + str(item),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    text = _probe_libelle_install(ctx)
    if text == None:
        return {"changed": False,
                "msg": "no libelle installation found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    parsed = _parse_libelle_info(text)
    if "arch_total_mb" not in parsed or "arch_free_mb" not in parsed:
        return {"changed": False,
                "msg": "no archive dir sizing found in libelle output",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    total = parsed["arch_total_mb"]
    free = parsed["arch_free_mb"]
    used = total - free
    used_percent = 0.0
    if total > 0:
        used_percent = (used * 100.0) / total

    warn = params.get("warn", 70)
    crit = params.get("crit", 90)
    levels = params.get("levels")
    if levels != None:
        warn = levels[0]
        crit = levels[1]

    if used_percent >= crit:
        state = "CRIT"
    elif used_percent >= warn:
        state = "WARN"
    else:
        state = "OK"

    msg = "Archive Dir %d%% used (free %d MB of %d MB)" % (
        int(used_percent), free, total)
    details = "total=%d MB free=%d MB used=%d MB used_percent=%s" % (
        total, free, used, str(used_percent))

    return {"changed": False, "msg": msg,
            "data": {"state": state,
                     "metrics": {"used_percent": used_percent,
                                 "used_mb": float(used),
                                 "free_mb": float(free),
                                 "total_mb": float(total)},
                     "details": details}}
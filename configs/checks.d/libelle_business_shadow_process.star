def _to_mb(size):
    size = size.replace(" ", "")
    if size.endswith("MB"):
        return int(float(size[:-2]))
    if size.endswith("GB"):
        return int(float(size[:-2])) * 1024
    if size.endswith("TB"):
        return int(float(size[:-2])) * 1024 * 1024
    if size.endswith("PB"):
        return int(float(size[:-2])) * 1024 * 1024 * 1024
    if size.endswith("EB"):
        return int(float(size[:-2])) * 1024 * 1024 * 1024 * 1024
    return int(float(size))

def _parse_info(raw):
    parsed = {}
    for line in raw.splitlines():
        parts = line.split(":")
        key = parts[0].strip() if len(parts) > 0 else ""
        val = parts[1].strip() if len(parts) > 1 else ""
        if key.startswith("Host"):
            parsed["host"] = val
        elif key.startswith("Start-Time"):
            parsed["start_time"] = val
        elif key == "Release":
            parsed["release"] = val
        elif key.startswith("Status"):
            parsed["libelle_status"] = val
        elif key.startswith("trdrecover") or key.startswith("trdarchiver"):
            parsed["process"] = key.split()[0]
            parsed["process_status"] = parts[2].strip() if len(parts) > 2 else ""
        elif key.startswith("Archive-Dir total"):
            parsed["arch_total_mb"] = _to_mb(val)
        elif key.startswith("Archive-Dir free"):
            parsed["arch_free_mb"] = _to_mb(val)
    return parsed

def _read_shadow_data(ctx):
    res = ctx.run(["cat", "/proc/libelle_business_shadow"], mutates=False)
    if res.rc == 127 or res.rc != 0:
        return None
    return res.stdout

def main(ctx, params):
    if params.get("_discover"):
        data = _read_shadow_data(ctx)
        if data == None:
            return {"changed": False, "msg": "Libelle Business Shadow not installed",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 0 items",
                "data": {"discovery": []}}

    item = params.get("item", "")
    data = _read_shadow_data(ctx)
    if data == None:
        return {"changed": False, "msg": "Libelle Business Shadow not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    parsed = _parse_info(data)
    message = "Libelle Business Shadow"
    if "host" in parsed:
        message += ", Host: %s" % parsed["host"]
    if "release" in parsed:
        message += ", Release: %s" % parsed["release"]
    if "start_time" in parsed:
        message += ", Start Time: %s" % parsed["start_time"]

    return {"changed": False, "msg": message,
            "data": {"state": "OK", "metrics": {}, "details": ""}}
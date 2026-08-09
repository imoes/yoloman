def _split_first_space(line):
    idx = line.find(" ")
    if idx == -1:
        return (line, "")
    return (line[:idx], line[idx+1:])

def _parse_byte_values(value_str):
    if value_str == "N/A":
        return 0.0
    value_str = value_str.rstrip("iB")
    if value_str.endswith("E"):
        return float(value_str[:-1]) * 1024 * 1024 * 1024 * 1024
    if value_str.endswith("P"):
        return float(value_str[:-1]) * 1024 * 1024 * 1024
    if value_str.endswith("T"):
        return float(value_str[:-1]) * 1024 * 1024
    if value_str.endswith("G"):
        return float(value_str[:-1]) * 1024
    if value_str.endswith("M"):
        return float(value_str[:-1])
    if value_str.lower().endswith("k"):
        return float(value_str[:-1]) / 1024
    return float(value_str) / (1024 * 1024)

def _sanitize_line(line):
    units = ("k", "K", "B", "M", "G", "T", "P", "E", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB")
    sanitized_line = []
    for word in line:
        if word in units and sanitized_line:
            sanitized_line[-1] += word
        else:
            sanitized_line.append(word)
    return sanitized_line

def _normalize(s):
    return s.replace("-", "").replace(":", "").replace(" ", "")

def _parse_ceph_df(text):
    parsed = {}
    section = None
    global_headers = None
    pools_headers = None
    for raw_line in text.splitlines():
        if not raw_line.strip():
            continue
        line = raw_line.split()
        if not line:
            continue
        if line[0] in ["GLOBAL:", "RAW"] or _normalize("".join(line)) == "RAWSTORAGE":
            section = "global"
            continue
        if _normalize("".join(line)) == "POOLS":
            section = "pools"
            continue
        line = _sanitize_line(line)
        if section == "global":
            hdr_joined = _normalize("".join(line))
            if hdr_joined == "SIZEAVAILRAWUSEDPERCENTRAWUSED" and len(line) == 7:
                global_headers = ["SIZE", "AVAIL", "RAW USED", "%RAW USED", "OBJECTS"]
            elif hdr_joined == "CLASSSIZEAVAILUSED..." and len(line) == 7:
                global_headers = ["CLASS", "SIZE", "AVAIL", "USED", "RAW USED", "%RAW USED"]
            elif global_headers != None:
                parsed.setdefault("SUMMARY", dict(zip(global_headers, line)))
            continue
        if section == "pools":
            hdr_joined = _normalize("".join(line))
            if hdr_joined == "NAMEIDCATEGORYQUOTAOBJECTSQUOTABYTESUSED..." and len(line) == 16:
                pools_headers = ["NAME", "ID", "CATEGORY", "QUOTA OBJECTS", "QUOTA BYTES", "USED", "%USED", "MAX AVAIL", "OBJECTS", "DIRTY", "READ", "WRITE", "RAW USED"]
            elif hdr_joined == "NAMEIDCATEGORYQUOTAOBJECTSQUOTABYTES..." and len(line) == 14:
                pools_headers = ["NAME", "ID", "CATEGORY", "QUOTA OBJECTS", "QUOTA BYTES", "USED", "%USED", "MAX AVAIL", "OBJECTS", "DIRTY", "READ", "WRITE", "RAW USED"]
            elif hdr_joined == "POOLIDSTOREDused..." and len(line) == 13:
                pools_headers = ["POOL", "ID", "STORED", "OBJECTS", "USED", "%USED", "MAX AVAIL", "QUOTA OBJECTS", "QUOTA BYTES", "DIRTY", "USED COMPR", "UNDER COMPR"]
            elif hdr_joined == "POOLIDPGSstored..." and len(line) == 14:
                pools_headers = ["POOL", "ID", "PGS", "STORED", "OBJECTS", "USED", "%USED", "MAX AVAIL", "QUOTA OBJECTS", "QUOTA BYTES", "DIRTY", "USED COMPR", "UNDER COMPR"]
            elif hdr_joined == "POOLIDstored(data)(omap)objectsused(data)(omap)...maxavail..." and len(line) == 19:
                pools_headers = ["POOL", "ID", "STORED", "(DATA)", "(OMAP)", "OBJECTS", "USED", "(DATA)", "(OMAP)", "%USED", "MAX AVAIL", "QUOTA OBJECTS", "QUOTA BYTES", "DIRTY", "USED COMPR", "UNDER COMPR"]
            elif hdr_joined == "POOLIDPGsstored(data)(omap)..." and len(line) == 20:
                pools_headers = ["POOL", "ID", "PGS", "STORED", "STORED (DATA)", "STORED (OMAP)", "OBJECTS", "USED", "USED (DATA)", "USED (OMAP)", "%USED", "MAX AVAIL", "QUOTA OBJECTS", "QUOTA BYTES", "DIRTY", "USED COMPR", "UNDER COMPR"]
            elif pools_headers != None and len(line) >= 14:
                item_name = line[0]
                values = line[1:]
                parsed.setdefault(item_name, dict(zip(pools_headers[1:], values)))
            continue
    mps = []
    for mp, data in parsed.items():
        if mp == "SUMMARY":
            size_mb = _parse_byte_values(data.get("SIZE", "0"))
            avail_mb = _parse_byte_values(data.get("AVAIL", "0"))
        else:
            avail_mb = _parse_byte_values(data.get("MAX AVAIL", "0"))
            used_size = data.get("STORED", data.get("USED", "0"))
            size_mb = avail_mb + _parse_byte_values(used_size)
        mps.append((mp, size_mb, avail_mb, 0))
    return mps

def _grade(size_mb, used_mb, warn, crit):
    if size_mb <= 0:
        return "UNKNOWN"
    pct = (used_mb / size_mb) * 100
    if pct >= float(crit):
        return "CRIT"
    if pct >= float(warn):
        return "WARN"
    return "OK"

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["ceph", "df"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "ceph not available", "data": {"discovery": []}}
        text = res.stdout
        if not text:
            return {"changed": False, "msg": "no ceph df output", "data": {"discovery": []}}
        pools = _parse_ceph_df(text)
        discovery = []
        warn = 80
        crit = 90
        for mp, size_mb, avail_mb, _in_use in pools:
            used_mb = size_mb - avail_mb
            if mp != "SUMMARY":
                discovery.append({"item": mp, "params": {"warn": warn, "crit": crit}, "metrics": ["used_percent", "size", "free"]})
        return {"changed": False, "msg": "discovered %d items" % len(discovery), "data": {"discovery": discovery}}

    item = params.get("item", "")
    res = ctx.run(["ceph", "df"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "ceph not available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    text = res.stdout
    if not text:
        return {"changed": False, "msg": "no ceph df output", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    pools = _parse_ceph_df(text)
    warn = params.get("warn", 80)
    crit = params.get("crit", 90)
    found = None
    for mp, size_mb, avail_mb, _in_use in pools:
        if mp == item:
            found = (mp, size_mb, avail_mb)
            break
    if found == None:
        return {"changed": False, "msg": "no such pool: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    mp, size_mb, avail_mb = found
    used_mb = size_mb - avail_mb
    if size_mb > 0:
        used_percent = (used_mb / size_mb) * 100
    else:
        used_percent = 0
    state = _grade(size_mb, used_mb, warn, crit)
    details = "Pool %s: Size %f MB, Used %f MB, Avail %f MB (%d%% used)" % (item, size_mb, used_mb, avail_mb, used_percent)
    return {"changed": False, "msg": details, "data": {"state": state, "metrics": {"used_percent": used_percent, "size": size_mb, "free": avail_mb}, "details": details}}
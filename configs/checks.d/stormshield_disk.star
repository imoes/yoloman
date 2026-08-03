def _fetch_snmp(ctx, community, host, oid, walk):
    if walk:
        cmd = ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid]
    else:
        cmd = ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid]
    res = ctx.run(cmd, mutates=False)
    if res.rc == 127:
        return None
    if res.rc != 0:
        return None
    return res.stdout

def _sys_descr(ctx, community, host):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if res.rc != 0:
        return ""
    return res.stdout.strip()

def _exists(ctx, community, host, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc != 0:
        return False
    return True

def _is_stormshield(ctx, community, host):
    sd = _sys_descr(ctx, community, host)
    if sd == "":
        return False
    if sd == ".1.3.6.1.4.1.11256.2.0":
        return True
    if sd.startswith(".1.3.6.1.4.1.11256.1"):
        return True
    if sd.startswith(".1.3.6.1.4.1.8072"):
        return True
    return False

def _has_basic(ctx, community, host):
    return _exists(ctx, community, host, ".1.3.6.1.4.1.11256.1.0.1.0")

def _has_ha(ctx, community, host):
    return _exists(ctx, community, host, ".1.3.6.1.4.1.11256.1.11.1.0")

def _parse_table(lines):
    result = {}
    if not lines:
        return result
    for line in lines.splitlines():
        s = line.find(" ")
        if s == -1:
            continue
        oid = line[:s]
        val = line[s + 1:].strip()
        if oid.endswith('""') or (len(val) > 1 and val.endswith('"') and val.startswith('"')):
            if len(val) >= 2 and val[0] == '"' and val[-1] == '"':
                val = val[1:-1]
        result[oid] = val
    return result

def _base_oid(oid):
    parts = oid.split(".")
    # OIDEnd index omitted (first component is the index part)
    return ".".join(parts[1:]) if len(parts) > 1 else oid

def _index_from_oid(oid, base):
    rel = oid[len(base) + 1:] if oid.startswith(base) else oid
    return rel

def _fetch_disk_table(ctx, community, host):
    standalone_lines = _fetch_snmp(ctx, community, host, ".1.3.6.1.4.1.11256.1.0.1", False)
    standalone_map = {}
    if standalone_lines:
        standalone_map = _parse_table(standalone_lines)

    cluster_lines = _fetch_snmp(ctx, community, host, ".1.3.6.1.4.1.11256.1.10.5.1", True)
    cluster_table = _parse_table(cluster_lines) if cluster_lines else {}

    parsed = []
    if cluster_table:
        base = ".1.3.6.1.4.1.11256.1.10.5.1"
        indexes = []
        for oid in cluster_table:
            idx = oid[len(base) + 1:]
            if idx:
                indexes.append(idx.split(".")[0])
        seen = {}
        for oid in cluster_table:
            idx = oid[len(base) + 1:]
            if not idx:
                continue
            index_part = idx.split(".")[0]
            col = oid[len(base) + 1 + len(index_part):]
            if col.startswith("."):
                col = col[1:]
            key = index_part
            if key not in seen:
                seen[key] = {"index": "", "name": "", "selftest": "", "israid": "", "raidstatus": "", "position": ""}
            colname = {".1": "index", ".2": "name", ".3": "selftest", ".4": "israid", ".5": "raidstatus", ".6": "position"}
            field = colname.get(col)
            if field and col in (".1", ".2", ".3", ".4", ".5", ".6"):
                seen[key][field] = cluster_table[oid]
        for key in sorted(seen.keys()):
            d = seen[key]
            parsed.append({
                "clusterindex": d["index"].split(".")[0] if d["index"] else key,
                "index": d["index"],
                "name": d["name"],
                "selftest": d["selftest"],
                "israid": d["israid"],
                "raidstatus": d["raidstatus"],
                "position": d["position"],
            })
        return parsed

    if standalone_map:
        vals = []
        for col in (".1", ".2", ".3", ".4", ".5", ".6"):
            vals.append(standalone_map.get(".1.3.6.1.4.1.11256.1.0.1" + col, ""))
        parsed.append({
            "clusterindex": "0",
            "index": vals[0],
            "name": vals[1],
            "selftest": vals[2],
            "israid": vals[3],
            "raidstatus": vals[4],
            "position": vals[5],
        })
        return parsed

    return []


def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    if params.get("_discover"):
        if not _is_stormshield(ctx, community, host):
            return {"changed": False, "msg": "not a stormshield device", "data": {"discovery": []}}
        if not _has_basic(ctx, community, host):
            return {"changed": False, "msg": "stormshield basic info absent", "data": {"discovery": []}}
        section = _fetch_disk_table(ctx, community, host)
        out = []
        for disk in section:
            out.append({"item": disk["clusterindex"], "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    if not _is_stormshield(ctx, community, host):
        return {"changed": False, "msg": "not a stormshield device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not _has_basic(ctx, community, host):
        return {"changed": False, "msg": "stormshield basic info absent",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    section = _fetch_disk_table(ctx, community, host)
    if not section:
        return {"changed": False, "msg": "no disk data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    target = None
    for disk in section:
        if item == disk["clusterindex"]:
            target = disk
            break
    if target == None:
        return {"changed": False, "msg": "no such item: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    infotext = "Device Index %s, Selftest: %s, Device Mount Point Name: %s" % (
        target["index"], target["selftest"], target["name"])
    if target["selftest"] != "PASSED":
        state = "WARN"
    else:
        state = "OK"
    if target["israid"] != "0":
        infotext = infotext + ", Raid active, Raid Status %s, Disk Position %s" % (
            target["raidstatus"], target["position"])

    return {"changed": False, "msg": infotext,
            "data": {"state": state, "metrics": {}, "details": infotext}}
def _brocade_sensor_convert(section, what):
    return_list = []
    for row in section:
        presence = row[0]
        state = row[1]
        name = row[2].lstrip()
        if name.startswith(what) and presence != "6" and (_saveint(state) > 0 or what == "Power"):
            sensor_id = name.split("#")[-1]
            return_list.append([sensor_id, name, state])
    return return_list

def _saveint(i):
    if not i:
        return 0
    digits = i
    if digits.startswith("-"):
        digits = digits[1:]
    if not digits.isdigit():
        return 0
    return int(i)

def _detect_brocade(ctx, host, community):
    sysoid = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if sysoid.rc != 0:
        return False
    oid = sysoid.stdout.strip()
    if oid.startswith(".1.3.6.1.4.1.1588.2.1.1") or oid.startswith(".1.3.6.1.24.1.1588.2.1.1") or oid.startswith(".1.3.6.1.4.1.1588.2.2.1") or oid.startswith(".1.3.6.1.4.1.1588.3.3.1") or oid == ".1.3.6.1.4.1.1916.2.306":
        return True
    return False

def _read_section(ctx, host, community):
    base = ".1.3.6.1.4.1.1588.2.1.1.1.1.22.1"
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + ".3"], mutates=False)
    if res.rc != 0:
        return []
    presence_map = {}
    state_map = {}
    name_map = {}
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        idx = oid[len(base + ".3") + 1:]
        presence_map[idx] = line[sp + 1:]
    res4 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + ".4"], mutates=False)
    if res4.rc == 0:
        for line in res4.stdout.splitlines():
            sp = line.find(" ")
            if sp < 0:
                continue
            oid = line[:sp]
            idx = oid[len(base + ".4") + 1:]
            state_map[idx] = line[sp + 1:]
    res5 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + ".5"], mutates=False)
    if res5.rc == 0:
        for line in res5.stdout.splitlines():
            sp = line.find(" ")
            if sp < 0:
                continue
            oid = line[:sp]
            idx = oid[len(base + ".5") + 1:]
            name_map[idx] = line[sp + 1:]
    section = []
    for idx in presence_map:
        section.append([presence_map[idx], state_map.get(idx, "0"), name_map.get(idx, "")])
    return section

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    if params.get("_discover"):
        if not _detect_brocade(ctx, host, community):
            return {"changed": False, "msg": "not a brocade device", "data": {"discovery": []}}
        section = _read_section(ctx, host, community)
        sensors = _brocade_sensor_convert(section, "Power")
        discovery = []
        for sensor in sensors:
            discovery.append({"item": sensor[0], "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d power supplies" % len(discovery), "data": {"discovery": discovery}}
    item = params.get("item", "")
    if not _detect_brocade(ctx, host, community):
        return {"changed": False, "msg": "not a brocade device", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    section = _read_section(ctx, host, community)
    sensors = _brocade_sensor_convert(section, "Power")
    for snmp_item, name, value in sensors:
        if item == snmp_item:
            v = _saveint(value)
            if v != 1:
                return {"changed": False, "msg": "Error on supply %s" % name, "data": {"state": "CRIT", "metrics": {}, "details": ""}}
            return {"changed": False, "msg": "No problems found", "data": {"state": "OK", "metrics": {}, "details": ""}}
    return {"changed": False, "msg": "Supply not found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
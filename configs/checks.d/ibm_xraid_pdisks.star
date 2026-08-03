def _snmp_get_table(ctx, community, host, column_base):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, column_base],
        mutates=False,
    )
    rows = {}
    if res.rc != 0:
        return rows
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        oid = line[:sp]
        val = line[sp + 1:]
        if not oid.startswith(column_base + "."):
            continue
        index = oid[len(column_base) + 1:]
        rows[index] = val
    return rows

def _snmp_get_value(ctx, community, host, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout.strip()

def _safe_int_last_char(s):
    if len(s) == 0:
        return None
    ch = s[-1]
    digits = "0123456789"
    if ch in digits:
        return int(ch)
    return None

def _parse_pdisks(ctx, community, host):
    base = ".1.3.6.1.4.1.795.14.1"
    oid_slot = base + ".503.1.1.4"
    oid_diskid = base + ".400.1.1.1"
    oid_disktype = base + ".400.1.1.5"
    oid_state = base + ".400.1.1.11"
    oid_desc = base + ".400.1.1.12"

    col_slot = _snmp_get_table(ctx, community, host, oid_slot)
    col_diskid = _snmp_get_table(ctx, community, host, oid_diskid)
    col_disktype = _snmp_get_table(ctx, community, host, oid_disktype)
    col_state = _snmp_get_table(ctx, community, host, oid_state)
    col_desc = _snmp_get_table(ctx, community, host, oid_desc)

    data = {}
    for index in col_desc:
        slot_desc = col_desc.get(index, "")
        disk_id = col_diskid.get(index, "")
        disk_type = col_disktype.get(index, "")
        disk_state = col_state.get(index, "")

        slot_desc_lower = slot_desc.lower()
        if "slot" not in slot_desc_lower:
            continue
        parts = slot_desc.split(", ")
        if len(parts) < 3:
            continue
        slot_id_int = _safe_int_last_char(parts[-1])
        enc_id = _safe_int_last_char(parts[-2])
        hba_id = _safe_int_last_char(parts[-3])
        if slot_id_int == None or enc_id == None or hba_id == None:
            continue
        disk_path = "%d/%d/%d" % (hba_id, enc_id, slot_id_int)
        data[disk_path] = (slot_id_int, disk_id, disk_type, disk_state, slot_desc)
    return data

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        descr = _snmp_get_value(ctx, community, host, ".1.3.6.1.2.1.1.1.0")
        detect_oid_val = _snmp_get_value(ctx, community, host, ".1.3.6.1.4.1.795.14.1.100.1.0")
        if descr == None or detect_oid_val == None:
            return {"changed": False, "msg": "not an IBM X-RAID system", "data": {"discovery": []}}
        if descr != "software: windows" and descr != "linux":
            return {"changed": False, "msg": "not an IBM X-RAID system", "data": {"discovery": []}}

        section = _parse_pdisks(ctx, community, host)
        discovery = []
        for disk_path in section:
            discovery.append({"item": disk_path, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d items" % len(discovery), "data": {"discovery": discovery}}

    item = params.get("item", "")
    section = _parse_pdisks(ctx, community, host)
    for disk_path, disk_entry in section.items():
        if disk_path == item:
            _slot_label, _disk_id, _disk_type, disk_state, slot_desc = disk_entry
            if disk_state == "3":
                return {"changed": False, "msg": "Disk is active [%s]" % slot_desc,
                        "data": {"state": "OK", "metrics": {}, "details": ""}}
            if disk_state == "4":
                return {"changed": False, "msg": "Disk is rebuilding [%s]" % slot_desc,
                        "data": {"state": "WARN", "metrics": {}, "details": ""}}
            if disk_state == "5":
                return {"changed": False, "msg": "Disk is dead [%s]" % slot_desc,
                        "data": {"state": "CRIT", "metrics": {}, "details": ""}}

    return {"changed": False, "msg": "disk is missing", "data": {"state": "CRIT", "metrics": {}, "details": ""}}
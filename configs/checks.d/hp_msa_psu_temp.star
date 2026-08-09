def _parse_section(text):
    section = {}
    cur_item = None
    cur = {}
    for line in text.splitlines():
        s = line.strip()
        if not s:
            continue
        parts = s.split(" ")
        if len(parts) < 3:
            continue
        if parts[0] != "power-supplies":
            continue
        # parts: power-supplies <id> <field> [rest...]
        idx = parts[1]
        field = parts[2]
        val = " ".join(parts[3:]) if len(parts) > 3 else ""
        # treat same-id lines as same item keyed by name or id
        key = idx
        if field == "name":
            # use name as the item identifier for readability
            key = val
        if idx != cur_item:
            if cur_item != None and cur.get("name", "").startswith("") :
                # commit previous only if it has the needed data
                pass
            # We key items by their 'name' value if present, else by id
            cur_item = idx
            cur = {}
            cur["_id"] = idx
        cur[field] = val
        if field == "name":
            cur["name"] = val
    # Re-key: we want the item name
    # Re-iterate to build final map keyed by name field or id
    # Simpler: re-parse and key by name
    return _rekey_by_name(text)


def _rekey_by_name(text):
    items = []
    cur = None
    for line in text.splitlines():
        s = line.strip()
        if not s:
            continue
        parts = s.split(" ")
        if len(parts) < 4:
            continue
        if parts[0] != "power-supplies":
            continue
        idx = parts[1]
        field = parts[2]
        val = " ".join(parts[3:])
        if cur == None or cur.get("_id") != idx:
            cur = {"_id": idx}
            items.append(cur)
        cur[field] = val
    result = {}
    for it in items:
        name = it.get("name", it.get("_id"))
        result[name] = it
    return result


def _is_present(data):
    indicators = ("dc12v", "dc5v", "dc33v", "dc12i", "dc5i", "dctemp")
    for i in indicators:
        v = data.get(i)
        if v != "0" and v != "":
            return True
    return False


def _get_data(ctx, host, community):
    # Try the on-host Checkmk agent section file first
    path = "/var/lib/cmkagent/hp_msa_psu"
    st = ctx.stat(path) if hasattr(ctx, "stat") else None
    if st != None and st.get("exists"):
        return ctx.file_read(path)
    # Fallback: there is no on-host Checkmk agent here.
    # This data comes from an HP MSA storage array; if not present, return None.
    return None


def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        text = _get_data(ctx, host, community)
        if text == None or text == "":
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        section = _rekey_by_name(text)
        discovery = []
        for item, data in section.items():
            if _is_present(data):
                discovery.append({"item": item, "params": {"warn": 40.0, "crit": 45.0},
                                  "metrics": ["temperature"]})
        return {"changed": False,
                "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    text = _get_data(ctx, params.get("host", "localhost"),
                     params.get("community", "public"))
    if text == None or text == "":
        return {"changed": False, "msg": "no HP MSA PSU data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    section = _rekey_by_name(text)
    data = section.get(item)
    if data == None:
        return {"changed": False, "msg": "no such PSU: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not _is_present(data):
        return {"changed": False, "msg": "PSU data invalid for: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    dctemp = data.get("dctemp")
    if dctemp == None or dctemp == "" or dctemp == "0":
        return {"changed": False, "msg": "no temperature data for: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    temp = float(dctemp)
    warn = params.get("warn", 40.0)
    crit = params.get("crit", 45.0)
    if temp >= crit:
        state = "CRIT"
    elif temp >= warn:
        state = "WARN"
    else:
        state = "OK"
    msg = "Temperature Power Supply %s: %f C" % (item, temp)
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"temperature": temp}, "details": ""}}
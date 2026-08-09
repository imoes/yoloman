# ibm_tl_media_access_devices — SNMP check for IBM tape library media access devices.
# Discovery walks the mediaAccessDevice OIDs; check grades device state via the
# sibling scsiProtocolController OIDs. Thresholds are vendor-supplied status
# codes, not numeric levels, so there are no warn/crit params to map.

def _parse_name(raw):
    # ibm_tape_library_parse_device_name: trim, collapse internal whitespace.
    return " ".join(raw.split())

def _device_state(avail, status):
    # ibm_tape_library_get_device_state: map (availability, operationalStatus) to (state, summary).
    # Availability: 1=other,2=unknown,3=running,4=offline,5=on,6=off,7=notInstalled,8=installError,...
    # OperationalStatus (SNIA): 0=unknown,1=other,2=ok,3=degraded,4=stopped,5=non-functional,...
    avail_int = int(avail) if avail.isdigit() else 0
    status_int = int(status) if status.isdigit() else 0
    if status_int in (0, 1):
        return ("WARN", "status unknown")
    if status_int == 3:
        return ("WARN", "status degraded")
    if status_int in (4, 5, 6, 7):
        return ("CRIT", "status not functional")
    if status_int == 2:
        if avail_int in (4, 7, 8):
            return ("CRIT", "device not available")
        if avail_int in (5, 6):
            return ("WARN", "device off")
        if avail_int in (0, 1, 2):
            return ("WARN", "availability unknown")
        return ("OK", "running")
    return ("OK", "ok")

def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        media_oid = "1.3.6.1.4.1.14851.3.1.6.2.1"
        walk = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Osn", host, media_oid + ".3"],
            mutates=False,
        )
        if walk.rc != 0:
            return {"changed": False, "msg": "no media access devices found",
                    "data": {"discovery": [], "host_labels": {}}}
        devices = {}
        for line in walk.stdout.splitlines():
            sp = line.find(" ")
            if sp < 0:
                continue
            full_oid = line[:sp]
            value = line[sp + 1:]
            if not full_oid.startswith(media_oid + ".3."):
                continue
            idx = full_oid[len(media_oid + ".3."):]
            name = _parse_name(value)
            if name == "" or name in devices:
                continue
            devices[name] = idx
        if not devices:
            return {"changed": False, "msg": "no media access devices found",
                    "data": {"discovery": [], "host_labels": {}}}
        discovery = []
        for name, idx in devices.items():
            discovery.append({
                "item": name,
                "params": {},
                "metrics": [],
                "service_labels": {"device_name": name},
            })
        return {"changed": False,
                "msg": "discovered %d media access devices" % len(discovery),
                "data": {"discovery": discovery, "host_labels": {}}}

    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base_oid = "1.3.6.1.4.1.14851.3.1.6.2.1"
    walk = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Osn", host, base_oid + ".3"],
        mutates=False,
    )
    if walk.rc != 0:
        return {"changed": False, "msg": "no media access devices found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    target_idx = None
    found = False
    for line in walk.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        full_oid = line[:sp]
        value = line[sp + 1:]
        if not full_oid.startswith(base_oid + ".3."):
            continue
        idx = full_oid[len(base_oid + ".3"):]
        name = _parse_name(value)
        if name == item:
            target_idx = idx
            found = True
            break
    if not found:
        return {"changed": False, "msg": "media access device not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    type_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, base_oid + ".2" + target_idx], mutates=False)
    clean_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, base_oid + ".6" + target_idx], mutates=False)
    ctrl_oid = "1.3.6.1.4.1.14851.3.1.12.2.1"
    ctrl_avail_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ctrl_oid + ".6" + target_idx], mutates=False)
    ctrl_status_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ctrl_oid + ".4" + target_idx], mutates=False)

    type_map = {
        "0": "unknown",
        "1": "worm drive",
        "2": "magneto optical drive",
        "3": "tape drive",
        "4": "dvd drive",
        "5": "cdrom drive",
    }
    clean_map = {"0": "unknown", "1": "true", "2": "false"}
    dev_type = type_map.get(type_res.stdout.strip(), "unknown") if type_res.rc == 0 else "unknown"
    dev_clean = clean_map.get(clean_res.stdout.strip(), "unknown") if clean_res.rc == 0 else "unknown"

    state = "OK"
    details = ""
    if ctrl_avail_res.rc == 0 and ctrl_status_res.rc == 0:
        s, summ = _device_state(ctrl_avail_res.stdout.strip(), ctrl_status_res.stdout.strip())
        state = s
        details = summ + "; Type: " + dev_type + ", Needs cleaning: " + dev_clean
    else:
        details = "Type: " + dev_type + ", Needs cleaning: " + dev_clean

    return {"changed": False,
            "msg": "Type: " + dev_type + ", Needs cleaning: " + dev_clean,
            "data": {"state": state, "metrics": {}, "details": details}}
PROVISIONING_MAP = {
    1: "FULL",
    2: "TPVV",
    3: "SNP",
    4: "PEER",
    5: "UNKNOWN",
    6: "TDVV",
    7: "DDS",
}

STATE_MAP = {
    1: "OK",
    2: "WARN",
    3: "CRIT",
}

def main(ctx, params):
    par_host = params.get("host", "localhost")
    port = params.get("port", 8080)
    username = params.get("username", "3paradm")
    password = params.get("password", "3pardata")
    base_url = "https://%s:%d/api/v1" % (par_host, port)

    auth_res = ctx.run([
        "curl", "-sk", "--max-time", "30", "-X", "POST",
        "-H", "Content-Type: application/json",
        "-d", '{"user":"%s","password":"%s"}' % (username, password),
        base_url + "/credentials",
    ], mutates=False)

    if auth_res.rc != 0 or not auth_res.stdout:
        err = "3PAR API auth failed: " + auth_res.stderr
        if params.get("_discover"):
            return {"changed": False, "msg": err, "data": {"discovery": []}}
        return {"changed": False, "msg": err,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    auth_data = json.decode(auth_res.stdout)
    session_key = auth_data.get("key", "")
    if not session_key:
        err = "3PAR API returned no session key"
        if params.get("_discover"):
            return {"changed": False, "msg": err, "data": {"discovery": []}}
        return {"changed": False, "msg": err,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    vols_res = ctx.run([
        "curl", "-sk", "--max-time", "30",
        "-H", "X-HP3PAR-WSAPI-SessionKey: " + session_key,
        "-H", "Accept: application/json",
        base_url + "/volumes",
    ], mutates=False)

    if vols_res.rc != 0 or not vols_res.stdout:
        err = "3PAR API volumes fetch failed: " + vols_res.stderr
        if params.get("_discover"):
            return {"changed": False, "msg": err, "data": {"discovery": []}}
        return {"changed": False, "msg": err,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    raw = json.decode(vols_res.stdout)
    members = raw.get("members", [])

    volumes = {}
    for vol in members:
        name = vol.get("name", "")
        if not name:
            continue
        policies = vol.get("policies", {})
        is_system = policies.get("system", False)

        total_mib = float(vol.get("sizeMiB", 0))
        user_space = vol.get("userSpace")
        if user_space != None:
            used_mib = float(user_space.get("usedMiB", 0))
            raw_reserved_mib = float(user_space.get("rawReservedMiB", 0))
        else:
            used_mib = float(vol.get("totalUsedMiB", 0))
            raw_reserved_mib = float(vol.get("totalReservedMiB", 0))
        free_mib = total_mib - used_mib
        provisioning_bytes = raw_reserved_mib * 1024 * 1024

        cap_eff = vol.get("capacityEfficiency")
        dedup = cap_eff.get("deduplication") if cap_eff != None else None
        compaction = cap_eff.get("compaction") if cap_eff != None else None

        prov_type_id = vol.get("provisioningType", 5)
        ptype = PROVISIONING_MAP.get(prov_type_id, "UNKNOWN")
        state_id = vol.get("state", 1)
        vol_state = STATE_MAP.get(state_id, "UNKNOWN")
        wwn = vol.get("wwn", "")

        volumes[name] = {
            "is_system": is_system,
            "total_mib": total_mib,
            "used_mib": used_mib,
            "free_mib": free_mib,
            "provisioning_bytes": provisioning_bytes,
            "dedup": dedup,
            "compaction": compaction,
            "ptype": ptype,
            "vol_state": vol_state,
            "wwn": wwn,
        }

    if params.get("_discover"):
        discovery = []
        for name in volumes:
            v = volumes[name]
            if not v["is_system"]:
                discovery.append({
                    "item": name,
                    "params": {"levels": (80.0, 90.0)},
                    "metrics": ["used_percent", "fs_used", "fs_free", "fs_provisioning"],
                })
        return {"changed": False, "msg": "discovered %d volumes" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    v = volumes.get(item)
    if v == None:
        return {"changed": False, "msg": "volume not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    total_mib = v["total_mib"]
    used_mib = v["used_mib"]
    free_mib = v["free_mib"]

    if total_mib <= 0:
        return {"changed": False, "msg": "volume has zero size",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    used_pct = (used_mib / total_mib) * 100.0
    levels = params.get("levels", (80.0, 90.0))
    warn = levels[0]
    crit = levels[1]
    fs_state = "CRIT" if used_pct >= crit else ("WARN" if used_pct >= warn else "OK")

    vol_state = v["vol_state"]
    if vol_state == "CRIT":
        fs_state = "CRIT"
    elif vol_state == "WARN" and fs_state == "OK":
        fs_state = "WARN"

    parts = ["Used: %f of %f MiB (%f%%)" % (used_mib, total_mib, used_pct)]
    parts.append("Type: %s" % v["ptype"])
    parts.append("WWN: %s" % v["wwn"])

    dedup = v["dedup"]
    compaction = v["compaction"]
    if dedup != None:
        parts.append("Dedup: %s" % str(dedup))
    if compaction != None:
        parts.append("Compact: %s" % str(compaction))

    metrics = {
        "used_percent": used_pct,
        "fs_used": used_mib,
        "fs_free": free_mib,
        "fs_provisioning": v["provisioning_bytes"],
    }

    return {
        "changed": False,
        "msg": ", ".join(parts),
        "data": {"state": fs_state, "metrics": metrics, "details": ""},
    }
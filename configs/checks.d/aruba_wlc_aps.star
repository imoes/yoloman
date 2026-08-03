_MAP_AP_PRODUCTS = {
    "1": "a50", "2": "a52", "3": "a60", "4": "a61", "5": "a70",
    "6": "walljackAp61", "7": "a2E", "8": "ap1200", "9": "ap80s",
    "10": "ap80m", "11": "wg102", "12": "ap40", "13": "ap41",
    "14": "ap65", "15": "NesotMW1700", "16": "ortronics Wi Jack Duo",
    "17": "ortronics Duo", "18": "ap80MB", "19": "ap80SB", "20": "ap85",
    "21": "ap124", "22": "ap125", "23": "ap120", "24": "ap121",
    "25": "ap1250", "26": "ap120abg", "27": "ap121abg", "28": "ap124abg",
    "29": "ap125abg", "30": "rap5wn", "31": "rap5", "32": "rap2wg",
    "33": "reserved-4", "34": "ap105", "35": "ap65wb", "36": "ap651",
    "37": "reserved-6", "38": "ap60p", "39": "reserved-7", "40": "ap92",
    "41": "ap93", "42": "ap68", "43": "ap68p", "44": "ap175p",
    "45": "ap175ac", "46": "ap175dc", "47": "ap134", "48": "ap135",
    "49": "reserved-8", "50": "ap93h", "51": "rap3wn", "52": "rap3wnp",
    "53": "ap104", "54": "rap155", "55": "rap155p", "56": "rap108",
    "57": "rap109", "58": "ap224", "59": "ap225", "60": "ap114",
    "61": "ap115", "62": "rap109L", "63": "ap274", "64": "ap275",
    "65": "ap214a", "66": "ap215a", "67": "ap204", "68": "ap205",
    "69": "ap103", "70": "ap103H", "72": "ap227", "73": "ap214",
    "74": "ap215", "75": "ap228", "76": "ap205H", "9999": "undefined",
}

_MAP_STATE = {"1": (0, "up"), "2": (2, "down")}

_BASE_OID = ".1.3.6.1.4.1.14823.2.2.1.5.2.1.4.1"


def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        sysoid = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if sysoid.rc != 0:
            return {"changed": False, "msg": "no aruba wlc found", "data": {"discovery": []}}
        if not sysoid.stdout.startswith(".1.3.6.1.4.1.14823.1.1"):
            return {"changed": False, "msg": "no aruba wlc found", "data": {"discovery": []}}

        walk = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, _BASE_OID + ".3"],
            mutates=False,
        )
        if walk.rc != 0:
            return {"changed": False, "msg": "no aruba wlc found", "data": {"discovery": []}}

        names = {}
        for line in walk.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid, val = parts[0], parts[1]
            idx = oid[len(_BASE_OID) + 1:]
            names[idx] = _strip_snmp(val)

        aps = []
        for idx in names:
            status = ctx.run(
                ["snmpget", "-v2c", "-c", community, "-Oqv", host, _BASE_OID + ".19." + idx],
                mutates=False,
            )
            unprov = ctx.run(
                ["snmpget", "-v2c", "-c", community, "-Oqv", host, _BASE_OID + ".22." + idx],
                mutates=False,
            )
            if status.rc != 0 or unprov.rc != 0:
                continue
            st = _strip_snmp(status.stdout)
            up = _strip_snmp(unprov.stdout)
            if st == "1" and up != "1":
                aps.append({
                    "item": names[idx],
                    "params": {"warn": None, "crit": None},
                    "metrics": [],
                })
        return {
            "changed": False,
            "msg": "discovered %d APs" % len(aps),
            "data": {"discovery": aps, "host_labels": {"cmk/vendor": "aruba"}},
        }

    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    sysoid = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if sysoid.rc != 0 or not sysoid.stdout.startswith(".1.3.6.1.4.1.14823.1.1"):
        return {
            "changed": False,
            "msg": "no aruba wlc found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    gname_walk = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, _BASE_OID + ".3"],
        mutates=False,
    )
    if gname_walk.rc != 0:
        return {
            "changed": False,
            "msg": "failed to query AP table",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    idx_of = None
    for line in gname_walk.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid, val = parts[0], parts[1]
        idx = oid[len(_BASE_OID) + 1:]
        if _strip_snmp(val) == item:
            idx_of = idx
            break

    if idx_of == None:
        return {
            "changed": False,
            "msg": "no such AP: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    status = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, _BASE_OID + ".19." + idx_of],
        mutates=False,
    )
    unprov = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, _BASE_OID + ".22." + idx_of],
        mutates=False,
    )
    group = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, _BASE_OID + ".4." + idx_of],
        mutates=False,
    )
    sysloc = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, _BASE_OID + ".32." + idx_of],
        mutates=False,
    )

    if status.rc != 0:
        return {
            "changed": False,
            "msg": "failed to query AP status",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    ap_status = _strip_snmp(status.stdout)
    ap_unprov = _strip_snmp(unprov.stdout) if unprov.rc == 0 else ""
    ap_group = _strip_snmp(group.stdout) if group.rc == 0 else ""
    ap_sysloc = _strip_snmp(sysloc.stdout) if sysloc.rc == 0 else ""

    st, state_readable = _MAP_STATE.get(ap_status, (3, "unknown"))
    infotext = "Status: %s" % state_readable
    if ap_group != "":
        infotext += ", Group: %s" % ap_group
    if ap_sysloc != "":
        infotext += ", System location: %s" % ap_sysloc

    final_state = state_readable
    if ap_unprov == "1":
        final_state = "WARN"

    return {
        "changed": False,
        "msg": infotext,
        "data": {"state": final_state, "metrics": {}, "details": ""},
    }


def _strip_snmp(val):
    v = val.strip()
    if v.startswith("STRING: "):
        return v[len("STRING: "):].strip('"')
    if v.startswith("INTEGER: "):
        return v[len("INTEGER: "):]
    if v.startswith("OID: "):
        return v[len("OID: "):]
    if v.startswith("Timeticks: "):
        return v[len("Timeticks: "):]
    return v.strip('"')
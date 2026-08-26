# WLAN clients per SSID — translated from checkmk.wlc_clients (cmk/plugins/cisco/agent_based).
# READ-ONLY: snmpwalk only, never mutates.
#
# HAND-WRITTEN, and the only check in this catalogue that is. The batch produced a Starlark list
# comprehension with a syntax error ("got for, want ','") on every attempt, and Starlark has no
# comprehension over dict.items() the way the Python source does — so the loop is written out. A check that
# fails to parse is not a check, and a fourth prompt round is more expensive than reading the source.
#
# TWO DEVICE FAMILIES, both from Checkmk's own sections:
#
#   Airespace / classic Cisco WLC   .1.3.6.1.4.1.14179.2.1.1.1  column 2 = SSID, 42 = interface,
#                                                               38 = clients   -> clients PER INTERFACE
#   Catalyst 9800                   .1.3.6.1.4.1.9.9.512.1.1.1.1.4 = SSID list, zipped positionally with
#                                                               .1.3.6.1.4.1.14179.2.1.1.1.38 = clients
#
# DETECTED BY DATA, not by sysObjectID. Checkmk matches a list of seven 9800 product OIDs plus a regex over
# the Airespace ones, and that list is a maintenance burden which answers a question the walk itself answers:
# a controller either has the table or it does not. The cost of being wrong is an empty discovery, not a
# wrong reading.

_AIRESPACE = ".1.3.6.1.4.1.14179.2.1.1.1"
_C9800_SSID = ".1.3.6.1.4.1.9.9.512.1.1.1.1.4"

_SUMMARY = "Summary"


def _walk(ctx, params, oid):
    """(suffix, value) pairs under oid, or None when the walk failed."""
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
         "-Oqn", params.get("host", "localhost"), oid],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout:
        return None
    out = []
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        full = line[:sp]
        val = line[sp + 1:].strip()
        # Values arrive quoted for string columns (-Oq strips the type, not the quotes).
        if len(val) >= 2 and val[0] == "\"" and val[-1] == "\"":
            val = val[1:-1]
        if not full.startswith(oid):
            continue
        suffix = full[len(oid):]
        if suffix.startswith("."):
            suffix = suffix[1:]
        out.append((suffix, val))
    return out


def _to_int(s):
    if s == "":
        return 0
    neg = False
    i = 0
    if s[0] == "-":
        neg = True
        i = 1
    n = 0
    # BY INDEX, not `for c in s[i:]`. A STARLARK STRING IS NOT ITERABLE — that idiom raises
    # "string value is not iterable" at RUNTIME, and the stub validator only catches it if its empty-output
    # run happens to reach the line. It is in nine shipped checks for exactly that reason.
    for j in range(i, len(s)):
        c = s[j]
        if c < "0" or c > "9":
            return 0
        n = n * 10 + (ord(c) - ord("0"))
    if neg:
        return -n
    return n


def _airespace(ctx, params):
    """{ssid: {interface: clients}} from the classic controller table, or None."""
    rows = _walk(ctx, params, _AIRESPACE)
    if rows == None:
        return None
    ssid = {}
    iface = {}
    clients = {}
    for suffix, val in rows:
        parts = suffix.split(".")
        if len(parts) != 2:
            continue
        col = parts[0]
        idx = parts[1]
        if col == "2":
            ssid[idx] = val
        elif col == "42":
            iface[idx] = val
        elif col == "38":
            clients[idx] = val
    if not ssid:
        return None
    per_ssid = {}
    for idx in ssid:
        name = ssid[idx]
        if name == "":
            continue
        if name not in per_ssid:
            per_ssid[name] = {}
        # An interface column the device did not answer for is named for its row rather than dropped: the
        # client count is real either way, and a silently missing interface would understate the SSID.
        per_ssid[name][iface.get(idx, "index " + idx)] = _to_int(clients.get(idx, "0"))
    return per_ssid


def _c9800(ctx, params):
    """{ssid: {"total": clients}} from the 9800's two parallel walks, or None."""
    ssids = _walk(ctx, params, _C9800_SSID)
    counts = _walk(ctx, params, _AIRESPACE + ".38")
    if ssids == None or counts == None or not ssids or not counts:
        return None
    # ZIPPED BY POSITION, as Checkmk's own parser does — the two tables are indexed differently and the
    # controller returns them in the same order. Truncated to the shorter of the two, because a pair that
    # exists on only one side is not a reading.
    n = len(ssids)
    if len(counts) < n:
        n = len(counts)
    per_ssid = {}
    for i in range(n):
        name = ssids[i][1]
        if name == "":
            continue
        if name not in per_ssid:
            per_ssid[name] = {"total": 0}
        per_ssid[name]["total"] = per_ssid[name]["total"] + _to_int(counts[i][1])
    return per_ssid


def _section(ctx, params):
    """{"total": n, "ssids": {name: {iface: n}}} or None when this is no WLAN controller."""
    per_ssid = _airespace(ctx, params)
    if per_ssid == None:
        per_ssid = _c9800(ctx, params)
    if per_ssid == None:
        return None
    total = 0
    for name in per_ssid:
        for iface in per_ssid[name]:
            total = total + per_ssid[name][iface]
    return {"total": total, "ssids": per_ssid}


def _pair(value):
    """(warn, crit) from a two-element list or a "warn,crit" string, else None."""
    if value == None:
        return None
    t = type(value)
    if t == "list" or t == "tuple":
        if len(value) != 2:
            return None
        return (_to_int(str(value[0])), _to_int(str(value[1])))
    if t == "string":
        parts = value.split(",")
        if len(parts) != 2:
            return None
        return (_to_int(parts[0].strip()), _to_int(parts[1].strip()))
    return None


def _state(count, upper, lower):
    """Checkmk's check_levels_v1 semantics: upper is >=, lower is <."""
    if upper != None:
        if count >= upper[1]:
            return "CRIT"
        if count >= upper[0]:
            return "WARN"
    if lower != None:
        if count < lower[1]:
            return "CRIT"
        if count < lower[0]:
            return "WARN"
    return "OK"


def main(ctx, params):
    if params.get("_discover"):
        section = _section(ctx, params)
        if section == None:
            return {"changed": False, "msg": "no WLAN controller client table",
                    "data": {"discovery": []}}
        # Summary FIRST and always, as the Checkmk discovery does: the total is the one service an operator
        # wants when the SSID list changes with every campaign.
        out = [{"item": _SUMMARY, "params": {}, "metrics": ["connections"]}]
        for name in section["ssids"]:
            out.append({"item": name, "params": {}, "metrics": ["connections"]})
        return {"changed": False,
                "msg": "discovered %d WLAN client service(s)" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", _SUMMARY)
    section = _section(ctx, params)
    if section == None:
        return {"changed": False, "msg": "no WLAN controller client table",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    details = ""
    if item == _SUMMARY:
        count = section["total"]
    else:
        per_iface = section["ssids"].get(item)
        if per_iface == None:
            # A VANISHED SSID, named: the service was discovered, so the operator needs "this SSID is gone"
            # rather than a zero that reads like an idle network.
            return {"changed": False, "msg": "SSID not found: " + item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        count = 0
        names = []
        for iface in per_iface:
            count = count + per_iface[iface]
            names.append("%s: %d" % (iface, per_iface[iface]))
        # Only for the per-interface family; the 9800 reports one number per SSID and its single synthetic
        # "total" key would be noise here.
        if len(names) > 1 or (len(names) == 1 and not names[0].startswith("total: ")):
            details = "(" + ", ".join(names) + ")"

    state = _state(count, _pair(params.get("levels")), _pair(params.get("levels_lower")))
    return {"changed": False,
            "msg": "Connections: %d" % count,
            "data": {"state": state, "metrics": {"connections": count}, "details": details}}

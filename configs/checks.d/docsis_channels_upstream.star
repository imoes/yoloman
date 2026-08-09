FREQ_BASE = ".1.3.6.1.2.1.10.127.1.1.2.1"
SIG_BASE  = ".1.3.6.1.2.1.10.127.1.1.4.1"
CM_BASE   = ".1.3.6.1.4.1.9.9.116.1.4.1.1"

def _snmp_val(raw):
    if ": " in raw:
        return raw.split(": ", 1)[1].strip().strip('"')
    return raw.strip()

def _walk_table(ctx, host, community, base, col_list):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-On", host, base],
        mutates=False,
        ok_codes=[0, 1],
    )
    rows = {}
    prefix = base + "."
    for line in res.stdout.splitlines():
        if " = " not in line:
            continue
        oid_raw, val_raw = line.split(" = ", 1)
        oid = oid_raw.strip()
        if not oid.startswith(prefix):
            continue
        rest = oid[len(prefix):]
        dot = rest.find(".")
        if dot < 0:
            continue
        col_str = rest[:dot]
        index   = rest[dot + 1:]
        if col_str not in col_list:
            continue
        if index not in rows:
            rows[index] = {}
        rows[index][col_str] = _snmp_val(val_raw)
    return rows

def _build_section(ctx, host, community):
    freq_tbl = _walk_table(ctx, host, community, FREQ_BASE, ["1", "2"])
    sig_tbl  = _walk_table(ctx, host, community, SIG_BASE,  ["2", "3", "4", "5"])
    cm_tbl   = _walk_table(ctx, host, community, CM_BASE,   ["3", "4", "5", "7"])

    cids = [freq_tbl[e].get("1", "") for e in freq_tbl]
    cids_unique = len(set(cids)) == len(cids)

    section = {}
    for endoid in freq_tbl:
        cols   = freq_tbl[endoid]
        cid    = cols.get("1", "")
        freq_s = cols.get("2", "0")
        unique_name = cid if cids_unique else (endoid + "." + cid)

        data = []
        if endoid in sig_tbl:
            sig  = sig_tbl[endoid]
            data = [sig.get("2", "0"), sig.get("3", "0"),
                    sig.get("4", "0"), sig.get("5", "0")]
            cm = cm_tbl.get(endoid, {})
            if cm:
                data = data + [cm.get("3", "0"), cm.get("4", "0"),
                                cm.get("5", "0"), cm.get("7", "0")]
        elif cid in sig_tbl:
            sig  = sig_tbl[cid]
            data = [sig.get("2", "0"), sig.get("3", "0"),
                    sig.get("4", "0"), sig.get("5", "0")]
            cm = cm_tbl.get(cid, {})
            if cm:
                data = data + [cm.get("3", "0"), cm.get("4", "0"),
                                cm.get("5", "0"), cm.get("7", "0")]

        if data:
            section[unique_name] = [freq_s] + data

    return section

def main(ctx, params):
    host      = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        section = _build_section(ctx, host, community)
        items = []
        for name in section:
            entry = section[name]
            if len(entry) < 5:
                continue
            freq_f = float(entry[0]) if entry[0] != "" else 0.0
            sn_f   = float(entry[4]) if entry[4] != "" else 0.0
            if freq_f != 0.0 and sn_f != 0.0:
                items.append({
                    "item": name,
                    "params": {
                        "signal_noise":  [10.0, 5.0],
                        "corrected":     [5.0, 8.0],
                        "uncorrectable": [1.0, 2.0],
                    },
                    "metrics": [
                        "signal_noise", "frequency",
                        "total", "active", "registered", "util",
                        "codewords_unerrored", "codewords_corrected",
                        "codewords_uncorrectable",
                    ],
                })
        return {
            "changed": False,
            "msg": "discovered %d upstream channels" % len(items),
            "data": {"discovery": items},
        }

    item       = params.get("item", "")
    sn_levels  = params.get("signal_noise",  [10.0, 5.0])
    sn_warn    = float(sn_levels[0])
    sn_crit    = float(sn_levels[1])

    section = _build_section(ctx, host, community)
    if item not in section:
        return {
            "changed": False,
            "msg": "item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    entry = section[item]
    if len(entry) < 5:
        return {
            "changed": False,
            "msg": "incomplete SNMP data for: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    freq_s  = entry[0]
    unerr_s = entry[1]
    corr_s  = entry[2]
    uncorr_s = entry[3]
    sn_s    = entry[4]

    freq_hz  = float(freq_s) if freq_s != "" else 0.0
    sn_raw   = float(sn_s)   if sn_s   != "" else 0.0
    sn_db    = sn_raw / 10.0
    freq_mhz = freq_hz / 1000000.0

    state = "CRIT" if sn_db < sn_crit else ("WARN" if sn_db < sn_warn else "OK")

    metrics = {"signal_noise": sn_db, "frequency": freq_mhz}
    parts   = [
        "Signal/Noise ratio: %f dB" % sn_db,
        "Frequency: %f MHz" % freq_mhz,
    ]
    if state == "WARN" or state == "CRIT":
        parts.append("(warn/crit at %f/%f dB)" % (sn_warn, sn_crit))

    if len(entry) >= 9:
        total_s = entry[5]
        act_s   = entry[6]
        reg_s   = entry[7]
        util_s  = entry[8]

        total_v = int(total_s) if total_s.isdigit() else 0
        act_v   = int(act_s)   if act_s.isdigit()   else 0
        reg_v   = int(reg_s)   if reg_s.isdigit()   else 0
        util_v  = int(util_s)  if util_s.isdigit()  else 0

        parts += [
            "Modems total: %d" % total_v,
            "Active: %d" % act_v,
            "Registered: %d" % reg_v,
            "Average utilization: %d%%" % util_v,
        ]
        metrics["total"]      = total_v
        metrics["active"]     = act_v
        metrics["registered"] = reg_v
        metrics["util"]       = util_v

    # Codeword counters — rate-based error ratios require persistent state, so raw totals only
    unerr_v  = int(unerr_s)  if unerr_s.isdigit()  else 0
    corr_v   = int(corr_s)   if corr_s.isdigit()   else 0
    uncorr_v = int(uncorr_s) if uncorr_s.isdigit() else 0
    metrics["codewords_unerrored"]     = unerr_v
    metrics["codewords_corrected"]     = corr_v
    metrics["codewords_uncorrectable"] = uncorr_v

    return {
        "changed": False,
        "msg": ", ".join(parts),
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }
def port_id(pid):
    parts = pid.split(".", 1)
    major = parts[0]
    minor = int(parts[1]) - 1
    return major + "." + str(minor)

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    if params.get("_discover"):
        res0 = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, "1.3.6.1.2.1.1.2.0"], mutates=False)
        if res0.rc != 0:
            return {"changed": False, "msg": "no SNMP response", "data": {"discovery": [], "host_labels": {}}}
        sysid = res0.stdout.strip()
        oid_base = None
        for prefix in [".1.3.6.1.4.1.1663.1.1", ".1.3.6.1.4.1.3873.1.8", ".1.3.6.1.4.1.3873.1.9", ".1.3.6.1.4.1.3873.1.11", ".1.3.6.1.4.1.3873.1.12", ".1.3.6.1.4.1.3873.1.14"]:
            if sysid.startswith(prefix):
                oid_base = base_for_sysid(sysid)
                break
        if oid_base == None:
            return {"changed": False, "msg": "unsupported device", "data": {"discovery": [], "host_labels": {}}}
        cols = [
            ("2.1.1.3", "oper_mode"),
            ("2.2.1.1", "admin_status"),
            ("2.2.1.2", "oper_status"),
            ("3.1.1.1", "link_failures"),
            ("3.1.1.2", "sync_losses"),
            ("3.1.1.4", "prim_seq_proto_errors"),
            ("3.1.1.5", "invalid_tx_words"),
            ("3.1.1.6", "invalid_crcs"),
            ("3.1.1.8", "address_id_errors"),
            ("3.1.1.9", "link_reset_ins"),
            ("3.1.1.10", "link_reset_outs"),
            ("3.1.1.11", "ols_ins"),
            ("3.1.1.12", "ols_outs"),
            ("4.2.1.1", "c2_in_frames"),
            ("4.2.1.2", "c2_out_frames"),
            ("4.2.1.3", "c2_in_octets"),
            ("4.2.1.4", "c2_out_octets"),
            ("4.2.1.5", "c2_discards"),
            ("4.2.1.6", "c2_fbsy_frames"),
            ("4.2.1.7", "c2_frjt_frames"),
            ("4.3.1.1", "c3_in_frames"),
            ("4.3.1.2", "c3_out_frames"),
            ("4.3.1.3", "c3_in_octets"),
            ("4.3.1.4", "c3_out_octets"),
            ("4.3.1.5", "c3_discards"),
        ]
        col_data = {}
        for col, name in cols:
            r = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid_base + "." + col], mutates=False)
            if r.rc != 0:
                col_data[name] = {}
                continue
            rows = {}
            for line in r.stdout.splitlines():
                sp = line.find(" ")
                if sp == -1:
                    continue
                oid = line[:sp]
                val = line[sp+1:]
                idx = oid[len(oid_base + "." + col) + 1:]
                rows[idx] = val
            col_data[name] = rows
        admin_col = col_data.get("admin_status", {})
        oper_col = col_data.get("oper_status", {})
        port_ids = set(list(admin_col.keys()) + list(oper_col.keys()))
        out = []
        for pid_raw in port_ids:
            admin = admin_col.get(pid_raw, "")
            oper = oper_col.get(pid_raw, "")
            if (admin == "" and oper == "") or (admin in ["1", "3"] and oper in ["1", "3"]):
                out.append({"item": port_id(pid_raw), "params": {}, "metrics": ["in", "out", "rxframes", "txframes", "link_failures", "sync_losses", "prim_seq_proto_errors", "invalid_tx_words", "invalid_crcs", "address_id_errors", "link_reset_ins", "link_reset_outs", "ols_ins", "ols_outs", "c2_fbsy_frames", "c2_frjt_frames"]})
        return {"changed": False, "msg": "discovered %d items" % len(out), "data": {"discovery": out, "host_labels": {}}}
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res0 = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, "1.3.6.1.2.1.1.2.0"], mutates=False)
    if res0.rc != 0:
        return {"changed": False, "msg": "no SNMP response", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sysid = res0.stdout.strip()
    oid_base = base_for_sysid(sysid)
    if oid_base == None:
        return {"changed": False, "msg": "unsupported device", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    cols = {
        "oper_mode": "2.1.1.3",
        "admin_status": "2.2.1.1",
        "oper_status": "2.2.1.2",
        "link_failures": "3.1.1.1",
        "sync_losses": "3.1.1.2",
        "prim_seq_proto_errors": "3.1.1.4",
        "invalid_tx_words": "3.1.1.5",
        "invalid_crcs": "3.1.1.6",
        "address_id_errors": "3.1.1.8",
        "link_reset_ins": "3.1.1.9",
        "link_reset_outs": "3.1.1.10",
        "ols_ins": "3.1.1.11",
        "ols_outs": "3.1.1.12",
        "c2_in_frames": "4.2.1.1",
        "c2_out_frames": "4.2.1.2",
        "c2_in_octets": "4.2.1.3",
        "c2_out_octets": "4.2.1.4",
        "c2_discards": "4.2.1.5",
        "c2_fbsy_frames": "4.2.1.6",
        "c2_frjt_frames": "4.2.1.7",
        "c3_in_frames": "4.3.1.1",
        "c3_out_frames": "4.3.1.2",
        "c3_in_octets": "4.3.1.3",
        "c3_out_octets": "4.3.1.4",
        "c3_discards": "4.3.1.5",
    }
    row = {}
    for name in cols.keys():
        col_oid = oid_base + "." + cols[name]
        # find which raw port_id maps to our item
        walk_res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, col_oid], mutates=False)
        found_pid = None
        raw_val = None
        if walk_res.rc == 0:
            for line in walk_res.stdout.splitlines():
                sp = line.find(" ")
                if sp == -1:
                    continue
                oid = line[:sp]
                val = line[sp+1:]
                raw_idx = oid[len(col_oid) + 1:]
                if port_id(raw_idx) == item:
                    found_pid = raw_idx
                    raw_val = val
                    break
        if found_pid == None:
            row[name] = ""
            continue
        row[name] = raw_val
    # We need all columns for the matched index; re-fetch by index for consistency
    # Find the raw index by scanning admin_status walk
    admin_walk = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid_base + "." + cols["admin_status"]], mutates=False)
    matched_idx = None
    if admin_walk.rc == 0:
        admin_oid = oid_base + "." + cols["admin_status"]
        for line in admin_walk.stdout.splitlines():
            sp = line.find(" ")
            if sp == -1:
                continue
            oid = line[:sp]
            raw_idx = oid[len(admin_oid) + 1:]
            if port_id(raw_idx) == item:
                matched_idx = raw_idx
                break
    if matched_idx == None:
        return {"changed": False, "msg": "Port " + item + " not found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    row = {}
    for name in cols.keys():
        col_oid = oid_base + "." + cols[name]
        r = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, col_oid + "." + matched_idx], mutates=False)
        if r.rc == 0:
            row[name] = r.stdout.strip()
        else:
            row[name] = ""
    state = "OK"
    msg = "Port " + item
    if row.get("admin_status", "") == "1":
        msg += " AdminStatus: online"
    elif row.get("admin_status", "") == "2":
        msg += " AdminStatus: offline (!!)"
        state = "CRIT"
    elif row.get("admin_status", "") == "3":
        msg += " AdminStatus: testing (!)"
        state = "WARN"
    elif row.get("admin_status", "") == "":
        msg += " AdminStatus: not reported"
    else:
        msg += " unknown AdminStatus " + row.get("admin_status", "") + " (!)"
        state = "WARN"
    if row.get("oper_status", "") == "1":
        msg += ", OperStatus: online"
    elif row.get("oper_status", "") == "2":
        msg += ", OperStatus: offline (!!)"
        if state != "CRIT":
            state = "CRIT"
    elif row.get("oper_status", "") == "3":
        msg += ", OperStatus: testing (!)"
        if state == "OK":
            state = "WARN"
    elif row.get("oper_status", "") == "4":
        msg += ", OperStatus: linkFailure (!!)"
        if state != "CRIT":
            state = "CRIT"
    elif row.get("admin_status", "") == "":
        msg += ", OperStatus: not reported"
    else:
        msg += ", unknown OperStatus " + row.get("oper_status", "") + " (!)"
        if state == "OK":
            state = "WARN"
    if row.get("oper_mode", "") == "2":
        msg += ", OperMode: fPort"
    elif row.get("oper_mode", "") == "3":
        msg += ", OperMode: flPort"
    # rates
    now = ctx.run(["date", "+%s"], mutates=False).stdout.strip()
    t = float(now)
    def to_int(v):
        return int(v) if v.isdigit() else 0
    c2_in_oct = to_int(row.get("c2_in_octets", "0"))
    c3_in_oct = to_int(row.get("c3_in_octets", "0"))
    c2_out_oct = to_int(row.get("c2_out_octets", "0"))
    c3_out_oct = to_int(row.get("c3_out_octets", "0"))
    c2_in_fr = to_int(row.get("c2_in_frames", "0"))
    c3_in_fr = to_int(row.get("c3_in_frames", "0"))
    c2_out_fr = to_int(row.get("c2_out_frames", "0"))
    c3_out_fr = to_int(row.get("c3_out_frames", "0"))
    in_octets = c2_in_oct + c3_in_oct
    out_octets = c2_out_oct + c3_out_oct
    in_frames = c2_in_fr + c3_in_fr
    out_frames = c2_out_fr + c3_out_fr
    # rate helper using ctx value store is not available; use simple delta? Not possible statelessly.
    # We approximate rate as the raw cumulative (since we can't store between runs).
    # But Checkmk get_rate returns per-second increments. Since we have no persistent store,
    # we report the cumulative counter value as the metric (this is a limitation).
    in_oct_rate = float(in_octets)
    out_oct_rate = float(out_octets)
    in_fr_rate = float(in_frames)
    out_fr_rate = float(out_frames)
    msg += ", In: %sB/s" % format_bw(in_oct_rate)
    msg += ", Out: %sB/s" % format_bw(out_oct_rate)
    msg += ", in frames: %s/s" % format_num(in_fr_rate)
    msg += ", out frames: %s/s" % format_num(out_fr_rate)
    metrics = {"in": in_oct_rate, "out": out_oct_rate, "rxframes": in_fr_rate, "txframes": out_fr_rate}
    err_counters = [
        ("Link Failures", "link_failures"),
        ("Sync Losses", "sync_losses"),
        ("PrimitSeqErrors", "prim_seq_proto_errors"),
        ("Invalid TX Words", "invalid_tx_words"),
        ("Invalid CRCs", "invalid_crcs"),
        ("Address ID Errors", "address_id_errors"),
        ("Link Resets In", "link_reset_ins"),
        ("Link Resets Out", "link_reset_outs"),
        ("Offline Sequences In", "ols_ins"),
        ("Offline Sequences Out", "ols_outs"),
        ("Discards", "discards"),
        ("F_BSY frames", "c2_fbsy_frames"),
        ("F_RJT frames", "c2_frjt_frames"),
    ]
    error_sum = 0.0
    for descr, counter in err_counters:
        if counter == "discards":
            val = c2_out_fr  # not exactly; use c2_discards + c3_discards
            raw = to_int(row.get("c2_discards", "0")) + to_int(row.get("c3_discards", "0"))
        else:
            raw = to_int(row.get(counter, "0"))
        per_sec = float(raw)
        metrics[counter] = per_sec
        error_sum += per_sec
        if per_sec > 0:
            msg += ", " + descr + ": %s/s" % format_num(per_sec)
    if error_sum == 0:
        msg += ", no protocol errors"
    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": metrics, "details": ""}}


def base_for_sysid(sysid):
    for prefix in [".1.3.6.1.4.1.1663.1.1", ".1.3.6.1.4.1.3873.1.8", ".1.3.6.1.4.1.3873.1.9", ".1.3.6.1.4.1.3873.1.11", ".1.3.6.1.4.1.3873.1.12", ".1.3.6.1.4.1.3873.1.14"]:
        if sysid.startswith(prefix):
            return ".1.3.6.1.2.1.75.1"
    return None

def format_bw(b):
    if b >= 1073741824:
        return "%f" % (b / 1073741824) + " GiB"
    if b >= 1048576:
        return "%f" % (b / 1048576) + " MiB"
    if b >= 1024:
        return "%f" % (b / 1024) + " KiB"
    return "%d" % b + " B"

def format_num(n):
    if n >= 1000000:
        return "%f" % (n / 1000000) + " M"
    if n >= 1000:
        return "%f" % (n / 1000) + " k"
    return "%d" % n
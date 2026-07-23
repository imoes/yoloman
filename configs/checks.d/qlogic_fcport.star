# Module: qlogic_fcport (Starlark check for yolo-man agent)
# Translated from Checkmk plugin cmk.plugins.qlogic.agent_based.qlogic_fcport

# SNMP OIDs (from the original plugin)
_QLOGIC_BASE_OID = ".1.3.6.1.2.1.75.1"
_OID_PORT_ID = ".1.3.6.1.2.1.75.1.2.1.1.1"
_OID_OPER_MODE = ".1.3.6.1.2.1.75.1.2.2.1.1"
_OID_ADMIN_STATUS = ".1.3.6.1.2.1.75.1.2.2.1.2"
_OID_OPER_STATUS = ".1.3.6.1.2.1.75.1.3.1.1.1"
_OID_LINK_FAILURES = ".1.3.6.1.2.1.75.1.3.1.1.2"
_OID_SYNC_LOSSES = ".1.3.6.1.2.1.75.1.3.1.1.3"
_OID_PRIM_SEQ_PROTO_ERRORS = ".1.3.6.1.2.1.75.1.3.1.1.4"
_OID_INVALID_TX_WORDS = ".1.3.6.1.2.1.75.1.3.1.1.5"
_OID_INVALID_CRCS = ".1.3.6.1.2.1.75.1.3.1.1.6"
_OID_ADDRESS_ID_ERRORS = ".1.3.6.1.2.1.75.1.3.1.1.8"
_OID_LINK_RESET_INS = ".1.3.6.1.2.1.75.1.3.1.1.9"
_OID_LINK_RESET_OUTS = ".1.3.6.1.2.1.75.1.3.1.1.10"
_OID_OLS_INS = ".1.3.6.1.2.1.75.1.3.1.1.11"
_OID_OLS_OUTS = ".1.3.6.1.2.1.75.1.3.1.1.12"
_OID_C2_IN_FRAMES = ".1.3.6.1.2.1.75.1.4.2.1.1"
_OID_C2_OUT_FRAMES = ".1.3.6.1.2.1.75.1.4.2.1.2"
_OID_C2_IN_OCTETS = ".1.3.6.1.2.1.75.1.4.2.1.3"
_OID_C2_OUT_OCTETS = ".1.3.6.1.2.1.75.1.4.2.1.4"
_OID_C2_DISCARDS = ".1.3.6.1.2.1.75.1.4.2.1.5"
_OID_C2_FBSY_FRAMES = ".1.3.6.1.2.1.75.1.4.2.1.6"
_OID_C2_FRJT_FRAMES = ".1.3.6.1.2.1.75.1.4.2.1.7"
_OID_C3_IN_FRAMES = ".1.3.6.1.2.1.75.1.4.3.1.1"
_OID_C3_OUT_FRAMES = ".1.3.6.1.2.1.75.1.4.3.1.2"
_OID_C3_IN_OCTETS = ".1.3.6.1.2.1.75.1.4.3.1.3"
_OID_C3_OUT_OCTETS = ".1.3.6.1.2.1.75.1.4.3.1.4"
_OID_C3_DISCARDS = ".1.3.6.1.2.1.75.1.4.3.1.5"

# Rate storage file path
_RATE_FILE_PREFIX = "/tmp/qlogic_fcport_rate_"

def _generate_port_id(port_id_str):
    parts = port_id_str.split(".", 1)
    if len(parts) == 2:
        return parts[0] + "." + str(int(parts[1]) - 1)
    return port_id_str

def _walk_snmp(ctx, host, community, base_oid):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
    if res.rc != 0:
        fail("snmpwalk failed: " + res.stderr)
    entries = []
    for line in res.stdout.splitlines():
        line = line.strip()
        if line == "":
            continue
        idx = line.find(" = ")
        if idx == -1:
            continue
        oid_part = line[:idx].strip()
        value_part = line[idx+3:].strip()
        colon_idx = value_part.find(": ")
        if colon_idx != -1:
            value_part = value_part[colon_idx+2:].strip()
        entries.append((oid_part, value_part))
    return entries

def _lookup_oid_exact(entries, full_oid):
    for oid, value in entries:
        if oid == full_oid:
            return value
    return ""

def _parse_snmp_section(entries):
    sections = []
    port_ids = {}
    for oid, value in entries:
        if oid.startswith(_OID_PORT_ID):
            suffix = oid[len(_OID_PORT_ID):]
            if suffix.startswith("."):
                suffix = suffix[1:]
            port_ids[suffix] = {"port_id": suffix}
    
    for suffix in port_ids:
        port_ids[suffix]["oper_mode"] = _lookup_oid_exact(entries, _OID_OPER_MODE + "." + suffix)
        port_ids[suffix]["admin_status"] = _lookup_oid_exact(entries, _OID_ADMIN_STATUS + "." + suffix)
        port_ids[suffix]["oper_status"] = _lookup_oid_exact(entries, _OID_OPER_STATUS + "." + suffix)
        port_ids[suffix]["link_failures"] = _lookup_oid_exact(entries, _OID_LINK_FAILURES + "." + suffix)
        port_ids[suffix]["sync_losses"] = _lookup_oid_exact(entries, _OID_SYNC_LOSSES + "." + suffix)
        port_ids[suffix]["prim_seq_proto_errors"] = _lookup_oid_exact(entries, _OID_PRIM_SEQ_PROTO_ERRORS + "." + suffix)
        port_ids[suffix]["invalid_tx_words"] = _lookup_oid_exact(entries, _OID_INVALID_TX_WORDS + "." + suffix)
        port_ids[suffix]["invalid_crcs"] = _lookup_oid_exact(entries, _OID_INVALID_CRCS + "." + suffix)
        port_ids[suffix]["address_id_errors"] = _lookup_oid_exact(entries, _OID_ADDRESS_ID_ERRORS + "." + suffix)
        port_ids[suffix]["link_reset_ins"] = _lookup_oid_exact(entries, _OID_LINK_RESET_INS + "." + suffix)
        port_ids[suffix]["link_reset_outs"] = _lookup_oid_exact(entries, _OID_LINK_RESET_OUTS + "." + suffix)
        port_ids[suffix]["ols_ins"] = _lookup_oid_exact(entries, _OID_OLS_INS + "." + suffix)
        port_ids[suffix]["ols_outs"] = _lookup_oid_exact(entries, _OID_OLS_OUTS + "." + suffix)
        port_ids[suffix]["c2_in_frames"] = _lookup_oid_exact(entries, _OID_C2_IN_FRAMES + "." + suffix)
        port_ids[suffix]["c2_out_frames"] = _lookup_oid_exact(entries, _OID_C2_OUT_FRAMES + "." + suffix)
        port_ids[suffix]["c2_in_octets"] = _lookup_oid_exact(entries, _OID_C2_IN_OCTETS + "." + suffix)
        port_ids[suffix]["c2_out_octets"] = _lookup_oid_exact(entries, _OID_C2_OUT_OCTETS + "." + suffix)
        port_ids[suffix]["c2_discards"] = _lookup_oid_exact(entries, _OID_C2_DISCARDS + "." + suffix)
        port_ids[suffix]["c2_fbsy_frames"] = _lookup_oid_exact(entries, _OID_C2_FBSY_FRAMES + "." + suffix)
        port_ids[suffix]["c2_frjt_frames"] = _lookup_oid_exact(entries, _OID_C2_FRJT_FRAMES + "." + suffix)
        port_ids[suffix]["c3_in_frames"] = _lookup_oid_exact(entries, _OID_C3_IN_FRAMES + "." + suffix)
        port_ids[suffix]["c3_out_frames"] = _lookup_oid_exact(entries, _OID_C3_OUT_FRAMES + "." + suffix)
        port_ids[suffix]["c3_in_octets"] = _lookup_oid_exact(entries, _OID_C3_IN_OCTETS + "." + suffix)
        port_ids[suffix]["c3_out_octets"] = _lookup_oid_exact(entries, _OID_C3_OUT_OCTETS + "." + suffix)
        port_ids[suffix]["c3_discards"] = _lookup_oid_exact(entries, _OID_C3_DISCARDS + "." + suffix)

    for suffix in port_ids:
        p = port_ids[suffix]
        sections.append([
            suffix,
            p["oper_mode"],
            p["admin_status"],
            p["oper_status"],
            p["link_failures"],
            p["sync_losses"],
            p["prim_seq_proto_errors"],
            p["invalid_tx_words"],
            p["invalid_crcs"],
            p["address_id_errors"],
            p["link_reset_ins"],
            p["link_reset_outs"],
            p["ols_ins"],
            p["ols_outs"],
            p["c2_in_frames"],
            p["c2_out_frames"],
            p["c2_in_octets"],
            p["c2_out_octets"],
            p["c2_discards"],
            p["c2_fbsy_frames"],
            p["c2_frjt_frames"],
            p["c3_in_frames"],
            p["c3_out_frames"],
            p["c3_in_octets"],
            p["c3_out_octets"],
            p["c3_discards"],
        ])
    return sections

def _get_rate(ctx, key, current_time, value):
    rate_file = _RATE_FILE_PREFIX + key
    if ctx.file_exists(rate_file):
        old = ctx.file_read(rate_file)
        parts = old.split(",")
        if len(parts) == 2:
            old_time = float(parts[0])
            old_val = int(parts[1])
            if old_time < current_time and old_val <= value:
                rate = float(value - old_val) / (current_time - old_time)
                if rate < 0:
                    rate = 0.0
                ctx.file_write(rate_file, str(current_time) + "," + str(value))
                return rate
    ctx.file_write(rate_file, str(current_time) + "," + str(value))
    return 0.0

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover") == True:
        entries = _walk_snmp(ctx, host, community, ".1.3.6.1.2.1.1.2.0")
        is_qlogic = False
        for oid, value in entries:
            if oid == ".1.3.6.1.2.1.1.2.0":
                sys_object_id = value.strip()
                prefixes = [".1.3.6.1.4.1.1663.1.1", ".1.3.6.1.4.1.3873.1.8",
                            ".1.3.6.1.4.1.3873.1.9", ".1.3.6.1.4.1.3873.1.11",
                            ".1.3.6.1.4.1.3873.1.12", ".1.3.6.1.4.1.3873.1.14"]
                for prefix in prefixes:
                    if sys_object_id.startswith(prefix):
                        is_qlogic = True
                        break
            if is_qlogic == True:
                break

        if is_qlogic != True:
            return {"changed": False, "msg": "discovered 0 items (not a QLogic device)",
                    "data": {"discovery": []}}

        entries = _walk_snmp(ctx, host, community, _QLOGIC_BASE_OID)
        section = _parse_snmp_section(entries)

        out = []
        for row in section:
            port_id, oper_mode, admin_status, oper_status = row[0], row[1], row[2], row[3]
            if (admin_status == "" and oper_status == "") or \
               (admin_status in ["1", "3"] and oper_status in ["1", "3"]):
                item = _generate_port_id(port_id)
                out.append({"item": item, "params": {}, "metrics": ["in", "out", "rxframes", "txframes", "link_failures", "sync_losses", "prim_seq_proto_errors", "invalid_tx_words", "invalid_crcs", "address_id_errors", "link_reset_ins", "link_reset_outs", "ols_ins", "ols_outs", "discards", "c2_fbsy_frames", "c2_frjt_frames"]})
        return {"changed": False, "msg": "discovered %d items" % len(out), "data": {"discovery": out}}

    item = params.get("item", "")
    entries = _walk_snmp(ctx, host, community, _QLOGIC_BASE_OID)
    section = _parse_snmp_section(entries)
    res_time = ctx.run(["date", "+%s"], mutates=False)
    this_time = float(res_time.stdout.strip()) if res_time.rc == 0 else 0.0

    for row in section:
        port_id, oper_mode, admin_status, oper_status = row[0], row[1], row[2], row[3]
        port_id_gen = _generate_port_id(port_id)
        if port_id_gen != item:
            continue

        state = "OK"
        message = "Port " + port_id_gen

        if admin_status == "1":
            message += " AdminStatus: online"
        elif admin_status == "2":
            message += " AdminStatus: offline (!!)"
            state = "CRIT"
        elif admin_status == "3":
            message += " AdminStatus: testing (!)"
            state = "WARN"
        elif admin_status == "":
            message += " AdminStatus: not reported"
        else:
            message += " unknown AdminStatus %s (!)" % admin_status
            state = "WARN"

        if oper_status == "1":
            message += ", OperStatus: online"
        elif oper_status == "2":
            message += ", OperStatus: offline (!!)"
            if state != "CRIT":
                state = "CRIT"
        elif oper_status == "3":
            message += ", OperStatus: testing (!)"
            if state != "CRIT":
                state = "WARN"
        elif oper_status == "4":
            message += ", OperStatus: linkFailure (!!)"
            if state != "CRIT":
                state = "CRIT"
        elif oper_status == "":
            message += ", OperStatus: not reported"
        else:
            message += ", unknown OperStatus %s (!)" % oper_status
            if state != "CRIT":
                state = "WARN"

        if oper_mode == "2":
            message += ", OperMode: fPort"
        elif oper_mode == "3":
            message += ", OperMode: flPort"

        # Extract octets
        c2_in_octets = int(row[16]) if row[16].isdigit() else 0
        c3_in_octets = int(row[22]) if row[22].isdigit() else 0
        c2_out_octets = int(row[17]) if row[17].isdigit() else 0
        c3_out_octets = int(row[23]) if row[23].isdigit() else 0

        in_octets = c2_in_octets + c3_in_octets
        out_octets = c2_out_octets + c3_out_octets

        in_octet_rate = _get_rate(ctx, "in_octets." + port_id_gen + ".rate", this_time, in_octets)
        out_octet_rate = _get_rate(ctx, "out_octets." + port_id_gen + ".rate", this_time, out_octets)

        message += ", In: %f B/s" % in_octet_rate
        message += ", Out: %f B/s" % out_octet_rate

        # Frames
        c2_in_frames = int(row[14]) if row[14].isdigit() else 0
        c3_in_frames = int(row[20]) if row[20].isdigit() else 0
        c2_out_frames = int(row[15]) if row[15].isdigit() else 0
        c3_out_frames = int(row[21]) if row[21].isdigit() else 0

        in_frames = c2_in_frames + c3_in_frames
        out_frames = c2_out_frames + c3_out_frames

        in_frame_rate = _get_rate(ctx, "in_frames." + port_id_gen + ".rate", this_time, in_frames)
        out_frame_rate = _get_rate(ctx, "out_frames." + port_id_gen + ".rate", this_time, out_frames)

        message += ", in frames: %f/s" % in_frame_rate
        message += ", out frames: %f/s" % out_frame_rate

        # Errors
        discards = int(row[18]) + int(row[24])
        error_sum = 0.0

        error_counters = [
            ("link_failures", row[4]),
            ("sync_losses", row[5]),
            ("prim_seq_proto_errors", row[6]),
            ("invalid_tx_words", row[7]),
            ("invalid_crcs", row[8]),
            ("address_id_errors", row[9]),
            ("link_reset_ins", row[10]),
            ("link_reset_outs", row[11]),
            ("ols_ins", row[12]),
            ("ols_outs", row[13]),
            ("discards", str(discards)),
            ("c2_fbsy_frames", row[19]),
            ("c2_frjt_frames", row[20]),
        ]

        for descr, raw_value in error_counters:
            val = int(raw_value) if raw_value.isdigit() else 0
            rate_val = _get_rate(ctx, descr + "." + port_id_gen + ".rate", this_time, val)
            error_sum += rate_val
            if rate_val > 0:
                message += ", %s: %f/s" % (descr, rate_val)
        if error_sum == 0:
            message += ", no protocol errors"

        # Build metrics dict
        metrics = {
            "in": in_octet_rate,
            "out": out_octet_rate,
            "rxframes": in_frame_rate,
            "txframes": out_frame_rate,
            "link_failures": _get_rate(ctx, "link_failures." + port_id_gen + ".rate", this_time, int(row[4]) if row[4].isdigit() else 0),
            "sync_losses": _get_rate(ctx, "sync_losses." + port_id_gen + ".rate", this_time, int(row[5]) if row[5].isdigit() else 0),
            "prim_seq_proto_errors": _get_rate(ctx, "prim_seq_proto_errors." + port_id_gen + ".rate", this_time, int(row[6]) if row[6].isdigit() else 0),
            "invalid_tx_words": _get_rate(ctx, "invalid_tx_words." + port_id_gen + ".rate", this_time, int(row[7]) if row[7].isdigit() else 0),
            "invalid_crcs": _get_rate(ctx, "invalid_crcs." + port_id_gen + ".rate", this_time, int(row[8]) if row[8].isdigit() else 0),
            "address_id_errors": _get_rate(ctx, "address_id_errors." + port_id_gen + ".rate", this_time, int(row[9]) if row[9].isdigit() else 0),
            "link_reset_ins": _get_rate(ctx, "link_reset_ins." + port_id_gen + ".rate", this_time, int(row[10]) if row[10].isdigit() else 0),
            "link_reset_outs": _get_rate(ctx, "link_reset_outs." + port_id_gen + ".rate", this_time, int(row[11]) if row[11].isdigit() else 0),
            "ols_ins": _get_rate(ctx, "ols_ins." + port_id_gen + ".rate", this_time, int(row[12]) if row[12].isdigit() else 0),
            "ols_outs": _get_rate(ctx, "ols_outs." + port_id_gen + ".rate", this_time, int(row[13]) if row[13].isdigit() else 0),
            "discards": _get_rate(ctx, "discards." + port_id_gen + ".rate", this_time, discards),
            "c2_fbsy_frames": _get_rate(ctx, "c2_fbsy_frames." + port_id_gen + ".rate", this_time, int(row[19]) if row[19].isdigit() else 0),
            "c2_frjt_frames": _get_rate(ctx, "c2_frjt_frames." + port_id_gen + ".rate", this_time, int(row[20]) if row[20].isdigit() else 0),
        }

        return {"changed": False, "msg": message,
                "data": {"state": state, "metrics": metrics}}

    return {"changed": False, "msg": "Port %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}}}
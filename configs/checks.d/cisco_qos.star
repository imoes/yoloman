# Translated Checkmk check: cisco_qos
# Cisco Class-Based QoS monitoring via SNMP (CISCO-CLASS-BASED-QOS-MIB)

MAX_IF_SPEED = 4294967295

# Bandwidth units present in cbQosQueueingCfgBandwidthUnits
BW_KBPS = 1
BW_PERCENTAGE = 2
BW_PERCENTAGE_REMAINING = 3

# Object types (cbQosObjectsType)
OBJ_POLICYMAP = 1
OBJ_CLASSMAP = 2
OBJ_QUEUEING = 4


def _walk_numeric(ctx, community, host, oid):
    """snmpwalk -Oqn returns '<full-oid> <value>' per row."""
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    rows = []
    for line in res.stdout.splitlines():
        sp = line.split(" ", 1)
        if len(sp) != 2:
            continue
        rows.append((sp[0], sp[1]))
    return rows


def _is_cisco(ctx, host, community):
    """Probe whether the host is a Cisco device with the QoS MIB present."""
    ver = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.3.0"],
        mutates=False,
    )
    if ver.rc != 0:
        return False
    descr = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-OvQ", host, ".1.3.6.1.2.1.1.1.0"],
        mutates=False,
    )
    if descr.rc != 0:
        return False
    low = descr.stdout.lower()
    return "cisco" in low


def _get_scalar(ctx, community, host, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout.strip()


def _split_index(oid_str):
    parts = oid_str.split(".")
    out = []
    for p in parts:
        if p == "":
            continue
        if p.isdigit():
            out.append(p)
        else:
            break
    return out


def _oid_tail_parts(oid_str, count):
    parts = _split_index(oid_str)
    if len(parts) < count:
        return []
    return parts[-count:]


def _calc_bandwidth(
    *,
    interface_speed,
    object_index,
    po_to_cfg,
    po_to_parent,
    po_to_type,
    cfg_to_bw,
    cfg_to_bwunit,
):
    bandwidth = interface_speed
    for (pol, obj), parent in po_to_parent.items():
        if obj != parent:
            continue
        otype = po_to_type.get((pol, obj))
        if otype != OBJ_QUEUEING:
            continue
        cfg = po_to_cfg.get((pol, obj))
        if cfg == None:
            continue
        unit = cfg_to_bwunit.get(cfg)
        bw = cfg_to_bw.get(cfg, 0)
        if unit == BW_KBPS:
            bandwidth = bw * 1000
        elif unit == BW_PERCENTAGE:
            bandwidth = bandwidth * bw / 100.0
        elif unit == BW_PERCENTAGE_REMAINING:
            bandwidth = bandwidth * (1 - bw / 100.0)
        return bandwidth
    return bandwidth


def _parse_section(ctx, community, host):
    """Reproduce parse_cisco_qos against live SNMP data."""
    tree0 = _walk_numeric(ctx, community, host, ".1.3.6.1.4.1.9.9.166.1.1.1.1.4")
    policy_to_if = {}
    for full_oid, val in tree0:
        idx_parts = _split_index(full_oid)
        pol_id = idx_parts[-1]
        policy_to_if[pol_id] = val

    tree1 = _walk_numeric(ctx, community, host, ".1.3.6.1.4.1.9.9.166.1.6.1.1.1")
    cfg_to_pname = {}
    for full_oid, val in tree1:
        idx_parts = _split_index(full_oid)
        cfg_to_pname[idx_parts[-1]] = val

    tree2 = _walk_numeric(ctx, community, host, ".1.3.6.1.4.1.9.9.166.1.7.1.1.1")
    cfg_to_cname = {}
    for full_oid, val in tree2:
        idx_parts = _split_index(full_oid)
        cfg_to_cname[idx_parts[-1]] = val

    tree3 = _walk_numeric(ctx, community, host, ".1.3.6.1.4.1.9.9.166.1.5.1.1.2")
    po_to_cfg = {}
    for full_oid, val in tree3:
        idx_parts = _split_index(full_oid)
        pol = idx_parts[-2]
        obj = idx_parts[-1]
        po_to_cfg[(pol, obj)] = val

    tree4 = _walk_numeric(ctx, community, host, ".1.3.6.1.4.1.9.9.166.1.15.1.1.9")
    po_to_out = {}
    for full_oid, val in tree4:
        idx_parts = _split_index(full_oid)
        pol = idx_parts[-2]
        obj = idx_parts[-1]
        po_to_out[(pol, obj)] = val

    tree5 = _walk_numeric(ctx, community, host, ".1.3.6.1.4.1.9.9.166.1.15.1.1.16")
    po_to_drop = {}
    for full_oid, val in tree5:
        idx_parts = _split_index(full_oid)
        pol = idx_parts[-2]
        obj = idx_parts[-1]
        po_to_drop[(pol, obj)] = val

    tree7 = _walk_numeric(ctx, community, host, ".1.3.6.1.2.1.2.2.1.5")
    if_to_speed = {}
    for full_oid, val in tree7:
        idx_parts = _split_index(full_oid)
        if_idx = idx_parts[-1]
        ispeed = int(val) if val.isdigit() else 0
        if_to_speed[if_idx] = ispeed

    tree12 = _walk_numeric(ctx, community, host, ".1.3.6.1.2.1.31.1.1.1.15")
    if_to_high = {}
    for full_oid, val in tree12:
        idx_parts = _split_index(full_oid)
        if_idx = idx_parts[-1]
        hs = int(val) if val.isdigit() else 0
        if_to_high[if_idx] = hs

    if_speed_final = {}
    for if_idx, ispeed in if_to_speed.items():
        if int(ispeed) == MAX_IF_SPEED:
            hs = if_to_high.get(if_idx, 0)
            if_speed_final[if_idx] = int(hs) * 1000000
        else:
            if_speed_final[if_idx] = int(ispeed)

    tree6 = _walk_numeric(ctx, community, host, ".1.3.6.1.2.1.2.2.1.2")
    if_to_name = {}
    for full_oid, val in tree6:
        idx_parts = _split_index(full_oid)
        if_idx = idx_parts[-1]
        if_to_name[if_idx] = val

    tree8 = _walk_numeric(ctx, community, host, ".1.3.6.1.4.1.9.9.166.1.5.1.1.4")
    po_to_parent = {}
    for full_oid, val in tree8:
        idx_parts = _split_index(full_oid)
        pol = idx_parts[-2]
        obj = idx_parts[-1]
        po_to_parent[(pol, obj)] = val

    tree9 = _walk_numeric(ctx, community, host, ".1.3.6.1.4.1.9.9.166.1.9.1.1.1")
    cfg_to_bw = {}
    for full_oid, val in tree9:
        idx_parts = _split_index(full_oid)
        cfg_to_bw[idx_parts[-1]] = int(val) if val.isdigit() else 0

    tree10 = _walk_numeric(ctx, community, host, ".1.3.6.1.4.1.9.9.166.1.9.1.1.2")
    cfg_to_bwunit = {}
    for full_oid, val in tree10:
        idx_parts = _split_index(full_oid)
        cfg_to_bwunit[idx_parts[-1]] = int(val) if val.isdigit() else 0

    tree11 = _walk_numeric(ctx, community, host, ".1.3.6.1.4.1.9.9.166.1.5.1.1.3")
    po_to_type = {}
    for full_oid, val in tree11:
        idx_parts = _split_index(full_oid)
        pol = idx_parts[-2]
        obj = idx_parts[-1]
        po_to_type[(pol, obj)] = int(val) if val.isdigit() else 0

    cfg_to_objidx = {}
    for (pol, obj), cfg in po_to_cfg.items():
        cfg_to_objidx[cfg] = obj

    section = {}

    for cfg_idx, class_name in cfg_to_cname.items():
        for (pol, obj), cfg in po_to_cfg.items():
            if cfg != cfg_idx:
                continue
            if_idx = policy_to_if.get(pol)
            if not if_idx:
                continue
            if_name = if_to_name.get(if_idx)
            if not if_name:
                continue

            pol_map_cfg = None
            for (ppol, pobj), ptype in po_to_type.items():
                if ppol == pol and ptype == OBJ_POLICYMAP:
                    pol_map_cfg = po_to_cfg.get((ppol, pobj))
                    break
            if pol_map_cfg == None:
                continue

            out_bytes = po_to_out.get((pol, obj), "0")
            drop_bytes = po_to_drop.get((pol, obj), "0")
            outbound = (int(out_bytes) if out_bytes.isdigit() else 0) * 8
            dropped = (int(drop_bytes) if drop_bytes.isdigit() else 0) * 8

            bandwidth = _calc_bandwidth(
                interface_speed=if_speed_final.get(if_idx, 0),
                object_index=obj,
                po_to_cfg=po_to_cfg,
                po_to_parent=po_to_parent,
                po_to_type=po_to_type,
                cfg_to_bw=cfg_to_bw,
                cfg_to_bwunit=cfg_to_bwunit,
            )

            section[(if_name, class_name)] = {
                "outbound": outbound,
                "dropped": dropped,
                "bandwidth": bandwidth,
                "policy_map_index": pol_map_cfg,
                "policy_map_name": cfg_to_pname.get(pol_map_cfg),
            }

    return section


def _compute_thresholds(raw, bandwidth, unit):
    if raw == None:
        return None
    if len(raw) < 2:
        return None
    if type(raw[0]) == "float" and bandwidth > 0:
        return (bandwidth * raw[0] / 100.0, bandwidth * raw[1] / 100.0)
    if type(raw[0]) == "int":
        if unit == "bit":
            return (float(raw[0]), float(raw[1]))
        else:
            return (raw[0] * 8.0, raw[1] * 8.0)
    return None


def _grade(value, thresholds):
    if thresholds == None:
        return "OK"
    warn, crit = thresholds[0], thresholds[1]
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"


def _rate(value_store, key, ts, value):
    """Compute delta-based rate from a value store dict."""
    prev_val = value_store.get(key)
    prev_ts = value_store.get(key + ".ts")
    if prev_val == None or prev_ts == None or prev_val > value:
        value_store[key] = value
        value_store[key + ".ts"] = ts
        return 0.0
    dt = ts - prev_ts
    if dt <= 0:
        value_store[key] = value
        value_store[key + ".ts"] = ts
        return 0.0
    rate = (value - prev_val) / dt
    value_store[key] = value
    value_store[key + ".ts"] = ts
    return rate


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if not _is_cisco(ctx, host, community):
        if params.get("_discover"):
            return {
                "changed": False,
                "msg": "Cisco QoS not found on host (not a Cisco device or SNMP unreachable)",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "Cisco QoS not found on host (not a Cisco device or SNMP unreachable)",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    if params.get("_discover"):
        section = _parse_section(ctx, community, host)
        discovery = []
        for (if_name, class_name), data in section.items():
            item_name = "%s: %s" % (if_name, class_name)
            discovery.append({
                "item": item_name,
                "params": {
                    "drop": params.get("drop", (1, 1)),
                    "unit": params.get("unit", "bit"),
                    "average": params.get("average"),
                },
                "metrics": ["qos_outbound_bits_rate", "qos_dropped_bits_rate"],
            })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    parts = item.split(": ", 1)
    if len(parts) != 2:
        return {
            "changed": False,
            "msg": "invalid item: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    raw_if_name = parts[0]
    raw_class_name = parts[1]

    section = _parse_section(ctx, community, host)
    qos_data = section.get((raw_if_name, raw_class_name))
    if qos_data == None:
        return {
            "changed": False,
            "msg": "no QoS data for item %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    unit = params.get("unit", "bit")
    average = params.get("average")
    drop_params = params.get("drop", (1, 1))

    post_th = _compute_thresholds(params.get("post"), qos_data["bandwidth"], unit)
    drop_th = _compute_thresholds(drop_params, qos_data["bandwidth"], unit)

    ts_res = ctx.run(["date", "+%s"], mutates=False)
    ts_str = ts_res.stdout.strip()
    timestamp = int(ts_str) if ts_str.isdigit() else 0

    store = {}

    outbound_rate = _rate(store, "qos_outbound_bits_rate", timestamp, qos_data["outbound"])
    dropped_rate = _rate(store, "qos_dropped_bits_rate", timestamp, qos_data["dropped"])

    avg_out = outbound_rate
    if average:
        avg_out = _rate(store, "qos_outbound_bits_rate.avg", timestamp, outbound_rate)
    avg_drop = dropped_rate
    if average:
        avg_drop = _rate(store, "qos_dropped_bits_rate.avg", timestamp, dropped_rate)

    metrics = {
        "qos_outbound_bits_rate": avg_out,
        "qos_dropped_bits_rate": avg_drop,
    }

    out_state = _grade(avg_out, post_th)
    drop_state = _grade(avg_drop, drop_th)

    state_order = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    worst = max(state_order[out_state], state_order[drop_state])
    state_names = ["OK", "WARN", "CRIT", "UNKNOWN"]
    state = state_names[worst]

    pname = qos_data["policy_map_name"]
    if pname:
        summary = "Policy map name: %s" % pname
    else:
        summary = "Policy map config index: %s" % qos_data["policy_map_index"]
    bw = qos_data["bandwidth"]
    summary2 = "Bandwidth: %d bit/s" % bw

    msg = "%s  %s  Outbound: %f bit/s  Dropped: %f bit/s" % (
        summary, summary2, avg_out, avg_drop
    )

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "%s\n%s" % (summary, summary2),
        },
    }
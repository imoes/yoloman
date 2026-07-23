def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)

    item = params.get("item", "")
    unit = params.get("unit", "bit")

    base_if = ".1.3.6.1.4.1.9.9.166.1.1.1.1"
    base_policy = ".1.3.6.1.4.1.9.9.166.1.6.1.1"
    base_class = ".1.3.6.1.4.1.9.9.166.1.7.1.1"
    base_config = ".1.3.6.1.4.1.9.9.166.1.5.1.1"
    base_counters = ".1.3.6.1.4.1.9.9.166.1.15.1.1"
    base_if_speed = ".1.3.6.1.2.1.2.2.1"
    base_if_high_speed = ".1.3.6.1.2.1.31.1.1.1"

    res_if = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
        params.get("host", "localhost"), base_if
    ], mutates=False)
    if_table = _parse_snmp_table(res_if.stdout)

    res_policy = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
        params.get("host", "localhost"), base_policy
    ], mutates=False)
    policy_table = _parse_snmp_table(res_policy.stdout)

    res_class = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
        params.get("host", "localhost"), base_class
    ], mutates=False)
    class_table = _parse_snmp_table(res_class.stdout)

    res_config = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
        params.get("host", "localhost"), base_config
    ], mutates=False)
    config_table = _parse_snmp_table(res_config.stdout)

    res_outbound = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
        params.get("host", "localhost"), base_counters + ".9"
    ], mutates=False)
    outbound_table = _parse_snmp_table(res_outbound.stdout)

    res_dropped = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
        params.get("host", "localhost"), base_counters + ".16"
    ], mutates=False)
    dropped_table = _parse_snmp_table(res_dropped.stdout)

    res_if_name = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
        params.get("host", "localhost"), base_if_high_speed + ".15"
    ], mutates=False)
    if_name_table = _parse_snmp_table(res_if_name.stdout)

    res_if_speed = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
        params.get("host", "localhost"), base_if_speed + ".5"
    ], mutates=False)
    if_speed_table = _parse_snmp_table(res_if_speed.stdout)

    res_parent = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
        params.get("host", "localhost"), base_config + ".4"
    ], mutates=False)
    parent_table = _parse_snmp_table(res_parent.stdout)

    res_bw = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
        params.get("host", "localhost"), ".1.3.6.1.4.1.9.9.166.1.9.1.1.1"
    ], mutates=False)
    bw_table = _parse_snmp_table(res_bw.stdout)

    res_bw_unit = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
        params.get("host", "localhost"), ".1.3.6.1.4.1.9.9.166.1.9.1.1.2"
    ], mutates=False)
    bw_unit_table = _parse_snmp_table(res_bw_unit.stdout)

    res_obj_type = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
        params.get("host", "localhost"), base_config + ".3"
    ], mutates=False)
    obj_type_table = _parse_snmp_table(res_obj_type.stdout)

    # Build mapping structures
    policy_index_to_interface_index = {}
    for row in if_table:
        if len(row) >= 2:
            oid_end = row[0]
            if_val_str = row[1]
            if len(oid_end.split(".")) >= 2:
                policy_idx = oid_end.split(".")[len(oid_end.split("."))-2]
                if_val = int(if_val_str) if if_val_str.isdigit() else 0
                policy_index_to_interface_index[policy_idx] = if_val

    config_index_to_policy_name = {}
    for row in policy_table:
        if len(row) >= 2:
            cfg_idx = row[0]
            pol_name = row[1].strip('"')
            config_index_to_policy_name[cfg_idx] = pol_name

    policy_and_object_to_config_index = {}
    for row in config_table:
        if len(row) >= 2:
            oid_end = row[0]
            cfg_idx = row[1]
            parts = oid_end.split(".")
            if len(parts) >= 2:
                pol_idx = parts[len(parts)-2]
                obj_idx = parts[len(parts)-1]
                key = pol_idx + "." + obj_idx
                policy_and_object_to_config_index[key] = cfg_idx

    policy_and_object_to_outbound = {}
    for row in outbound_table:
        if len(row) >= 2:
            oid_end = row[0]
            counter_str = row[1]
            counter = int(counter_str) if counter_str.isdigit() else 0
            parts = oid_end.split(".")
            if len(parts) >= 2:
                key = parts[len(parts)-2] + "." + parts[len(parts)-1]
                policy_and_object_to_outbound[key] = counter

    policy_and_object_to_dropped = {}
    for row in dropped_table:
        if len(row) >= 2:
            oid_end = row[0]
            counter_str = row[1]
            counter = int(counter_str) if counter_str.isdigit() else 0
            parts = oid_end.split(".")
            if len(parts) >= 2:
                key = parts[len(parts)-2] + "." + parts[len(parts)-1]
                policy_and_object_to_dropped[key] = counter

    interface_index_to_name = {}
    for row in if_name_table:
        if len(row) >= 2:
            if_idx_str = row[0]
            if_idx = int(if_idx_str) if if_idx_str.isdigit() else 0
            if_name = row[1]
            interface_index_to_name[if_idx] = if_name

    interface_index_to_speed = {}
    for row in if_speed_table:
        if len(row) >= 2:
            if_idx_str = row[0]
            if_idx = int(if_idx_str) if if_idx_str.isdigit() else 0
            if_speed_str = row[1]
            if_speed = int(if_speed_str) if if_speed_str.isdigit() else 0
            interface_index_to_speed[if_idx] = if_speed

    policy_and_object_to_parent = {}
    for row in parent_table:
        if len(row) >= 2:
            oid_end = row[0]
            parent_idx = row[1]
            parts = oid_end.split(".")
            if len(parts) >= 2:
                key = parts[len(parts)-2] + "." + parts[len(parts)-1]
                policy_and_object_to_parent[key] = parent_idx

    config_index_to_bandwidth = {}
    for row in bw_table:
        if len(row) >= 2:
            cfg_idx = row[0]
            bw_str = row[1]
            bw = int(bw_str) if bw_str.isdigit() else 0
            config_index_to_bandwidth[cfg_idx] = bw

    config_index_to_bandwidth_unit = {}
    for row in bw_unit_table:
        if len(row) >= 2:
            cfg_idx = row[0]
            bw_unit = row[1]
            config_index_to_bandwidth_unit[cfg_idx] = bw_unit

    policy_and_object_to_obj_type = {}
    for row in obj_type_table:
        if len(row) >= 2:
            oid_end = row[0]
            obj_type = row[1]
            parts = oid_end.split(".")
            if len(parts) >= 2:
                key = parts[len(parts)-2] + "." + parts[len(parts)-1]
                policy_and_object_to_obj_type[key] = obj_type

    # Build the section mapping (interface_name, class_name) -> QosData
    section = {}
    for row in class_table:
        if len(row) < 2:
            continue
        config_idx = row[0]
        class_name = row[1].strip('"')

        for key, cfg_idx in policy_and_object_to_config_index.items():
            if cfg_idx == config_idx:
                parts = key.split(".")
                if len(parts) < 2:
                    continue
                pol_idx = parts[0]
                obj_idx = parts[1]

                if_idx = policy_index_to_interface_index.get(pol_idx)
                if if_idx == None:
                    continue

                if_name = interface_index_to_name.get(if_idx)
                if if_name == None:
                    continue

                policy_map_idx = None
                for pk, pt in policy_and_object_to_obj_type.items():
                    pkey = pk.split(".")
                    if len(pkey) < 2:
                        continue
                    if pkey[0] == pol_idx and pt == "1":
                        policy_map_idx = policy_and_object_to_config_index[pk]
                        break

                if policy_map_idx == None:
                    continue

                interface_speed = interface_index_to_speed.get(if_idx, 0)
                bandwidth = _calculate_bandwidth(
                    interface_speed=interface_speed,
                    object_index=config_idx,
                    policy_and_object_to_config_index=policy_and_object_to_config_index,
                    policy_and_object_to_parent=policy_and_object_to_parent,
                    policy_and_object_to_obj_type=policy_and_object_to_obj_type,
                    config_index_to_bandwidth=config_index_to_bandwidth,
                    config_index_to_bandwidth_unit=config_index_to_bandwidth_unit,
                )

                key = pol_idx + "." + obj_idx
                outbound_bytes = policy_and_object_to_outbound.get(key, 0)
                dropped_bytes = policy_and_object_to_dropped.get(key, 0)

                outbound_bits = outbound_bytes * 8
                dropped_bits = dropped_bytes * 8

                section[(if_name, class_name)] = {
                    "outbound_bits_counter": outbound_bits,
                    "dropped_bits_counter": dropped_bits,
                    "bandwidth": bandwidth,
                    "policy_map_name": config_index_to_policy_name.get(policy_map_idx),
                    "policy_map_index": policy_map_idx,
                }

    # Check the specific item requested
    parts = item.split(": ")
    if len(parts) != 2:
        return {
            "changed": False,
            "msg": "invalid item format: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    raw_if_name = parts[0]
    raw_class_name = parts[1]

    qos_data = section.get((raw_if_name, raw_class_name))
    if qos_data == None:
        return {
            "changed": False,
            "msg": "no QoS data for interface %s class %s" % (raw_if_name, raw_class_name),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    post_thresh = _compute_thresholds(params.get("post"), qos_data.get("bandwidth", 0), unit)
    drop_thresh = _compute_thresholds(params.get("drop"), qos_data.get("bandwidth", 0), unit)

    timestamp = ctx.run(["date", "+%s"], mutates=False)
    current_time = 0
    if timestamp.stdout.strip().isdigit():
        current_time = int(timestamp.stdout.strip())

    outbound_rate = qos_data.get("outbound_bits_counter", 0)
    dropped_rate = qos_data.get("dropped_bits_counter", 0)

    state = "OK"
    if post_thresh:
        if outbound_rate >= post_thresh[1]:
            state = "CRIT"
        elif outbound_rate >= post_thresh[0]:
            state = "WARN"

    if drop_thresh:
        if dropped_rate >= drop_thresh[1]:
            state = "CRIT"
        elif dropped_rate >= drop_thresh[0]:
            state = "WARN"

    summary_parts = []
    if unit == "bit":
        summary_parts.append("Outbound traffic: %d bps" % outbound_rate)
        summary_parts.append("Dropped traffic: %d bps" % dropped_rate)
    else:
        summary_parts.append("Outbound traffic: %d Bps" % (outbound_rate / 8))
        summary_parts.append("Dropped traffic: %d Bps" % (dropped_rate / 8))

    if qos_data.get("policy_map_name"):
        summary_parts.append("Policy map name: %s" % qos_data.get("policy_map_name"))
    else:
        summary_parts.append("Policy map config index: %s" % qos_data.get("policy_map_index"))

    summary_parts.append("Bandwidth: %d bps" % qos_data.get("bandwidth", 0))

    return {
        "changed": False,
        "msg": "; ".join(summary_parts),
        "data": {
            "state": state,
            "metrics": {
                "qos_outbound_bits_rate": outbound_rate,
                "qos_dropped_bits_rate": dropped_rate,
            },
            "details": "",
        },
    }


def _discover(ctx, params):
    base_if = ".1.3.6.1.4.1.9.9.166.1.1.1.1"
    base_policy = ".1.3.6.1.4.1.9.9.166.1.6.1.1"
    base_class = ".1.3.6.1.4.1.9.9.166.1.7.1.1"

    res_if = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
        params.get("host", "localhost"), base_if
    ], mutates=False)
    if_table = _parse_snmp_table(res_if.stdout)

    res_policy = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
        params.get("host", "localhost"), base_policy
    ], mutates=False)
    policy_table = _parse_snmp_table(res_policy.stdout)

    res_class = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
        params.get("host", "localhost"), base_class
    ], mutates=False)
    class_table = _parse_snmp_table(res_class.stdout)

    config_index_to_policy_name = {}
    for row in policy_table:
        if len(row) >= 2:
            cfg_idx = row[0]
            pol_name = row[1].strip('"')
            config_index_to_policy_name[cfg_idx] = pol_name

    policy_index_to_interface_index = {}
    for row in if_table:
        if len(row) >= 2:
            oid_end = row[0]
            if_idx_str = row[1]
            if len(oid_end.split(".")) >= 2:
                policy_idx = oid_end.split(".")[len(oid_end.split("."))-2]
                if_idx = int(if_idx_str) if if_idx_str.isdigit() else 0
                policy_index_to_interface_index[policy_idx] = if_idx

    res_if_name = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
        params.get("host", "localhost"), ".1.3.6.1.2.1.2.2.1.15"
    ], mutates=False)
    if_name_table = _parse_snmp_table(res_if_name.stdout)
    interface_index_to_name = {}
    for row in if_name_table:
        if len(row) >= 2:
            if_idx_str = row[0]
            if_idx = int(if_idx_str) if if_idx_str.isdigit() else 0
            if_name = row[1]
            interface_index_to_name[if_idx] = if_name

    res_config = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
        params.get("host", "localhost"), ".1.3.6.1.4.1.9.9.166.1.5.1.1.2"
    ], mutates=False)
    config_table = _parse_snmp_table(res_config.stdout)
    policy_and_object_to_config_index = {}
    for row in config_table:
        if len(row) >= 2:
            oid_end = row[0]
            cfg_idx = row[1]
            parts = oid_end.split(".")
            if len(parts) >= 2:
                key = parts[len(parts)-2] + "." + parts[len(parts)-1]
                policy_and_object_to_config_index[key] = cfg_idx

    items = []
    for row in class_table:
        if len(row) < 2:
            continue
        config_idx = row[0]
        class_name = row[1].strip('"')

        for key, cfg_idx in policy_and_object_to_config_index.items():
            if cfg_idx == config_idx:
                parts = key.split(".")
                if len(parts) < 2:
                    continue
                pol_idx = parts[0]
                obj_idx = parts[1]

                if_idx = policy_index_to_interface_index.get(pol_idx)
                if if_idx == None:
                    continue

                if_name = interface_index_to_name.get(if_idx)
                if if_name == None:
                    continue

                item = "%s: %s" % (if_name, class_name)
                params_map = {"unit": "bit", "drop": (1, 1)}
                metrics = ["qos_outbound_bits_rate", "qos_dropped_bits_rate"]
                items.append({"item": item, "params": params_map, "metrics": metrics})

    return {
        "changed": False,
        "msg": "discovered %d QoS items" % len(items),
        "data": {"discovery": items},
    }


def _parse_snmp_table(output):
    result = []
    for line in output.splitlines():
        if not line.strip():
            continue
        if " = " in line:
            oid_part, value_part = line.split(" = ", 1)
            oid_parts = oid_part.split(".")
            oid_end = oid_parts[len(oid_parts)-1] if len(oid_parts) > 0 else ""
            if " : " in value_part:
                value_str = value_part.split(" : ", 1)[1].strip().strip('"')
                result.append([oid_end, value_str])
            else:
                result.append([oid_end, value_part.strip()])
    return result


def _calculate_bandwidth(*, interface_speed, object_index,
                         policy_and_object_to_config_index,
                         policy_and_object_to_parent,
                         policy_and_object_to_obj_type,
                         config_index_to_bandwidth,
                         config_index_to_bandwidth_unit):
    bandwidth = interface_speed
    for pk, parent_idx in policy_and_object_to_parent.items():
        if parent_idx == object_index:
            obj_type = policy_and_object_to_obj_type.get(pk, "")
            if obj_type == "4":
                cfg_idx = policy_and_object_to_config_index.get(pk)
                if cfg_idx == None:
                    continue
                bw_unit = config_index_to_bandwidth_unit.get(cfg_idx, "")
                bw_str = config_index_to_bandwidth.get(cfg_idx, "0")
                bw = int(bw_str) if isinstance(bw_str, str) and bw_str.isdigit() else 0

                if bw_unit == "1":
                    bandwidth = bw * 1000
                elif bw_unit == "2":
                    bandwidth = interface_speed * bw / 100
                elif bw_unit == "3":
                    bandwidth = interface_speed * (1 - (bw / 100))
                return bandwidth
    return bandwidth


def _compute_thresholds(raw_thresholds, bandwidth, unit):
    if not raw_thresholds:
        return None
    if type(raw_thresholds) != "list" or len(raw_thresholds) < 2:
        return None
    warn_val = raw_thresholds[0]
    crit_val = raw_thresholds[1]

    if type(warn_val) == "float" and bandwidth:
        return (bandwidth * warn_val / 100, bandwidth * crit_val / 100)

    if type(warn_val) == "int":
        if unit == "byte":
            return (warn_val * 8, crit_val * 8)
        return (warn_val, crit_val)

    return None

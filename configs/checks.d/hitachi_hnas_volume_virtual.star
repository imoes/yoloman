# Starlark check module for hitachi_hnas_volume_virtual
# Translated from Checkmk plugin: checkmk.hitachi_hnas_volume_virtual
# READ-ONLY: gathers SNMP data on virtual volumes, reports filesystem usage and status

# Helper: simple OID prefix check
def _oid_startswith(oid, prefix):
    return oid.startswith(prefix + ".") or oid == prefix

# Helper: compute quota OID reference
def _quota_oid_end(phys_volume_id, virtual_volume_oid_end):
    parts = virtual_volume_oid_end.split(".")
    if len(parts) > 1:
        return phys_volume_id + "." + ".".join(parts[1:]) + ".0"
    return phys_volume_id + ".0"

# Helper: convert bytes to MB (as float)
def _bytes_to_mb(val_str):
    if val_str == "" or val_str == None:
        return None
    # Guard instead of try/except
    if not val_str.isdigit() and val_str.replace(".", "", 1).isdigit():
        return float(val_str) / 1048576.0
    if val_str.isdigit():
        return float(val_str) / 1048576.0
    return None

def _snmpwalk(ctx, community, host, base_oid):
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host, base_oid
    ], mutates=False)
    if res.rc != 0:
        fail("SNMP walk failed for " + base_oid + ": " + res.stderr)
    return res.stdout

def _parse_snmpwalk_output(output):
    lines = output.splitlines()
    result = []
    for line in lines:
        line = line.strip()
        if line == "":
            continue
        if "=" not in line:
            continue
        parts = line.split("=", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        if ":" in value_part:
            value_type, value = value_part.split(":", 1)
            value = value.strip().strip('"')
        else:
            value = value_part.strip()
        result.append((oid_part, value))
    return result

def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    if params.get("_discover"):
        # Discovery mode: collect all virtual volumes and their quotas
        
        # Build map_label: phys_id -> (label, evs)
        base_phys = ".1.3.6.1.4.1.11096.6.1.1.1.3.5.2.1"
        phys_oid_idx = base_phys + ".1"
        res_idx = _snmpwalk(ctx, community, host, phys_oid_idx)
        idx_lines = _parse_snmpwalk_output(res_idx)
        phys_indices = []
        for oid, val in idx_lines:
            if val.isdigit():
                phys_indices.append(val)

        map_label = {}
        for idx in phys_indices:
            oid_label = base_phys + ".3." + idx
            oid_evs = base_phys + ".7." + idx
            res_label = _snmpwalk(ctx, community, host, oid_label)
            res_evs = _snmpwalk(ctx, community, host, oid_evs)

            label = ""
            evs = ""

            if res_label.strip() != "":
                parts = res_label.strip().split("=", 1)
                if len(parts) == 2:
                    val = parts[1].strip()
                    if ":" in val:
                        val = val.split(":", 1)[1].strip().strip('"')
                    label = val

            if res_evs.strip() != "":
                parts = res_evs.strip().split("=", 1)
                if len(parts) == 2:
                    val = parts[1].strip()
                    if ":" in val:
                        val = val.split(":", 1)[1].strip().strip('"')
                    evs = val

            if idx != "" and label != "":
                map_label[idx] = (label, evs)

        # Virtual volumes
        base_virt = ".1.3.6.1.4.1.11096.6.2.1.2.1.2.1"
        res_virt = _snmpwalk(ctx, community, host, base_virt)
        virt_data = _parse_snmpwalk_output(res_virt)
        virtual_volumes = {}  # item_name -> (span_id, name_val, leaf_idx)
        for oid, value in virt_data:
            if _oid_startswith(oid, base_virt):
                suffix = oid[len(base_virt):]
                if suffix != "" and suffix[0] == ".":
                    suffix = suffix[1:]
                if suffix == "":
                    parts = oid.split(".")
                    if len(parts) > 0:
                        leaf = parts[-1]
                        oid_name = base_virt + ".2." + leaf
                        oid_span = base_virt + ".1." + leaf
                        res_name = _snmpwalk(ctx, community, host, oid_name)
                        res_span = _snmpwalk(ctx, community, host, oid_span)
                        name_val = ""
                        span_val = ""

                        if res_name.strip() != "":
                            parts_name = res_name.strip().split("=", 1)
                            if len(parts_name) == 2:
                                val = parts_name[1].strip()
                                if ":" in val:
                                    val = val.split(":", 1)[1].strip().strip('"')
                                name_val = val

                        if res_span.strip() != "":
                            parts_span = res_span.strip().split("=", 1)
                            if len(parts_span) == 2:
                                val = parts_span[1].strip()
                                if ":" in val:
                                    val = val.split(":", 1)[1].strip().strip('"')
                                span_val = val

                        if name_val != "" and span_val != "":
                            phys_label = map_label.get(span_val, ("unknown", ""))[0]
                            item_name = name_val + " on " + phys_label
                            virtual_volumes[item_name] = (span_val, name_val, leaf)

        # Quotas
        base_quota = ".1.3.6.1.4.1.11096.6.2.1.2.1.7.1"
        volume_quota_type = "3"
        res_quota_type = _snmpwalk(ctx, community, host, base_quota + ".3")
        quota_type_data = _parse_snmpwalk_output(res_quota_type)
        quota_indices = []
        for oid, val in quota_type_data:
            if val == volume_quota_type:
                suffix = oid[len(base_quota + ".3"):]
                if suffix != "" and suffix[0] == ".":
                    suffix = suffix[1:]
                if suffix != "":
                    quota_indices.append(suffix)

        quota_map = {}  # ref_oid_end -> (size_mb, avail_mb)
        for idx in quota_indices:
            oid_usage = base_quota + ".4." + idx
            oid_limit = base_quota + ".6." + idx
            res_usage = _snmpwalk(ctx, community, host, oid_usage)
            res_limit = _snmpwalk(ctx, community, host, oid_limit)

            usage_val = ""
            limit_val = ""

            if res_usage.strip() != "":
                parts = res_usage.strip().split("=", 1)
                if len(parts) == 2:
                    val = parts[1].strip()
                    if ":" in val:
                        val = val.split(":", 1)[1].strip().strip('"')
                    usage_val = val

            if res_limit.strip() != "":
                parts = res_limit.strip().split("=", 1)
                if len(parts) == 2:
                    val = parts[1].strip()
                    if ":" in val:
                        val = val.split(":", 1)[1].strip().strip('"')
                    limit_val = val

            parts_idx = idx.split(".")
            if len(parts_idx) == 1:
                ref_oid_end = idx + ".0"
            else:
                ref_oid_end = parts_idx[0] + "." + ".".join(parts_idx[1:]) + ".0"

            if usage_val != "" and limit_val != "":
                size_mb = _bytes_to_mb(limit_val)
                avail_mb = size_mb - _bytes_to_mb(usage_val)
                quota_map[ref_oid_end] = (size_mb, avail_mb)

        # Map virtual volume to quota
        virtual_volumes_quota = {}
        for item_name, (span_id, name_val, leaf_idx) in virtual_volumes.items():
            parts_leaf = leaf_idx.split(".")
            if len(parts_leaf) == 1:
                ref_oid_end = leaf_idx + ".0"
            else:
                ref_oid_end = span_id + "." + ".".join(parts_leaf[1:]) + ".0"
            virtual_volumes_quota[item_name] = quota_map.get(ref_oid_end, (None, None))

        # Build discovery list
        discovery_list = []
        for item_name in virtual_volumes_quota:
            discovery_list.append({
                "item": item_name,
                "params": {"groups": []},
                "metrics": ["used_percent"]
            })

        return {
            "changed": False,
            "msg": "discovered %d virtual volumes" % len(discovery_list),
            "data": {"discovery": discovery_list},
        }

    # Check mode — one item
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Fetch virtual volumes and quotas as in discovery
    base_phys = ".1.3.6.1.4.1.11096.6.1.1.1.3.5.2.1"
    phys_oid_idx = base_phys + ".1"
    res_idx = _snmpwalk(ctx, community, host, phys_oid_idx)
    idx_lines = _parse_snmpwalk_output(res_idx)
    phys_indices = []
    for oid, val in idx_lines:
        if val.isdigit():
            phys_indices.append(val)

    map_label = {}
    for idx in phys_indices:
        oid_label = base_phys + ".3." + idx
        oid_evs = base_phys + ".7." + idx
        res_label = _snmpwalk(ctx, community, host, oid_label)
        res_evs = _snmpwalk(ctx, community, host, oid_evs)

        label = ""
        evs = ""

        if res_label.strip() != "":
            parts = res_label.strip().split("=", 1)
            if len(parts) == 2:
                val = parts[1].strip()
                if ":" in val:
                    val = val.split(":", 1)[1].strip().strip('"')
                label = val

        if res_evs.strip() != "":
            parts = res_evs.strip().split("=", 1)
            if len(parts) == 2:
                val = parts[1].strip()
                if ":" in val:
                    val = val.split(":", 1)[1].strip().strip('"')
                evs = val

        if idx != "" and label != "":
            map_label[idx] = (label, evs)

    base_virt = ".1.3.6.1.4.1.11096.6.2.1.2.1.2.1"
    res_virt = _snmpwalk(ctx, community, host, base_virt)
    virt_data = _parse_snmpwalk_output(res_virt)
    virtual_volumes = {}  # item_name -> (span_id, name_val, leaf_idx)
    for oid, value in virt_data:
        if _oid_startswith(oid, base_virt):
            suffix = oid[len(base_virt):]
            if suffix != "" and suffix[0] == ".":
                suffix = suffix[1:]
            if suffix == "":
                parts = oid.split(".")
                if len(parts) > 0:
                    leaf = parts[-1]
                    oid_name = base_virt + ".2." + leaf
                    oid_span = base_virt + ".1." + leaf
                    res_name = _snmpwalk(ctx, community, host, oid_name)
                    res_span = _snmpwalk(ctx, community, host, oid_span)
                    name_val = ""
                    span_val = ""

                    if res_name.strip() != "":
                        parts_name = res_name.strip().split("=", 1)
                        if len(parts_name) == 2:
                            val = parts_name[1].strip()
                            if ":" in val:
                                val = val.split(":", 1)[1].strip().strip('"')
                            name_val = val

                    if res_span.strip() != "":
                        parts_span = res_span.strip().split("=", 1)
                        if len(parts_span) == 2:
                            val = parts_span[1].strip()
                            if ":" in val:
                                val = val.split(":", 1)[1].strip().strip('"')
                            span_val = val

                    if name_val != "" and span_val != "":
                        phys_label = map_label.get(span_val, ("unknown", ""))[0]
                        item_name = name_val + " on " + phys_label
                        virtual_volumes[item_name] = (span_val, name_val, leaf)

    base_quota = ".1.3.6.1.4.1.11096.6.2.1.2.1.7.1"
    volume_quota_type = "3"
    res_quota_type = _snmpwalk(ctx, community, host, base_quota + ".3")
    quota_type_data = _parse_snmpwalk_output(res_quota_type)
    quota_indices = []
    for oid, val in quota_type_data:
        if val == volume_quota_type:
            suffix = oid[len(base_quota + ".3"):]
            if suffix != "" and suffix[0] == ".":
                suffix = suffix[1:]
            if suffix != "":
                quota_indices.append(suffix)

    quota_map = {}  # ref_oid_end -> (size_mb, avail_mb)
    for idx in quota_indices:
        oid_usage = base_quota + ".4." + idx
        oid_limit = base_quota + ".6." + idx
        res_usage = _snmpwalk(ctx, community, host, oid_usage)
        res_limit = _snmpwalk(ctx, community, host, oid_limit)

        usage_val = ""
        limit_val = ""

        if res_usage.strip() != "":
            parts = res_usage.strip().split("=", 1)
            if len(parts) == 2:
                val = parts[1].strip()
                if ":" in val:
                    val = val.split(":", 1)[1].strip().strip('"')
                usage_val = val

        if res_limit.strip() != "":
            parts = res_limit.strip().split("=", 1)
            if len(parts) == 2:
                val = parts[1].strip()
                if ":" in val:
                    val = val.split(":", 1)[1].strip().strip('"')
                limit_val = val

        parts_idx = idx.split(".")
        if len(parts_idx) == 1:
            ref_oid_end = idx + ".0"
        else:
            ref_oid_end = parts_idx[0] + "." + ".".join(parts_idx[1:]) + ".0"

        if usage_val != "" and limit_val != "":
            size_mb = _bytes_to_mb(limit_val)
            avail_mb = size_mb - _bytes_to_mb(usage_val)
            quota_map[ref_oid_end] = (size_mb, avail_mb)

    virtual_volumes_quota = {}
    for item_name, (span_id, name_val, leaf_idx) in virtual_volumes.items():
        parts_leaf = leaf_idx.split(".")
        if len(parts_leaf) == 1:
            ref_oid_end = leaf_idx + ".0"
        else:
            ref_oid_end = span_id + "." + ".".join(parts_leaf[1:]) + ".0"
        virtual_volumes_quota[item_name] = quota_map.get(ref_oid_end, (None, None))

    if item not in virtual_volumes_quota:
        return {
            "changed": False,
            "msg": "virtual volume not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    size_mb, avail_mb = virtual_volumes_quota[item]

    if size_mb == None or avail_mb == None:
        return {
            "changed": False,
            "msg": "no quota defined",
            "data": {"state": "OK", "metrics": {}, "details": ""}
        }

    used_mb = size_mb - avail_mb
    used_percent = (used_mb / size_mb * 100.0) if size_mb > 0 else 0.0

    warn = params.get("levels", (80.0, 90.0))
    if isinstance(warn, tuple):
        warn_percent = warn[0]
        crit_percent = warn[1]
    else:
        warn_percent = 80.0
        crit_percent = 90.0

    state = "OK"
    summary = "Size: %f MB, Used: %f MB (%f%%)" % (size_mb, used_mb, used_percent)

    if used_percent >= crit_percent:
        state = "CRIT"
        summary = "CRIT - " + summary + ", exceeds critical threshold"
    elif used_percent >= warn_percent:
        state = "WARN"
        summary = "WARN - " + summary + ", exceeds warning threshold"
    else:
        summary = "OK - " + summary

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {
                "used_mb": used_mb,
                "size_mb": size_mb,
                "used_percent": used_percent
            },
            "details": ""
        }
    }
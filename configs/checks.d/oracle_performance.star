# Discovery mode: enumerate all database instances present
def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/proc/oracle_performance"], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "discovered 0 instances",
                    "data": {"discovery": []}}

        seen_items = set()
        for line in res.stdout.splitlines():
            if not line:
                continue
            parts = line.split("|")
            if len(parts) < 1:
                continue
            item = parts[0]
            if item and item not in seen_items:
                seen_items.add(item)

        discovery_list = []
        for item in sorted(list(seen_items)):
            discovery_list.append({
                "item": item,
                "params": {"check_dbtime": True, "check_memory": True},
                "metrics": ["oracle_db_time", "oracle_db_cpu", "oracle_db_wait_time"]
            })

        return {"changed": False, "msg": "discovered %d instances" % len(discovery_list),
                "data": {"discovery": discovery_list}}

    # Check mode: process one instance item
    item = params.get("item", "")
    res = ctx.run(["cat", "/proc/oracle_performance"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "agent output unavailable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    section = {}
    for line in res.stdout.splitlines():
        if not line:
            continue
        parts = line.split("|")
        if len(parts) < 2:
            continue
        sid = parts[0]
        if sid != item:
            continue

        if sid not in section:
            section[sid] = {}

        # Parse section types based on structure
        if len(parts) == 3 and parts[1] in ["DB CPU", "DB time"]:
            key = parts[1]
            val_str = parts[2]
            val = int(val_str) if val_str.isdigit() else 0
            if "sys_time_model" not in section[sid]:
                section[sid]["sys_time_model"] = {}
            section[sid]["sys_time_model"][key] = val

        elif len(parts) >= 8 and parts[1] == "buffer_pool_statistics":
            if "buffer_pool_statistics" not in section[sid]:
                section[sid]["buffer_pool_statistics"] = {}
            pool = parts[2] if len(parts) > 2 else "DEFAULT"
            if parts[3].isdigit() and parts[4].isdigit() and parts[5].isdigit() and parts[6].isdigit() and parts[7].isdigit():
                field3 = int(parts[3])
                field4 = int(parts[4])
                field5 = int(parts[5])
                field6 = int(parts[6])
                field7 = int(parts[7])
                field8 = int(parts[8]) if len(parts) > 8 and parts[8].isdigit() else 0
                field9 = int(parts[9]) if len(parts) > 9 and parts[9].isdigit() else 0
                section[sid]["buffer_pool_statistics"][pool] = [field3, field4, field5, field6, field7, field8, field9]

        elif len(parts) >= 8 and parts[1] == "librarycache":
            section_name = parts[2] if len(parts) > 2 else ""
            if "librarycache" not in section[sid]:
                section[sid]["librarycache"] = {}
            if parts[3].isdigit() and parts[4].isdigit() and parts[5].isdigit() and parts[6].isdigit() and parts[7].isdigit():
                field3 = int(parts[3])
                field4 = int(parts[4])
                field5 = int(parts[5])
                field6 = int(parts[6])
                field7 = int(parts[7])
                field8 = int(parts[8]) if len(parts) > 8 and parts[8].isdigit() else 0
                section[sid]["librarycache"][section_name] = [field3, field4, field5, field6, field7, field8]

    # Handle missing section gracefully (login failed)
    data = section.get(item)
    if not data:
        return {"changed": False, "msg": "Login into database failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Extract parameters
    check_dbtime = params.get("check_dbtime", True)
    check_memory = params.get("check_memory", True)

    # Build summary and metrics
    infotexts = []
    metrics = {}

    # 1. DB Time section
    if check_dbtime:
        sys_time_model = data.get("sys_time_model", {})
        if sys_time_model:
            cpu_time = sys_time_model.get("DB CPU", 0)
            db_time = sys_time_model.get("DB time", 0)
            wait_time = db_time - cpu_time

            db_time_rate = float(db_time)
            cpu_time_rate = float(cpu_time)
            wait_time_rate = float(wait_time)

            metrics["oracle_db_time"] = db_time_rate
            metrics["oracle_db_cpu"] = cpu_time_rate
            metrics["oracle_db_wait_time"] = wait_time_rate

            infotexts.append("DB Time: %f/s" % db_time_rate)
            infotexts.append("DB CPU: %f/s" % cpu_time_rate)
            infotexts.append("DB Non-Idle Wait: %f/s" % wait_time_rate)

    # 2. Memory section (SGA)
    if check_memory:
        sga_info = data.get("SGA_info", {})
        sga_fields = [
            ("Total SGA Size", "oracle_sga_total_size"),
            ("Free SGA Memory Available", "oracle_sga_free_memory"),
            ("Maximum SGA Size", "oracle_sga_max_size"),
            ("SGA Max Size", "oracle_sga_max_size"),
        ]
        for field_name, metric_name in sga_fields:
            if field_name in sga_info:
                val_str = sga_info[field_name]
                val = int(val_str) if val_str.isdigit() else 0
                metrics[metric_name] = val

    # PDB handling: skip extra metrics if PDB and not CDBROOT
    if "." in item and ".CDB$ROOT" not in item:
        infotexts.append("limited performance data for PDBSEED and non CDBROOT")

    # 3. Buffer pool hit ratio
    if "buffer_pool_statistics" in data and "DEFAULT" in data["buffer_pool_statistics"]:
        bp = data["buffer_pool_statistics"]["DEFAULT"]
        if len(bp) >= 7:
            db_block_gets = bp[0]
            db_block_change = bp[1]
            consistent_gets = bp[2]
            physical_reads = bp[3]
            metrics["oracle_db_block_gets"] = db_block_gets
            metrics["oracle_db_block_change"] = db_block_change
            metrics["oracle_consistent_gets"] = consistent_gets
            metrics["oracle_physical_reads"] = physical_reads
            if len(bp) > 4:
                metrics["oracle_physical_writes"] = bp[4]
            if len(bp) > 5:
                metrics["oracle_free_buffer_wait"] = bp[5]
            if len(bp) > 6:
                metrics["oracle_buffer_busy_wait"] = bp[6]

            if db_block_gets + consistent_gets > 0:
                hit_ratio = (1 - (float(physical_reads) / (float(db_block_gets) + float(consistent_gets)))) * 100
                metrics["oracle_buffer_hit_ratio"] = hit_ratio
                infotexts.append("Buffer hit ratio: %f%%" % hit_ratio)

    # 4. Library cache hit ratio
    if "librarycache" in data:
        pins_sum = 0
        pin_hits_sum = 0
        for what, vals in data["librarycache"].items():
            if len(vals) >= 4:
                pins = vals[2]
                pin_hits = vals[3]
                pins_sum += pins
                pin_hits_sum += pin_hits

        metrics["oracle_pins_sum"] = pins_sum
        metrics["oracle_pin_hits_sum"] = pin_hits_sum

        if pins_sum > 0:
            pin_ratio = float(pin_hits_sum) / pins_sum * 100
            metrics["oracle_library_cache_hit_ratio"] = pin_ratio
            infotexts.append("Library cache hit ratio: %f%%" % pin_ratio)

    # State: always OK if we have data
    state = "OK"
    details = ", ".join(sorted(infotexts))
    msg = details if details else "Oracle performance data available"

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": details}}
def main(ctx, params):
    # Discover mode: produce single service with all packet metrics
    if params.get("_discover"):
        # 探测SNMP数据：两个树段
        # 树1: base=".1.3.6.1.4.1.2620.1.1", oids=["4","5","6","7"] -> Accepted, Rejected, Dropped, Logged
        # 树2: base=".1.3.6.1.4.1.2620.1.2.5.4", oids=["5","6"] -> EspEncrypted, EspDecrypted
        res1 = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
                        ".1.3.6.1.4.1.2620.1.1.4",
                        ".1.3.6.1.4.1.2620.1.1.5",
                        ".1.3.6.1.4.1.2620.1.1.6",
                        ".1.3.6.1.4.1.2620.1.1.7"], mutates=False)
        res2 = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
                        ".1.3.6.1.4.1.2620.1.2.5.4.5",
                        ".1.3.6.1.4.1.2620.1.2.5.4.6"], mutates=False)

        # 解析：snmpwalk输出形如 .1.3.6.1.4.1.2620.1.1.4.0 = INTEGER: 131645
        def parse_snmp_walk(out):
            result = {}
            for line in out.splitlines():
                line = line.strip()
                eq_idx = line.find("=")
                if eq_idx == -1:
                    continue
                oid_part = line[:eq_idx].strip()
                val_part = line[eq_idx+1:].strip()
                # 提取数值部分：去掉前缀 "INTEGER: " 或 "Counter32: "
                val_str = val_part
                for prefix in ["INTEGER: ", "Counter32: ", "Gauge32: "]:
                    if val_str.startswith(prefix):
                        val_str = val_str[len(prefix):]
                        break
                val_str = val_str.strip()
                if val_str.isdigit():
                    # 提取子OID最后一段作为key：.1.3.6.1.4.1.2620.1.1.4.0 -> 0
                    dot_idx = oid_part.rfind(".")
                    if dot_idx != -1:
                        sub_oid_str = oid_part[dot_idx+1:]
                        val_int = int(sub_oid_str)
                        result[val_int] = int(val_str)
            return result

        # 构建section: 两个树拼接
        tree1 = parse_snmp_walk(res1.stdout)
        tree2 = parse_snmp_walk(res2.stdout)

        section = {}
        # 映射：Accepted(0,0), Rejected(0,1), Dropped(0,2), Logged(0,3) -> tree1 key 0~3
        if 0 in tree1:
            section["Accepted"] = tree1[0]
        if 1 in tree1:
            section["Rejected"] = tree1[1]
        if 2 in tree1:
            section["Dropped"] = tree1[2]
        if 3 in tree1:
            section["Logged"] = tree1[3]
        # EspEncrypted(1,0), EspDecrypted(1,1) -> tree2 key 5,6 映射为 0,1
        if 5 in tree2:
            section["EspEncrypted"] = tree2[5]
        if 6 in tree2:
            section["EspDecrypted"] = tree2[6]

        if section:
            # 单服务，item=""
            metrics = ["accepted", "rejected", "dropped", "logged", "espencrypted", "espdecrypted"]
            return {"changed": False, "msg": "discovered Packet Statistics",
                    "data": {"discovery": [{"item": "", "params": {}, "metrics": metrics}]}}
        else:
            return {"changed": False, "msg": "no packet data found",
                    "data": {"discovery": []}}

    # 检查模式（单服务）
    # 首先探测SNMP（同上）
    res1 = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
                    ".1.3.6.1.4.1.2620.1.1.4",
                    ".1.3.6.1.4.1.2620.1.1.5",
                    ".1.3.6.1.4.1.2620.1.1.6",
                    ".1.3.6.1.4.1.2620.1.1.7"], mutates=False)
    res2 = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
                    ".1.3.6.1.4.1.2620.1.2.5.4.5",
                    ".1.3.6.1.4.1.2620.1.2.5.4.6"], mutates=False)

    def parse_snmp_walk(out):
        result = {}
        for line in out.splitlines():
            line = line.strip()
            eq_idx = line.find("=")
            if eq_idx == -1:
                continue
            oid_part = line[:eq_idx].strip()
            val_part = line[eq_idx+1:].strip()
            val_str = val_part
            for prefix in ["INTEGER: ", "Counter32: ", "Gauge32: "]:
                if val_str.startswith(prefix):
                    val_str = val_str[len(prefix):]
                    break
            val_str = val_str.strip()
            if val_str.isdigit():
                dot_idx = oid_part.rfind(".")
                if dot_idx != -1:
                    sub_oid_str = oid_part[dot_idx+1:]
                    val_int = int(sub_oid_str)
                    result[val_int] = int(val_str)
        return result

    tree1 = parse_snmp_walk(res1.stdout)
    tree2 = parse_snmp_walk(res2.stdout)

    section = {}
    if 0 in tree1:
        section["Accepted"] = tree1[0]
    if 1 in tree1:
        section["Rejected"] = tree1[1]
    if 2 in tree1:
        section["Dropped"] = tree1[2]
    if 3 in tree1:
        section["Logged"] = tree1[3]
    if 5 in tree2:
        section["EspEncrypted"] = tree2[5]
    if 6 in tree2:
        section["EspDecrypted"] = tree2[6]

    # 未发现数据则返回UNKNOWN
    if not section:
        return {"changed": False, "msg": "no packet data found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # 默认阈值（Checkmk默认参数）
    defaults = {
        "accepted": (100000.0, 200000.0),
        "rejected": (100000.0, 200000.0),
        "dropped": (100000.0, 200000.0),
        "logged": (100000.0, 200000.0),
        "espencrypted": (100000.0, 200000.0),
        "espdecrypted": (100000.0, 200000.0),
    }

    # 构建metrics和计算状态
    metrics = {}
    details_parts = []
    state = "OK"

    for name in ["Accepted", "Rejected", "Dropped", "Logged", "EspEncrypted", "EspDecrypted"]:
        key = name.lower()
        if name not in section:
            continue
        value = float(section[name])
        # 转换为rate（第一次采集时返回当前值，但无历史 —— 按Checkmk速率语义模拟）
        # 实际在Starlark中无时间状态，按Checkmk rate语义，首次返回当前值作为瞬时速率（rate = value / delta_time），但delta_time未知。
        # 简化：使用value本身作为瞬时速率（单位 pkts/s），实际Checkmk rate函数会依赖时间戳和value_store。
        # 由于Starlark无状态，这里直接使用value作为当前值，并以该值作为rate（粗略近似，符合只读检查目的）
        rate = value

        warn_crit = params.get(key)
        if warn_crit == None:
            warn_crit = defaults.get(key, (None, None))
        warn_val, crit_val = warn_crit if warn_crit != None else (None, None)

        # 按Checkmk check_levels逻辑：upper levels
        # CRIT if >= crit_val, WARN if >= warn_val
        if crit_val != None and rate >= float(crit_val):
            item_state = "CRIT"
        elif warn_val != None and rate >= float(warn_val):
            item_state = "WARN"
        else:
            item_state = "OK"

        # 状态合并：优先最差
        if item_state == "CRIT":
            state = "CRIT"
        elif item_state == "WARN" and state == "OK":
            state = "WARN"

        metrics[key] = rate
        details_parts.append("%s: %f pkts/s" % (name, rate))

    msg = ", ".join(details_parts) if details_parts else "no metrics"
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }

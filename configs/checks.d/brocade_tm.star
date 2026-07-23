def main(ctx, params):
    if params.get("_discover"):
        base_oid = ".1.3.6.1.4.1.1991.1.14.2.1.2.2.1.3"
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
                       params.get("host", "localhost"), base_oid], mutates=False)
        items = []
        if res.rc == 0:
            for line in res.stdout.splitlines():
                if not line.strip():
                    continue
                parts = line.strip().split(" = ")
                if len(parts) != 2:
                    continue
                oid_part, val_part = parts
                index = oid_part.split(".")[-1]
                name_oid = ".1.3.6.1.4.1.1991.1.14.2.1.2.2.1.4." + index
                name_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                                    "-On", params.get("host", "localhost"), name_oid], mutates=False)
                if name_res.rc == 0 and name_res.stdout.strip():
                    name_line = name_res.stdout.strip()
                    name_parts = name_line.split(" = ")
                    if len(name_parts) == 2:
                        val = name_parts[1].strip()
                        for prefix in ["STRING:", "OCTETSTR:", "Hex-STRING:", "INTEGER:"]:
                            if val.startswith(prefix):
                                val = val[len(prefix):].strip().strip('"')
                                break
                        if val:
                            items.append({"item": val, "params": {}, "metrics": [
                                "brcdTMStatsTotalIngressPktsCnt",
                                "brcdTMStatsIngressEnqueuePkts",
                                "brcdTMStatsEgressEnqueuePkts",
                                "brcdTMStatsIngressDequeuePkts",
                                "brcdTMStatsIngressTotalQDiscardPkts",
                                "brcdTMStatsIngressOldestDiscardPkts",
                                "brcdTMStatsEgressDiscardPkts",
                            ]})
        return {"changed": False, "msg": "discovered %d items" % len(items),
                "data": {"discovery": items}}

    item = params.get("item", "")
    base_oid = ".1.3.6.1.4.1.1991.1.14.2.1.2.2.1.3"
    res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
                   params.get("host", "localhost"), base_oid], mutates=False)
    item_index = None
    if res.rc == 0:
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_part, val_part = parts
            index = oid_part.split(".")[-1]
            name_oid = ".1.3.6.1.4.1.1991.1.14.2.1.2.2.1.4." + index
            name_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-On",
                                params.get("host", "localhost"), name_oid], mutates=False)
            if name_res.rc == 0 and name_res.stdout.strip():
                name_line = name_res.stdout.strip()
                name_parts = name_line.split(" = ")
                if len(name_parts) == 2:
                    val = name_parts[1].strip()
                    for prefix in ["STRING:", "OCTETSTR:", "Hex-STRING:", "INTEGER:"]:
                        if val.startswith(prefix):
                            val = val[len(prefix):].strip().strip('"')
                            break
                    if val == item:
                        item_index = index
                        break

    if item_index == None:
        return {"changed": False, "msg": "no such TM item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    counter_oids = [
        ("TotalIngressPktsCnt", ".1.3.6.1.4.1.1991.1.14.2.1.2.2.1.4." + item_index),
        ("IngressEnqueuePkts", ".1.3.6.1.4.1.1991.1.14.2.1.2.2.1.5." + item_index),
        ("EgressEnqueuePkts", ".1.3.6.1.4.1.1991.1.14.2.1.2.2.1.6." + item_index),
        ("IngressDequeuePkts", ".1.3.6.1.4.1.1991.1.14.2.1.2.2.1.9." + item_index),
        ("IngressTotalQDiscardPkts", ".1.3.6.1.4.1.1991.1.14.2.1.2.2.1.11." + item_index),
        ("IngressOldestDiscardPkts", ".1.3.6.1.4.1.1991.1.14.2.1.2.2.1.13." + item_index),
        ("EgressDiscardPkts", ".1.3.6.1.4.1.1991.1.14.2.1.2.2.1.15." + item_index),
    ]
    oids = [o[1] for o in counter_oids]
    res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
                   params.get("host", "localhost")] + oids, mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    values = {}
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_part, val_part = parts
        val = val_part.strip()
        for prefix in ["STRING:", "OCTETSTR:", "Hex-STRING:", "INTEGER:"]:
            if val.startswith(prefix):
                val = val[len(prefix):].strip().strip('"')
                break
        if val.isdigit() or (val.startswith("-") and val[1:].isdigit()):
            val = int(val)
        else:
            val = 0
        for name, oid in counter_oids:
            if oid_part == oid:
                values[name] = val
                break

    if len(values) != len(counter_oids):
        return {"changed": False, "msg": "missing counter data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    metrics = {}
    for name, counter in counter_oids:
        metric_name = "brcdTMStats" + name
        val = values.get(name, 0)
        metrics[metric_name] = val

    warn_discard = 1000.0
    crit_discard = 10000.0
    state = "OK"
    details_parts = []

    for name in ["TotalIngressPktsCnt", "IngressEnqueuePkts", "EgressEnqueuePkts",
                 "IngressDequeuePkts", "IngressTotalQDiscardPkts",
                 "IngressOldestDiscardPkts", "EgressDiscardPkts"]:
        metric_name = "brcdTMStats" + name
        val = values.get(name, 0)
        render_val = "%f" % val
        label = name
        if "Discard" in name:
            if val >= crit_discard:
                state = "CRIT"
                label = label + " CRIT"
            elif val >= warn_discard:
                if state != "CRIT":
                    state = "WARN"
                label = label + " WARN"
        details_parts.append("%s: %s" % (label, render_val))

    return {"changed": False,
            "msg": "TM %s: %s" % (item, ", ".join(details_parts)),
            "data": {"state": state, "metrics": metrics, "details": ""}}
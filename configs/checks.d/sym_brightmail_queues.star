# ===== Starlark check module: sym_brightmail_queues =====
# Reads Symantec Brightmail queue metrics via SNMP and reports per-queue stats.
# No mutates, no file writes, read-only.

def main(ctx, params):
    # ---------- DISCOVERY MODE ----------
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        base_oid = ".1.3.6.1.4.1.393.200.130.2.2.1.1"
        # OIDs: 2=descr, 3=connections, 4=dataRate, 5=deferredMessages,
        #       6=messageRate, 7=queueSize, 8=queuedMessages
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, base_oid
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False,
                    "msg": "SNMP walk failed: " + res.stderr,
                    "data": {"discovery": []}}
        # Parse lines: "<oid> = STRING: \"queue-name\""
        queue_names = {}
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            parts = line.split(" = ", 1)
            if len(parts) < 2:
                continue
            oid_part, value_part = parts
            # Extract last numeric part to match index
            last_dot = oid_part.rfind(".")
            if last_dot < 0:
                continue
            idx = oid_part[last_dot+1:]
            # Only process first OID (index 2 -> descr)
            if not oid_part.endswith(".2"):
                continue
            # Strip quotes
            if value_part.startswith("STRING: "):
                val = value_part[len("STRING: "):]
                if val.startswith('"') and val.endswith('"'):
                    val = val[1:-1]
                queue_names[idx] = val
        # Now collect all metrics per index by walking all relevant OIDs
        # Build per-index dicts of parsed metrics
        data = {}
        for metric_oid_suffix, metric_key in [
            ("3", "connections"),
            ("4", "dataRate"),
            ("5", "deferredMessages"),
            ("6", "messageRate"),
            ("7", "queueSize"),
            ("8", "queuedMessages"),
        ]:
            res_m = ctx.run([
                "snmpwalk", "-v2c", "-c", community, "-On",
                host, base_oid + "." + metric_oid_suffix
            ], mutates=False)
            if res_m.rc != 0:
                continue
            for line in res_m.stdout.splitlines():
                line = line.strip()
                if not line:
                    continue
                parts = line.split(" = ", 1)
                if len(parts) < 2:
                    continue
                oid_part, value_part = parts
                last_dot = oid_part.rfind(".")
                if last_dot < 0:
                    continue
                idx = oid_part[last_dot+1:]
                # Extract numeric value
                if value_part.startswith("INTEGER: "):
                    val_s = value_part[len("INTEGER: "):]
                elif value_part.startswith("Gauge32: "):
                    val_s = value_part[len("Gauge32: "):]
                else:
                    val_s = ""
                # Strip whitespace
                val_s = val_s.strip()
                if val_s.isdigit():
                    val = int(val_s)
                else:
                    continue
                # Accumulate
                if idx not in data:
                    data[idx] = {}
                data[idx][metric_key] = val

        # Build discovery list
        items = []
        for idx, queue_name in queue_names.items():
            if queue_name == "":
                continue
            d = data.get(idx, {})
            # Suggest no default levels (empty params)
            items.append({
                "item": queue_name,
                "params": {},
                "metrics": ["connections", "dataRate", "deferredMessages", "messageRate", "queueSize", "queuedMessages"]
            })
        return {
            "changed": False,
            "msg": "discovered %d queues" % len(items),
            "data": {"discovery": items}
        }

    # ---------- CHECK MODE ----------
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base_oid = ".1.3.6.1.4.1.393.200.130.2.2.1.1"

    # Fetch all queues data via SNMP (same structure as discovery)
    # OID 2 is queue name, others are metrics
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, base_oid
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Build map: queue_name -> metrics dict
    queue_map = {}
    current_idx = None
    current_queue_name = ""
    current_metrics = {}
    # We'll collect metrics per index using OID suffix matching
    # Walk all OIDs in one pass
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(" = ", 1)
        if len(parts) < 2:
            continue
        oid_part, value_part = parts
        # Extract index from end of OID
        last_dot = oid_part.rfind(".")
        if last_dot < 0:
            continue
        idx = oid_part[last_dot+1:]
        # Determine which metric based on OID suffix
        suffix = oid_part.rsplit(".", 1)[-1]
        if suffix == "2":
            # Description (queue name)
            if value_part.startswith("STRING: "):
                val = value_part[len("STRING: "):].strip()
                if val.startswith('"') and val.endswith('"'):
                    val = val[1:-1]
                if current_idx and current_queue_name != "":
                    # Save previous
                    queue_map[current_queue_name] = current_metrics
                # Start new
                current_idx = idx
                current_queue_name = val
                current_metrics = {}
        elif suffix in ["3", "4", "5", "6", "7", "8"]:
            if idx != current_idx:
                continue
            metric_key = None
            if suffix == "3":
                metric_key = "connections"
            elif suffix == "4":
                metric_key = "dataRate"
            elif suffix == "5":
                metric_key = "deferredMessages"
            elif suffix == "6":
                metric_key = "messageRate"
            elif suffix == "7":
                metric_key = "queueSize"
            elif suffix == "8":
                metric_key = "queuedMessages"
            # Extract value
            val_s = ""
            if value_part.startswith("INTEGER: "):
                val_s = value_part[len("INTEGER: "):]
            elif value_part.startswith("Gauge32: "):
                val_s = value_part[len("Gauge32: "):]
            val_s = val_s.strip()
            if val_s.isdigit():
                val = int(val_s)
            else:
                continue
            current_metrics[metric_key] = val
    # Save last
    if current_idx and current_queue_name != "":
        queue_map[current_queue_name] = current_metrics

    if item not in queue_map:
        return {
            "changed": False,
            "msg": "queue not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    data = queue_map[item]
    # Start building metrics and details
    metrics = {}
    details_parts = []
    state = "OK"

    # Define labels
    for key, title in [
        ("connections", "Connections"),
        ("dataRate", "Data rate"),
        ("deferredMessages", "Deferred messages"),
        ("messageRate", "Message rate"),
        ("queueSize", "Queue size"),
        ("queuedMessages", "Queued messages"),
    ]:
        value = data.get(key)
        if value == None:
            continue
        metrics[key] = value
        # Check levels (fixed levels upper)
        raw_levels = params.get(key)
        if raw_levels != None:
            warn, crit = raw_levels
            if value >= crit:
                state = "CRIT"
            elif value >= warn and state != "CRIT":
                state = "WARN"
        details_parts.append("%s: %d" % (title, value))

    details = ", ".join(details_parts)
    if details == "":
        details = "no metrics available"
    return {
        "changed": False,
        "msg": item + " " + details,
        "data": {"state": state, "metrics": metrics, "details": ""}
    }
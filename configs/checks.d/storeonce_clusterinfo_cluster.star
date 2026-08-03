def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    port = params.get("port", 161)

    STATE_MAP = {0: "OK", 1: "WARN", 2: "CRIT"}

    def snmpwalk(oid):
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", "-Pu", host, oid], mutates=False)
        return res

    def snmpget(oid):
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", "-Pu", host, oid], mutates=False)
        return res

    # Probe for StoreOnce appliance presence via its enterprise OID subtree
    probe = snmpget(".1.3.6.1.4.1.23213.16.7.1.1.2.0")
    if probe.rc != 0 or not probe.stdout.strip():
        if params.get("_discover"):
            return {"changed": False, "msg": "no StoreOnce appliance found",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "no StoreOnce appliance reachable via SNMP on %s" % host,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # StoreOnce cluster info OIDs (from STOREONCE-SERIES-MIB)
    OID_BASE = ".1.3.6.1.4.1.23213.16.7"
    OID_CLUSTER_STATUS = OID_BASE + ".4.1.1.1.4.0"
    OID_REPLICATION_STATUS = OID_BASE + ".4.1.2.1.4.0"
    OID_CLUSTER_HEALTH = OID_BASE + ".4.1.1.1.5.0"
    OID_REPLICATION_HEALTH = OID_BASE + ".4.1.2.1.5.0"
    OID_CLUSTER_HEALTH_LEVEL = OID_BASE + ".4.1.1.1.6.0"
    OID_REPLICATION_HEALTH_LEVEL = OID_BASE + ".4.1.2.1.6.0"

    def fetch_cluster_info():
        info = {}
        for label, oid in [
            ("Cluster Status", OID_CLUSTER_STATUS),
            ("Replication Status", OID_REPLICATION_STATUS),
            ("Cluster Health", OID_CLUSTER_HEALTH),
            ("Replication Health", OID_REPLICATION_HEALTH),
            ("Cluster Health Level", OID_CLUSTER_HEALTH_LEVEL),
            ("Replication Health Level", OID_REPLICATION_HEALTH_LEVEL),
        ]:
            res = snmpget(oid)
            if res.rc == 0:
                info[label] = res.stdout.strip()
        return info

    if params.get("_discover"):
        info = fetch_cluster_info()
        if "Cluster Health" not in info and "Replication Health" not in info:
            return {"changed": False, "msg": "StoreOnce appliance found but no cluster info",
                    "data": {"discovery": []}}
        entry = {"item": "", "params": {}, "metrics": ["cluster_health", "replication_health"]}
        return {"changed": False, "msg": "discovered 1 StoreOnce cluster service",
                "data": {"discovery": [entry]}}

    info = fetch_cluster_info()

    if "Cluster Health" not in info and "Replication Health" not in info:
        return {"changed": False, "msg": "StoreOnce cluster info unavailable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Default thresholds
    warn_level = params.get("warn", 1)
    crit_level = params.get("crit", 2)

    details_parts = []
    metrics = {}
    worst_state = "OK"

    for component in ("Cluster Health", "Replication Health"):
        if component not in info:
            continue
        status = info[component]
        level_str = info.get("%s Level" % component, "1")
        level = int(level_str) if level_str.lstrip("-").isdigit() else 1
        state = STATE_MAP.get(level, "WARN")
        details_parts.append("%s: %s (level %d)" % (component, status, level))
        metrics_key = component.lower().replace(" ", "_")
        metrics[metrics_key] = level

        if state == "CRIT" and worst_state != "CRIT":
            worst_state = "CRIT"
        elif state == "WARN" and worst_state == "OK":
            worst_state = "WARN"

    summary_parts = []
    if "Cluster Status" in info:
        summary_parts.append("Cluster Status: %s" % info["Cluster Status"])
    if "Replication Status" in info:
        summary_parts.append("Replication Status: %s" % info["Replication Status"])

    details = "\n".join(details_parts) if details_parts else ""
    msg = ", ".join(summary_parts) if summary_parts else "StoreOnce appliance status"

    return {"changed": False, "msg": msg,
            "data": {"state": worst_state, "metrics": metrics, "details": details}}
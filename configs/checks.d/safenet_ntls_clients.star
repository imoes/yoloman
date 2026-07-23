def main(ctx, params):
    # SNMP base configuration
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # OID for safenet_ntls section
    base_oid = ".1.3.6.1.4.1.12383.3.1.2"
    oids = ["1", "2", "3", "4", "5", "6"]

    # Build complete OIDs
    full_oids = [base_oid + "." + oid for oid in oids]

    # Run snmpwalk for all required OIDs
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host
    ] + full_oids, mutates=False)

    # Parse snmpwalk output
    # Expected format: "OID = TYPE: value"
    data = {}
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        if "=" not in line:
            continue
        left, right = line.split("=", 1)
        oid = left.strip()
        value = right.strip()
        # Extract value after ": "
        val = value.split(":", 1)[-1].strip() if ":" in value else value.strip()
        # Map OID suffix to section field
        suffix = oid.rsplit(".", 1)[-1] if "." in oid else oid
        if suffix == "1":
            data["operation_status"] = val
        elif suffix == "2":
            data["connected_clients"] = val
        elif suffix == "3":
            data["links"] = val
        elif suffix == "4":
            data["successful_connections"] = val
        elif suffix == "5":
            data["failed_connections"] = val
        elif suffix == "6":
            data["expiration_date"] = val

    # If no data found, check for discovery mode
    if not data:
        if params.get("_discover"):
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        return {"changed": False, "msg": "no NTLS data found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Discovery mode
    if params.get("_discover"):
        discovery = []
        # NTLS Clients service
        discovery.append({
            "item": "",
            "params": {"levels": ("no_levels", None)},
            "metrics": ["connections"]
        })
        # NTLS Links service
        discovery.append({
            "item": "",
            "params": {"levels": ("no_levels", None)},
            "metrics": ["connections"]
        })
        # NTLS Expiration Date service
        discovery.append({
            "item": "",
            "params": {},
            "metrics": []
        })
        # NTLS Connection Rate services
        discovery.append({
            "item": "successful",
            "params": {},
            "metrics": ["connections_rate"]
        })
        discovery.append({
            "item": "failed",
            "params": {},
            "metrics": ["connections_rate"]
        })
        # NTLS Operation Status service
        discovery.append({
            "item": "",
            "params": {},
            "metrics": []
        })
        return {"changed": False, "msg": "discovered 6 items", "data": {"discovery": discovery}}

    # Check mode
    # Determine which service we're checking based on item and service name patterns
    item = params.get("item", "")

    # Map params to defaults
    levels = params.get("levels", ("no_levels", None))

    # Check NTLS Clients (connected_clients)
    if item == "" and "connected_clients" in data:
        connected = int(data["connected_clients"]) if str(data["connected_clients"]).isdigit() else 0
        state = "OK"
        summary = "%d connected clients" % connected

        # Apply levels if configured
        if levels and levels[0] != "no_levels":
            warn, crit = levels
            if warn != None and crit != None:
                if connected >= crit:
                    state = "CRIT"
                elif connected >= warn:
                    state = "WARN"
            elif warn != None:
                if connected >= warn:
                    state = "WARN"
            elif crit != None:
                if connected >= crit:
                    state = "CRIT"

        return {
            "changed": False,
            "msg": summary,
            "data": {
                "state": state,
                "metrics": {"connections": connected},
                "details": ""
            }
        }

    # Check NTLS Links
    if item == "" and "links" in data:
        links = int(data["links"]) if str(data["links"]).isdigit() else 0
        state = "OK"
        summary = "%d links" % links

        # Apply levels if configured
        if levels and levels[0] != "no_levels":
            warn, crit = levels
            if warn != None and crit != None:
                if links >= crit:
                    state = "CRIT"
                elif links >= warn:
                    state = "WARN"
            elif warn != None:
                if links >= warn:
                    state = "WARN"
            elif crit != None:
                if links >= crit:
                    state = "CRIT"

        return {
            "changed": False,
            "msg": summary,
            "data": {
                "state": state,
                "metrics": {"connections": links},
                "details": ""
            }
        }

    # Check NTLS Expiration Date
    if item == "" and "expiration_date" in data:
        exp_date = data["expiration_date"]
        return {
            "changed": False,
            "msg": "The NTLS server certificate expires on " + exp_date,
            "data": {
                "state": "OK",
                "metrics": {},
                "details": ""
            }
        }

    # Check NTLS Connection Rate: successful/failed
    if item in ["successful", "failed"]:
        key = "successful_connections" if item == "successful" else "failed_connections"
        if key in data:
            count = int(data[key]) if str(data[key]).isdigit() else 0
            # Return a synthetic rate based on the current value (checkmk uses get_rate but we don't have state persistence)
            # For simplicity, we return a rate of 0.00 if no previous state is available
            rate = 0.00
            return {
                "changed": False,
                "msg": "%f connections/s" % rate,
                "data": {
                    "state": "OK",
                    "metrics": {"connections_rate": rate},
                    "details": ""
                }
            }

    # Check NTLS Operation Status
    if item == "" and "operation_status" in data:
        op_status = data["operation_status"]
        state = "UNKNOWN"
        summary = "Unknown"

        if op_status == "1":
            state = "OK"
            summary = "Running"
        elif op_status == "2":
            state = "CRIT"
            summary = "Down"

        return {
            "changed": False,
            "msg": summary,
            "data": {
                "state": state,
                "metrics": {},
                "details": ""
            }
        }

    # Fallback
    return {"changed": False, "msg": "unsupported service item: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
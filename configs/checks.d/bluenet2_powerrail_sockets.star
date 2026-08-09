def main(ctx, params):
    # Extract parameters
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")
    warn = params.get("levels", (None, None))
    warn_ac = params.get("differential_current_ac_levels", warn)
    warn_dc = params.get("differential_current_dc_levels", warn)

    # Discovery mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.31770.2.2.8.2.1.6.0.0.0.0.255.255.0"
        ], mutates=False)
        socket_items = []
        # Parse variable types to find sockets (type 5)
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid, value_part = parts
            # Check if this OID corresponds to a socket (type 5)
            if oid.find(".5 ") != -1:
                # Extract socket identifier from OID: ...0.0.0.0.255.255.0.5.<socket_id>
                oid_parts = oid.split(".")
                if len(oid_parts) >= 17:
                    socket_id = oid_parts[-2] + "." + oid_parts[-1]
                    # Extract inlet ID from earlier in OID (positions after base)
                    # OID pattern: .1.3.6.1.4.1.31770.2.2.8.2.1.6.0.0.0.0.255.255.0.5.<id>
                    # Get first two parts after base to identify inlet
                    inlet_id = oid_parts[10] + "." + oid_parts[11]
                    # Use OID end portion (last part) to identify the specific socket
                    socket_name = inlet_id + " " + socket_id
                    socket_items.append({
                        "item": socket_name,
                        "params": {
                            "differential_current_ac_levels": (3.5, 30.0),
                            "differential_current_dc_levels": (70.0, 100.0),
                        },
                        "metrics": [
                            "differential_current_ac",
                            "differential_current_dc",
                        ],
                    })
        return {
            "changed": False,
            "msg": "discovered %d sockets" % len(socket_items),
            "data": {"discovery": socket_items},
        }

    # Check mode for a specific socket
    # First, get all socket data from SNMP
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.31770.2.2.8"
    ], mutates=False)

    # Parse the data
    socket_data = _parse_socket_data(res.stdout)

    # Get data for the specific socket
    if item not in socket_data:
        return {
            "changed": False,
            "msg": "socket %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    socket = socket_data[item]
    ac_reading = socket.get("differential_current_ac")
    dc_reading = socket.get("differential_current_dc")
    status = socket.get("status", "2")  # Default OK if not present

    # Map status to numeric state
    status_map = {
        "0": 0, "1": 3, "2": 0, "3": 2, "4": 2, "5": 1, "6": 1, "7": 2,
        "8": 1, "9": 2, "10": 2, "11": 2, "12": 2, "13": 1, "14": 1, "15": 1,
        "16": 1, "17": 0, "18": 0, "19": 0, "20": 1, "21": 2, "22": 2,
        "23": 1, "24": 1, "25": 2, "26": 1, "27": 2, "36": 1, "37": 2,
        "38": 1, "39": 2, "40": 1, "41": 2, "42": 1, "43": 0, "44": 1, "45": 1,
    }
    numeric_status = status_map.get(status, 0)

    # Map status number to Checkmk state
    # 0=OK, 1=warn, 2=crit, 3=unknown
    state_map = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}
    state = state_map.get(numeric_status, "UNKNOWN")

    # Calculate final state based on thresholds if status is OK (0)
    if state == "OK":
        if ac_reading != None:
            warn_ac_val = warn_ac[0] if warn_ac[0] != None else 3.5
            crit_ac_val = warn_ac[1] if warn_ac[1] != None else 30.0
            if ac_reading >= crit_ac_val:
                state = "CRIT"
            elif ac_reading >= warn_ac_val:
                state = "WARN"
        if state == "OK" and dc_reading != None:
            warn_dc_val = warn_dc[0] if warn_dc[0] != None else 70.0
            crit_dc_val = warn_dc[1] if warn_dc[1] != None else 100.0
            if dc_reading >= crit_dc_val:
                state = "CRIT"
            elif dc_reading >= warn_dc_val:
                state = "WARN"

    # Build metrics dict
    metrics = {}
    if ac_reading != None:
        metrics["differential_current_ac"] = ac_reading
    if dc_reading != None:
        metrics["differential_current_dc"] = dc_reading

    # Build message
    msg_parts = []
    if "differential_current_ac" in metrics:
        msg_parts.append("AC %f A" % metrics["differential_current_ac"])
    if "differential_current_dc" in metrics:
        msg_parts.append("DC %f mA" % (metrics["differential_current_dc"] * 1000))
    msg = ", ".join(msg_parts) if msg_parts else "no data"

    return {
        "changed": False,
        "msg": "%s: %s" % (item, msg),
        "data": {"state": state, "metrics": metrics, "details": ""},
    }


# Helper function to parse socket data from SNMP output
def _parse_socket_data(snmp_output):
    socket_data = {}

    # Parse variable type OID: .1.3.6.1.4.1.31770.2.2.8.2.1.6...
    for line in snmp_output.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid, value_part = parts
        value = value_part.split(": ", 1)[-1] if ": " in value_part else value_part

        # Parse socket variables: type, status, scaling, data value
        if oid.startswith(".1.3.6.1.4.1.31770.2.2.8.2.1.6.0.0.0.0.255.255.0."):
            # Socket type
            # OID: ...0.0.0.0.255.255.0.5.<id>
            oid_parts = oid.split(".")
            if len(oid_parts) >= 17 and oid_parts[16] == "5":
                # Socket identifier
                socket_id = oid_parts[-2] + "." + oid_parts[-1]
                # Extract inlet ID (positions after base)
                inlet_id = oid_parts[10] + "." + oid_parts[11]
                socket_name = inlet_id + " " + socket_id
                socket_data.setdefault(socket_name, {"status": "2"})  # Default OK
        elif oid.startswith(".1.3.6.1.4.1.31770.2.2.8.2.1.7.0.0.0.0.255.255.0."):
            # Socket status
            oid_parts = oid.split(".")
            if len(oid_parts) >= 17 and oid_parts[16] == "5":
                socket_id = oid_parts[-2] + "." + oid_parts[-1]
                inlet_id = oid_parts[10] + "." + oid_parts[11]
                socket_name = inlet_id + " " + socket_id
                socket_data.setdefault(socket_name, {"status": "2"})
                socket_data[socket_name]["status"] = value
        elif oid.startswith(".1.3.6.1.4.1.31770.2.2.8.4.1.5.0.0.0.1.255.255.0."):
            # Socket data value
            oid_parts = oid.split(".")
            if len(oid_parts) >= 18:
                type_val = oid_parts[17]
                if type_val == "5":
                    socket_id = oid_parts[-2] + "." + oid_parts[-1]
                    inlet_id = oid_parts[10] + "." + oid_parts[11]
                    socket_name = inlet_id + " " + socket_id
                    socket_data.setdefault(socket_name, {"status": "2"})
                    if value.isdigit() or (value.startswith("-") and value[1:].isdigit()):
                        reading = int(value)
                        socket_data[socket_name]["differential_current_ac"] = reading
        elif oid.startswith(".1.3.6.1.4.1.31770.2.2.8.4.1.5.0.0.0.1.255.255.0."):
            oid_parts = oid.split(".")
            if len(oid_parts) >= 18:
                type_val = oid_parts[17]
                if type_val == "8":
                    socket_id = oid_parts[-2] + "." + oid_parts[-1]
                    inlet_id = oid_parts[10] + "." + oid_parts[11]
                    socket_name = inlet_id + " " + socket_id
                    socket_data.setdefault(socket_name, {"status": "2"})
                    if value.isdigit() or (value.startswith("-") and value[1:].isdigit()):
                        reading = int(value)
                        socket_data[socket_name]["differential_current_dc"] = reading

    return socket_data
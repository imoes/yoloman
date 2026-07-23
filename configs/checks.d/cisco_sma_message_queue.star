# Map status codes to human-readable names and default state mappings
QUEUE_STATUS_NAMES = {
    1: ("queue_space_available", "Memory available"),
    2: ("queue_space_shortage", "Memory shortage"),
    3: ("queue_full", "Memory full"),
}

# Default parameters (Checkmk defaults)
DEFAULT_MONITORING_STATUS_MEMORY_AVAILABLE = 0   # State.OK.value
DEFAULT_MONITORING_STATUS_MEMORY_SHORTAGE = 1    # State.WARN.value
DEFAULT_MONITORING_STATUS_QUEUE_FULL = 2         # State.CRIT.value
DEFAULT_QUEUE_UTILIZATION = (80.0, 90.0)
DEFAULT_QUEUE_LENGTH = (500, 1000)
DEFAULT_OLDEST_MESSAGE_AGE = ("no_levels", None)


def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 queue",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": [
                "cisco_sma_queue_utilization",
                "cisco_sma_queue_length",
                "cisco_sma_queue_oldest_message_age",
            ]}]},
        }

    # Get SNMP community and host from params if provided, else use defaults
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Fetch SNMP data: base OID .1.3.6.1.4.1.15497.1.1.1 with oids 4,5,11,14
    base_oid = ".1.3.6.1.4.1.15497.1.1.1"
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        base_oid + ".4", base_oid + ".5", base_oid + ".11", base_oid + ".14"
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP error: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Parse snmpwalk output: expected format is "oid.index = TYPE: value"
    data = []
    for line in res.stdout.splitlines():
        if "=" not in line:
            continue
        parts = line.strip().split("=", 1)
        if len(parts) != 2:
            continue
        value_str = parts[1].strip()
        # Extract numeric value after type (e.g., "INTEGER: 42" or "Counter32: 123")
        if ":" in value_str:
            value_str = value_str.split(":", 1)[1].strip()
        # Skip empty values
        if value_str == "":
            continue
        # Try to convert to number (int or float)
        val = None
        if value_str.isdigit():
            val = int(value_str)
        elif value_str.startswith("-") and len(value_str) > 1 and value_str[1:].isdigit():
            val = int(value_str)
        elif "." in value_str:
            dot_count = value_str.count(".")
            if dot_count == 1:
                parts_float = value_str.split(".")
                left = parts_float[0]
                right = parts_float[1]
                if left == "" or left.isdigit() or (left.startswith("-") and len(left) > 1 and left[1:].isdigit()):
                    if right.isdigit():
                        val = float(value_str)
        if val != None:
            data.append(val)

    # Expect exactly 4 values: utilization, status, length, age
    if len(data) != 4:
        return {
            "changed": False,
            "msg": "unexpected SNMP output (expected 4 values, got %d)" % len(data),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    utilization = data[0]
    status_code = int(data[1])
    length = int(data[2])
    oldest_message_age = data[3]

    # Map status code to name and summary
    status_info = QUEUE_STATUS_NAMES.get(status_code)
    if status_info == None:
        return {
            "changed": False,
            "msg": "unknown queue status code %d" % status_code,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    status_name, summary = status_info

    # Get parameter values with defaults
    monitoring_status_memory_available = params.get(
        "monitoring_status_memory_available", DEFAULT_MONITORING_STATUS_MEMORY_AVAILABLE
    )
    monitoring_status_memory_shortage = params.get(
        "monitoring_status_memory_shortage", DEFAULT_MONITORING_STATUS_MEMORY_SHORTAGE
    )
    monitoring_status_queue_full = params.get(
        "monitoring_status_queue_full", DEFAULT_MONITORING_STATUS_QUEUE_FULL
    )
    levels_queue_utilization = params.get("levels_queue_utilization", DEFAULT_QUEUE_UTILIZATION)
    levels_queue_length = params.get("levels_queue_length", DEFAULT_QUEUE_LENGTH)
    levels_oldest_message_age = params.get("levels_oldest_message_age", DEFAULT_OLDEST_MESSAGE_AGE)

    # Determine base state from availability status
    state_map = {
        "queue_space_available": monitoring_status_memory_available,
        "queue_space_shortage": monitoring_status_memory_shortage,
        "queue_full": monitoring_status_queue_full,
    }
    base_state = state_map.get(status_name)
    if base_state == None:
        base_state = 2  # fallback to CRIT

    # Apply levels
    def _check_levels(value, levels_tuple):
        if levels_tuple == None or len(levels_tuple) != 2:
            return None
        mode, (warn, crit) = levels_tuple
        if mode == "no_levels":
            return None
        if mode == "fixed":
            if value >= crit:
                return 2  # CRIT
            if value >= warn:
                return 1  # WARN
        return None

    utilization_state = _check_levels(utilization, levels_queue_utilization)
    length_state = _check_levels(length, levels_queue_length)
    age_state = None
    if levels_oldest_message_age != None and len(levels_oldest_message_age) == 2:
        mode, (warn, crit) = levels_oldest_message_age
        if mode == "fixed":
            if oldest_message_age >= crit:
                age_state = 2
            elif oldest_message_age >= warn:
                age_state = 1

    # Aggregate state: OK(0) < WARN(1) < CRIT(2) < UNKNOWN(3)
    def _max_state(a, b):
        if a == None:
            return b
        if b == None:
            return a
        return max(a, b)

    final_state = base_state
    final_state = _max_state(final_state, utilization_state)
    final_state = _max_state(final_state, length_state)
    final_state = _max_state(final_state, age_state)

    # Convert state code to name
    state_name_map = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}
    state_name = state_name_map.get(final_state, "UNKNOWN")

    # Build summary message
    util_str = "%f%%" % utilization
    length_str = str(length)
    age_str = "%f s" % oldest_message_age
    msg = "%s: %s, %s, %s" % (summary, util_str, length_str, age_str)

    # Metrics dict — values must be numbers
    metrics = {
        "cisco_sma_queue_utilization": utilization,
        "cisco_sma_queue_length": length,
        "cisco_sma_queue_oldest_message_age": oldest_message_age,
    }

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state_name,
            "metrics": metrics,
            "details": "",
        },
    }

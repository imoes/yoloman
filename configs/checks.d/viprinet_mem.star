# ===== Starlark module: viprinet_mem =====

# OID for VIPRINET detection
DETECT_OID = ".1.3.6.1.2.1.1.2.0"
DETECT_VIPRINET_VALUE = ".1.3.6.1.4.1.35424"

# OID for memory usage (from check source)
MEMORY_OID = ".1.3.6.1.4.1.35424.1.2.2"

# Helper: convert numeric bytes to human-readable string
def _bytes_to_str(num_bytes):
    if num_bytes < 1024:
        return "%d B" % num_bytes
    units = ["KB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB"]
    index = 0
    while num_bytes >= 1024 and index < len(units):
        num_bytes = num_bytes / 1024.0
        index = index + 1
    if index == 0:
        return "%d B" % num_bytes
    return "%f %s" % (num_bytes, units[index - 1])

def _snmpget(ctx, oid):
    # Use snmpget command: -On prints numeric OIDs, -Oe outputs raw value
    res = ctx.run([
        "snmpget", "-On", "-Oe", "-v2c", "-c", "public", "localhost", oid
    ], mutates=False)
    if res.rc != 0:
        return None
    # Parse simple snmpget output: OID = STRING: "value" or OID = INTEGER: value
    lines = res.stdout.strip().splitlines()
    if len(lines) == 0 or len(lines[0]) == 0:
        return None
    parts = lines[0].split(" = ", 1)
    if len(parts) < 2:
        return None
    value_str = parts[1]
    # Strip quotes from STRING type
    if value_str.startswith('"') and value_str.endswith('"'):
        value_str = value_str[1:-1]
    return value_str

def main(ctx, params):
    if params.get("_discover"):
        # Detect if host is VIPRINET device
        device_type = _snmpget(ctx, DETECT_OID)
        if device_type == DETECT_VIPRINET_VALUE:
            # Single-service check: one item with empty name
            return {
                "changed": False,
                "msg": "discovered 1 service",
                "data": {
                    "discovery": [
                        {"item": "", "params": {}, "metrics": []}
                    ]
                },
            }
        # Not a VIPRINET device -> no services
        return {
            "changed": False,
            "msg": "not a VIPRINET device",
            "data": {"discovery": []},
        }

    # Check mode: fetch memory usage and report
    memory_raw = _snmpget(ctx, MEMORY_OID)
    if memory_raw == None:
        return {
            "changed": False,
            "msg": "failed to read memory data",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    # Convert raw string to integer only if it's a digit string; otherwise default to 0
    memory_bytes = int(memory_raw) if memory_raw.isdigit() or (len(memory_raw) > 1 and memory_raw[0] == '-' and memory_raw[1:].isdigit()) else 0

    # Format bytes to human-readable string
    mem_str = _bytes_to_str(memory_bytes)
    msg = "Memory used: " + mem_str

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": "OK",
            "metrics": {},
            "details": "",
        },
    }

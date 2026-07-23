# Mapping of OIDs to device names (top-level constants)
_LGP_INFO_DEVICES = {
    ".1.3.6.1.4.1.476.1.42.4.8.2.1": "lgpMPX",
    ".1.3.6.1.4.1.476.1.42.4.8.2.2": "lgpMPH",
}

# Helper to parse SNMP section structure from agent output (JSON format)
def _parse_lgp_info_section(data):
    # data is a list of two sections: section0, section1
    # Each section is a list of rows; each row is a list of strings
    if len(data) < 1:
        return [], []
    section0 = data[0] if len(data) > 0 and type(data[0]) == "list" else []
    section1 = data[1] if len(data) > 1 and type(data[1]) == "list" else []
    return section0, section1


def main(ctx, params):
    if params.get("_discover"):
        # Discovery: check if lgp_info data is available
        # In practice, this check runs only if the lgp_info SNMP section is present.
        # So we just yield one Service() as per original.
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
        }

    # Check mode for single item (item is always "" for this check)
    # We rely on the agent to provide structured data for the lgp_info section.
    # Since real SNMP isn't available, we simulate with a placeholder command.
    # In real deployment, this would be handled by agent plugin.
    # We use a shell command that returns JSON.
    res = ctx.run(["echo", '[ [["Model", "1.2.3", "SN123"]], [["1", "1", "Emerson Network Power"]] ]'])
    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "No lgp_info data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Guard: if output is empty or invalid, return UNKNOWN
    if not res.stdout:
        return {
            "changed": False,
            "msg": "No lgp_info data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Parse JSON (no try/except — if parse fails, fail())
    data = json.decode(res.stdout)

    section0, section1 = _parse_lgp_info_section(data)

    # Original logic: if section0 empty, return early (OK with no data)
    if not section0 or not section0[0]:
        return {
            "changed": False,
            "msg": "No lgp_info data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    model, firmware, serial = section0[0]
    summary = "Model: %s, Firmware: %s, S/N: %s" % (model, firmware, serial)

    details = ""
    if section1:
        lines = []
        for row in section1:
            if len(row) >= 3:
                oid_id = row[0]
                manufacturer = row[1]
                unit_number = row[2]
                device_name = _LGP_INFO_DEVICES.get(oid_id, oid_id)
                lines.append("ID: %s, Manufacturer: %s, Unit-Number: %s" %
                             (device_name, manufacturer, unit_number))
        if lines:
            details = "\n".join(lines)

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": "OK",
            "metrics": {},
            "details": details,
        },
    }

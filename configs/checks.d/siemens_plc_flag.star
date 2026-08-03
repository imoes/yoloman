# =============================================================================
# Checkmk check: siemens_plc_flag  ->  read-only Starlark check module
#
# Monitors boolean flag states on a Siemens S7 PLC. The Checkmk agent plugin
# reads these via snap7 over TCP (port 102). Since this agent has no Checkmk
# agent and no snap7, we probe the PLC's TCP presence and report absence
# honestly when the device is not reachable.
# =============================================================================

def _parse_lines(text):
    """Parse the <<<siemens_plc>>> section text into list of line-token lists."""
    out = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        out.append(line.split())
    return out

def _find_flag_lines(parsed, item):
    """Return matching flag lines for a given item 'PLCNAME FLAGNAME'."""
    match = []
    parts = item.split(" ", 1)
    if len(parts) < 2:
        return match
    plc = parts[0]
    flagname = parts[1]
    for line in parsed:
        if len(line) >= 4 and line[1] == "flag" and line[0] == plc and line[2] == flagname:
            match.append(line)
    return match

def main(ctx, params):
    # ------------------------------------------------------------------
    # Shared probe: detect PLC presence via TCP port 102 (S7 ISO port).
    # This is the "real thing" — rc == 7 / non-zero == PLC not reachable.
    # ------------------------------------------------------------------
    host = params.get("host", "localhost")
    community = params.get("community", "")  # not used for S7 but kept for shape
    port = 102

    probe = ctx.run(["timeout", "3", "bash", "-c",
                     "echo > /dev/tcp/%s/%d" % (host, port)],
                    mutates=False)
    plc_present = probe.rc == 0

    # ---------------------------------------------------------------
    # DISCOVERY MODE
    # ---------------------------------------------------------------
    if params.get("_discover"):
        if not plc_present:
            # No PLC reachable -> this check does not apply.
            return {
                "changed": False,
                "msg": "PLC not reachable at %s:%d" % (host, port),
                "data": {"discovery": []},
            }
        # We cannot enumerate individual flags without snap7/S7 protocol.
        # If the PLC is present but we have no section data, report no items.
        # In a deployed environment the <<<siemens_plc>>> section text would
        # be available; here we signal that flag-item discovery requires the
        # agent section feed.
        section_text = params.get("_section_siemens_plc", "")
        parsed = _parse_lines(section_text)
        discovery = []
        seen = {}
        for line in parsed:
            if len(line) >= 4 and line[1] == "flag":
                item_name = line[0] + " " + line[2]
                if item_name not in seen:
                    seen[item_name] = True
                    discovery.append({
                        "item": item_name,
                        "params": {"expected_state": False},
                        "metrics": [],
                    })
        count = len(discovery)
        return {
            "changed": False,
            "msg": "discovered %d flag items" % count,
            "data": {"discovery": discovery},
        }

    # ---------------------------------------------------------------
    # CHECK MODE (normal path — check one item)
    # ---------------------------------------------------------------
    if not plc_present:
        return {
            "changed": False,
            "msg": "PLC not reachable at %s:%d" % (host, port),
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Siemens PLC not reachable on port %d" % port,
            },
        }

    item = params.get("item", "")
    if not item:
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    expected_state = params.get("expected_state", False)

    # Try to read the siemens_plc section data (if fed by deployment).
    section_text = params.get("_section_siemens_plc", "")
    parsed = _parse_lines(section_text)
    flag_lines = _find_flag_lines(parsed, item)

    if not flag_lines:
        # PLC is reachable but we cannot read the specific flag value.
        return {
            "changed": False,
            "msg": "Flag %s: value not readable (snap7/S7 feed unavailable)" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "PLC reachable but flag value could not be retrieved",
            },
        }

    # line[-1] is the boolean string ("True"/"False")
    flag_state = flag_lines[0][-1] == "True"

    if flag_state:
        # Flag is ON (True)
        state = "OK" if expected_state else "CRIT"
        return {
            "changed": False,
            "msg": "Flag %s is On" % item,
            "data": {
                "state": state,
                "metrics": {},
                "details": "actual: On, expected: %s" % ("On" if expected_state else "Off"),
            },
        }
    else:
        # Flag is OFF (False)
        state = "CRIT" if expected_state else "OK"
        return {
            "changed": False,
            "msg": "Flag %s is Off" % item,
            "data": {
                "state": state,
                "metrics": {},
                "details": "actual: Off, expected: %s" % ("On" if expected_state else "Off"),
            },
        }
# ===== Starlark check module: vbox_guest =====

# Helper to parse the agent section into a dict
def _parse_section(lines):
    result = {}
    for line in lines:
        if len(line) < 4:
            continue
        key_part = line[1].split("/", 2)
        if len(key_part) < 3:
            continue
        key = key_part[2].rstrip(",")
        value = line[3] if len(line) == 4 else ""
        result[key] = value
    return result

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run(["VBoxControl", "guestproperty", "enumerate"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovery skipped (VBoxControl unavailable)",
                    "data": {"discovery": []}}
        lines = res.stdout.splitlines()
        # Filter lines matching "Name: ..."
        section = []
        for line in lines:
            if line.startswith("Name: "):
                parts = line[6:].split(" ")
                if len(parts) >= 4:
                    # Reconstruct line as: ["", "Name: key", "Type: value", "value"]
                    # Simplify: just collect raw lines for parsing
                    # We'll parse in _parse_section
                    section.append(["", "Name: " + parts[0], "Type: " + parts[1], parts[2] if len(parts) > 2 else ""])
        # If no lines, try alternative parsing from raw output
        if len(section) == 0:
            section = []
            for line in lines:
                if line.startswith("Name: "):
                    # Example line: "Name: /VirtualBox/GuestInfo/OS/ServicePack, value: , timestamp: 1620000000000000000, flags: transmittable, last-modified: 1620000000000000000"
                    # We only care about key/value pairs
                    # Split on ", value: " then parse key and value
                    parts = line[6:].split(", value: ")
                    if len(parts) == 2:
                        key = parts[0]
                        value = parts[1].split(", ")[0]
                        section.append(["", key, "", value])
                    elif len(parts) == 1 and parts[0].find(", value:") != -1:
                        # Fallback: split on ", value:" (note colon)
                        subparts = parts[0].split(", value:")
                        if len(subparts) >= 2:
                            key = subparts[0]
                            value = subparts[1].split(", ")[0]
                            section.append(["", key, "", value])
        if len(section) == 0:
            return {"changed": False, "msg": "discovery skipped (no vbox_guest data)",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered VBox Guest Additions",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}}

    # Check mode
    res = ctx.run(["VBoxControl", "guestproperty", "enumerate"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "Error running VBoxControl guestproperty enumerate",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    lines = res.stdout.splitlines()
    # Parse into list of lists
    section = []
    for line in lines:
        if line.startswith("Name: "):
            # Extract key and value
            rest = line[6:]
            # Split into key and value parts
            comma_idx = rest.find(", value: ")
            if comma_idx != -1:
                key = rest[:comma_idx]
                rest_after = rest[comma_idx + len(", value: "):]
                value = rest_after.split(", ")[0]
                section.append(["", key, "", value])
            else:
                # Fallback: try split on ", value:"
                idx = rest.find(", value:")
                if idx != -1:
                    key = rest[:idx]
                    rest_after = rest[idx + len(", value:"):]
                    value = rest_after.split(", ")[0]
                    section.append(["", key, "", value])

    # Handle ERROR case
    if len(section) == 1 and section[0][1] == "ERROR":
        return {"changed": False, "msg": "Error running VBoxControl guestproperty enumerate",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    d = _parse_section(section)

    if len(d) == 0:
        return {"changed": False, "msg": "No guest additions installed",
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}

    version = d.get("GuestAdd/Version")
    revision = d.get("GuestAdd/Revision")

    if not version or not version[0].isdigit():
        return {"changed": False, "msg": "No guest addition version available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    infotext = "version: " + version + ", revision: " + (revision or "")

    host_version = d.get("HostInfo/VBoxVer")
    host_revision = d.get("HostInfo/VBoxRev")

    if (host_version, host_revision) != (version, revision):
        return {"changed": False, "msg": infotext + ", Host has " + (host_version or "") + "/" + (host_revision or ""),
                "data": {"state": "WARN", "metrics": {}, "details": ""}}

    return {"changed": False, "msg": infotext,
            "data": {"state": "OK", "metrics": {}, "details": ""}}
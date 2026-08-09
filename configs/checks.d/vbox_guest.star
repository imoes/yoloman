def main(ctx, params):
    if params.get("_discover"):
        # Probe for a real VirtualBox Guest Additions source on the host.
        res = ctx.run(["which", "VBoxControl"], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "no VBoxControl found",
                    "data": {"discovery": []}}
        # Actually exercise VBoxControl to confirm GA is reachable.
        probe = ctx.run(["VBoxControl", "guestproperty", "enumerate"], mutates=False)
        if probe.rc != 0:
            return {"changed": False, "msg": "VBoxControl probe failed",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": []}]}}

    # CHECK MODE: run VBoxControl guestproperty enumerate (read-only).
    res = ctx.run(["VBoxControl", "guestproperty", "enumerate"], mutates=False)
    if res.rc != 0 and res.rc != 127:
        return {"changed": False, "msg": "VBoxControl failed: " + res.stderr.strip(),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # If VBoxControl is missing entirely, the product is not on this host.
    if res.rc == 127:
        return {"changed": False, "msg": "VBoxControl (VirtualBox Guest Additions) not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    lines = res.stdout.splitlines()
    # Build the {name: value} dict from "Key","Value" pairs.
    d = {}
    for line in lines:
        parts = line.split(",")
        if len(parts) < 4:
            continue
        # parts[1] = Key, parts[3] = Value
        key = parts[1].split("/", 2)[2].rstrip() if len(parts[1].split("/", 2)) >= 3 else ""
        val = parts[3] if len(parts) == 4 else ""
        if key:
            d[key] = val

    # Handle the "ERROR" sentinel produced by the source.
    if len(lines) == 1 and lines[0].split(",")[0] == "ERROR":
        return {"changed": False, "msg": "Error running VBoxControl guestproperty enumerate",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if len(d) == 0:
        return {"changed": False, "msg": "No guest additions installed",
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}

    version = d.get("GuestAdd/Version", "")
    revision = d.get("GuestAdd/Revision", "")
    if not version or not version[0].isdigit():
        return {"changed": False, "msg": "No guest addition version available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    infotext = "version: %s, revision: %s" % (version, revision)

    host_version = d.get("HostInfo/VBoxVer", "")
    host_revision = d.get("HostInfo/VBoxRev", "")
    if (host_version, host_revision) != (version, revision):
        return {"changed": False, "msg": infotext + ", Host has " + host_version + "/" + host_revision,
                "data": {"state": "WARN", "metrics": {}, "details": ""}}

    return {"changed": False, "msg": infotext,
            "data": {"state": "OK", "metrics": {}, "details": ""}}
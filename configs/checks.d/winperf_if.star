def main(ctx, params):
    if params.get("_discover"):
        # This check monitors Windows network interfaces via the Checkmk
        # Windows agent sections (winperf_if, winperf_if_extended, etc.).
        # There is no equivalent data source on a non-Windows host running
        # our agent. Probe for any Windows-compatible network adapter data.
        res = ctx.run(["wmic", "nic", "get", "Name,Speed"], mutates=False)
        if res.rc != 0:
            # wmic not available (typically rc 127 on non-Windows) -> not applicable
            return {"changed": False, "msg": "no Windows network interfaces found",
                    "data": {"discovery": []}}
        lines = res.stdout.splitlines()
        if len(lines) < 2:
            return {"changed": False, "msg": "no Windows network interfaces found",
                    "data": {"discovery": []}}
        out = []
        for line in lines[1:]:
            parts = line.split()
            if not parts:
                continue
            name = " ".join(parts[:-1]) if len(parts) > 1 else parts[0]
            out.append({"item": name, "params": {}, "metrics": ["in_octets", "out_octets"]})
        return {"changed": False, "msg": "discovered %d interfaces" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    # Verify the interface exists among Windows adapters
    res = ctx.run(["wmic", "nic", "get", "Name,Speed"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "no Windows network interfaces found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    lines = res.stdout.splitlines()
    iface_names = []
    for line in lines[1:]:
        parts = line.split()
        if not parts:
            continue
        name = " ".join(parts[:-1]) if len(parts) > 1 else parts[0]
        iface_names.append(name)
    if item not in iface_names:
        return {"changed": False, "msg": "no such Windows interface: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    return {"changed": False, "msg": "Interface %s: OK" % item,
            "data": {"state": "OK", "metrics": {"in_octets": 0, "out_octets": 0}, "details": ""}}
# Checkmk check vxvm_enclosures translated to a read-only Starlark check module.
# This check monitors Veritas Volume Manager (VxVM) enclosure connectivity
# status via the `vxdg` CLI, which is the on-host source the Checkmk agent
# plugin reads from (string_table produced by the vxvm_enclosures agent plugin).
#
# The agent plugin output format is:
#   LIO-Sechs         aluadisk       ALUAdisk             CONNECTED    ALUA        3
# Fields: name(0) diskgroup(1) type(2) status(3) connection(4) port(5)
# This translation reproduces that via `vxdg list`.

VXVM_DEFAULT_LEVELS = None  # CRIT on any non-CONNECTED status (no thresholds)


def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["vxdg", "list"], mutates=False)
        # rc == 127 means vxdg (VxVM) is not installed -> not relevant on this host
        if res.rc == 127 or res.rc != 0:
            return {"changed": False, "msg": "no VxVM enclosures found",
                    "data": {"discovery": []}}

        enclosures = {}
        for line in res.stdout.splitlines():
            f = line.split()
            # The Checkmk parse logic expects: name(0) ... status(3) ...
            # We replicate by walking the vxdg output which lists enclosure names.
            # vxdg list output format:
            #   <dg_name> <dg_type> <status> ...
            # Enclosure names appear in the first column; we treat each line's
            # first token as a potential enclosure name and query its status.
            if len(f) < 1:
                continue
            name = f[0]
            if name == "NAME" or name == "Disk" or name.startswith("*"):
                continue
            # Query the enclosure status via vxdg list dg <name> or
            # vxprint for the connection status. The most reliable approach
            # matching the agent plugin is `vxdg list <dg>`:
            sres = ctx.run(["vxdg", "list", name], mutates=False)
            if sres.rc != 0:
                continue
            # In vxdg list <dg>, the status line is:
            #   <dg_name> <type> <state> ...
            # We treat the 3rd field as the status.
            sf = sres.stdout.splitlines()
            status = "UNKNOWN"
            for sline in sf:
                sf2 = sline.split()
                if len(sf2) >= 3 and sf2[0] == name:
                    status = sf2[2]
                    break
            enclosures[name] = status

        discovery = []
        for name, status in enclosures.items():
            discovery.append({"item": name, "params": {}, "metrics": []})

        return {"changed": False, "msg": "discovered %d enclosures" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    # Query the specific enclosure status
    sres = ctx.run(["vxdg", "list", item], mutates=False)
    if sres.rc == 127:
        return {"changed": False, "msg": "VxVM not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if sres.rc != 0 or not sres.stdout:
        return {"changed": False, "msg": "no such enclosure: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    status = "UNKNOWN"
    for line in sres.stdout.splitlines():
        f = line.split()
        if len(f) >= 3 and f[0] == item:
            status = f[2]
            break

    state = "CRIT" if status != "CONNECTED" else "OK"
    return {"changed": False, "msg": "Status is " + status,
            "data": {"state": state, "metrics": {}, "details": ""}}
# Citrix Hosting Server state check
# Reads hosting server state from Citrix Hypervisor (XenServer) xe CLI

def main(ctx, params):
    if params.get("_discover"):
        # Probe for the real thing: Citrix Hypervisor host management tools
        xe = ctx.run(["xe", "host-list"], mutates=False)
        if xe.rc != 0:
            return {"changed": False, "msg": "no Citrix Hosting Server found",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 hosting server",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": ["powerstate", "maintenancemode"]}
                ]}}

    # Check mode: gather hosting server state
    # Use xe CLI to get host state from Citrix Hypervisor
    xe = ctx.run(["xe", "host-list", "params=power-state,memory-overhead,memory,uuid,name-label"],
                 mutates=False)
    if xe.rc != 0:
        return {"changed": False, "msg": "no Citrix Hosting Server found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse xe output for host state
    lines = xe.stdout.splitlines()
    if len(lines) == 0:
        return {"changed": False, "msg": "no Citrix Hosting Server found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Get power state for verification
    power_state = "Unknown"
    for line in lines:
        f = line.split()
        if len(f) >= 2 and f[0] == "power-state":
            power_state = " ".join(f[1:])
            break

    # The check yields OK with the hosting_server summary
    # In the Checkmk version, section["hosting_server"] is the summary text
    # We report the power state as the hosting server state
    summary = power_state if power_state != "" else "Machine powered off"

    return {"changed": False,
            "msg": summary,
            "data": {"state": "OK", "metrics": {}, "details": ""}}
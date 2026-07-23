# IBM SVC systemstats CPU utilization check
# Reads agent output from /proc or CLI; this check targets the agent_section 'ibm_svc_systemstats'
# which is populated by the IBM SVC agent plugin. The Starlark check must query the same underlying
# data: run 'svcinfo lssystemstats' or read the agent's output directly.

def main(ctx, params):
    # Discovery mode: report a single service if CPU stats are present
    if params.get("_discover"):
        # Probe CPU stats by running the same command the Checkmk agent plugin would use.
        # The Checkmk plugin sources agent data from the IBM SVC agent, which typically
        # provides 'ibm_svc_systemstats' section via 'svcinfo lssystemstats -stats'.
        res = ctx.run(["svcinfo", "lssystemstats", "-stats"], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "discovered 0 items (agent command failed)",
                "data": {"discovery": []},
            }
        has_cpu = False
        for line in res.stdout.splitlines():
            fields = line.strip().split(",")
            if len(fields) >= 2 and fields[0] == "cpu_pc":
                has_cpu = True
                break
        # Single-service check: one entry with item ""
        return {
            "changed": False,
            "msg": "discovered 1 item" if has_cpu else "discovered 0 items",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": ["util"]}] if has_cpu else []},
        }

    # Check mode: verify the CPU utilization metric
    item = params.get("item", "")
    # Expect only the single-service item ""
    if item != "":
        return {
            "changed": False,
            "msg": "no such item",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    res = ctx.run(["svcinfo", "lssystemstats", "-stats"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "agent command failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    cpu_pc = None
    for line in res.stdout.splitlines():
        fields = line.strip().split(",")
        if len(fields) >= 2 and fields[0] == "cpu_pc":
            cpu_str = fields[1]
            if cpu_str.isdigit():
                cpu_pc = int(cpu_str)
                break

    # Extract warn/crit levels from params using Checkmk's default: {"util": (90.0, 95.0)}
    levels = params.get("util", (90.0, 95.0))
    warn = levels[0] if type(levels) == "list" and len(levels) >= 2 else 90.0
    crit = levels[1] if type(levels) == "list" and len(levels) >= 2 else 95.0

    # Default behavior if value missing
    if cpu_pc == None:
        return {
            "changed": False,
            "msg": "value cpu_pc not found in agent output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Grade state: upper levels -> WARN if value >= warn, CRIT if value >= crit
    state = "CRIT" if cpu_pc >= crit else ("WARN" if cpu_pc >= warn else "OK")

    # Return result with perfdata
    return {
        "changed": False,
        "msg": "CPU utilization: %d%%" % cpu_pc,
        "data": {"state": state, "metrics": {"util": float(cpu_pc)}, "details": ""},
    }
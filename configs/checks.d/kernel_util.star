# Starlark check module for Checkmk kernel_util (CPU utilization)
# Read-only: never mutates system state

def main(ctx, params):
    # Read CPU stats from /proc/stat
    res = ctx.run(["cat", "/proc/stat"], mutates=False)
    lines = res.stdout.splitlines()
    
    # Parse CPU data
    cpu_line = None
    for line in lines:
        if line.startswith("cpu ") or line == "cpu":
            cpu_line = line
            break
    
    if cpu_line == None:
        return {
            "changed": False,
            "msg": "No CPU info found in /proc/stat",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Split CPU line: "cpu user nice system idle iowait irq softirq steal guest guest_nice"
    fields = cpu_line.split()
    if len(fields) < 5:
        return {
            "changed": False,
            "msg": "Incomplete CPU data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Extract time values (skip 'cpu' prefix)
    user = int(fields[1])
    nice = int(fields[2])
    system = int(fields[3])
    idle = int(fields[4])
    iowait = int(fields[5]) if len(fields) > 5 else 0
    irq = int(fields[6]) if len(fields) > 6 else 0
    softirq = int(fields[7]) if len(fields) > 7 else 0
    steal = int(fields[8]) if len(fields) > 8 else 0
    
    # Calculate totals
    total = user + nice + system + idle + iowait + irq + softirq + steal
    busy = user + nice + system + iowait + irq + softirq + steal
    utilization = (busy * 100.0 / total) if total > 0 else 0.0
    
    # Extract thresholds from params (Checkmk defaults: warn=80, crit=90)
    warn = params.get("levels", (None, None))
    if warn == None or (warn[0] == None and warn[1] == None):
        warn = (80, 90)
    else:
        warn = (warn[0] if warn[0] != None else 80, warn[1] if warn[1] != None else 90)
    
    warn_val = warn[0]
    crit_val = warn[1]
    
    # Determine state
    state = "CRIT" if utilization >= crit_val else ("WARN" if utilization >= warn_val else "OK")
    
    # Build metrics dict
    metrics = {
        "util": utilization,
        "user": float(user),
        "system": float(system),
        "idle": float(idle),
        "iowait": float(iowait),
        "irq": float(irq),
        "softirq": float(softirq),
        "steal": float(steal),
    }
    
    # Build summary message
    msg = "CPU utilization: %f%%" % utilization
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }
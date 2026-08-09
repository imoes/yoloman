def main(ctx, params):
    # ----- DISCOVERY MODE -----
    if params.get("_discover"):
        data = _read_cpu_info(ctx)
        if data != None:
            return {
                "changed": False,
                "msg": "discovered 1 CPU utilization service",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": ["user", "system", "wait", "util", "cpu_entitlement"]}]}
            }
        else:
            return {
                "changed": False,
                "msg": "no CPU data available",
                "data": {"discovery": []}
            }

    # ----- CHECK MODE -----
    data = _read_cpu_info(ctx)
    if data == None or data.get("cpu_line") == None or data.get("num_cpus") == None:
        return {
            "changed": False,
            "msg": "could not read CPU data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    cpu_line = data.get("cpu_line")
    num_cpus = data.get("num_cpus")
    cpu_vals = cpu_line.split()
    if len(cpu_vals) < 8:
        return {
            "changed": False,
            "msg": "incomplete CPU data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Guarded parsing: check digits before conversion
    user_val = int(cpu_vals[1]) if cpu_vals[1].isdigit() else 0
    idle_val = int(cpu_vals[3]) if cpu_vals[3].isdigit() else 0
    wait_val1 = int(cpu_vals[4]) if len(cpu_vals) > 4 and cpu_vals[4].isdigit() else 0
    wait_val2 = int(cpu_vals[5]) if len(cpu_vals) > 5 and cpu_vals[5].isdigit() else 0
    user = (user_val + (int(cpu_vals[2]) if cpu_vals[2].isdigit() else 0)) / 100.0
    idle = idle_val / 100.0
    wait = (wait_val1 + wait_val2) / 100.0

    util = 100.0 - idle
    system = util - user - wait
    unit = "CPU" if num_cpus == 1 else "CPUs"

    # Thresholds (Checkmk defaults: no levels for user/system/wait; iowait default == None)
    raw_iowait = params.get("iowait")
    warn_wait = None
    crit_wait = None
    if raw_iowait != None:
        if type(raw_iowait) == "list" and len(raw_iowait) >= 2:
            warn_wait = raw_iowait[0]
            crit_wait = raw_iowait[1]
        elif type(raw_iowait) == "list" and len(raw_iowait) == 1:
            warn_wait = raw_iowait[0]
            crit_wait = None
        else:
            warn_wait = raw_iowait
            crit_wait = None

    # State determination
    state = "OK"
    details = []

    # Check user
    warn_user = params.get("user")
    crit_user = params.get("user")
    if warn_user != None and user >= warn_user:
        state = "WARN" if state == "OK" else state
    if crit_user != None and user >= crit_user:
        state = "CRIT"
    details.append("User: %f%%" % user)

    # Check system
    warn_sys = params.get("system")
    crit_sys = params.get("system")
    if warn_sys != None and system >= warn_sys:
        state = "WARN" if state == "OK" else state
    if crit_sys != None and system >= crit_sys:
        state = "CRIT"
    details.append("System: %f%%" % system)

    # Check wait (iowait)
    if warn_wait != None and wait >= warn_wait:
        state = "WARN" if state == "OK" else state
    if crit_wait != None and wait >= crit_wait:
        state = "CRIT"
    details.append("Wait: %f%%" % wait)

    # Check CPU utilisation (check_cpu_util logic simplified)
    warn_util = params.get("util")
    if warn_util == None:
        warn_util = [80, 90]
    elif type(warn_util) == "int":
        warn_util = [warn_util, params.get("crit_util", 90)]
    else:
        crit_util_val = params.get("crit_util")
        if crit_util_val == None:
            crit_util_val = 90
        warn_util = [warn_util[0], crit_util_val]
    if util >= warn_util[1]:
        state = "CRIT"
    elif util >= warn_util[0]:
        state = "WARN" if state == "OK" else state
    details.append("Utilisation: %f%%" % util)

    details.append("%d %s corresponding to 100%%" % (num_cpus, unit))
    msg = "; ".join(details)
    metrics = {
        "user": user,
        "system": system,
        "wait": wait,
        "util": util,
        "cpu_entitlement": num_cpus,
    }

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": metrics, "details": ""}
    }


def _read_cpu_info(ctx):
    # Read /proc/stat for CPU times
    stat_content = ctx.file_read("/proc/stat")
    lines = stat_content.split("\n")
    cpu_line = ""
    for line in lines:
        if line.startswith("cpu "):
            cpu_line = line
            break

    # Read number of CPUs from /proc/cpuinfo
    num_cpus = 1
    cpuinfo = ctx.file_read("/proc/cpuinfo")
    if cpuinfo != "":
        processors = 0
        for line in cpuinfo.split("\n"):
            if line.strip().startswith("processor"):
                processors += 1
        if processors > 0:
            num_cpus = processors

    if cpu_line != "":
        return {"cpu_line": cpu_line, "num_cpus": num_cpus}
    return None
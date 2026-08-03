# checkmk.cpu_utilization_os -> read-only Starlark check module for the yolo-man agent
# Reads /proc/stat directly (the real on-host source the Checkmk agent plugin reads),
# computes CPU utilization rate over a sample interval, and grades it.

CPU_STATE_OK = "OK"
CPU_STATE_WARN = "WARN"
CPU_STATE_CRIT = "CRIT"
CPU_STATE_UNKNOWN = "UNKNOWN"

DEFAULT_WARN = 80.0
DEFAULT_CRIT = 90.0


def _sum_list(items):
    total = 0
    for x in items:
        total = total + x
    return total


def _read_cpu_times(ctx):
    """Read current CPU jiffies from /proc/stat. Returns (total, idle) or None on failure."""
    res = ctx.run(["cat", "/proc/stat"], mutates=False)
    if res.rc != 0:
        return None
    first = res.stdout.splitlines()[0] if res.stdout else ""
    parts = first.split()
    if len(parts) < 2 or parts[0] != "cpu":
        return None
    nums = []
    for p in parts[1:]:
        if not p.isdigit():
            return None
        nums.append(int(p))
    total = _sum_list(nums)
    idle = nums[3]
    if len(nums) >= 5:
        idle = idle + nums[4]
    return (total, idle)


def _grade_util(util, params):
    warn = params.get("warn", DEFAULT_WARN)
    crit = params.get("crit", DEFAULT_CRIT)
    if util >= crit:
        return CPU_STATE_CRIT
    if util >= warn:
        return CPU_STATE_WARN
    return CPU_STATE_OK


def main(ctx, params):
    if params.get("_discover"):
        if not ctx.file_exists("/proc/stat"):
            return {"changed": False, "msg": "CPU not measured here (no /proc/stat)",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered CPU utilization",
                "data": {"discovery": [
                    {"item": "",
                     "params": {"warn": DEFAULT_WARN, "crit": DEFAULT_CRIT},
                     "metrics": ["util"]}]}}

    if not ctx.file_exists("/proc/stat"):
        return {"changed": False, "msg": "no /proc/stat (not Linux?)",
                "data": {"state": CPU_STATE_UNKNOWN, "metrics": {}, "details": ""}}

    a = _read_cpu_times(ctx)
    if a == None:
        return {"changed": False, "msg": "failed to read /proc/stat (initial)",
                "data": {"state": CPU_STATE_UNKNOWN, "metrics": {}, "details": ""}}

    ctx.run(["sleep", "1"], mutates=False)

    b = _read_cpu_times(ctx)
    if b == None:
        return {"changed": False, "msg": "failed to read /proc/stat (sample)",
                "data": {"state": CPU_STATE_UNKNOWN, "metrics": {}, "details": ""}}

    total_a, idle_a = a
    total_b, idle_b = b
    total_d = total_b - total_a
    idle_d = idle_b - idle_a
    if total_d <= 0:
        return {"changed": False, "msg": "CPU sampling window too small",
                "data": {"state": CPU_STATE_UNKNOWN, "metrics": {}, "details": ""}}

    util = (total_d - idle_d) * 100.0 / total_d
    state = _grade_util(util, params)
    warn = params.get("warn", DEFAULT_WARN)
    crit = params.get("crit", DEFAULT_CRIT)
    return {"changed": False,
            "msg": "CPU utilization %f%% (warn %f%%, crit %f%%)" % (util, warn, crit),
            "data": {"state": state, "metrics": {"util": util}, "details": ""}}
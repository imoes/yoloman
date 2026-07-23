def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [
                {"item": "", "params": {}, "metrics": []},
            ]},
        }

    host = params.get("host", "localhost")
    rack = params.get("rack", 0)
    slot = params.get("slot", 2)

    script = (
        "import snap7; c=snap7.client.Client(); c.connect('{}',{},{}); ".format(host, rack, slot) +
        "s=c.get_cpu_state(); c.disconnect(); " +
        "print('S7CpuStatusRun' if int(s)==8 else ('S7CpuStatusStop' if int(s)==4 else 'S7CpuStatusUnknown'))"
    )

    res = ctx.run(["python3", "-c", script], mutates=False)

    if res.rc != 0:
        detail = res.stderr.strip()
        return {
            "changed": False,
            "msg": "cannot connect to PLC: " + detail,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": detail},
        }

    state_str = res.stdout.strip()

    if state_str == "S7CpuStatusRun":
        return {
            "changed": False,
            "msg": "CPU is running",
            "data": {"state": "OK", "metrics": {}, "details": ""},
        }
    if state_str == "S7CpuStatusStop":
        return {
            "changed": False,
            "msg": "CPU is stopped",
            "data": {"state": "CRIT", "metrics": {}, "details": ""},
        }
    return {
        "changed": False,
        "msg": "CPU is in unknown state: " + state_str,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": state_str},
    }
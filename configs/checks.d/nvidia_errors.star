def _parse_nvidia_output(stdout):
    lines = []
    for raw in stdout.splitlines():
        s = raw.strip()
        if not s:
            continue
        parts = s.split(None, 1)
        lines.append(parts)
    return lines


def _find_line(lines, key):
    for parts in lines:
        if len(parts) >= 1 and parts[0] == key:
            return parts
    return None


def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["nvidia-smi", "-q", "-d", "ERROR", "--id=0"], mutates=False)
        if res.rc == 127:
            return {"changed": False, "msg": "nvidia-smi not installed", "data": {"discovery": [], "host_labels": {}}}
        if res.rc != 0:
            return {"changed": False, "msg": "nvidia-smi query failed", "data": {"discovery": [], "host_labels": {}}}
        lines = _parse_nvidia_output(res.stdout)
        gpu_errors_line = None
        for parts in lines:
            if len(parts) >= 1 and parts[0] == "GPUErrors:":
                gpu_errors_line = parts
                break
        if gpu_errors_line == None:
            return {"changed": False, "msg": "no NVIDIA GPU found", "data": {"discovery": [], "host_labels": {}}}
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {},
                        "metrics": ["gpu_errors"],
                    }
                ],
                "host_labels": {},
            },
        }

    res = ctx.run(["nvidia-smi", "-q", "-d", "ERROR", "--id=0"], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "nvidia-smi not installed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.rc != 0:
        return {"changed": False, "msg": "nvidia-smi query failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    lines = _parse_nvidia_output(res.stdout)
    gpu_errors_line = _find_line(lines, "GPUErrors:")
    if gpu_errors_line == None:
        return {"changed": False, "msg": "no GPU error data available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    raw_val = gpu_errors_line[1] if len(gpu_errors_line) > 1 else "0"
    if not raw_val.isdigit():
        return {"changed": False, "msg": "invalid GPU error count: %s" % raw_val, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    errors = int(raw_val)
    if errors == 0:
        state = "OK"
        msg = "No GPU errors"
    else:
        state = "CRIT"
        msg = "%d GPU errors" % errors
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"gpu_errors": errors},
            "details": "",
        },
    }
# checkmk.nvidia_smi_gpu_util — GPU utilization %s
# READ-ONLY Starlark check module translating Checkmk's nvidia_smi_gpu_util.
# Source: nvidia-smi -q -d UTILIZATION -x (XML), no shell pipes, no Checkmk binaries.

def main(ctx, params):
    if params.get("_discover"):
        # Discovery: run nvidia-smi to enumerate GPUs with gpu_util present.
        res = ctx.run([
            "nvidia-smi", "--query-gpu=index", "--format=csv,noheader",
        ], mutates=False)
        if res.rc == 127:
            # Not installed -> not applicable here. Do NOT substitute /proc.
            return {"changed": False, "msg": "nvidia-smi not installed",
                    "data": {"discovery": []}}
        if res.rc != 0:
            return {"changed": False, "msg": "nvidia-smi not installed",
                    "data": {"discovery": []}}
        out = []
        for line in res.stdout.splitlines():
            idx = line.strip()
            if idx == "" or not idx.isdigit():
                continue
            out.append({"item": idx, "params": {"levels": None},
                        "metrics": ["gpu_utilization"]})
        return {"changed": False, "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    # Read per-GPU utilization percentage directly from nvidia-smi.
    res = ctx.run([
        "nvidia-smi", "--query-gpu=" + item + ":index,utilization.gpu",
        "--format=csv,noheader,nounits",
    ], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "nvidia-smi not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.rc != 0:
        return {"changed": False, "msg": "nvidia-smi not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    lines = res.stdout.splitlines()
    if not lines:
        return {"changed": False, "msg": "no data for gpu " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    parts = lines[0].strip().split(",")
    if len(parts) < 2:
        return {"changed": False, "msg": "no data for gpu " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    util_str = parts[1].strip()
    # util may be "N/A" if GPU is in an unusable state.
    if util_str == "N/A":
        return {"changed": False, "msg": "gpu %s unavailable" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not util_str.isdigit():
        return {"changed": False, "msg": "gpu %s unusable" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    util = int(util_str)

    levels = params.get("levels")
    warn = 0
    crit = 0
    if levels != None:
        warn = levels[0]
        crit = levels[1]

    state = "OK"
    if crit != 0 and util >= crit:
        state = "CRIT"
    elif warn != 0 and util >= warn:
        state = "WARN"

    return {"changed": False, "msg": "Gpu %s Util: %d" % (item, util),
            "data": {"state": state, "metrics": {"gpu_utilization": util},
                     "details": ""}}
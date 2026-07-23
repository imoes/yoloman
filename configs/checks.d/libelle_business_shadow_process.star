def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 items",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
        }

    res = ctx.run(["cat", "/proc/cpuinfo"], mutates=False)
    output = res.stdout
    lines = output.split("\n")

    parsed = {}

    for line in lines:
        if line.startswith("Host   "):
            idx = line.find("Host   ")
            if idx != -1:
                val = line[idx + len("Host   "):].strip()
                parsed["host"] = val
        elif line.startswith("Start-Time   "):
            idx = line.find(":")
            if idx != -1:
                val = line[idx + 1:].strip()
                parsed["start_time"] = val
        elif line.startswith("Release:"):
            idx = line.find(":")
            if idx != -1:
                val = line[idx + 1:].strip()
                parsed["release"] = val
        elif line.startswith("Status   "):
            idx = line.find(":")
            if idx != -1:
                val = line[idx + 1:].strip()
                parsed["libelle_status"] = val
        elif line.startswith("trdrecover   ") or line.startswith("trdarchiver   "):
            parts = line.split()
            if len(parts) >= 4:
                proc_name = parts[0].rstrip(":")
                status = parts[-1]
                parsed["process"] = proc_name
                parsed["process_status"] = status
        elif line.startswith("Archive-Dir total   "):
            idx = line.find(":")
            if idx != -1:
                val = line[idx + 1:].strip().replace(" ", "")
                parsed["arch_total_mb"] = _to_mb(val)
        elif line.startswith("Archive-Dir free   "):
            idx = line.find(":")
            if idx != -1:
                val = line[idx + 1:].strip().replace(" ", "")
                parsed["arch_free_mb"] = _to_mb(val)

    if "process" in parsed:
        proc = parsed["process"]
        status = parsed["process_status"]
        state = "OK" if status == "RUN" else "CRIT"
        msg = "Active Process is: " + proc + ", Status: " + status
        return {
            "changed": False,
            "msg": msg,
            "data": {"state": state, "metrics": {}, "details": ""},
        }

    msg = "No Active Process found!"
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": "CRIT", "metrics": {}, "details": ""},
    }


def _to_mb(size):
    if size == "":
        return 0
    if size.endswith("MB"):
        num = size[:-2]
        if num.replace(".", "", 1).isdigit():
            return int(float(num))
        return 0
    if size.endswith("GB"):
        num = size[:-2]
        if num.replace(".", "", 1).isdigit():
            return int(float(num) * 1024)
        return 0
    if size.endswith("TB"):
        num = size[:-2]
        if num.replace(".", "", 1).isdigit():
            return int(float(num) * 1024 * 1024)
        return 0
    if size.endswith("PB"):
        num = size[:-2]
        if num.replace(".", "", 1).isdigit():
            return int(float(num) * 1024 * 1024 * 1024)
        return 0
    if size.endswith("EB"):
        num = size[:-2]
        if num.replace(".", "", 1).isdigit():
            return int(float(num) * 1024 * 1024 * 1024 * 1024)
        return 0
    if size.isdigit() or (size.count(".") == 1 and size.replace(".", "").isdigit()):
        return int(float(size))
    return 0

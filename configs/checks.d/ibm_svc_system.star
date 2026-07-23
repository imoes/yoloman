WANTED_KEYS = ["name", "location", "code_level", "email_contact_location"]

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
    user = params.get("user", "monitor")
    ssh_key = params.get("ssh_key", "")

    cmd = ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "BatchMode=yes",
           "-o", "ConnectTimeout=10"]
    if ssh_key != "":
        cmd = cmd + ["-i", ssh_key]
    cmd = cmd + [user + "@" + host, "lssystem -delim :"]

    res = ctx.run(cmd, mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SSH/lssystem failed: " + res.stderr.strip(),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stderr.strip()},
        }

    data = {}
    for raw in res.stdout.splitlines():
        line = raw.strip()
        if line == "":
            continue
        idx = line.find(":")
        if idx < 1:
            continue
        key = line[:idx].strip()
        val = line[idx + 1:].strip()
        if key not in data:
            data[key] = val

    parts = []
    for key in WANTED_KEYS:
        val = data.get(key, "")
        if val != "":
            parts.append(key + ": " + val)

    msg = ", ".join(parts) if len(parts) > 0 else "no data retrieved"

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": "OK", "metrics": {}, "details": ""},
    }
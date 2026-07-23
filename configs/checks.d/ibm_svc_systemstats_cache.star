def main(ctx, params):
    host = params.get("host", "localhost")
    user = params.get("user", "admin")

    ssh_args = ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "BatchMode=yes"]
    key = params.get("ssh_key", "")
    if key != "":
        ssh_args = ssh_args + ["-i", key]
    ssh_args = ssh_args + [user + "@" + host, "lssystemstats"]

    res = ctx.run(ssh_args, mutates=False)

    total_cache_pc = None
    write_cache_pc = None

    if res.rc == 0:
        for line in res.stdout.splitlines():
            parts = line.split()
            if len(parts) < 2:
                continue
            stat_name = parts[0]
            stat_current = parts[1]
            if not stat_current.isdigit():
                continue
            if stat_name == "total_cache_pc":
                total_cache_pc = int(stat_current)
            elif stat_name == "write_cache_pc":
                write_cache_pc = int(stat_current)

    if params.get("_discover"):
        discovery = []
        if total_cache_pc != None:
            discovery.append({
                "item": "",
                "params": {},
                "metrics": ["write_cache_pc", "total_cache_pc"],
            })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "lssystemstats failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if total_cache_pc == None:
        return {
            "changed": False,
            "msg": "value total_cache_pc not found in agent output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    if write_cache_pc == None:
        return {
            "changed": False,
            "msg": "value write_cache_pc not found in agent output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    msg = "Write cache usage is %d %%, total cache usage is %d %%" % (write_cache_pc, total_cache_pc)
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": "OK",
            "metrics": {
                "write_cache_pc": write_cache_pc,
                "total_cache_pc": total_cache_pc,
            },
            "details": "",
        },
    }
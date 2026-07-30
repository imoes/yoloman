def _parse_instances(ps_output):
    instances = {}
    for line in ps_output.splitlines():
        parts = line.split()
        if len(parts) < 4:
            continue
        pid_str = parts[0]
        if not pid_str.isdigit():
            continue
        binary_name = parts[1].split("/")[-1]
        if binary_name != "postgres":
            continue
        datadir = None
        for i in range(2, len(parts) - 1):
            if parts[i] == "-D":
                datadir = parts[i + 1]
                break
        if datadir == None:
            continue
        name = datadir.rstrip("/").split("/")[-1].upper()
        if name == "":
            continue
        instances[name] = int(pid_str)
    return instances


def main(ctx, params):
    ps_res = ctx.run(["ps", "ax", "-o", "pid,args"], mutates=False)
    instances = _parse_instances(ps_res.stdout)

    if params.get("_discover"):
        discovery = [
            {"item": name, "params": {}, "metrics": ["pid"]}
            for name in instances
        ]
        return {
            "changed": False,
            "msg": "discovered %d instances" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    pid = instances.get(item)

    version_str = ""
    ver_res = ctx.run(["psql", "--version"], mutates=False, ok_codes=[0, 127])
    if ver_res.rc == 0:
        ver_lines = ver_res.stdout.strip().splitlines()
        if len(ver_lines) > 0:
            version_str = ver_lines[0]

    if pid != None:
        details = ("Version: " + version_str) if version_str != "" else "Version: not found"
        return {
            "changed": False,
            "msg": "Status: running with PID %d" % pid,
            "data": {
                "state": "OK",
                "metrics": {"pid": pid},
                "details": details,
            },
        }

    if len(instances) == 0:
        return {
            "changed": False,
            "msg": "no postgres instance found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    return {
        "changed": False,
        "msg": "Status: instance %s is not running or postgres DATADIR name is not identical with instance name" % item,
        "data": {"state": "CRIT", "metrics": {}, "details": ""},
    }
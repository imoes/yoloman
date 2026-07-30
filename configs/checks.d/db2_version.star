def _get_instances(ctx):
    for cmd in ["db2ilist", "/usr/local/bin/db2ilist"]:
        res = ctx.run([cmd], mutates=False, ok_codes=[0, 1, 2, 127])
        if res.rc == 127:
            continue
        lines = [l.strip() for l in res.stdout.splitlines() if l.strip()]
        return lines, True
    return [], False

def _parse_db2level(output):
    for line in output.splitlines():
        if "Informational tokens" in line:
            parts = line.split('"')
            tokens = []
            for i in range(1, len(parts), 2):
                tokens.append(parts[i])
            if len(tokens) == 0:
                return ""
            ver = tokens[0].replace(" ", "")
            if len(tokens) >= 3:
                return ver + "," + tokens[1] + "(" + tokens[2] + ")"
            return ver
    return ""

def main(ctx, params):
    instances, db2_installed = _get_instances(ctx)

    if params.get("_discover"):
        if not db2_installed:
            return {
                "changed": False,
                "msg": "discovered 0 instances",
                "data": {"discovery": []},
            }
        items = [{"item": inst, "params": {}, "metrics": []} for inst in instances]
        return {
            "changed": False,
            "msg": "discovered %d instances" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")

    if not db2_installed:
        return {
            "changed": False,
            "msg": "DB2 not installed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if item not in instances:
        return {
            "changed": False,
            "msg": "Instance is down",
            "data": {"state": "CRIT", "metrics": {}, "details": ""},
        }

    level_res = ctx.run(
        ["su", "-l", item, "-c", "db2level"],
        mutates=False,
        ok_codes=[0, 1, 2, 127],
    )
    version = _parse_db2level(level_res.stdout)

    if version == "":
        return {
            "changed": False,
            "msg": "No instance information found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    return {
        "changed": False,
        "msg": version,
        "data": {"state": "OK", "metrics": {}, "details": ""},
    }
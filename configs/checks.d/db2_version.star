def _parse_db2level(stdout):
    for line in stdout.splitlines():
        if "Informational tokens" in line:
            parts = line.split('"')
            ver = ""
            build = ""
            ip = ""
            for i in range(1, len(parts), 2):
                tok = parts[i]
                if tok.startswith("DB2 v") or tok.startswith("DB2 V"):
                    ver = "DB2v" + tok[5:]
                elif tok.startswith("s") and len(tok) >= 5 and len(tok) <= 10:
                    build = tok
                elif (tok.startswith("IP") or tok.startswith("IT")) and len(tok) >= 4:
                    ip = tok
            if not ver:
                return None
            result = ver
            if build:
                result = result + "," + build
            if ip:
                result = result + "(" + ip + ")"
            return result
    return None


def _get_instance_homes(ctx):
    homes = {}
    if not ctx.file_exists("/etc/passwd"):
        return homes
    content = ctx.file_read("/etc/passwd")
    for line in content.splitlines():
        parts = line.split(":")
        if len(parts) >= 6:
            username = parts[0]
            homedir = parts[5]
            if ctx.file_exists(homedir + "/sqllib/db2profile"):
                homes[username] = homedir
    return homes


def main(ctx, params):
    if params.get("_discover"):
        homes = _get_instance_homes(ctx)
        discovery = [{"item": inst, "params": {}, "metrics": []} for inst in homes]
        return {
            "changed": False,
            "msg": "discovered %d DB2 instances" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    homes = _get_instance_homes(ctx)

    if item not in homes:
        return {
            "changed": False,
            "msg": "Instance is down",
            "data": {"state": "CRIT", "metrics": {}, "details": "instance user not found in passwd"},
        }

    home = homes[item]
    db2level = home + "/sqllib/bin/db2level"

    if not ctx.file_exists(db2level):
        return {
            "changed": False,
            "msg": "No instance information found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "db2level not found at " + db2level},
        }

    res = ctx.run(["su", "-", item, "-c", db2level], mutates=False, ok_codes=[0, 1, 2])

    if not res.stdout.strip():
        return {
            "changed": False,
            "msg": "Instance is down",
            "data": {"state": "CRIT", "metrics": {}, "details": res.stderr[:200]},
        }

    version = _parse_db2level(res.stdout)

    if version == None:
        return {
            "changed": False,
            "msg": "No instance information found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stdout[:200]},
        }

    return {
        "changed": False,
        "msg": version,
        "data": {"state": "OK", "metrics": {}, "details": ""},
    }
KNOWN_SOCKET_PATHS = [
    "/var/run/mysqld/mysqld.sock",
    "/tmp/mysql.sock",
    "/var/lib/mysql/mysql.sock",
]

MYSQLADMIN_PATHS = [
    "/usr/bin/mysqladmin",
    "/usr/local/bin/mysqladmin",
    "/usr/local/mysql/bin/mysqladmin",
]

def _find_mysqladmin(ctx):
    for p in MYSQLADMIN_PATHS:
        if ctx.file_exists(p):
            return p
    return ""

def _build_ping_cmd(binary, host, port, socket_path, user, password, defaults_file):
    cmd = [binary]
    if defaults_file != "":
        cmd = [binary, "--defaults-extra-file=" + defaults_file]
    if host != "":
        cmd += ["-h", host]
    if port != 0:
        cmd += ["-P", str(port)]
    if socket_path != "":
        cmd += ["-S", socket_path]
    if user != "":
        cmd += ["-u", user]
    if password != "":
        cmd += ["--password=" + password]
    cmd.append("ping")
    return cmd

def main(ctx, params):
    binary = _find_mysqladmin(ctx)

    if params.get("_discover"):
        if binary == "":
            return {
                "changed": False,
                "msg": "discovered 0 MySQL instances (mysqladmin not found)",
                "data": {"discovery": []},
            }

        found = [{"item": "mysql", "params": {}, "metrics": []}]
        seen = {"mysql": True}

        for sock in KNOWN_SOCKET_PATHS:
            if ctx.file_exists(sock):
                parts = sock.split("/")
                label = parts[-1].replace(".sock", "")
                if label == "mysqld":
                    label = "mysql"
                if not seen.get(label):
                    seen[label] = True
                    found.append({
                        "item": label,
                        "params": {"socket": sock},
                        "metrics": [],
                    })

        return {
            "changed": False,
            "msg": "discovered %d MySQL instances" % len(found),
            "data": {"discovery": found},
        }

    if binary == "":
        return {
            "changed": False,
            "msg": "mysqladmin not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "mysqladmin binary not found"},
        }

    item = params.get("item", "mysql")
    host = params.get("host", "")
    port = params.get("port", 0)
    socket_path = params.get("socket", "")
    user = params.get("user", "")
    password = params.get("password", "")
    defaults_file = params.get("defaults_extra_file", "")

    cmd = _build_ping_cmd(binary, host, port, socket_path, user, password, defaults_file)
    res = ctx.run(cmd, mutates=False, ok_codes=[0, 1])

    output = res.stdout.strip()
    if output == "mysqld is alive":
        return {
            "changed": False,
            "msg": "MySQL Daemon is alive",
            "data": {"state": "OK", "metrics": {}, "details": ""},
        }

    err = output if output != "" else res.stderr.strip()
    if err == "":
        err = "mysqladmin ping failed (rc=%d)" % res.rc

    return {
        "changed": False,
        "msg": err,
        "data": {"state": "CRIT", "metrics": {}, "details": ""},
    }
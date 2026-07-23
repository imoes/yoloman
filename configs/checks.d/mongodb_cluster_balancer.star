def _build_argv(host, port, username, password, authdb, js_expr):
    argv = ["mongosh", "--host", host, "--port", str(port),
            "--quiet", "--norc", "--eval", js_expr]
    if username != "":
        argv = argv + ["--username", username, "--password", password,
                       "--authenticationDatabase", authdb]
    return argv

def _parse_bool_line(stdout):
    for line in stdout.splitlines():
        s = line.strip().lower()
        if s == "true":
            return "true"
        if s == "false":
            return "false"
    return ""

def main(ctx, params):
    host     = params.get("host", "localhost")
    port     = params.get("port", 27017)
    username = params.get("username", "")
    password = params.get("password", "")
    authdb   = params.get("authdb", "admin")

    # sh.getBalancerState() returns true/false only on a mongos router;
    # a plain mongod returns an error, so rc != 0 -> empty discovery.
    probe = _build_argv(host, port, username, password, authdb,
                        "print(sh.getBalancerState())")

    if params.get("_discover"):
        res = ctx.run(probe, mutates=False, ok_codes=[0, 1])
        val = _parse_bool_line(res.stdout)
        if res.rc == 0 and val != "":
            return {
                "changed": False,
                "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": []},
                ]},
            }
        return {"changed": False, "msg": "no MongoDB balancer found",
                "data": {"discovery": []}}

    res = ctx.run(probe, mutates=False, ok_codes=[0, 1])
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "MongoDB connection failed",
            "data": {"state": "UNKNOWN", "metrics": {},
                     "details": res.stderr.strip()},
        }

    val = _parse_bool_line(res.stdout)
    if val == "true":
        return {"changed": False, "msg": "Balancer: enabled",
                "data": {"state": "OK", "metrics": {}, "details": ""}}
    if val == "false":
        return {"changed": False, "msg": "Balancer: disabled",
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}

    return {
        "changed": False,
        "msg": "unexpected output: " + res.stdout.strip(),
        "data": {"state": "UNKNOWN", "metrics": {},
                 "details": res.stdout.strip()},
    }
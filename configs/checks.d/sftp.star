def main(ctx, params):
    if params.get("_discover"):
        return {"changed": False, "msg": "active check (assign with parameters)", "data": {"discovery": []}}

    host = params.get("host") or ""
    user = params.get("user") or ""
    password = params.get("password") or ""
    port = int(params.get("port") or 22)
    timeout_s = int(params.get("timeout_s") or 10)
    put_local = params.get("put_local") or ""
    put_remote = params.get("put_remote") or ""
    get_remote = params.get("get_remote") or ""
    get_local = params.get("get_local") or ""
    timestamp = params.get("timestamp") or ""
    look_for_keys = params.get("look_for_keys") or False

    cmds = []
    if put_local != "" and put_remote != "":
        cmds.append("put " + put_local + " " + put_remote)
    if get_remote != "" and get_local != "":
        cmds.append("get " + get_remote + " " + get_local)
    if timestamp != "":
        cmds.append("ls -la " + timestamp)
    cmds.append("quit")
    batch = "\n".join(cmds)

    batch_safe = batch.replace("'", "'\\''")
    pass_safe = password.replace("'", "'\\''")

    id_opts = ""
    if not look_for_keys:
        id_opts = " -o IdentitiesOnly=yes -o PubkeyAuthentication=no"

    shell = (
        "echo '" + batch_safe + "' | " +
        "sshpass -p '" + pass_safe + "' " +
        "sftp" +
        " -P " + str(port) +
        " -o StrictHostKeyChecking=no" +
        " -o ConnectTimeout=" + str(timeout_s) +
        id_opts +
        " -b /dev/stdin" +
        " '" + user + "@" + host + "'"
    )

    r = ctx.run(["bash", "-c", shell])

    state = "OK"
    problems = []
    info = ["SFTP " + host + ":" + str(port)]

    if r.rc != 0:
        state = "CRIT"
        stderr = (r.stderr or "").strip()
        if stderr != "":
            problems.append(stderr[:200])
        else:
            problems.append("exit code %d" % r.rc)
    else:
        if put_local != "":
            info.append("put OK")
        if get_remote != "":
            info.append("get OK")
        if timestamp != "":
            stdout = r.stdout or ""
            fname = timestamp.split("/")[-1]
            for line in stdout.splitlines():
                if fname in line:
                    fields = line.split()
                    if len(fields) >= 8:
                        ts = fields[5] + " " + fields[6] + " " + fields[7]
                        info.append("mtime: " + ts)
                    break

    detail = "; ".join(info)
    if len(problems) > 0:
        detail = detail + " | " + "; ".join(problems)

    return {
        "changed": False,
        "msg": state,
        "data": {
            "state": state,
            "metrics": {},
            "details": detail,
        },
    }
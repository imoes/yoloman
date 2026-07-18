def main(ctx, params):
    if params.get("_discover"):
        return {"changed": False, "msg": "active check (assign with parameters)", "data": {"discovery": []}}

    host = params.get("host") or ""
    if not host:
        return {"changed": False, "msg": "UNKNOWN", "data": {"state": "UNKNOWN", "metrics": {}, "details": "No host configured"}}

    args = ["check_icmp"]

    min_pings = params.get("min_pings_ok")
    if min_pings != None and int(min_pings) > 0:
        args += ["-m", str(int(min_pings))]

    timeout_s = params.get("timeout_s")
    if timeout_s != None:
        args += ["-t", str(int(timeout_s))]

    packets = params.get("packets")
    if packets != None:
        args += ["-n", str(int(packets))]

    rta_warn = params.get("rta_warn_ms") or 200
    loss_warn = params.get("loss_warn_pct") or 80
    rta_crit = params.get("rta_crit_ms") or 500
    loss_crit = params.get("loss_crit_pct") or 100

    args += ["-w", "%d,%d%%" % (int(rta_warn), int(loss_warn))]
    args += ["-c", "%d,%d%%" % (int(rta_crit), int(loss_crit))]

    if params.get("ipv6"):
        args.append("-6")

    args.append(host)

    result = ctx.run(args, ok_codes=[0, 1, 2, 3])

    stdout = (result.stdout or "").strip()
    rc = result.rc
    if rc == None:
        rc = 3

    if rc == 0:
        state = "OK"
    elif rc == 1:
        state = "WARN"
    elif rc == 2:
        state = "CRIT"
    else:
        state = "UNKNOWN"

    detail = stdout
    metrics = {}

    if "|" in stdout:
        parts = stdout.split("|")
        detail = parts[0].strip()
        for item in parts[1].split():
            if "=" not in item:
                continue
            kv = item.split("=")
            key = kv[0]
            val_str = kv[1]
            num = ""
            for i in range(len(val_str)):
                c = val_str[i]
                if (c >= "0" and c <= "9") or c == ".":
                    num = num + c
                else:
                    break
            if num and num != ".":
                metrics[key] = float(num)

    if not detail:
        detail = "check_icmp exit %d" % rc

    return {"changed": False, "msg": state, "data": {"state": state, "metrics": metrics, "details": detail}}

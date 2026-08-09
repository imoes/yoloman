def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {
                            "hostname": params.get("hostname", ""),
                            "name": params.get("name"),
                            "server": params.get("server"),
                            "expect_all_addresses": params.get("expect_all_addresses", True),
                            "expected_addresses": params.get("expected_addresses", []),
                            "expected_authority": params.get("expected_authority"),
                            "response_time": params.get("response_time", [5.0, 10.0]),
                            "timeout": params.get("timeout", 30),
                        },
                        "metrics": ["response_time"],
                    }
                ]
            },
        }

    hostname = params.get("hostname", "")
    server = params.get("server")
    expect_all = params.get("expect_all_addresses", True)
    expected_addresses = params.get("expected_addresses", []) or []
    expected_authority = params.get("expected_authority")
    response_time = params.get("response_time", [5.0, 10.0]) or [5.0, 10.0]
    timeout = params.get("timeout", 30)

    args = ["-H", hostname]

    if server == None:
        args += ["-s", "127.0.0.1"]
    elif server and server != "default DNS server":
        args += ["-s", server]

    if expect_all:
        args.append("-L")

    for address in expected_addresses:
        args += ["-a", address]

    if expected_authority:
        args.append("-A")

    warn, crit = response_time[0], response_time[1]
    args += ["-w", "%f" % warn]
    args += ["-c", "%f" % crit]

    if timeout:
        args += ["-t", str(timeout)]

    res = ctx.run(["check_dns"] + args, mutates=False)

    if res.rc == 127:
        return {
            "changed": False,
            "msg": "check_dns command not found on this host",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    stdout = res.stdout.strip()
    stderr = res.stderr.strip()

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "DNS check failed: " + stderr,
            "data": {"state": "CRIT", "metrics": {}, "details": stdout},
        }

    state = "OK"
    metrics = {}

    for line in stdout.splitlines():
        ll = line.lower()
        if ll.startswith("response time") or "response time" in ll:
            parts = line.split("=")
            if len(parts) >= 2:
                val_str = parts[-1].strip().split()[0]
                if val_str.isdigit():
                    val = float(val_str)
                    metrics["response_time"] = val
                    if val >= crit:
                        state = "CRIT"
                    elif val >= warn:
                        state = "WARN"
            break

    if not metrics:
        for line in stdout.splitlines():
            parts = line.split("=")
            if len(parts) >= 2:
                val_str = parts[-1].strip().split()[0]
                if val_str.replace(".", "", 1).isdigit():
                    val = float(val_str)
                    metrics["response_time"] = val
                    if val >= crit:
                        state = "CRIT"
                    elif val >= warn:
                        state = "WARN"

    return {
        "changed": False,
        "msg": "DNS " + hostname + " " + state,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": stdout,
        },
    }
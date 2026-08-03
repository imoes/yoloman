def main(ctx, params):
    # Discovery mode: probe for check_tcp binary
    if params.get("_discover"):
        probe = ctx.run(["which", "check_tcp"], mutates=False)
        if probe.rc != 0:
            return {"changed": False, "msg": "check_tcp not installed", "data": {"discovery": []}}
        
        port = params.get("port", 80)
        return {
            "changed": False,
            "msg": "discovered TCP port check",
            "data": {
                "discovery": [
                    {
                        "item": str(port),
                        "params": {
                            "port": port,
                            "warn": 1.0,
                            "crit": 2.0,
                        },
                        "metrics": ["response_time"],
                    }
                ]
            },
        }
    
    # Check mode: run check_tcp and parse result
    port = int(params.get("item", params.get("port", 80)))
    host = params.get("host", "localhost")
    warn_default = params.get("warn", 1.0)
    crit_default = params.get("crit", 2.0)
    
    # Verify check_tcp is available
    probe = ctx.run(["which", "check_tcp"], mutates=False)
    if probe.rc != 0:
        return {
            "changed": False,
            "msg": "check_tcp not installed on this host",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Build check_tcp arguments
    args = ["-p", str(port), "-H", host]
    
    timeout = params.get("timeout")
    if timeout != None:
        args = args + ["-t", str(int(timeout))]
    
    warn = params.get("warn")
    crit = params.get("crit")
    if warn != None and crit != None:
        args = args + ["-w", str(warn), "-c", str(crit)]
    elif warn != None:
        args = args + ["-w", str(warn)]
    elif crit != None:
        args = args + ["-c", str(crit)]
    
    expect = params.get("expect", [])
    if expect != None:
        for e in expect:
            args = args + ["-e", e]
    
    send_string = params.get("send_string")
    if send_string != None:
        args = args + ["-s", send_string]
    
    quit_string = params.get("quit_string")
    if quit_string != None:
        args = args + ["-q", quit_string]
    
    # Run check_tcp
    res = ctx.run(["check_tcp"] + args, mutates=False)
    
    # Parse output: check_tcp format is "PORT STATUS - message | perfdata"
    stdout = res.stdout
    stderr = res.stderr
    output = stdout
    if not output or output.strip() == "":
        output = stderr
    
    # check_tcp exit codes: 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN
    if res.rc == 0:
        state = "OK"
    elif res.rc == 1:
        state = "WARN"
    elif res.rc == 2:
        state = "CRIT"
    else:
        state = "UNKNOWN"
    
    # Parse response time from perfdata if available
    response_time = 0.0
    metrics = {}
    details = output.strip()
    
    # Try to extract perfdata from the output
    if "|" in details:
        parts = details.split("|")
        if len(parts) >= 2:
            perfdata = parts[-1].strip()
            # Check for response_time in perfdata
            tokens = perfdata.split()
            for t in tokens:
                if t.startswith("rta=") or t.startswith("response_time="):
                    val_part = t.split("=")[1] if "=" in t else ""
                    # Take the numeric part before any unit
                    val_str = ""
                    for ch in val_part:
                        if ch.isdigit() or ch == ".":
                            val_str = val_str + ch
                        elif val_str != "":
                            break
                    if val_str != "" and val_str != ".":
                        response_time = float(val_str)
                        metrics["response_time"] = response_time
                        break
    
    # Apply threshold logic if we have warn/crit levels for response_time
    if response_time > 0 and (warn != None or crit != None):
        w = warn if warn != None else warn_default
        c = crit if crit != None else crit_default
        if response_time >= c:
            state = "CRIT"
        elif response_time >= w:
            state = "WARN"
    
    msg_parts = []
    if "|" in details:
        msg_parts.append(details.split("|")[0].strip())
    else:
        msg_parts.append(details)
    if response_time > 0:
        msg_parts.append("rta=%fs" % response_time)
    
    return {
        "changed": False,
        "msg": " ".join(msg_parts),
        "data": {"state": state, "metrics": metrics, "details": details},
    }
def _render_iobandwidth(bytes_per_sec):
    b = bytes_per_sec
    if b < 1024:
        return "%dB/s" % int(b)
    if b < 1024 * 1024:
        return "%dKB/s" % int(b / 1024)
    if b < 1024 * 1024 * 1024:
        return "%dMB/s" % int(b / (1024 * 1024))
    return "%dGB/s" % int(b / (1024 * 1024 * 1024))

def main(ctx, params):
    if params.get("_discover"):
        # Probe: OpenVPN must be installed and the real client-status log must exist.
        version = ctx.run(["openvpn", "--version"], mutates=False)
        if version.rc == 127:
            return {"changed": False, "msg": "OpenVPN not installed",
                    "data": {"discovery": []}}
        # The agent plugin reads an external status file written by the OpenVPN
        # server's --status / --client-connect logic. Check for the conventional paths.
        paths = []
        for p in ["/etc/openvpn/client-status.log",
                  "/var/log/openvpn/client-status.log",
                  "/tmp/openvpn-clients.log"]:
            paths.append(p)
            break
        found = False
        status_path = None
        for p in paths:
            if ctx.file_exists(p):
                status_path = p
                found = True
                break
        if not found:
            return {"changed": False, "msg": "no OpenVPN client-status file found",
                    "data": {"discovery": []}}

        content = ctx.file_read(status_path) if status_path else ""
        discovery = []
        seen = set()
        for line in content.splitlines():
            f = line.split(",")
            if len(f) < 5:
                continue
            name = f[0]
            if name in seen:
                continue
            seen.add(name)
            discovery.append({"item": name, "params": {},
                              "metrics": ["in", "out"]})
        return {"changed": False,
                "msg": "discovered %d OpenVPN clients" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    # Re-establish that OpenVPN is present on the host.
    version = ctx.run(["openvpn", "--version"], mutates=False)
    if version.rc == 127:
        return {"changed": False, "msg": "OpenVPN not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    status_path = None
    for p in ["/etc/openvpn/client-status.log",
              "/var/log/openvpn/client-status.log",
              "/tmp/openvpn-clients.log"]:
        if ctx.file_exists(p):
            status_path = p
            break
    if status_path == None:
        return {"changed": False, "msg": "OpenVPN client-status file not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    content = ctx.file_read(status_path)
    now = ctx.now()
    infos = ["Channel is up"]
    metrics = {}
    found = False
    for line in content.splitlines():
        f = line.split(",")
        if len(f) < 5:
            continue
        if f[0] == item:
            inbytes = f[2]
            outbytes = f[3]
            in_val = int(inbytes) if inbytes.isdigit() else 0
            out_val = int(outbytes) if outbytes.isdigit() else 0
            # Compute byte-rate since last sample using the agent's persistent
            # value store, keyed by item+counter.
            store = ctx.value_store()
            prev_in = store.get(item + ":in", None)
            prev_out = store.get(item + ":out", None)
            prev_t = store.get(item + ":time", None)
            if prev_in != None and prev_t != None:
                dt = now - prev_t
                if dt > 0:
                    in_rate = (in_val - prev_in) / dt
                    out_rate = (out_val - prev_out) / dt
                else:
                    in_rate = 0.0
                    out_rate = 0.0
            else:
                in_rate = 0.0
                out_rate = 0.0
            store.set(item + ":in", in_val)
            store.set(item + ":out", out_val)
            store.set(item + ":time", now)
            infos.append("in: %s" % _render_iobandwidth(in_rate))
            infos.append("out: %s" % _render_iobandwidth(out_rate))
            metrics["in"] = in_rate
            metrics["out"] = out_rate
            found = True
            break

    if not found:
        return {"changed": False, "msg": "Client connection not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    return {"changed": False, "msg": ", ".join(infos),
            "data": {"state": "OK", "metrics": metrics, "details": ""}}
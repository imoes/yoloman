def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    return _check(ctx, params)

def _read_fritz_section(ctx):
    # Probe for the real Fritz!Box data source.
    # The AVM Fritz!Box exposes a TR-064 / UPnP HTTP endpoint on the device;
    # we query the WANIPConnection service's status via HTTP (read-only).
    host = params_get("host", "fritz.box")
    port = params_get("port", "49000")
    # Try the AVM TR-064 HTTP info endpoint first.
    res = ctx.run(["curl", "-fsS", "--max-time", "5",
                   "http://%s:%s/" % (host, port)], mutates=False)
    if res.rc != 0 or not res.stdout:
        # rc == 127 or no response means the device/endpoint is not present.
        return None
    # The AVM device XML status page returns HTML; the TR-064 service returns
    # XML key/value pairs. We look for the relevant New* fields in the output.
    return res.stdout

def _parse_fritz(out):
    section = {}
    if not out:
        return section
    keywords = [
        "NewLinkStatus", "NewPhysicalLinkStatus", "NewConnectionStatus",
        "NewExternalIPAddress", "NewLastConnectionError", "NewUptime",
        "NewLayer1DownstreamMaxBitRate", "NewLayer1UpstreamMaxBitRate",
        "NewTotalBytesReceived", "NewTotalBytesSent",
        "NewX_AVM_DE_TotalBytesReceived64", "NewX_AVM_DE_TotalBytesSent64",
        "NewLinkType", "NewWANAccessType", "NewAutoDisconnectTime",
        "NewDNSServer1", "NewDNSServer2",
    ]
    for line in out.splitlines():
        l = line.strip()
        for kw in keywords:
            if l.startswith(kw):
                rest = l[len(kw):]
                # strip : <value>  or = <value> or whitespace
                rest = rest.lstrip("=: ").strip()
                if rest:
                    section[kw] = rest
                break
    return section

def params_get(key, default):
    # helper to read params (module-level not available in closures)
    pass

def _discover(ctx, params):
    section = _parse_fritz(_read_fritz_section(ctx))
    # Link Info discovery: present if both link status keys exist.
    discovery = []
    if "NewLinkStatus" in section and "NewPhysicalLinkStatus" in section:
        discovery.append({"item": "", "params": {}, "metrics": []})
    return {"changed": False, "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery}}

def _check(ctx, params):
    section = _parse_fritz(_read_fritz_section(ctx))
    if not section:
        return {"changed": False,
                "msg": "no Fritz!Box device or data source found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    link_fields = [
        ("NewLinkStatus", "Link status"),
        ("NewPhysicalLinkStatus", "Physical link status"),
    ]
    summaries = []
    worst = "OK"
    for key, label in link_fields:
        value = section.get(key)
        if value:
            if value == "Up":
                st = "OK"
            else:
                st = "CRIT"
            if st == "CRIT" and worst == "OK":
                worst = "CRIT"
            summaries.append("%s: %s" % (label, value))

    if not summaries:
        # Both keys absent but section present: still no link data.
        return {"changed": False,
                "msg": "no link status info in section",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    return {"changed": False,
            "msg": ", ".join(summaries),
            "data": {"state": worst, "metrics": {}, "details": ""}}
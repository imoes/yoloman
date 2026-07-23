CURL_OK = list(range(100))
WAN_SERVICE = "urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1"
WAN_PATH = "/igdupnp/control/WANCommonIFC1"
SOAP_TMPL = (
    '<?xml version="1.0" encoding="utf-8"?>' +
    '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"' +
    ' s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">' +
    '<s:Body><u:__ACTION__ xmlns:u="__SERVICE__"/></s:Body></s:Envelope>'
)

def _xml_get(text, tag):
    open_tag = "<" + tag + ">"
    close_tag = "</" + tag + ">"
    start = text.find(open_tag)
    if start == -1:
        return ""
    start = start + len(open_tag)
    end = text.find(close_tag, start)
    if end == -1:
        return ""
    return text[start:end]

def _soap(ctx, host, port, path, service, action):
    url = "http://" + host + ":" + str(port) + path
    body = SOAP_TMPL.replace("__ACTION__", action).replace("__SERVICE__", service)
    soap_hdr = '"' + service + "#" + action + '"'
    return ctx.run(
        ["curl", "-s", "-m", "10", "-X", "POST", url,
         "-H", 'Content-Type: text/xml; charset="utf-8"',
         "-H", "SOAPAction: " + soap_hdr,
         "-d", body],
        mutates=False,
        ok_codes=CURL_OK,
    )

def main(ctx, params):
    host = params.get("host", "fritz.box")
    port = params.get("port", 49000)

    if params.get("_discover"):
        res = _soap(ctx, host, port, WAN_PATH, WAN_SERVICE, "GetCommonLinkProperties")
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        if not _xml_get(res.stdout, "NewPhysicalLinkStatus"):
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "discovered 1 items",
            "data": {"discovery": [
                {
                    "item": "WAN",
                    "params": {
                        "warn_speed_in": 90,
                        "crit_speed_in": 95,
                        "warn_speed_out": 90,
                        "crit_speed_out": 95,
                    },
                    "metrics": ["in_octets", "out_octets", "in_rate", "out_rate",
                                "speed_in", "speed_out"],
                },
            ]},
        }

    item = params.get("item", "WAN")
    if item != "WAN":
        return {"changed": False, "msg": "unknown item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res_link = _soap(ctx, host, port, WAN_PATH, WAN_SERVICE, "GetCommonLinkProperties")
    if res_link.rc != 0 or not res_link.stdout.strip():
        return {"changed": False,
                "msg": "Fritz!Box unreachable (" + host + ":" + str(port) + ")",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    phys_status = _xml_get(res_link.stdout, "NewPhysicalLinkStatus")
    if not phys_status:
        return {"changed": False, "msg": "no link status in Fritz!Box response",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    ds_str = _xml_get(res_link.stdout, "NewLayer1DownstreamMaxBitRate")
    us_str = _xml_get(res_link.stdout, "NewLayer1UpstreamMaxBitRate")
    speed_in = int(ds_str) if ds_str.isdigit() else 0
    speed_out = int(us_str) if us_str.isdigit() else 0

    res_addon = _soap(ctx, host, port, WAN_PATH, WAN_SERVICE, "GetAddonInfos")
    in_octets = 0
    out_octets = 0
    in_rate = 0
    out_rate = 0

    if res_addon.rc == 0 and res_addon.stdout.strip():
        rx64 = _xml_get(res_addon.stdout, "NewX_AVM_DE_TotalBytesReceived64")
        tx64 = _xml_get(res_addon.stdout, "NewX_AVM_DE_TotalBytesSent64")
        rx32 = _xml_get(res_addon.stdout, "NewTotalBytesReceived")
        tx32 = _xml_get(res_addon.stdout, "NewTotalBytesSent")
        rx_str = rx64 if rx64.isdigit() else rx32
        tx_str = tx64 if tx64.isdigit() else tx32
        in_octets = int(rx_str) if rx_str.isdigit() else 0
        out_octets = int(tx_str) if tx_str.isdigit() else 0

        rr_str = _xml_get(res_addon.stdout, "NewByteReceiveRate")
        sr_str = _xml_get(res_addon.stdout, "NewByteSendRate")
        in_rate = int(rr_str) if rr_str.isdigit() else 0
        out_rate = int(sr_str) if sr_str.isdigit() else 0

    if phys_status == "Up":
        state = "OK"
    elif phys_status == "Initializing":
        state = "WARN"
    else:
        state = "CRIT"

    warn_util_in  = params.get("warn_speed_in",  90)
    crit_util_in  = params.get("crit_speed_in",  95)
    warn_util_out = params.get("warn_speed_out", 90)
    crit_util_out = params.get("crit_speed_out", 95)

    util_in_pct  = 0
    util_out_pct = 0
    if (speed_in > 0) and (in_rate > 0):
        util_in_pct = (in_rate * 8 * 100) / speed_in
        if util_in_pct >= crit_util_in:
            state = "CRIT"
        elif (util_in_pct >= warn_util_in) and (state == "OK"):
            state = "WARN"
    if (speed_out > 0) and (out_rate > 0):
        util_out_pct = (out_rate * 8 * 100) / speed_out
        if util_out_pct >= crit_util_out:
            state = "CRIT"
        elif (util_out_pct >= warn_util_out) and (state == "OK"):
            state = "WARN"

    speed_in_mbit  = speed_in  / 1000000.0
    speed_out_mbit = speed_out / 1000000.0
    in_kbit  = (in_rate  * 8) / 1000.0
    out_kbit = (out_rate * 8) / 1000.0

    parts = [phys_status]
    if speed_in > 0:
        parts.append("Speed: %f/%f Mbit/s" % (speed_in_mbit, speed_out_mbit))
    if (in_rate > 0) or (out_rate > 0):
        parts.append("In: %f kbit/s Out: %f kbit/s" % (in_kbit, out_kbit))
    if util_in_pct > 0:
        parts.append("Util: %f%%" % util_in_pct)

    return {
        "changed": False,
        "msg": ", ".join(parts),
        "data": {
            "state": state,
            "metrics": {
                "in_octets":  in_octets,
                "out_octets": out_octets,
                "in_rate":    in_rate,
                "out_rate":   out_rate,
                "speed_in":   speed_in,
                "speed_out":  speed_out,
            },
            "details": "Physical: %s | Max down/up: %f/%f Mbit/s" % (
                phys_status, speed_in_mbit, speed_out_mbit,
            ),
        },
    }
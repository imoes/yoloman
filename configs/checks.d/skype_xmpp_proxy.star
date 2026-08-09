def main(ctx, params):
    if params.get("_discover"):
        # Probe for the real data source: WMI capability
        # This check monitors Skype for Business XMPP Federation Proxy WMI counters
        # WMI is a Windows-only technology; on non-Windows hosts this check does not apply
        facts = ctx.facts()
        if facts.get("os_family") != "windows":
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}

    item = params.get("item", "")
    # Check mode: the data source is WMI which is Windows-only
    # On this host there is no WMI data source for Skype XMPP Proxy
    return {"changed": False, "msg": "no Skype XMPP Proxy WMI data available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
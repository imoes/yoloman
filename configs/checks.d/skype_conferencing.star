def main(ctx, params):
    # ---- Skype Conferencing (WMI-based Windows performance counters) ----
    # This is a Windows-specific check reading WMI performance counter
    # classes. On a non-Windows host (no WMI / no Skype for Business server)
    # there is nothing to discover.

    def _probe_wmi():
        # Determine whether we are on a host that can expose WMI Skype data.
        facts = ctx.facts()
        os_family = facts.get("os_family", "")
        if os_family != "windows":
            return None
        # On Windows hosts we would query the real WMI performance counter
        # classes that the Checkmk agent plugin reads (e.g.
        # "LS:CAA - Operations", "LS:USrv - Conference Mcu Allocator").
        # The yolo-man agent has no WMI access, so absent a special agent
        # the section is unavailable here.
        return None

    if params.get("_discover"):
        wmi = _probe_wmi()
        if wmi == None:
            return {"changed": False, "msg": "no WMI / Skype data available",
                    "data": {"discovery": []}}
        # If WMI data were available we would enumerate items per
        # required WMI table; here we never reach this branch.
        return {"changed": False, "msg": "discovered 0 items",
                "data": {"discovery": []}}

    item = params.get("item", "")
    wmi = _probe_wmi()
    if wmi == None:
        return {"changed": False,
                "msg": "no WMI / Skype conferencing data available on this host",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # The real check grades several counters; with no data source we cannot
    # grade anything, so we report UNKNOWN rather than OK.
    return {"changed": False,
            "msg": "Skype conferencing WMI data unavailable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
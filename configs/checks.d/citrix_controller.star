def main(ctx, params):
    # Read agent data from the citrix_controller section
    # The Checkmk agent plugin for Citrix Controller uses 'controller_info'
    # to produce the agent section; we replicate the same by running:
    #   /opt/citrix/icaclient/ctxstat -version
    # However, many deployments expose controller state via a local command
    # or a file. Checkmk's agent plugin reads '/opt/citrix/icaclient/ctxstat'.
    # If that command is available, we use it; otherwise fall back to checking
    # for known file paths or defaulting to UNKNOWN state if nothing is found.
    # For portability, we use a shell-agnostic command sequence via ctx.run.

    # Try to run ctxstat -version which yields multi-line output like:
    # ControllerVersion 22.12.0.55
    # ControllerState Active
    # LicensingGraceState NotActive
    # LicensingServerState OK
    # TotalFarmActiveSessions 123
    # TotalFarmInactiveSessions 45
    # DesktopsRegistered 10
    # ActiveSiteServices StoreFront,Web
    # If ctxstat is not available, check for a pre-canned file (e.g., from agent
    # fake-data) or fall back to UNKNOWN.

    # Prefer a direct command; fallback to reading a known file if ctxstat fails.
    res = ctx.run(["/opt/citrix/icaclient/ctxstat", "-version"], mutates=False)
    output = res.stdout.strip() if res.stdout.strip() else ""

    # If ctxstat failed, try a file fallback used in test setups
    if not output:
        if ctx.file_exists("/var/lib/citrix/controller_state"):
            output = ctx.file_read("/var/lib/citrix/controller_state").strip()
        else:
            # No data source available -> UNKNOWN
            return {
                "changed": False,
                "msg": "Citrix Controller: data not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }

    # Parse the output lines exactly as the Python parse_citrix_controller does
    lines = output.splitlines()
    section = {
        "version": None,
        "state": None,
        "licensing_grace_state": None,
        "licensing_server_state": None,
        "session": None,
        "desktop_count": None,
        "active_site_services": None,
    }
    session = {"active": 0, "inactive": 0}
    found_session = False

    for line in lines:
        f = line.strip().split()
        if not f:
            continue
        key = f[0]
        rest = f[1:] if len(f) > 1 else []

        if key == "ControllerVersion" and len(rest) >= 1:
            section["version"] = rest[0]
        elif key == "ControllerState":
            if len(rest) >= 1:
                section["state"] = rest[0]
            else:
                section["state"] = "Error"
        elif key == "LicensingGraceState" and section["licensing_grace_state"] == None:
            if len(rest) >= 1:
                section["licensing_grace_state"] = rest[0]
        elif key == "LicensingServerState" and section["licensing_server_state"] == None:
            if len(rest) >= 1:
                section["licensing_server_state"] = rest[0]
        elif key == "TotalFarmActiveSessions" and len(rest) >= 1 and rest[0].isdigit():
            session["active"] = int(rest[0])
            found_session = True
        elif key == "TotalFarmInactiveSessions" and len(rest) >= 1 and rest[0].isdigit():
            session["inactive"] = int(rest[0])
            found_session = True
        elif key == "DesktopsRegistered" and len(rest) >= 1 and rest[0].isdigit():
            section["desktop_count"] = int(rest[0])
        elif key == "DesktopsRegistered":
            section["desktop_count"] = "Error"
        elif key == "ActiveSiteServices":
            section["active_site_services"] = " ".join(rest)

    if found_session:
        section["session"] = session

    # ===== Discovery mode =====
    if params.get("_discover"):
        out = []
        if section.get("state") != None:
            out.append({"item": "", "params": {}, "metrics": []})
        if section.get("licensing_server_state") != None or section.get("licensing_grace_state") != None:
            out.append({"item": "", "params": {}, "metrics": []})
        if section.get("session") != None:
            out.append({"item": "", "params": {}, "metrics": ["total_sessions", "active_sessions", "inactive_sessions"]})
        if section.get("desktop_count") != None and section.get("desktop_count") != "Error":
            out.append({"item": "", "params": {}, "metrics": ["registered_desktops"]})
        if section.get("active_site_services") != None:
            out.append({"item": "", "params": {}, "metrics": []})

        return {
            "changed": False,
            "msg": "discovered %d services" % len(out),
            "data": {"discovery": out},
        }

    # ===== Check mode: "Citrix Controller State" =====
    item = params.get("item", "")
    if item == "Citrix Controller State" or item == "":
        raw_state = section.get("state")
        if raw_state == None:
            return {
                "changed": False,
                "msg": "Citrix Controller: no state data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        elif raw_state == "Error":
            return {
                "changed": False,
                "msg": "Citrix Controller: unknown",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        elif raw_state == "Active":
            return {
                "changed": False,
                "msg": "Citrix Controller: Active",
                "data": {"state": "OK", "metrics": {}, "details": ""},
            }
        else:
            return {
                "changed": False,
                "msg": "Citrix Controller: %s" % raw_state,
                "data": {"state": "CRIT", "metrics": {}, "details": ""},
            }

    # ===== Check mode: "Citrix Controller Licensing" =====
    if item == "Citrix Controller Licensing":
        out = []
        if section.get("licensing_server_state") != None:
            state_map = {
                "ServerNotSpecified": ("CRIT", "server not specified"),
                "NotConnected": ("WARN", "not connected"),
                "OK": ("OK", "OK"),
                "LicenseNotInstalled": ("CRIT", "license not installed"),
                "LicenseExpired": ("CRIT", "licenese expired"),
                "Incompatible": ("CRIT", "incompatible"),
                "Failed": ("CRIT", "failed"),
            }
            s = section.get("licensing_server_state")
            st, txt = state_map.get(s, ("UNKNOWN", "unknown[" + s + "]"))
            out.append("Licensing Server State: " + txt)
        if section.get("licensing_grace_state") != None:
            grace_map = {
                "NotActive": ("OK", "not active"),
                "Active": ("CRIT", "active"),
                "InOutOfBoxGracePeriod": ("WARN", "in-out-of-box grace period"),
                "InSupplementalGracePeriod": ("WARN", "in-supplemental grace period"),
                "InEmergencyGracePeriod": ("CRIT", "in-emergency grace period"),
                "GracePeriodExpired": ("CRIT", "grace period expired"),
                "Expired": ("CRIT", "expired"),
            }
            s = section.get("licensing_grace_state")
            st, txt = grace_map.get(s, ("UNKNOWN", "unknown[" + s + "]"))
            out.append("Licensing Grace State: " + txt)

        if not out:
            return {
                "changed": False,
                "msg": "Citrix Controller Licensing: data not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        # Aggregate worst state
        state = "OK"
        for s in out:
            if s.startswith("Licensing Server State:"):
                if "CRIT" in s or "expired" in s or "failed" in s or "not installed" in s or "incompatible" in s:
                    state = "CRIT"
                elif "WARN" in s:
                    state = "WARN" if state != "CRIT" else state
                elif "OK" in s:
                    state = "OK" if state == "OK" else state
            if s.startswith("Licensing Grace State:"):
                if "CRIT" in s or "active" in s or "expired" in s or "emergency" in s:
                    state = "CRIT" if state != "CRIT" else state
                elif "WARN" in s:
                    state = "WARN" if state != "CRIT" else state
        return {
            "changed": False,
            "msg": "; ".join(out),
            "data": {"state": state, "metrics": {}, "details": ""},
        }

    # ===== Check mode: "Citrix Total Sessions" =====
    if item == "Citrix Total Sessions":
        session = section.get("session")
        if session == None:
            return {
                "changed": False,
                "msg": "Citrix Sessions: no session data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        total = session.get("active", 0) + session.get("inactive", 0)
        active = session.get("active", 0)
        inactive = session.get("inactive", 0)
        warn_total = params.get("total")
        warn_active = params.get("active")
        warn_inactive = params.get("inactive")

        # Compute worst state
        state = "OK"
        if warn_total != None and len(warn_total) == 2:
            if total >= warn_total[1]:
                state = "CRIT"
            elif total >= warn_total[0]:
                state = "WARN"
        if warn_active != None and len(warn_active) == 2:
            if active >= warn_active[1]:
                state = "CRIT"
            elif active >= warn_active[0]:
                state = "WARN"
        if warn_inactive != None and len(warn_inactive) == 2:
            if inactive >= warn_inactive[1]:
                state = "CRIT"
            elif inactive >= warn_inactive[0]:
                state = "WARN"

        msg_parts = []
        msg_parts.append("total: %d" % total)
        msg_parts.append("active: %d" % active)
        msg_parts.append("inactive: %d" % inactive)
        return {
            "changed": False,
            "msg": "Citrix Sessions: " + ", ".join(msg_parts),
            "data": {"state": state, "metrics": {"total_sessions": total, "active_sessions": active, "inactive_sessions": inactive}, "details": ""},
        }

    # ===== Check mode: "Citrix Desktops Registered" =====
    if item == "Citrix Desktops Registered":
        desktop = section.get("desktop_count")
        if desktop == None or desktop == "Error":
            return {
                "changed": False,
                "msg": "Citrix Desktops: no desktops registered",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        levels = params.get("levels")
        levels_lower = params.get("levels_lower")

        # Determine state
        state = "OK"
        if levels != None and len(levels) == 2:
            if desktop >= levels[1]:
                state = "CRIT"
            elif desktop >= levels[0]:
                state = "WARN"
        if levels_lower != None and len(levels_lower) == 2:
            if desktop <= levels_lower[1]:
                state = "CRIT"
            elif desktop <= levels_lower[0]:
                state = "WARN"

        return {
            "changed": False,
            "msg": "Citrix Desktops: %d registered" % desktop,
            "data": {"state": state, "metrics": {"registered_desktops": desktop}, "details": ""},
        }

    # ===== Check mode: "Citrix Active Site Services" =====
    if item == "Citrix Active Site Services":
        services = section.get("active_site_services")
        if services == None:
            return {
                "changed": False,
                "msg": "Citrix Site Services: data not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        return {
            "changed": False,
            "msg": "Citrix Site Services: " + (services if services else "No services"),
            "data": {"state": "OK", "metrics": {}, "details": ""},
        }

    # Fallback: unknown item
    return {
        "changed": False,
        "msg": "Citrix Controller: unknown item " + item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
    }

def main(ctx, params):
    # Get parameters with Checkmk defaults
    status_expected = params.get("status", "Registered")
    subscription_status_expected = params.get("subscription_status", "ACTIVE")

    # Discovery mode
    if params.get("_discover"):
        res = ctx.run(["suse-manager-channel-info", "-s"], mutates=False)
        if res.rc != 0:
            res = ctx.run(["suseconnect", "-s"], mutates=False)
        if res.rc == 0:
            return {
                "changed": False,
                "msg": "discovered 1 item",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": ["days_to_expiry"]}]}
            }
        else:
            return {
                "changed": False,
                "msg": "no suseconnect data available",
                "data": {"discovery": []}
            }

    # Check mode: one service (item = "")
    res = ctx.run(["suse-manager-channel-info", "-s"], mutates=False)
    if res.rc != 0:
        res = ctx.run(["suseconnect", "-s"], mutates=False)
    if res.rc != 0 or res.stdout.strip() == "":
        return {
            "changed": False,
            "msg": "SLES license information unavailable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse the output
    specs = {}
    lines = res.stdout.strip().split("\n")
    mode_v15 = False

    # Detect mode: if first non-empty line starts with '(' it's v15+ format
    i = 0
    while i < len(lines):
        if lines[i].strip() != "":
            if lines[i].strip().startswith("("):
                mode_v15 = True
            break
        i = i + 1

    if mode_v15:
        # Parse V15+ format
        i = 0
        while i < len(lines):
            stripped = lines[i].strip()
            # Header line like "(SLES/12/x86_64)"
            if stripped.startswith("(") and stripped.endswith(")"):
                header = stripped[1:-1]
                parts = header.split("/")
                if len(parts) >= 1:
                    identifier = parts[0]
                    if i + 1 < len(lines):
                        status_line = lines[i+1].strip()
                        if "Registered" in status_line or "Not Registered" in status_line:
                            specs["registration_status"] = "Registered" if "Registered" in status_line else "Not Registered"
                            i = i + 2
                            continue
            elif stripped.startswith("    ") and len(stripped) > 0:
                idx = stripped.find(":")
                if idx != -1:
                    key = stripped[4:idx].strip()
                    value = stripped[idx+1:].strip()
                    if key == "Regcode":
                        specs["registration_code"] = value
                    elif key == "Starts at":
                        specs["starts_at"] = value
                    elif key == "Expires at":
                        specs["expires_at"] = value
                    elif key == "Status":
                        specs["subscription_status"] = value
                    elif key == "Type":
                        specs["subscription_type"] = value
            i = i + 1
    else:
        # Pre-V15 format
        for line in lines:
            if line.strip() == "" or ":" not in line:
                continue
            idx = line.find(":")
            key = line[:idx].strip()
            value = line[idx+1:].strip()
            if key == "identifier":
                specs["identifier"] = value
            elif key == "version":
                specs["version"] = value
            elif key == "arch":
                specs["architecture"] = value
            elif key == "status":
                specs["registration_status"] = value
            elif key == "regcode":
                specs["registration_code"] = value
            elif key == "starts_at":
                specs["starts_at"] = value
            elif key == "expires_at":
                specs["expires_at"] = value
            elif key == "subscription_status":
                specs["subscription_status"] = value
            elif key == "type":
                specs["subscription_type"] = value

    # Ensure we have SLES-related data
    if specs == {}:
        return {
            "changed": False,
            "msg": "No SLES license data found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Build return state and details
    state = "OK"
    details_parts = []

    # Registration status
    if "registration_status" in specs:
        if status_expected != "Ignore" and specs["registration_status"] != status_expected:
            state = "CRIT"
        details_parts.append("Status: " + specs["registration_status"])
    else:
        details_parts.append("Status: unknown")

    # Subscription status
    if "subscription_status" in specs:
        if subscription_status_expected != "Ignore" and specs["subscription_status"] != subscription_status_expected:
            state = "CRIT"
        details_parts.append("Subscription: " + specs["subscription_status"])
    else:
        details_parts.append("Subscription: unknown")

    # Expiration time calculation
    metrics = {}
    if "expires_at" in specs:
        expires_str = specs["expires_at"]
        date_parts = expires_str.split(" ")[0].split("-")
        time_parts = ["00","00","00"]
        if " " in expires_str:
            time_parts = expires_str.split(" ")[1].split(":")
        if len(date_parts) == 3 and len(time_parts) == 3:
            year = 0
            month = 0
            day = 0
            if date_parts[0].isdigit() and date_parts[1].isdigit() and date_parts[2].isdigit():
                year = int(date_parts[0])
                month = int(date_parts[1])
                day = int(date_parts[2])
            # Approximate days since epoch
            days_since_epoch = (year - 1970) * 365.25 + (month - 1) * 30.44 + (day - 1)
            # Get current date via date command
            date_res = ctx.run(["date", "+%Y-%m-%d"], mutates=False)
            current_date = "1970-01-01"
            if date_res.rc == 0 and date_res.stdout.strip() != "":
                current_date = date_res.stdout.strip()
            curr_parts = current_date.split("-")
            if len(curr_parts) == 3 and curr_parts[0].isdigit() and curr_parts[1].isdigit() and curr_parts[2].isdigit():
                curr_year = int(curr_parts[0])
                curr_month = int(curr_parts[1])
                curr_day = int(curr_parts[2])
                days_since_epoch_curr = (curr_year - 1970) * 365.25 + (curr_month - 1) * 30.44 + (curr_day - 1)
                days_to_expiry = int(days_since_epoch - days_since_epoch_curr)
                # Apply levels: warn at <= 14 days, crit at <= 7 days
                if days_to_expiry <= 7:
                    state = "CRIT"
                    details_parts.append("Expires in: %d days" % days_to_expiry)
                elif days_to_expiry <= 14:
                    state = "WARN"
                    details_parts.append("Expires in: %d days" % days_to_expiry)
                else:
                    details_parts.append("Expires in: %d days" % days_to_expiry)
                metrics["days_to_expiry"] = days_to_expiry
            else:
                details_parts.append("Expiration: unknown")
        else:
            details_parts.append("Expiration: unknown")
    else:
        details_parts.append("Expiration: missing data")

    # Subscription details if all present
    all_present = True
    for k in ["subscription_type", "registration_code", "starts_at", "expires_at"]:
        if not (k in specs):
            all_present = False
            break
    if all_present:
        details_parts.append("Subscription type: " + specs["subscription_type"] + ", Registration code: " + specs["registration_code"] + ", Starts at: " + specs["starts_at"] + ", Expires at: " + specs["expires_at"])

    summary = ", ".join(details_parts)

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }
def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/var/lib/check-mk-agent/source/jar_signature"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 jar signatures",
                    "data": {"discovery": []}}
        
        items = []
        for line in res.stdout.splitlines():
            stripped = line.strip()
            if stripped.startswith("[[[") and stripped.endswith("]]]"):
                item_name = stripped[3:-3]
                items.append({"item": item_name, "params": {},
                              "metrics": ["certificate_validity_days"]})
        
        return {"changed": False, "msg": "discovered %d jar signatures" % len(items),
                "data": {"discovery": items}}
    
    item = params.get("item", "")
    res = ctx.run(["cat", "/var/lib/check-mk-agent/source/jar_signature"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to read jar signature data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    lines = res.stdout.splitlines()
    in_block = False
    details = []
    in_cert = False
    cert = []
    
    for raw_line in lines:
        line = (" ".join(raw_line)).strip()
        if line == "[[[%s]]]" % item:
            in_block = True
        elif in_block and line.startswith("[[["):
            break
        elif in_block and line.startswith("X.509"):
            in_cert = True
            cert = [line]
        elif in_block and in_cert and line.startswith("[") and not line.startswith("[entry was signed on"):
            in_cert = False
            cert.append(line)
            details.append(cert)
    
    if not details:
        return {"changed": False, "msg": "No certificate found",
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    
    cert_dn, cert_valid = details[0]
    
    # Parse expiry date text
    expiry_date_text = ""
    if "will expire on " in cert_valid:
        expiry_date_text = cert_valid.split("will expire on ", 1)[1][:-1]
    elif "expired on" in cert_valid:
        expiry_date_text = cert_valid.split("expired on ", 1)[1][:-1]
    else:
        expiry_date_text = cert_valid.split("to ", 1)[1][:-1]
    
    # Parse date format: "%m/%d/%y %I:%M %p"
    expiry_date = 0
    parts = expiry_date_text.split()
    if len(parts) >= 2:
        date_part = parts[0]
        time_part = parts[1]
        ampm = parts[2] if len(parts) > 2 else ""
        
        date_components = date_part.split("/")
        if len(date_components) == 3:
            month_str = date_components[0]
            day_str = date_components[1]
            year_str = date_components[2]
            
            month = int(month_str) if month_str.isdigit() else 0
            day = int(day_str) if day_str.isdigit() else 0
            year = int(year_str) if year_str.isdigit() else 0
            
            time_components = time_part.split(":")
            hour = 0
            minute = 0
            if len(time_components) == 2:
                hour_str = time_components[0]
                minute_str = time_components[1]
                hour = int(hour_str) if hour_str.isdigit() else 0
                minute = int(minute_str) if minute_str.isdigit() else 0
                
                # Convert to 24-hour format if AM/PM present
                if ampm == "PM" and hour != 12:
                    hour += 12
                elif ampm == "AM" and hour == 12:
                    hour = 0
                
                # Calculate days from 1970-01-01
                def days_before_month(m, y):
                    days = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
                    is_leap = (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0)
                    if is_leap and m > 2:
                        return days[m - 1] + 1
                    return days[m - 1]
                
                year_diff = year - 1970
                leap_years = (year - 1969) // 4 - (year - 1901) // 100 + (year - 1601) // 400
                days = year_diff * 365 + leap_years + days_before_month(month, year) + day - 1
                
                expiry_date = days * 86400 + hour * 3600 + minute * 60
    
    # Approximate current time
    current_time_approx = 1704067200  # 2024-01-01 00:00:00 UTC
    
    expired_since = current_time_approx - expiry_date
    
    warn = 60 * 86400  # 60 days in seconds
    crit = 30 * 86400  # 30 days in seconds
    
    state = 0
    if expired_since >= 0:
        status_text = "Certificate expired " + str(expired_since // 86400) + " days ago"
        state = 2
    else:
        remaining_days = (-expired_since) // 86400
        status_text = "Certificate expires in " + str(remaining_days) + " days"
        if -expired_since <= crit:
            state = 2
        elif -expired_since <= warn:
            state = 1
        if state:
            status_text += " (warn/crit below 60/30 days)"
    
    # Compute remaining time for metrics (in seconds)
    remaining_seconds = -expired_since if expired_since < 0 else 0
    
    return {"changed": False, "msg": status_text,
            "data": {"state": "CRIT" if state == 2 else ("WARN" if state == 1 else "OK"),
                     "metrics": {"certificate_validity_days": remaining_seconds / 86400 if expired_since < 0 else -expired_since / 86400},
                     "details": ""}}
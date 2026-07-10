def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: list all certificate items
        res = ctx.run([
            "snmpwalk", "-On", "-v2c", "-c", "public", ctx.facts().get("hostname", "localhost"),
            ".1.3.6.1.4.1.9148.3.9.1.10.1.3"
        ], mutates=False)
        items = []
        for line in res.stdout.splitlines():
            # Format: .1.3.6.1.4.1.9148.3.9.1.10.1.3.X.Y certname
            # Extract the cert name from the end of the line
            parts = line.strip().split()
            if len(parts) >= 2:
                name = parts[-1].strip('"').strip("'")
                if name:
                    items.append({
                        "item": name,
                        "params": {"expire_lower": ["fixed", 604800.0, 2592000.0]},
                        "metrics": ["certificate_expiration_time"]
                    })
        return {
            "changed": False,
            "msg": "discovered %d certificates" % len(items),
            "data": {"discovery": items}
        }

    # Check mode: verify one specific certificate item
    item = params.get("item", "")
    expire_lower = params.get("expire_lower", ["fixed", 604800.0, 2592000.0])
    warn_level, crit_level = expire_lower[1], expire_lower[2]

    # Fetch certificate data via SNMP
    # We need all four OID columns: 3 (name), 5 (start), 6 (expire), 7 (issuer)
    base_oid = ".1.3.6.1.4.1.9148.3.9.1.10.1"
    res = ctx.run([
        "snmpwalk", "-On", "-v2c", "-c", "public", ctx.facts().get("hostname", "localhost"),
        base_oid + ".3", base_oid + ".5", base_oid + ".6", base_oid + ".7"
    ], mutates=False)

    # Parse SNMP output into structured data
    certs = {}
    lines = res.stdout.splitlines()
    # We'll collect all rows; each OID type gives us one column
    # We need to match by instance suffix (e.g., .65.1) to reconstruct rows
    # Format: OID.index = value
    cert_data = {}
    for line in lines:
        if not line.strip():
            continue
        parts = line.strip().split(" = ", 1)
        if len(parts) != 2:
            continue
        oid = parts[0].strip()
        value = parts[1].strip().strip('"').strip("'")
        # Extract the instance part: after last dot
        if oid.count('.') < 2:
            continue
        instance = oid.rsplit('.', 1)[1]
        # Determine which column by OID suffix
        if oid.endswith('.3'):
            # Certificate name
            if instance not in cert_data:
                cert_data[instance] = {}
            cert_data[instance]['name'] = value
        elif oid.endswith('.5'):
            # Start date
            if instance not in cert_data:
                cert_data[instance] = {}
            cert_data[instance]['start'] = value
        elif oid.endswith('.6'):
            # Expiry date
            if instance not in cert_data:
                cert_data[instance] = {}
            cert_data[instance]['expire'] = value
        elif oid.endswith('.7'):
            # Issuer
            if instance not in cert_data:
                cert_data[instance] = {}
            cert_data[instance]['issuer'] = value

    # Reconstruct section dict: name -> (start, expire, issuer)
    for inst, data in cert_data.items():
        name = data.get('name', '')
        if name:
            certs[name] = (data.get('start', ''), data.get('expire', ''), data.get('issuer', ''))

    # Check if requested item exists
    if item not in certs:
        return {
            "changed": False,
            "msg": "certificate not found: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    start, expire, issuer = certs[item]
    # Parse expiration time
    expire_date = expire.rsplit(" ", 1)[0]  # remove timezone
    expire_time_str = expire_date
    # Expected format: "Jul 25 00:33:17 2003 GMT"
    # Parse manually without time.strptime (not available in Starlark)
    months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    parts = expire_time_str.split()
    if len(parts) != 6:
        return {
            "changed": False,
            "msg": "invalid expiration date format for certificate: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    month_str, day_str, time_str, year_str = parts[0], parts[1], parts[2], parts[5]
    if month_str not in months:
        return {
            "changed": False,
            "msg": "invalid expiration date format for certificate: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    month = months.index(month_str) + 1
    day = int(day_str)
    year = int(year_str)
    
    # Parse HH:MM:SS
    time_parts = time_str.split(":")
    if len(time_parts) != 3:
        return {
            "changed": False,
            "msg": "invalid expiration date format for certificate: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    hour = int(time_parts[0])
    minute = int(time_parts[1])
    second = int(time_parts[2])
    
    # Calculate epoch time (UTC)
    # Using simplified calculation for Unix timestamp
    # Days from year 1970 to year-1
    def days_in_year(y):
        if (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0):
            return 366
        return 365
    
    total_days = 0
    for y in range(1970, year):
        total_days = total_days + days_in_year(y)
    
    # Days in current year up to end of previous month
    days_in_month = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    if (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0):
        days_in_month[1] = 29
    for m in range(0, month - 1):
        total_days = total_days + days_in_month[m]
    total_days = total_days + day - 1
    
    expire_time = total_days * 86400 + hour * 3600 + minute * 60 + second

    # Get current time from system via date command
    res_time = ctx.run(["date", "+%s"], mutates=False)
    now = int(res_time.stdout.strip())

    time_diff = expire_time - now

    # Determine state based on levels (lower bounds)
    if time_diff <= crit_level:
        state = "CRIT"
        msg = "Certificate %s expires in %s (crit at %s)" % (
            item, render_time(time_diff), render_time(crit_level)
        )
    elif time_diff <= warn_level:
        state = "WARN"
        msg = "Certificate %s expires in %s (warn at %s)" % (
            item, render_time(time_diff), render_time(warn_level)
        )
    else:
        state = "OK"
        msg = "Certificate %s expires in %s" % (
            item, render_time(time_diff)
        )

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"certificate_expiration_time": time_diff},
            "details": ""
        }
    }


def render_time(seconds):
    """Render seconds as human-readable time span (Checkmk style)"""
    seconds = int(seconds)
    if seconds < 0:
        return "expired"
    if seconds < 60:
        return "%d s" % seconds
    if seconds < 3600:
        return "%d m" % (seconds // 60)
    if seconds < 86400:
        return "%d h" % (seconds // 3600)
    return "%d d" % (seconds // 86400)

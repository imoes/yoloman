# Checkmk check: checkmk.acme_certificates (translated to read-only Starlark)

# OID base for the ACME certificate table (Avaya / ACME devices).
# Columns: .3 = cert name, .5 = start date, .6 = expire date, .7 = issuer
OID_BASE = ".1.3.6.1.4.1.9148.3.9.1.10.1"
COL_NAME = "3"
COL_START = "5"
COL_EXPIRE = "6"
COL_ISSUER = "7"

# Walk column OIDs (full OIDs for snmpwalk).
COL_NAME_OID = OID_BASE + "." + COL_NAME
COL_START_OID = OID_BASE + "." + COL_START
COL_EXPIRE_OID = OID_BASE + "." + COL_EXPIRE
COL_ISSUER_OID = OID_BASE + "." + COL_ISSUER

# Default thresholds (seconds until expiration): warn = 30 days, crit = 7 days.
# These are "lower" levels: WARN/CRIT when time_diff <= threshold.
DEFAULT_WARN = 2592000.0   # 30 days
DEFAULT_CRIT = 604800.0    # 7 days

# Month name to number mapping for parsing "Mon" abbreviations.
MONTHS = {
    "Jan": 1, "Feb": 2,
    "Mar": 3, "Apr": 4,
    "May": 5, "Jun": 6,
    "Jul": 7, "Aug": 8,
    "Sep": 9, "Oct": 10,
    "Nov": 11, "Dec": 12,
}


# Parse a Checkmk/ASN.1 date string "Jul 25 00:33:17 2003 GMT" into epoch seconds.
# Uses pure Starlark string operations (no datetime module, no regex).
def parse_asn1_date(s):
    # Split off the timezone (trailing "GMT").
    body = s
    # Remove trailing " GMT" if present.
    if body.endswith(" GMT"):
        body = body[:-4]
    else:
        # Try to strip any trailing timezone by taking the last token.
        parts = body.split(" ")
        if len(parts) >= 1 and parts[-1] != "":
            # Heuristic: if the last token is alphabetic it is a timezone.
            tz = parts[-1]
            if tz.isalpha():
                body = " ".join(parts[:-1])

    # Expected format: "Mon DD HH:MM:SS YYYY"
    fields = body.split(" ")
    if len(fields) < 5:
        return None
    mon_str = fields[0]
    day = int(fields[1])
    time_part = fields[2]
    year = int(fields[3])

    if mon_str not in MONTHS:
        return None
    month = MONTHS[mon_str]

    tfields = time_part.split(":")
    if len(tfields) < 3:
        return None
    hour = int(tfields[0])
    minute = int(tfields[1])
    second = int(tfields[2])

    # Convert to epoch seconds using a manual day-count.
    return to_epoch(year, month, day, hour, minute, second)


# Convert a UTC date/time to epoch seconds (treating input as UTC).
# Pure Starlark implementation — no calendar/datetime modules available.
def to_epoch(year, month, day, hour, minute, second):
    # Days per month for common years; index 0 unused, 1 = Jan.
    days_in_month = [0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

    # Count whole years since 1970, adding leap days.
    days = 0
    for y in range(1970, year):
        if is_leap(y):
            days += 366
        else:
            days += 365

    # Add whole months of the target year.
    for m in range(1, month):
        days += days_in_month[m]
        if m == 2 and is_leap(year):
            days += 1

    # Add whole days of the target month (days - 1 because the current day is
    # not yet complete).
    days += (day - 1)

    return days * 86400 + hour * 3600 + minute * 60 + second


def is_leap(y):
    return (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0)


# Trim a leading "STRING: " or similar ASN.1 type tag produced without -Oqv.
def strip_type_tag(value):
    if value == None:
        return value
    # Remove a leading type tag of the form "<TYPE>: ".
    idx = value.find(": ")
    if idx >= 0:
        # Heuristic: the type tag is a single word followed by ": ".
        prefix = value[:idx]
        # Only strip if the prefix is a simple alphanumeric token (the type tag).
        if prefix.replace(" ", "").isalnum() and not prefix.endswith("\""):
            value = value[idx + 2:]
    # Strip surrounding quotes if present.
    if len(value) >= 2 and value[0] == "\"" and value[-1] == "\"":
        value = value[1:-1]
    return value


def main(ctx, params):
    # --- DISCOVERY MODE ---
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        version = params.get("version", "2c")

        # Walk the certificate NAME column to enumerate items.
        res = ctx.run(
            ["snmpwalk", "-" + version, "-c", community, "-Oqv", host, COL_NAME_OID],
            mutates=False,
        )
        if res.rc != 0:
            # Device not reachable or not an ACME device — nothing to discover.
            return {"changed": False, "msg": "no ACME certificates found",
                    "data": {"discovery": []}}

        items = []
        for line in res.stdout.splitlines():
            if line == "":
                continue
            name = strip_type_tag(line.strip())
            if name == "" or name == None:
                continue
            items.append({
                "item": name,
                "params": {"expire_lower": ["fixed", [DEFAULT_WARN, DEFAULT_CRIT]]},
                "metrics": ["certificate_expiration_time"],
            })

        return {"changed": False,
                "msg": "discovered %d ACME certificates" % len(items),
                "data": {"discovery": items}}

    # --- CHECK MODE ---
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("version", "2c")

    # Resolve thresholds from params using Checkmk defaults.
    levels = params.get("expire_lower", ["fixed", [DEFAULT_WARN, DEFAULT_CRIT]])
    # levels may be a list ["fixed", [warn, crit]] or a bare [warn, crit].
    if type(levels) == "list" and len(levels) == 2 and type(levels[1]) == "list":
        thresholds = levels[1]
    elif type(levels) == "list" and len(levels) == 2:
        thresholds = levels
    else:
        thresholds = [DEFAULT_WARN, DEFAULT_CRIT]
    warn_threshold = thresholds[0] if len(thresholds) >= 1 else DEFAULT_WARN
    crit_threshold = thresholds[1] if len(thresholds) >= 2 else DEFAULT_CRIT

    # Read the four columns for this item by walking each column OID and
    # matching entries whose index suffix corresponds to the item.
    # First, we need the SNMP index for this item name. We walk the name
    # column and look for the row whose value matches `item`.
    name_res = ctx.run(
        ["snmpwalk", "-" + version, "-c", community, "-Oqv", host, COL_NAME_OID],
        mutates=False,
    )
    if name_res.rc != 0:
        return {"changed": False, "msg": "no ACME certificates found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Find the SNMP index for this item by scanning the full-OID output.
    # Re-walk with -Oqn (numeric OIDs) so we can extract the index suffix.
    name_full = ctx.run(
        ["snmpwalk", "-" + version, "-c", community, "-Oqn", host, COL_NAME_OID],
        mutates=False,
    )
    if name_full.rc != 0:
        return {"changed": False, "msg": "no ACME certificates found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    index = None
    for line in name_full.stdout.splitlines():
        if line == "":
            continue
        # Format: "<column-OID>.<index> <value>"
        sp = line.find(" ")
        if sp < 0:
            continue
        full_oid = line[:sp]
        val = line[sp + 1:]
        # The index is the suffix after the column base OID.
        col_oid = OID_BASE + "." + COL_NAME
        if full_oid.startswith(col_oid + "."):
            idx_suffix = full_oid[len(col_oid):]
        elif full_oid == col_oid:
            idx_suffix = ""
        else:
            idx_suffix = ""
        val = strip_type_tag(val)
        if val == item:
            index = idx_suffix
            break

    if index == None or index == "":
        return {"changed": False,
                "msg": "certificate %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Fetch start, expire, issuer using the resolved index.
    start_res = ctx.run(
        ["snmpget", "-" + version, "-c", community, "-Oqv", host,
         COL_START_OID + "." + index],
        mutates=False,
    )
    expire_res = ctx.run(
        ["snmpget", "-" + version, "-c", community, "-Oqv", host,
         COL_EXPIRE_OID + "." + index],
        mutates=False,
    )
    issuer_res = ctx.run(
        ["snmpget", "-" + version, "-c", community, "-Oqv", host,
         COL_ISSUER_OID + "." + index],
        mutates=False,
    )

    if start_res.rc != 0 or expire_res.rc != 0:
        return {"changed": False,
                "msg": "certificate %s data not available" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    start_date = strip_type_tag(start_res.stdout.strip())
    expire_date_raw = strip_type_tag(expire_res.stdout.strip())
    issuer_val = strip_type_tag(issuer_res.stdout.strip()) if issuer_res.rc == 0 else ""

    expire_epoch = parse_asn1_date(expire_date_raw)
    if expire_epoch == None:
        return {"changed": False,
                "msg": "could not parse expiration date for %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    now_res = ctx.run(["date", "+%s"], mutates=False)
    if now_res.rc != 0 or not now_res.stdout.strip().isdigit():
        now_epoch = to_epoch(0, 0, 0, 0, 0, 0)  # fallback (should not happen)
    else:
        now_epoch = int(now_res.stdout.strip())

    time_diff = expire_epoch - now_epoch

    # Grade: lower levels — CRIT if <= crit, WARN if <= warn.
    if time_diff <= crit_threshold:
        state = "CRIT"
    elif time_diff <= warn_threshold:
        state = "WARN"
    else:
        state = "OK"

    # Render the timespan in a human-friendly way.
    rendered = render_timespan(time_diff)
    msg = "Expiration in %s (issuer: %s)" % (rendered, issuer_val)

    return {"changed": False, "msg": msg,
            "data": {"state": state,
                     "metrics": {"certificate_expiration_time": time_diff},
                     "details": "Expires: %s, Issuer: %s" % (expire_date_raw, issuer_val)}}


# Render a number of seconds as a human-readable timespan.
def render_timespan(seconds):
    if seconds == None or seconds < 0:
        return "%d seconds" % seconds
    days = int(seconds // 86400)
    remainder = int(seconds % 86400)
    hours = int(remainder // 3600)
    remainder = int(remainder % 3600)
    mins = int(remainder // 60)
    secs = int(remainder % 60)
    parts = []
    if days > 0:
        parts.append("%d day%s" % (days, plural_s(days)))
    if hours > 0:
        parts.append("%d hour%s" % (hours, plural_s(hours)))
    if mins > 0:
        parts.append("%d minute%s" % (mins, plural_s(mins)))
    if secs > 0 or len(parts) == 0:
        parts.append("%d second%s" % (secs, plural_s(secs)))
    return ", ".join(parts)


def plural_s(n):
    return "s" if n != 1 else ""
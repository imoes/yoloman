def main(ctx, params):
    # Discovery mode: always yield one service with empty item
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {"signature_age": [86400, 604800]}, "metrics": []}]}
        }

    # Read the timestamp file
    paths = [
        "/var/lib/mcafee/av/sginstal.txt",
        "/var/lib/mcafee/av_client/sginstal.txt",
        "C:\\ProgramData\\McAfee\\AVEngine\\sginstal.txt"
    ]

    content = None
    for path in paths:
        if ctx.file_exists(path):
            content = ctx.file_read(path)
            break

    if content == None:
        return {
            "changed": False,
            "msg": "no McAfee signature timestamp file found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    lines = content.strip().splitlines()
    if len(lines) == 0 or not lines[0]:
        return {
            "changed": False,
            "msg": "invalid or empty signature timestamp file",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    date_str = lines[0].strip()
    # Validate format: YYYY/MM/DD
    if len(date_str) != 10 or date_str[4] != '/' or date_str[7] != '/':
        return {
            "changed": False,
            "msg": "invalid signature timestamp format: " + date_str,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    year_str = date_str[0:4]
    month_str = date_str[5:7]
    day_str = date_str[8:10]

    year = int(year_str) if year_str.isdigit() else 0
    month = int(month_str) if month_str.isdigit() else 0
    day = int(day_str) if day_str.isdigit() else 0

    if year == 0 or month == 0 or day == 0:
        return {
            "changed": False,
            "msg": "invalid signature timestamp numbers: " + date_str,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    if month < 1 or month > 12 or day < 1 or day > 31:
        return {
            "changed": False,
            "msg": "signature timestamp out of range: " + date_str,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Compute days since epoch (1970-01-01)
    def days_since_1970(y, m, d):
        y = y - 1
        days = (y - 1969) * 365 + (y // 4) - (y // 100) + (y // 400)
        days_in_months = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
        days += days_in_months[m - 1]
        # Leap year adjustment
        if m > 2 and ((y + 1) % 4 == 0 and ((y + 1) % 100 != 0 or (y + 1) % 400 == 0)):
            days += 1
        days += d - 1
        return days

    days = days_since_1970(year, month, day)
    timestamp = days * 86400

    # Get current time via external command
    res = ctx.run(["date", "+%s"], mutates=False)
    current_time_str = res.stdout.strip() if res.stdout else ""
    current_time = float(current_time_str) if current_time_str.replace(".", "").replace("-", "").isdigit() and current_time_str.count(".") <= 1 else 0.0

    age = current_time - timestamp

    # Apply thresholds
    signature_age = params.get("signature_age", [86400, 604800])
    warn = signature_age[0] if len(signature_age) > 0 else 86400
    crit = signature_age[1] if len(signature_age) > 1 else 604800

    # State logic (upper levels)
    if age >= crit:
        state = "CRIT"
    elif age >= warn:
        state = "WARN"
    else:
        state = "OK"

    # Format timespan
    def format_timespan(seconds):
        # Round to integer using int(x + 0.5) instead of round()
        seconds = int(seconds + 0.5)
        days = seconds // 86400
        hours = (seconds % 86400) // 3600
        minutes = (seconds % 3600) // 60
        secs = seconds % 60
        parts = []
        if days > 0:
            parts.append("%d d" % days)
        if hours > 0:
            parts.append("%d h" % hours)
        if minutes > 0 and days == 0:
            parts.append("%d m" % minutes)
        if secs > 0 and days == 0 and hours == 0:
            parts.append("%d s" % secs)
        if not parts:
            parts.append("0 s")
        return " ".join(parts)

    age_str = format_timespan(age)
    msg = "Time since last update of signatures: " + age_str

    metrics = {"age": age}

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }
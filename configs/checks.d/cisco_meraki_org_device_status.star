STATUS_MAP = {
    "online": 0,
    "alerting": 2,
    "offline": 1,
    "dormant": 1,
    "unknown": 3,
}

def main(ctx, params):
    # Discover mode: always yield one service (single-service check)
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 services",
            "data": {"discovery": [
                {"item": "", "params": {}, "metrics": ["last_reported"]}
            ]}
        }

    # Check mode: get device status for host
    api_key = params.get("api_key")
    if api_key == None or api_key == "":
        return {
            "changed": False,
            "msg": "api_key is required",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Use curl to fetch device status data
    curl_cmd = [
        "curl", "-s", "-S", "-f",
        "-H", "X-Cisco-Meraki-API-Key: %s" % api_key,
        "-H", "Content-Type: application/json",
        "-H", "Accept: application/json",
        "https://api.meraki.com/api/v1/devices/statuses"
    ]
    res = ctx.run(curl_cmd, mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "Could not fetch device status data from Meraki API",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    if not res.stdout:
        return {
            "changed": False,
            "msg": "No data received from Meraki API",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    data = json.decode(res.stdout)
    if type(data) != "list" or len(data) == 0:
        return {
            "changed": False,
            "msg": "Invalid response format from Meraki API",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    device_status = data[0]
    if type(device_status) != "dict":
        return {
            "changed": False,
            "msg": "Invalid device status format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    status = device_status.get("status", "unknown")
    last_reported = device_status.get("lastReportedAt", "")

    state_int = STATUS_MAP.get(status, 3)
    state_map = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}
    state = state_map.get(state_int, "UNKNOWN")

    summary = "Status: %s" % status

    metrics = {}
    details = ""
    if last_reported != "":
        if last_reported.endswith("Z") and len(last_reported) >= 20:
            ts_str = last_reported.rstrip("Z")
            parts = ts_str.split("T")
            if len(parts) == 2:
                date_part = parts[0]
                time_part = parts[1]
                date_parts = date_part.split("-")
                time_parts = time_part.split(":")
                if len(date_parts) == 3 and len(time_parts) >= 3:
                    date_y = int(date_parts[0]) if date_parts[0].isdigit() else 0
                    date_m = int(date_parts[1]) if date_parts[1].isdigit() else 0
                    date_d = int(date_parts[2]) if date_parts[2].isdigit() else 0
                    time_h = int(time_parts[0]) if time_parts[0].isdigit() else 0
                    time_min = int(time_parts[1]) if time_parts[1].isdigit() else 0
                    time_s_str = time_parts[2].split(".")[0]
                    time_s = int(time_s_str) if time_s_str.isdigit() else 0

                    # Calculate epoch seconds (approximate, UTC)
                    y = date_y - (1 if date_m <= 2 else 0)
                    era = y // 400
                    yoe = y - era * 400
                    doy = (153 * (date_m + (9 if date_m <= 2 else -3)) + 2) // 5 + date_d - 1
                    doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
                    days = era * 146097 + doe - 719469
                    epoch_sec = days * 86400 + time_h * 3600 + time_min * 60 + time_s

                    now_res = ctx.run(["date", "+%s"], mutates=False)
                    if now_res.stdout.strip().isdigit():
                        now = int(now_res.stdout.strip())
                        age = now - epoch_sec
                        if age < 0:
                            summary += ", Age: negative"
                        else:
                            if age < 60:
                                time_str = "%d s" % age
                            elif age < 3600:
                                time_str = "%d m" % (age // 60)
                            elif age < 86400:
                                time_str = "%d h" % (age // 3600)
                            else:
                                time_str = "%d d" % (age // 86400)
                            summary += ", Age: %s" % time_str
                        metrics["last_reported"] = age

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": details,
        },
    }
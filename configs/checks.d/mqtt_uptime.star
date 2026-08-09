def main(ctx, params):
    if params.get("_discover"):
        broker = params.get("broker", "localhost")
        port = params.get("port", 1883)
        # Probe for the real MQTT broker: is mosquitto (or similar) running?
        ps = ctx.run(["ps", "aux"], mutates=False)
        has_broker = False
        for line in ps.stdout.splitlines():
            low = line.lower()
            if "mosquitto" in low or "emqtt" in low or "rabbitmq" in low or "mqtt" in low:
                has_broker = True
                break
        # Also check if mosquitto binary exists
        bin_check = ctx.run(["sh", "-c", "command -v mosquitto mosquitto_sub emqtt_ctl 2>/dev/null"], mutates=False)
        if not has_broker and bin_check.rc == 127:
            return {"changed": False, "msg": "no MQTT broker or client found", "data": {"discovery": [], "host_labels": {}}}
        # Try to actually read $SYS/broker/version to confirm the broker is reachable and identify instance
        res = ctx.run(["mosquitto_sub", "-h", broker, "-p", str(port), "-t", "$SYS/broker/version", "-C", "1", "-W", "5"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no reachable MQTT broker", "data": {"discovery": []}}
        version = res.stdout.strip()
        if not version:
            return {"changed": False, "msg": "MQTT broker not providing $SYS topics", "data": {"discovery": []}}
        # Discover: one item per broker instance (use version string as identifier since it's a single broker)
        item = "broker"
        return {
            "changed": False,
            "msg": "discovered 1 MQTT broker instance",
            "data": {
                "discovery": [
                    {
                        "item": item,
                        "params": {},
                        "metrics": ["uptime"],
                        "service_labels": {"mqtt/version": version},
                    }
                ],
            },
        }

    item = params.get("item", "")
    broker = params.get("broker", "localhost")
    port = params.get("port", 1883)

    # Probe: is mosquitto_sub available?
    bin_check = ctx.run(["sh", "-c", "command -v mosquitto_sub"], mutates=False)
    if bin_check.rc == 127 or not bin_check.stdout.strip():
        return {"changed": False, "msg": "mosquitto_sub not installed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Read $SYS/broker/uptime from the real broker
    res = ctx.run(["mosquitto_sub", "-h", broker, "-p", str(port), "-t", "$SYS/broker/uptime", "-C", "1", "-W", "5"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to connect to MQTT broker " + broker + ":" + str(port), "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    raw_uptime = res.stdout.strip()
    if not raw_uptime:
        return {"changed": False, "msg": "MQTT broker not providing uptime", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse the uptime string into seconds (same logic as parse_uptime in source)
    uptime_seconds = _parse_uptime(raw_uptime)
    if uptime_seconds == 0:
        return {"changed": False, "msg": "could not parse MQTT broker uptime: " + raw_uptime, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # The uptime check itself has no warn/crit thresholds (params={}); report OK with metrics
    # Format uptime for display (delegate to uptime lib equivalent: days, hours, minutes, seconds)
    display = _render_uptime(uptime_seconds)
    return {
        "changed": False,
        "msg": display,
        "data": {
            "state": "OK",
            "metrics": {"uptime": uptime_seconds},
            "details": "MQTT broker uptime: " + display,
        },
    }


def _parse_uptime(value):
    if not value:
        return 0
    scales = {"days": 86400, "hours": 3600, "minutes": 60, "seconds": 1}
    parts = value.strip().split(" ")
    total = 0
    for i in range(0, len(parts), 2):
        if i + 1 >= len(parts):
            break
        num = parts[i]
        scale = parts[i + 1]
        if num.isdigit() and scale in scales:
            total = total + int(num) * scales[scale]
    return total


def _render_uptime(seconds):
    days = seconds / 86400
    hours = (seconds % 86400) / 3600
    minutes = (seconds % 3600) / 60
    secs = seconds % 60
    parts = []
    parts.append(str(int(days)) + " days")
    parts.append(str(int(hours)) + " hours")
    parts.append(str(int(minutes)) + " minutes")
    parts.append(str(int(secs)) + " seconds")
    return ", ".join(parts)
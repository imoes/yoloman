def main(ctx, params):
    host = params.get("host", "localhost")
    port = int(params.get("port", 8125))
    protocol = params.get("protocol", "udp")
    timeout = float(params.get("timeout", 1.0))
    metric = params["metric"]
    metric_type = params["metric_type"]
    metric_prefix = params.get("metric_prefix", "")
    value = int(params["value"])
    delta = bool(params.get("delta", False))
    state = params.get("state", "present")

    # Validate required fields
    if not metric:
        fail("metric is required")
    if metric_type not in ["counter", "gauge"]:
        fail("metric_type must be one of: counter, gauge")
    if protocol not in ["udp", "tcp"]:
        fail("protocol must be one of: udp, tcp")
    if state != "present":
        fail("state must be 'present'")

    # Build metric name with prefix
    metric_name = metric_prefix + "/" + metric if metric_prefix else metric

    # Build command line arguments for statsd-client
    cmd = ["statsd-client"]

    # Map options to command-line flags
    cmd.extend(["--host", str(host)])
    cmd.extend(["--port", str(port)])
    cmd.extend(["--protocol", protocol])
    cmd.extend(["--metric", metric])
    cmd.extend(["--metric-type", metric_type])
    cmd.extend(["--value", str(value)])

    if protocol == "tcp":
        cmd.extend(["--timeout", str(timeout)])

    if metric_prefix:
        cmd.extend(["--prefix", metric_prefix])

    if delta:
        cmd.extend(["--delta"])

    # Execute statsd-client
    res = ctx.run(cmd, mutates=True)
    if res.skipped:
        return {"changed": True, "msg": "would send metric " + metric_name + " (" + metric_type + ") to StatsD"}

    if res.rc != 0:
        fail("Failed sending to StatsD: " + res.stderr)

    # Determine display value
    if metric_type == "gauge":
        display_value = str(value) + " (delta=" + str(delta) + ")"
    else:
        display_value = str(value)

    return {"changed": True, "msg": "Sent " + metric_type + " " + metric_name + " -> " + str(display_value) + " to StatsD"}

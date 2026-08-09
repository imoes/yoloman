def main(ctx, params):
    if params.get("_discover"):
        # Probe for the real Datadog agent / logs source on the host.
        # The Datadog logs special agent writes a count of forwarded logs into
        # a cache file consumed by the Checkmk agent section. We look for the
        # Datadog log-forwarder (often `datadog-agent` or `forwarder`) to be
        # present, or its cache artifacts, rather than inventing a value.
        probed = False
        for tool in ["datadog-agent", "datadog-forwarder", "agent"]:
            res = ctx.run(["which", tool], mutates=False)
            if res.rc == 0:
                probed = True
                break
        if not probed:
            # No Datadog logs source on this host -> nothing to discover.
            return {"changed": False, "msg": "no Datadog logs source found",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": ["n_logs"]}]}}
    item = params.get("item", "")
    # Read the actual data the Datadog logs agent produces: a small cache file
    # with the count of forwarded logs. Probe existence of the real source.
    path = "/var/run/dd-forwarder/logs.count"
    if not ctx.file_exists(path):
        return {"changed": False,
                "msg": "no Datadog logs data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    text = ctx.file_read(path).strip()
    if text == "" or not text.isdigit():
        return {"changed": False,
                "msg": "Datadog logs data unreadable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    n_logs = int(text)
    plural = "" if n_logs == 1 else "s"
    summary = "Forwarded %d log%s to the Event Console" % (n_logs, plural)
    return {"changed": False, "msg": summary,
            "data": {"state": "OK", "metrics": {"n_logs": n_logs}, "details": ""}}
def main(ctx, params):
    state = params["state"]
    api_version = params.get("api_version", "v1")
    integration_key = params.get("integration_key")
    service_key = params.get("service_key")
    api_key = params.get("api_key")
    desc = params.get("desc", "Created via Ansible")
    incident_key = params.get("incident_key")
    client = params.get("client")
    client_url = params.get("client_url")
    source = params.get("source")
    component = params.get("component")
    incident_class = params.get("incident_class")
    link_url = params.get("link_url")
    link_text = params.get("link_text")
    severity = params.get("severity", "critical")
    custom_details = params.get("custom_details")

    # Validation
    if api_version != "v1" and api_version != "v2":
        fail("api_version must be 'v1' or 'v2'")
    if state != "triggered" and state != "acknowledged" and state != "resolved":
        fail("state must be one of: triggered, acknowledged, resolved")
    if state == "triggered" and api_version == "v2" and source == None:
        fail("source is required for api_version=v2 with state=triggered")

    # Handle deprecated service_key
    if integration_key == None and service_key != None:
        integration_key = service_key
    if api_version == "v1":
        if integration_key == None:
            fail("integration_key or service_key is required for api_version=v1")
        if api_key == None:
            fail("api_key is required for api_version=v1")

    # State to event_type mapping
    state_event_map = {
        "triggered": "trigger",
        "acknowledged": "acknowledge",
        "resolved": "resolve",
    }
    event_type = state_event_map[state]

    # Build payload for v2
    payload = {
        "summary": desc,
        "source": source,
        "severity": severity,
    }
    if component != None:
        payload["component"] = component
    if incident_class != None:
        payload["class"] = incident_class
    if custom_details != None:
        payload["custom_details"] = custom_details

    # Build link for v2
    link = {}
    if link_url != None:
        link["href"] = link_url
        if link_text != None:
            link["text"] = link_text

    # Check mode: predict if change is needed
    if ctx.check_mode:
        if state == "acknowledged" or state == "resolved":
            if incident_key == None:
                fail("incident_key is required for state " + state)
        return {"changed": True, "msg": "would %s incident" % event_type}

    # Perform the actual API call
    if api_version == "v1":
        # Use v1 endpoint: /generic/2010-04-15/create_event.json
        url = "https://events.pagerduty.com/generic/2010-04-15/create_event.json"
        payload_v1 = {
            "service_key": integration_key,
            "event_type": event_type,
            "incident_key": incident_key,
            "description": desc,
            "client": client,
            "client_url": client_url,
        }
        body = _dict_to_json(payload_v1)
        res = ctx.run(
            ["curl", "-s", "-X", "POST", "-H", "Content-Type: application/json",
             "-d", body, url],
            mutates=True
        )
        if res.rc != 0:
            fail("failed to %s incident (v1): %s" % (event_type, res.stderr))
        return {"changed": True, "msg": "%s incident (v1)" % event_type, "data": {"response": res.stdout}}

    else:  # v2
        url = "https://events.pagerduty.com/v2/enqueue"
        data_v2 = {
            "routing_key": integration_key,
            "event_action": event_type,
            "payload": payload,
        }
        if client != None:
            data_v2["client"] = client
        if client_url != None:
            data_v2["client_url"] = client_url
        if link != {}:
            data_v2["links"] = [link]
        if incident_key != None:
            data_v2["dedup_key"] = incident_key
        if event_type != "trigger":
            data_v2.pop("payload")
        body = _dict_to_json(data_v2)
        res = ctx.run(
            ["curl", "-s", "-X", "POST", "-H", "Content-Type: application/json",
             "-d", body, url],
            mutates=True
        )
        if res.rc != 0:
            fail("failed to %s incident (v2): %s" % (event_type, res.stderr))
        return {"changed": True, "msg": "%s incident (v2)" % event_type, "data": {"response": res.stdout}}


def _dict_to_json(d):
    items = []
    keys = sorted(d.keys())
    for i in range(len(keys)):
        k = keys[i]
        v = d[k]
        if v == None:
            continue
        if type(v) == "bool":
            items.append('"%s": %s' % (k, "true" if v else "false"))
        elif type(v) == "int":
            items.append('"%s": %s' % (k, str(v)))
        elif type(v) == "string":
            escaped = v.replace("\\", "\\\\").replace('"', '\\"')
            items.append('"%s": "%s"' % (k, escaped))
        elif type(v) == "dict":
            items.append('"%s": %s' % (k, _dict_to_json(v)))
        else:
            fail("unsupported type in JSON serialization")
    return "{" + ", ".join(items) + "}"

def main(ctx, params):
    key = params.get("key")
    event = params.get("event")
    if key == None:
        fail("key is required")
    if event == None:
        fail("event is required")
    if event not in ("deploy", "annotation"):
        fail("event must be 'deploy' or 'annotation'")

    # Validate required params per event type
    if event == "deploy":
        revision_id = params.get("revision_id")
        if revision_id == None:
            fail("revision_id is required for deploy events")
    elif event == "annotation":
        msg = params.get("msg")
        if msg == None:
            fail("msg is required for annotation events")

    # Build payload
    if event == "deploy":
        url = "https://event-gateway.stackdriver.com/v1/deployevent"
        deployed_by = params.get("deployed_by", "Ansible")
        deployed_to = params.get("deployed_to")
        repository = params.get("repository")
        payload = {"revision_id": params["revision_id"], "deployed_by": deployed_by}
        if deployed_to != None:
            payload["deployed_to"] = deployed_to
        if repository != None:
            payload["repository"] = repository
    else:  # annotation
        url = "https://event-gateway.stackdriver.com/v1/annotationevent"
        annotated_by = params.get("annotated_by", "Ansible")
        level = params.get("level", "INFO")
        instance_id = params.get("instance_id")
        event_epoch = params.get("event_epoch")
        payload = {"message": params["msg"], "annotated_by": annotated_by}
        if level != "INFO":
            payload["level"] = level
        if instance_id != None:
            payload["instance_id"] = instance_id
        if event_epoch != None:
            payload["event_epoch"] = event_epoch

    # In check_mode, just predict success without sending
    if ctx.check_mode:
        return {"changed": True, "msg": "would send " + event + " event to stackdriver"}

    # Build headers and send request
    headers = {
        "Content-Type": "application/json",
        "x-stackdriver-apikey": key
    }
    # Build JSON manually (no json module)
    def to_json(obj):
        items = []
        for k, v in obj.items():
            if type(v) == "string":
                # Escape quotes and backslashes
                esc = v.replace("\\", "\\\\").replace('"', '\\"')
                items.append('"' + k + '": "' + esc + '"')
            elif type(v) == "int":
                items.append('"' + k + '": ' + str(v))
            else:
                items.append('"' + k + '": ' + str(v))
        return "{" + ", ".join(items) + "}"
    data = to_json(payload)

    # Use ctx.run with curl
    res = ctx.run([
        "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
        "-X", "POST",
        "-H", "Content-Type: application/json",
        "-H", "x-stackdriver-apikey: " + key,
        "-d", data,
        url
    ])
    if res.rc != 0:
        fail("failed to send " + event + " event: curl failed with rc=" + str(res.rc))
    if res.stdout.strip() != "200":
        fail("failed to send " + event + " event: unexpected HTTP status " + res.stdout.strip())

    return {"changed": True, "msg": "sent " + event + " event to stackdriver"}

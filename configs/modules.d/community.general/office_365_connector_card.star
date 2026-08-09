def main(ctx, params):
    webhook = params["webhook"]
    summary = params.get("summary")
    color = params.get("color")
    title = params.get("title")
    text = params.get("text")
    actions = params.get("actions")
    sections = params.get("sections")

    # Validate required fields: summary or text must be present
    if summary == None and text == None:
        fail("Summary or Text is required.")

    # Build payload manually (no snake_dict_to_camel_dict available in Starlark)
    # Start with required context and type
    payload = {
        "@context": "http://schema.org/extensions",
        "@type": "MessageCard"
    }

    if summary != None:
        payload["summary"] = summary
    if color != None:
        payload["themeColor"] = color
    if title != None:
        payload["title"] = title
    if text != None:
        payload["text"] = text

    # Process actions
    if actions != None:
        action_items = []
        for action in actions:
            action_item = {}
            for key in action:
                # Convert snake_case to camelCase: "key_name" -> "keyName"
                parts = key.split("_")
                if len(parts) > 1:
                    camel = parts[0] + "".join([p.capitalize() for p in parts[1:]])
                else:
                    camel = key
                action_item[camel] = action[key]
            action_items.append(action_item)
        payload["potentialAction"] = action_items

    # Process sections
    if sections != None:
        sections_created = []
        for section in sections:
            section_payload = {}
            for key in section:
                parts = key.split("_")
                if len(parts) > 1:
                    camel = parts[0] + "".join([p.capitalize() for p in parts[1:]])
                else:
                    camel = key
                section_payload[camel] = section[key]
            sections_created.append(section_payload)
        payload["sections"] = sections_created

    # Build JSON string manually (no jsonify available)
    # Simple JSON builder — sufficient for this module's known structure
    def to_json(obj):
        if type(obj) == "dict":
            pairs = []
            for key in sorted(obj.keys()):
                val = to_json(obj[key])
                pairs.append('"%s": %s' % (key, val))
            return "{" + ", ".join(pairs) + "}"
        elif type(obj) == "list":
            items = [to_json(x) for x in obj]
            return "[" + ", ".join(items) + "]"
        elif type(obj) == "bool":
            return "true" if obj else "false"
        elif type(obj) == "int" or type(obj) == "float":
            return str(obj)
        elif type(obj) == "string":
            # Escape quotes and backslashes for JSON string
            escaped = obj.replace("\\", "\\\\").replace('"', '\\"')
            return '"' + escaped + '"'
        elif obj == None:
            return "null"
        else:
            fail("Unsupported JSON type: " + type(obj))

    payload_json = to_json(payload)

    # In check_mode: send minimal payload to validate webhook connectivity
    if ctx.check_mode:
        # Build minimal payload (only context and type)
        minimal = to_json({
            "@context": "http://schema.org/extensions",
            "@type": "MessageCard"
        })
        res = ctx.run(
            ["curl", "-s", "-X", "POST", "-H", "Content-Type: application/json",
             "-d", minimal, webhook],
            mutates=False,
            ok_codes=[0, 200, 400]
        )
        if res.rc != 0:
            fail("The Incoming Webhook was not reachable: " + res.stderr)
        # For check_mode, always report change as True (module is not idempotent)
        return {"changed": True, "msg": "Connector card would be sent"}

    # Perform actual request
    res = ctx.run(
        ["curl", "-s", "-X", "POST", "-H", "Content-Type: application/json",
         "-d", payload_json, webhook],
        mutates=True,
        ok_codes=[0, 200]
    )
    if res.rc != 0:
        fail("Failed to send connector card: " + res.stderr)

    return {"changed": True, "msg": "Connector card sent"}

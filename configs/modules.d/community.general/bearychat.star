def main(ctx, params):
    url = params["url"]
    text = params.get("text")
    markdown = params.get("markdown", True)
    channel = params.get("channel")
    attachments = params.get("attachments")

    # Build payload dict
    payload = {}
    if text != None:
        payload["text"] = text
    payload["markdown"] = markdown
    if channel != None:
        payload["channel"] = channel
    if attachments != None:
        payload.setdefault("attachments", [])
        i = 0
        while i < len(attachments):
            item = attachments[i]
            title = item.get("title")
            item_text = item.get("text")
            color = item.get("color")
            images = item.get("images")
            attachment = {}
            if title != None:
                attachment["title"] = title
            if item_text != None:
                attachment["text"] = item_text
            if color != None:
                attachment["color"] = color
            if images != None:
                target_images = attachment.setdefault("images", [])
                if type(images) != "list":
                    images = [images]
                j = 0
                while j < len(images):
                    img = images[j]
                    if type(img) == "dict" and "url" in img:
                        img = {"url": img["url"]}
                    elif type(img) == "string" and img.startswith("http"):
                        img = {"url": img}
                    else:
                        fail("BearyChat doesn't have support for this kind of attachment image")
                    target_images.append(img)
                    j = j + 1
            payload["attachments"].append(attachment)
            i = i + 1

    # Serialize payload to JSON-like string manually
    def to_json(obj):
        if type(obj) == "dict":
            items = []
            keys = []
            for k in obj:
                keys.append(k)
            i = 0
            while i < len(keys):
                k = keys[i]
                items.append('"%s":%s' % (k, to_json(obj[k])))
                i = i + 1
            return "{" + ",".join(items) + "}"
        elif type(obj) == "list":
            items = []
            i = 0
            while i < len(obj):
                items.append(to_json(obj[i]))
                i = i + 1
            return "[" + ",".join(items) + "]"
        elif type(obj) == "bool":
            if obj:
                return "true"
            else:
                return "false"
        elif type(obj) == "int" or type(obj) == "float":
            return str(obj)
        elif type(obj) == "string":
            # Escape basic JSON chars
            escaped = obj.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
            return '"' + escaped + '"'
        elif obj == None:
            return "null"
        else:
            fail("unsupported type for JSON serialization: %s" % type(obj))

    payload_json = to_json(payload)
    data = "payload=%s" % payload_json

    # Send the HTTP POST request
    res = ctx.run(
        ["curl", "-s", "-S", "-X", "POST", "-d", data, "-H", "Content-Type: application/x-www-form-urlencoded", url],
        mutates=True
    )

    if res.skipped:
        return {"changed": True, "msg": "would send notification"}

    if res.rc != 0:
        fail("failed to send notification to BearyChat: " + res.stderr)

    # BearyChat returns 200 on success
    # Since we don't have direct status code, we assume success if curl rc==0 and stderr empty
    if res.stderr.strip():
        fail("BearyChat responded with error: " + res.stderr)

    return {"changed": True, "msg": "OK"}

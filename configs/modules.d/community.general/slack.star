def main(ctx, params):
    token = params["token"]
    msg = params.get("msg")
    channel = params.get("channel")
    thread_id = params.get("thread_id")
    username = params.get("username", "Ansible")
    icon_url = params.get("icon_url", "https://docs.ansible.com/favicon.ico")
    icon_emoji = params.get("icon_emoji")
    link_names = params.get("link_names", 1)
    parse = params.get("parse")
    color = params.get("color", "normal")
    attachments = params.get("attachments")
    blocks = params.get("blocks")
    message_id = params.get("message_id")
    prepend_hash = params.get("prepend_hash", "auto")
    domain = params.get("domain")
    validate_certs = params.get("validate_certs", True)

    color_choices = ["normal", "good", "warning", "danger"]
    is_valid_hex = False
    if color.startswith("#") and (len(color) == 4 or len(color) == 7):
        valid_chars = True
        for c in color[1:]:
            if c not in "0123456789abcdefABCDEF":
                valid_chars = False
                break
        is_valid_hex = valid_chars
    if color not in color_choices and not is_valid_hex:
        fail("Color value specified should be either one of 'normal', 'good', 'warning', 'danger' or any valid hex value with length 3 or 6.")

    def escape_quotes(text):
        if text == None:
            return ""
        result = ""
        for c in text:
            if c == '"':
                result = result + "\\\""
            elif c == "'":
                result = result + "\\'"
            else:
                result = result + c
        return result

    def recursive_escape(obj, keys):
        if type(obj) == "dict":
            escaped = {}
            for key in obj.keys():
                v = obj.get(key)
                if type(v) == "string" and key in keys:
                    escaped[key] = escape_quotes(v)
                else:
                    escaped[key] = recursive_escape(v, keys)
            return escaped
        elif type(obj) == "list":
            result = []
            for item in obj:
                result.append(recursive_escape(item, keys))
            return result
        else:
            return obj

    payload = {}
    if color == "normal" and msg != None:
        payload["text"] = escape_quotes(msg)
    elif msg != None:
        payload["attachments"] = [{"text": escape_quotes(msg), "color": color, "mrkdwn_in": ["text"]}]

    if channel != None:
        if prepend_hash == "auto":
            if channel.startswith("#") or channel.startswith("@") or channel.startswith("C0") or channel.startswith("GF") or channel.startswith("G0") or channel.startswith("CP"):
                payload["channel"] = channel
            else:
                payload["channel"] = "#" + channel
        elif prepend_hash == "always":
            payload["channel"] = "#" + channel
        elif prepend_hash == "never":
            payload["channel"] = channel

    if thread_id != None:
        payload["thread_ts"] = thread_id
    if username != None:
        payload["username"] = username
    if icon_emoji != None:
        payload["icon_emoji"] = icon_emoji
    else:
        payload["icon_url"] = icon_url
    if link_names != None:
        payload["link_names"] = link_names
    if parse != None:
        payload["parse"] = parse
    if message_id != None:
        payload["ts"] = message_id

    if attachments != None:
        if "attachments" not in payload:
            payload["attachments"] = []
        attachment_keys_to_escape = ["title", "text", "author_name", "pretext", "fallback"]
        for attachment in attachments:
            att = dict(attachment)
            for key in attachment_keys_to_escape:
                if key in att and type(att.get(key)) == "string":
                    att[key] = escape_quotes(att[key])
            if "fallback" not in att:
                fallback_text = att.get("text", "")
                att["fallback"] = fallback_text
            payload["attachments"].append(att)

    if blocks != None:
        block_keys_to_escape = ["text", "alt_text"]
        payload["blocks"] = recursive_escape(blocks, block_keys_to_escape)

    use_webapi = False
    if token.count("/") >= 2:
        slack_uri = "https://hooks.slack.com/services/%s" % token
    elif token.startswith("xoxp-") or token.startswith("xoxb-") or token.startswith("xoxa-"):
        slack_uri = "https://slack.com/api/chat.update" if message_id != None else "https://slack.com/api/chat.postMessage"
        use_webapi = True
    else:
        if domain == None:
            fail("Slack has updated its webhook API. You need to specify a token of the form XXXX/YYYY/ZZZZ in your playbook")
        slack_uri = "https://%s/services/hooks/incoming-webhook?token=%s" % (domain, token)

    headers = [
        "Content-Type: application/json; charset=UTF-8",
        "Accept: application/json"
    ]
    if use_webapi:
        headers.append("Authorization: Bearer " + token)

    # Convert payload dict to JSON manually
    def dict_to_json(d):
        items = []
        for k in d.keys():
            v = d.get(k)
            if type(v) == "string":
                json_v = '"' + v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t") + '"'
            elif type(v) == "dict":
                json_v = dict_to_json(v)
            elif type(v) == "list":
                json_v = list_to_json(v)
            elif type(v) == "int":
                json_v = str(v)
            elif type(v) == "bool":
                json_v = "true" if v else "false"
            elif v == None:
                json_v = "null"
            else:
                json_v = '"' + str(v) + '"'
            items.append('"' + k + '":' + json_v)
        return "{" + ",".join(items) + "}"

    def list_to_json(lst):
        items = []
        for item in lst:
            if type(item) == "string":
                json_item = '"' + item.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t") + '"'
            elif type(item) == "dict":
                json_item = dict_to_json(item)
            elif type(item) == "list":
                json_item = list_to_json(item)
            elif type(item) == "int":
                json_item = str(item)
            elif type(item) == "bool":
                json_item = "true" if item else "false"
            elif item == None:
                json_item = "null"
            else:
                json_item = '"' + str(item) + '"'
            items.append(json_item)
        return "[" + ",".join(items) + "]"

    json_data = dict_to_json(payload)

    if ctx.check_mode:
        changed = True
        if message_id != None:
            fail("message_id with check_mode is not supported; unable to compare existing message")
        return {"changed": changed, "msg": "would send Slack notification"}

    # Build curl command args manually
    curl_args = ["curl", "-s", "-X", "POST"]
    for h in headers:
        curl_args.extend(["-H", h])
    curl_args.extend(["-d", json_data, slack_uri])

    res = ctx.run(curl_args, mutates=True)
    if res.rc != 0:
        fail("failed to send Slack notification: " + res.stderr)

    if use_webapi:
        resp = res.stdout.strip()
        if resp == "":
            fail("empty response from Slack API")
        
        ts_val = ""
        channel_val = ""
        ok_val = False
        error_val = ""
        
        # Very simple JSON parser for expected responses
        if '"ts"' in resp:
            # Expected response format: {"ok":true,"channel":"...","ts":"..."}
            if '"ok":true' in resp or '"ok": true' in resp:
                ok_val = True
                # Extract ts
                idx = resp.find('"ts"')
                if idx >= 0:
                    colon_idx = resp.find(":", idx)
                    if colon_idx >= 0:
                        start = resp.find('"', colon_idx + 1)
                        end = resp.find('"', start + 1)
                        if start >= 0 and end > start:
                            ts_val = resp[start + 1:end]
                # Extract channel
                idx = resp.find('"channel"')
                if idx >= 0:
                    colon_idx = resp.find(":", idx)
                    if colon_idx >= 0:
                        start = resp.find('"', colon_idx + 1)
                        end = resp.find('"', start + 1)
                        if start >= 0 and end > start:
                            channel_val = resp[start + 1:end]
            elif '"ok":false' in resp or '"ok": false' in resp:
                # Extract error
                idx = resp.find('"error"')
                if idx >= 0:
                    colon_idx = resp.find(":", idx)
                    if colon_idx >= 0:
                        start = resp.find('"', colon_idx + 1)
                        end = resp.find('"', start + 1)
                        if start >= 0 and end > start:
                            error_val = resp[start + 1:end]
                fail("Slack API error: " + error_val)
            else:
                fail("could not determine ok status from response")
            
            if ok_val:
                return {
                    "changed": True,
                    "msg": "OK",
                    "ts": ts_val,
                    "channel": channel_val,
                    "api": {"ok": True}
                }
            else:
                fail("Slack API error: unknown error")
        else:
            fail("unexpected Slack API response format")
    else:
        return {"changed": True, "msg": "OK"}

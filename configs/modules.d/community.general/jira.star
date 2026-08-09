def main(ctx, params):
    # Extract required and optional parameters
    uri = params["uri"].rstrip("/")
    operation = params["operation"]
    username = params.get("username")
    password = params.get("password")
    token = params.get("token")
    timeout = float(params.get("timeout", 10))
    validate_certs = params.get("validate_certs", True)

    # Mutually exclusive auth checks
    if token != None and (username != None or password != None):
        fail("token is mutually exclusive with username and password")
    if username == None and token == None:
        fail("one of username or token must be provided")

    # Construct base URL
    restbase = uri + "/rest/api/2"

    # Helper to build auth header
    def auth_header():
        if token != None:
            return {"Authorization": "Bearer " + token}
        else:
            auth_raw = username + ":" + password
            # encode base64 manually (no stdlib)
            alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
            padded = auth_raw + "=" * ((3 - len(auth_raw) % 3) % 3)
            result = ""
            for i in range(0, len(padded), 4):
                chunk = padded[i:i+4]
                b1 = ord(chunk[0]) if len(chunk) > 0 else 0
                b2 = ord(chunk[1]) if len(chunk) > 1 else 0
                b3 = ord(chunk[2]) if len(chunk) > 2 else 0
                b4 = ord(chunk[3]) if len(chunk) > 3 else 0
                i1 = (b1 & 0xFC) >> 2
                i2 = ((b1 & 0x03) << 4) | ((b2 & 0xF0) >> 4)
                i3 = ((b2 & 0x0F) << 2) | ((b3 & 0xC0) >> 6)
                i4 = b3 & 0x3F
                if i == len(padded) - 4 and len(auth_raw) % 3 == 1:
                    result += alphabet[i1] + alphabet[i2] + "=="
                elif i == len(padded) - 4 and len(auth_raw) % 3 == 2:
                    result += alphabet[i1] + alphabet[i2] + alphabet[i3] + "="
                else:
                    result += alphabet[i1] + alphabet[i2] + alphabet[i3] + alphabet[i4]
            return {"Authorization": "Basic " + result}

    # Helper for HTTP requests
    def do_request(method, url, data=None, content_type="application/json", extra_headers=None):
        headers = {"Content-Type": content_type}
        headers.update(auth_header())
        if extra_headers:
            headers.update(extra_headers)
        json_data = json.dumps(data) if data and content_type == "application/json" else None
        args = ["curl", "-sSf", "-X", method, "-H", "Content-Type: " + content_type]
        for k, v in headers.items():
            args.extend(["-H", k + ": " + v])
        if validate_certs:
            args.append("-k")
        if json_data:
            args.extend(["-d", json_data])
        args.append(url)
        res = ctx.run(args, mutates=(method != "GET"))
        if res.skipped:
            return None  # check_mode predicted
        if res.rc != 0:
            fail("curl failed: " + res.stderr)
        body = res.stdout.strip()
        if not body:
            return {}
        # simple JSON parse
        return json.loads(body)

    # Handle specific operations
    if operation == "create":
        if not params.get("project") or not params.get("issuetype") or not params.get("summary"):
            fail("operation create requires project, issuetype, and summary")
        createfields = {
            "project": {"key": params["project"]},
            "summary": params["summary"],
            "issuetype": {"name": params["issuetype"]}
        }
        if params.get("description"):
            createfields["description"] = params["description"]
        fields = params.get("fields", {})
        # merge at top level
        for k, v in fields.items():
            createfields[k] = v
        data = {"fields": createfields}
        result = do_request("POST", restbase + "/issue/", data)
        if result == None:
            return {"changed": True, "msg": "would create issue", "data": {}}
        return {"changed": True, "msg": "created issue " + result.get("key", ""), "data": result}

    if operation == "comment":
        if not params.get("issue") or not params.get("comment"):
            fail("operation comment requires issue and comment")
        data = {"body": params["comment"]}
        if params.get("comment_visibility"):
            data["visibility"] = params["comment_visibility"]
        if params.get("fields"):
            data.update(params["fields"])
        result = do_request("POST", restbase + "/issue/" + params["issue"] + "/comment", data)
        if result == None:
            return {"changed": True, "msg": "would add comment to " + params["issue"], "data": {}}
        return {"changed": True, "msg": "added comment to " + params["issue"], "data": result}

    if operation == "worklog":
        if not params.get("issue") or not params.get("comment"):
            fail("operation worklog requires issue and comment")
        data = {"comment": params["comment"]}
        if params.get("comment_visibility"):
            data["visibility"] = params["comment_visibility"]
        if params.get("fields"):
            data.update(params["fields"])
        result = do_request("POST", restbase + "/issue/" + params["issue"] + "/worklog", data)
        if result == None:
            return {"changed": True, "msg": "would add worklog to " + params["issue"], "data": {}}
        return {"changed": True, "msg": "added worklog to " + params["issue"], "data": result}

    if operation == "edit":
        if not params.get("issue"):
            fail("operation edit requires issue")
        if not params.get("fields"):
            fail("operation edit requires fields")
        data = {"fields": params["fields"]}
        result = do_request("PUT", restbase + "/issue/" + params["issue"], data)
        if result == None:
            return {"changed": True, "msg": "would edit issue " + params["issue"], "data": {}}
        return {"changed": True, "msg": "edited issue " + params["issue"], "data": result}

    if operation == "update":
        if not params.get("issue"):
            fail("operation update requires issue")
        if not params.get("fields"):
            fail("operation update requires fields")
        data = {"update": params["fields"]}
        result = do_request("PUT", restbase + "/issue/" + params["issue"], data)
        if result == None:
            return {"changed": True, "msg": "would update issue " + params["issue"], "data": {}}
        return {"changed": True, "msg": "updated issue " + params["issue"], "data": result}

    if operation == "fetch":
        if not params.get("issue"):
            fail("operation fetch requires issue")
        result = do_request("GET", restbase + "/issue/" + params["issue"])
        return {"changed": False, "msg": "fetched issue " + params["issue"], "data": result}

    if operation == "search":
        if not params.get("jql"):
            fail("operation search requires jql")
        jql = params["jql"]
        url = restbase + "/search?jql=" + jql.replace(" ", "%20")
        if params.get("fields"):
            fields_list = list(params["fields"].keys())
            url += "&fields=" + "&fields=".join([f.replace(" ", "%20") for f in fields_list])
        if params.get("maxresults") != None:
            url += "&maxResults=" + str(params["maxresults"])
        result = do_request("GET", url)
        return {"changed": False, "msg": "searched issues", "data": result}

    if operation == "transition":
        if not params.get("issue") or not params.get("status"):
            fail("operation transition requires issue and status")
        # Get transitions
        tmeta = do_request("GET", restbase + "/issue/" + params["issue"] + "/transitions")
        tid = None
        target = params["status"]
        for t in tmeta.get("transitions", []):
            if t.get("name") == target:
                tid = t.get("id")
                break
        if tid == None:
            fail("failed to find transition for status: " + target)
        fields = dict(params.get("fields", {}))
        if params.get("summary") != None:
            fields["summary"] = params["summary"]
        if params.get("description") != None:
            fields["description"] = params["description"]
        data = {"transition": {"id": tid}, "fields": fields}
        if params.get("comment"):
            data["update"] = {"comment": [{"add": {"body": params["comment"]}}]}
        result = do_request("POST", restbase + "/issue/" + params["issue"] + "/transitions", data)
        if result == None:
            return {"changed": True, "msg": "would perform transition to " + target, "data": {}}
        return {"changed": True, "msg": "performed transition to " + target, "data": result}

    if operation == "link":
        if not params.get("linktype") or not params.get("inwardissue") or not params.get("outwardissue"):
            fail("operation link requires linktype, inwardissue, and outwardissue")
        data = {
            "type": {"name": params["linktype"]},
            "inwardIssue": {"key": params["inwardissue"]},
            "outwardIssue": {"key": params["outwardissue"]}
        }
        result = do_request("POST", restbase + "/issueLink/", data)
        if result == None:
            return {"changed": True, "msg": "would create issue link", "data": {}}
        return {"changed": True, "msg": "created issue link", "data": result}

    if operation == "attach":
        if not params.get("issue") or not params.get("attachment"):
            fail("operation attach requires issue and attachment")
        attachment = params["attachment"]
        filename = attachment.get("filename")
        content = attachment.get("content")
        if not filename and not content:
            fail("attachment requires at least one of filename or content")
        # Load content from file if not provided
        if content == None and filename:
            content = ctx.file_read(filename).strip()
        if content == None:
            fail("could not read file: " + filename)
        # Detect mime type
        mime = attachment.get("mimetype")
        if not mime:
            # Simple heuristics — no stdlib
            if filename.endswith(".pdf"):
                mime = "application/pdf"
            elif filename.endswith(".txt"):
                mime = "text/plain"
            elif filename.endswith((".png", ".jpg", ".jpeg", ".gif")):
                mime = "image/" + filename.rsplit(".", 1)[1]
            elif filename.endswith(".csv"):
                mime = "text/csv"
            else:
                mime = "application/octet-stream"
        # Build multipart manually
        boundary = "".join(["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9"])
        name = filename if filename else "attachment.bin"
        lines = [
            "--" + boundary,
            "Content-Disposition: form-data; name=\"file\"; filename=\"" + name + "\"",
            "Content-Type: " + mime,
            "",
            content,
            "--" + boundary + "--",
            ""
        ]
        multipart_data = "\r\n".join(lines)
        content_type = "multipart/form-data; boundary=" + boundary
        headers = {"X-Atlassian-Token": "no-check"}
        result = do_request("POST", restbase + "/issue/" + params["issue"] + "/attachments", None, content_type, headers)
        if result == None:
            return {"changed": True, "msg": "would attach " + name, "data": {}}
        return {"changed": True, "msg": "attached " + name, "data": result}

    fail("unsupported operation: " + operation)

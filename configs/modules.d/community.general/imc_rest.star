def main(ctx, params):
    hostname = params["hostname"]
    username = params.get("username", "admin")
    password = params.get("password", "password")
    content = params.get("content")
    path = params.get("path")
    protocol = params.get("protocol", "https")
    timeout = params.get("timeout", 60)
    validate_certs = params.get("validate_certs", True)

    # Mutual exclusion check
    if content != None and path != None:
        fail("content and path are mutually exclusive")
    if content == None and path == None:
        fail("one of content or path is required")

    # Read content from path if provided
    if content == None:
        if not ctx.file_exists(path):
            fail("Cannot find/access path: " + path)
        content = ctx.file_read(path)

    # Build base URL
    url = protocol + "://" + hostname + "/nuova"

    # Login
    login_data = "<aaaLogin inName=\"" + username + "\" inPassword=\"" + password + "\"/>"
    res = ctx.run(["curl", "-s", "-k", "-X", "POST", "-d", login_data, url],
                  mutates=False)
    if res.rc != 0:
        fail("Login failed: " + res.stderr)

    # Parse login response to extract cookie
    login_xml = res.stdout.strip()
    cookie_start = login_xml.find('outCookie="')
    if cookie_start == -1:
        fail("Could not find cookie in login response")
    cookie_start += len('outCookie="')
    cookie_end = login_xml.find('"', cookie_start)
    if cookie_end == -1:
        fail("Could not find cookie in login response")
    cookie = login_xml[cookie_start:cookie_end]

    # Prepare XML fragments
    wrapped = "<root>" + content.replace("\n", "") + "</root>"

    # Parse XML fragments manually
    fragments = []
    i = 0
    while i < len(wrapped):
        start_tag = wrapped.find('<', i)
        if start_tag == -1:
            break
        end_tag = wrapped.find('>', start_tag)
        if end_tag == -1:
            break
        tag_end = wrapped.find('/>', start_tag)
        if tag_end == -1:
            tag_end = wrapped.find('</', start_tag)
        if tag_end == -1:
            tag_end = end_tag + 1
        else:
            if tag_end < end_tag:
                tag_end = end_tag + 1
        fragment = wrapped[start_tag:tag_end]
        # Skip comments
        if not fragment.startswith("<!--"):
            fragments.append(fragment)
        i = tag_end

    result = {"changed": False, "elapsed": 0, "response": "", "status": 200}

    # Process fragments
    for fragment in fragments:
        if fragment.startswith("<!--"):
            continue

        # Inject cookie
        if "cookie=" not in fragment:
            # Find the first tag opening and add cookie attribute
            first_bracket = fragment.find('<')
            if first_bracket != -1:
                second_space = fragment.find(' ', first_bracket + 1)
                if second_space == -1:
                    second_space = first_bracket + 1
                # Insert cookie before first attribute or before closing
                if fragment.find('/>', second_space) != -1:
                    # Self-closing tag
                    insert_pos = fragment.find('/>', second_space)
                    fragment = fragment[:insert_pos] + " cookie=\"" + cookie + "\"" + fragment[insert_pos:]
                else:
                    insert_pos = fragment.find('>', second_space)
                    fragment = fragment[:insert_pos] + " cookie=\"" + cookie + "\"" + fragment[insert_pos:]

        # Perform request
        res = ctx.run(["curl", "-s", "-k", "-X", "POST", "-d", fragment, url],
                      mutates=True)
        if res.skipped:
            # Check mode prediction
            return {"changed": True, "msg": "would send IMC request", "elapsed": 0, "response": "OK", "status": 200}

        if res.rc != 0:
            fail("IMC request failed: " + res.stderr)

        # Parse response
        xml_out = res.stdout.strip()

        # Extract status for changes detection
        if "<configConfMo>" in xml_out:
            if "status=\"modified\"" in xml_out:
                result["changed"] = True

        # Extract error info if present
        if "errorCode=" in xml_out:
            err_code_start = xml_out.find("errorCode=\"") + len("errorCode=\"")
            err_code_end = xml_out.find("\"", err_code_start)
            err_code = xml_out[err_code_start:err_code_end] if err_code_end > err_code_start else ""
            err_desc_start = xml_out.find("errorDescr=\"") + len("errorDescr=\"")
            err_desc_end = xml_out.find("\"", err_desc_start)
            err_desc = xml_out[err_desc_start:err_desc_end] if err_desc_end > err_desc_start else ""
            fail("Request failed: " + err_desc + " (Code: " + err_code + ")")

        # Update result metadata
        result["response"] = "OK"
        result["status"] = 200

    # Calculate elapsed time (simplified: use 0 since ctx has no timestamp support)
    result["elapsed"] = 0

    if result["changed"]:
        return {"changed": True, "msg": "IMC configuration changed", "elapsed": result["elapsed"], "response": result["response"], "status": result["status"]}
    else:
        return {"changed": False, "msg": "IMC configuration unchanged", "elapsed": result["elapsed"], "response": result["response"], "status": result["status"]}

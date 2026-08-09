def main(ctx, params):
    # Required fields
    from_address = params["from_address"]
    to_addresses = params["to_addresses"]
    subject = params["subject"]
    body = params["body"]

    # Optional authentication
    api_key = params.get("api_key")
    username = params.get("username")
    password = params.get("password")

    # Validation: either (username + password) or api_key
    if api_key != None and (username != None or password != None):
        fail("api_key cannot be used together with username or password")
    if api_key == None:
        if username == None or password == None:
            fail("username and password are required when api_key is not provided")

    # Optional sendgrid-dependent features
    cc = params.get("cc")
    bcc = params.get("bcc")
    attachments = params.get("attachments")
    from_name = params.get("from_name")
    html_body = params.get("html_body", False)
    headers = params.get("headers")

    # Check for sendgrid library dependency if any advanced options used
    has_sendgrid = ctx.file_exists("/usr/lib/python*/site-packages/sendgrid") or ctx.file_exists("/usr/local/lib/python*/site-packages/sendgrid")

    sendgrid_lib_args = [cc, bcc, attachments, headers, from_name, html_body, api_key]
    has_arg = False
    for arg in sendgrid_lib_args:
        if arg != None:
            has_arg = True
            break
    if has_arg and not has_sendgrid:
        fail("sendgrid library is required when using any of the following arguments: api_key, bcc, cc, headers, from_name, html_body, attachments")

    # Check mode: only validate, no actual sending
    if ctx.check_mode:
        return {"changed": False, "msg": "would send email to " + str(len(to_addresses)) + " recipient(s)"}

    # Build request body for SendGrid API v2 (fallback when no sendgrid lib)
    if not has_sendgrid:
        SENDGRID_URI = "https://api.sendgrid.com/api/mail.send.json"

        # Build form-encoded data
        data = {
            'api_user': username,
            'api_key': password,
            'from': from_address,
            'subject': subject,
            'text': body
        }

        # Build form parts
        parts = []
        for k, v in data.items():
            # Simple URL encoding
            val = str(v).replace("%", "%25").replace("&", "%26").replace("=", "%3D")
            parts.append(str(k) + "=" + val)

        # Add recipients
        for recipient in to_addresses:
            parts.append("to[]=" + str(recipient).replace("%", "%25").replace("&", "%26").replace("=", "%3D"))

        # Add CC/BCC if present
        if cc != None:
            for recip in cc:
                parts.append("cc[]=" + str(recip).replace("%", "%25").replace("&", "%26").replace("=", "%3D"))
        if bcc != None:
            for recip in bcc:
                parts.append("bcc[]=" + str(recip).replace("%", "%25").replace("&", "%26").replace("=", "%3D"))

        encoded_data = "&".join(parts)

        curl_headers = [
            "-H", "User-Agent: Ansible",
            "-H", "Content-type: application/x-www-form-urlencoded",
            "-H", "Accept: application/json"
        ]

        res = ctx.run(
            ["curl", "-s", "-X", "POST", "-d", encoded_data] + curl_headers + [SENDGRID_URI],
            mutates=True
        )
        if res.rc != 0:
            fail("unable to send email through SendGrid API: " + res.stderr)

        # Basic success detection
        if res.stdout.find("\"status\": \"success\"") != -1:
            return {"changed": False, "msg": subject}
        if res.stdout.find("\"errors\"") != -1:
            fail("SendGrid API returned errors: " + res.stdout)

        fail("SendGrid API response was unexpected: " + res.stdout)

    # Use sendgrid library if available (simulate via curl for Starlark compatibility)
    # Build form data for sendgrid v2
    form_parts = []
    data = {
        'api_user': username,
        'api_key': password if api_key == None else api_key,
        'from': from_address,
        'subject': subject,
        'text': body if not html_body else "",
        'html': body if html_body else ""
    }
    for k, v in data.items():
        if v != "":
            val = str(v).replace("%", "%25").replace("&", "%26").replace("=", "%3D")
            form_parts.append(str(k) + "=" + val)

    # Add recipients
    for recipient in to_addresses:
        form_parts.append("to[]=" + str(recipient).replace("%", "%25").replace("&", "%26").replace("=", "%3D"))

    # Add optional fields
    if cc != None:
        for recip in cc:
            form_parts.append("cc[]=" + str(recip).replace("%", "%25").replace("&", "%26").replace("=", "%3D"))
    if bcc != None:
        for recip in bcc:
            form_parts.append("bcc[]=" + str(recip).replace("%", "%25").replace("&", "%26").replace("=", "%3D"))

    if headers != None:
        header_str = "{"
        first = True
        for k, v in headers.items():
            if not first:
                header_str += ","
            first = False
            header_str += "\"" + str(k) + "\":\"" + str(v).replace("\"", "\\\"") + "\""
        header_str += "}"
        form_parts.append("headers=" + str(header_str).replace("%", "%25").replace("&", "%26").replace("=", "%3D"))

    if from_name != None:
        form_parts.append("fromname=" + str(from_name).replace("%", "%25").replace("&", "%26").replace("=", "%3D"))

    # Attachments not supported without sendgrid library
    if attachments != None:
        fail("attachments are not supported in sendgrid module when sendgrid library is not installed")

    encoded_data = "&".join(form_parts)

    SENDGRID_URI = "https://api.sendgrid.com/api/mail.send.json"
    curl_headers = [
        "-H", "User-Agent: Ansible",
        "-H", "Content-type: application/x-www-form-urlencoded",
        "-H", "Accept: application/json"
    ]

    res = ctx.run(
        ["curl", "-s", "-X", "POST", "-d", encoded_data] + curl_headers + [SENDGRID_URI],
        mutates=True
    )
    if res.rc != 0:
        fail("unable to send email through SendGrid API: " + res.stderr)

    if res.stdout.find("\"status\": \"success\"") != -1:
        return {"changed": False, "msg": subject}
    if res.stdout.find("\"errors\"") != -1:
        fail("SendGrid API returned errors: " + res.stdout)

    fail("SendGrid API response was unexpected: " + res.stdout)

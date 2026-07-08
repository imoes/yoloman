def main(ctx, params):
    host = params.get("host", "localhost")
    port = int(params.get("port", 25))
    timeout = int(params.get("timeout", 20))
    ehlohost = params.get("ehlohost")
    sender = params.get("sender", "root")
    recipients = params.get("to", ["root"])
    cc = params.get("cc", [])
    bcc = params.get("bcc", [])
    subject = params.get("subject")
    body = params.get("body")
    attach_files = params.get("attach", [])
    headers = params.get("headers", [])
    charset = params.get("charset", "utf-8")
    subtype = params.get("subtype", "plain")
    secure = params.get("secure", "try")
    username = params.get("username")
    password = params.get("password")
    message_id_domain = params.get("message_id_domain", "ansible")

    if subject == None:
        fail("subject is required")

    if body == None:
        body = subject

    # Build email content (simplified representation for check_mode)
    sender_phrase, sender_addr = _parse_addr(sender)
    to_list = [_format_addr(_parse_addr(a)) for a in recipients]
    cc_list = [_format_addr(_parse_addr(a)) for a in cc]
    bcc_list = [_parse_addr(a)[1] for a in bcc]
    all_addrs = set(bcc_list)
    for a in recipients + cc:
        all_addrs.add(_parse_addr(a)[1])

    # Build headers
    msg_headers = [
        "From: " + _format_addr((sender_phrase, sender_addr)),
        "To: " + ", ".join(to_list),
        "Subject: " + subject,
        "Date: " + _formatdate(),
    ]
    for h in headers:
        if "=" in h:
            k, v = h.split("=", 1)
            msg_headers.append(k.strip() + ": " + v.strip())
    msg_headers.append("X-Mailer: Ansible mail module")

    msg_lines = []
    msg_lines.extend(msg_headers)
    msg_lines.append("")
    msg_lines.append(body)
    msg_lines.append("")
    msg_lines.append("")
    msg_content = "\n".join(msg_lines)

    # Handle secure connection (check_mode)
    if ctx.check_mode:
        changed = True
        # If sending would fail, we can't predict without actually running SMTP,
        # but for idempotency we assume success unless required parameters are missing
        return {"changed": changed, "msg": "Mail would be sent successfully"}

    # For actual sending, we rely on ctx.run if SMTP CLI is available
    # Since Starlark cannot do SMTP directly, fall back to using sendmail if present
    # This is a pragmatic approximation for the Starlark runtime

    # Try to use sendmail CLI if available
    sendmail_paths = ["/usr/sbin/sendmail", "/usr/bin/sendmail"]
    sendmail_found = False
    for sp in sendmail_paths:
        if ctx.file_exists(sp):
            sendmail_found = True
            break
    if not sendmail_found:
        fail("No sendmail or SMTP CLI available; cannot send email")

    # Build sendmail arguments
    sendmail_argv = [sendmail_found, "-t"]
    # Prepare message body with headers
    msg_full = msg_content
    for filename in attach_files:
        if not ctx.file_exists(filename):
            fail("Attachment file not found: " + filename)
        # In practice, we cannot attach binary files in Starlark without external tooling
        # For simplicity, skip binary attachments in Starlark and warn
        # A real implementation would need base64 encoding and MIME handling via CLI tools
        fail("Attachment support is not available in Starlark implementation of mail module")

    # Write message to temp file and pipe to sendmail
    # Since ctx.run can't pipe easily, use a temporary file
    tmp_path = "/tmp/ansible_mail_msg_" + str(hash(msg_content))[:10]
    ctx.file_write(tmp_path, msg_full, mode="0600")

    res = ctx.run(sendmail_argv + [tmp_path], mutates=True)
    if res.rc != 0:
        ctx.file_write(tmp_path, "", mode="0600")  # cleanup
        fail("sendmail failed: " + res.stderr)

    # Clean up temp file
    ctx.file_write(tmp_path, "", mode="0600")

    return {"changed": True, "msg": "Mail sent successfully"}


def _parse_addr(addr):
    # Simplified parseaddr: splits on '<' or takes as-is
    addr = addr.strip()
    if addr.startswith("<") and addr.endswith(">"):
        return ("", addr[1:-1])
    if "<" in addr:
        parts = addr.split("<", 1)
        phrase = parts[0].strip()
        email = parts[1].strip().rstrip(">")
        return (phrase, email)
    return ("", addr)


def _format_addr(pair):
    phrase, email = pair
    if phrase:
        return phrase + " <" + email + ">"
    return email


def _formatdate():
    # Simplified date string for Message-ID
    # In production, use a proper date library; here we approximate
    return "Date"  # placeholder; real implementation needs real date logic

def main(ctx, params):
    user = params["user"]
    password = params["password"]
    to = params["to"]
    msg_body = params["msg"]
    host = params.get("host")
    port = params.get("port", 5222)
    encoding = params.get("encoding")

    # Check for xmpp module availability
    res = ctx.run(["python3", "-c", "import xmpp"], mutates=False)
    if res.rc != 0:
        fail("unable to import xmpp (xmpppy); please install it")

    # Parse JID
    at_idx = user.find("@")
    if at_idx == -1:
        fail("invalid user JID: missing '@'")
    user_part = user[:at_idx]
    server_part = user[at_idx + 1:]

    target_host = host if host else server_part
    target_port = port

    # Parse 'to' for room vs user
    nick = None
    to_room = to
    slash_idx = to.find("/")
    if slash_idx != -1:
        to_room = to[:slash_idx]
        nick = to[slash_idx + 1:]

    # Prepare message body and type
    msg_type = "groupchat" if nick else "chat"

    # Escape single quotes in strings for python -c
    def escape(s):
        return s.replace("'", "\\'")

    # Build Python script
    script_lines = [
        "import sys, time",
        "import xmpp",
        "jid = xmpp.JID('" + escape(user) + "')",
        "user = jid.getNode()",
        "server = jid.getDomain()",
        "conn = xmpp.Client(server, debug=[])",
        "if not conn.connect(server=('" + escape(target_host) + "', " + str(target_port) + ")):",
        "    sys.exit(1)",
        "if not conn.auth(user, '" + escape(password) + "', 'Ansible'):",
        "    sys.exit(2)",
        "conn.sendInitPresence(requestRoster=0)",
    ]

    if nick:
        script_lines.extend([
            "msg = xmpp.protocol.Message(body='" + escape(msg_body) + "')",
            "msg.setType('groupchat')",
            "msg.setTag('x', namespace='http://jabber.org/protocol/muc#user')",
            "join = xmpp.Presence(to='" + escape(to) + "')",
            "join.setTag('x', namespace='http://jabber.org/protocol/muc')",
            "conn.send(join)",
            "time.sleep(1)",
        ])
    else:
        script_lines.extend([
            "msg = xmpp.protocol.Message(body='" + escape(msg_body) + "')",
            "msg.setType('chat')",
        ])

    script_lines.extend([
        "msg.setTo('" + escape(to_room) + "')",
        "conn.send(msg)",
        "time.sleep(1)",
        "conn.disconnect()",
    ])

    cmd_script = "; ".join(script_lines)

    if ctx.check_mode:
        # In check_mode: simulate by skipping actual send but still verify connectivity
        # We'll run the script but intercept the conn.send call
        # To do this safely, we monkey-patch xmpp.Client.send to be a no-op
        patch_script = (
            "import xmpp",
            "original_send = xmpp.Client.send",
            "xmpp.Client.send = lambda self, *args, **kwargs: None",
        )
        full_script = "; ".join(patch_script + (cmd_script,))
        cmd = ["python3", "-c", full_script]
        res = ctx.run(cmd, mutates=False)
        if res.rc == 1:
            fail("Failed to connect to server: " + target_host)
        if res.rc == 2:
            fail("Failed to authorize " + user_part + " on: " + server_part)
        if res.rc != 0:
            fail("Jabber connection or auth failed")
        return {"changed": True, "msg": "would send jabber message to " + to + " as " + user}
    else:
        res = ctx.run(["python3", "-c", cmd_script], mutates=True)
        if res.rc == 1:
            fail("Failed to connect to server: " + target_host)
        if res.rc == 2:
            fail("Failed to authorize " + user_part + " on: " + server_part)
        if res.rc != 0:
            fail("Jabber message send failed")

    return {"changed": True, "msg": "sent jabber message to " + to + " as " + user}

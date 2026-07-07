def main(ctx, params):
    subscription = params["subscription"]
    token = params["token"]
    room = params["room"]
    msg = params["msg"]
    notify = params.get("notify")

    base_url = "https://" + subscription + ".campfirenow.com"
    headers = {
        "Content-Type": "application/xml",
        "User-Agent": "Ansible/1.2"
    }

    def escape_xml(text):
        return (text
                .replace("&", "&amp;")
                .replace("<", "&lt;")
                .replace(">", "&gt;")
                .replace("'", "&apos;")
                .replace('"', "&quot;"))

    def send_request(data):
        url = base_url + "/room/" + room + "/speak.xml"
        res = ctx.run(
            ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "-X", "POST",
             "-u", token + ":X", "-H", "Content-Type: application/xml",
             "-H", "User-Agent: Ansible/1.2", "-d", data, url],
            mutates=True
        )
        if res.skipped:
            return True, "would send message"
        if res.rc != 0 or res.stdout.strip() not in ["200", "201"]:
            fail("campfire api request failed with exit code " + str(res.rc) +
                 " and output: " + res.stderr)
        return False, res.stdout.strip()

    # Send notification sound if requested
    if notify:
        sound_data = "<message><type>SoundMessage</type><body>" + escape_xml(notify) + "</body></message>"
        send_request(sound_data)

    # Send the main message
    msg_data = "<message><body>" + escape_xml(msg) + "</body></message>"
    changed, status = send_request(msg_data)

    return {"changed": True, "msg": "message sent to room " + room, "room": room, "msg": msg, "notify": notify}

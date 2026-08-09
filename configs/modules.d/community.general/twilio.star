def main(ctx, params):
    account_sid = params["account_sid"]
    auth_token = params["auth_token"]
    msg = params["msg"]
    from_number = params["from_number"]
    to_numbers = params["to_numbers"]
    media_url = params.get("media_url")

    uri = "https://api.twilio.com/2010-04-01/Accounts/%s/Messages.json" % account_sid
    agent = "Ansible"

    for number in to_numbers:
        data = {'From': from_number, 'To': number, 'Body': msg}
        if media_url != None:
            data['MediaUrl'] = media_url

        # Build URL-encoded query string manually
        pairs = []
        for k in sorted(data.keys()):
            v = str(data[k])
            # Simple URL encoding for required characters only
            v = v.replace('%', '%25').replace(' ', '+').replace('&', '%26').replace('=', '%3D')
            pairs.append(k + '=' + v)
        encoded_data = '&'.join(pairs)

        headers = {
            'User-Agent': agent,
            'Content-type': 'application/x-www-form-urlencoded',
            'Accept': 'application/json',
        }

        # Use curl for HTTP POST with basic auth
        cmd = [
            "curl", "-s", "-S", "-X", "POST",
            "-u", account_sid + ":" + auth_token,
            "-H", "User-Agent: " + agent,
            "-H", "Content-type: application/x-www-form-urlencoded",
            "-H", "Accept: application/json",
            "-d", encoded_data,
            uri
        ]

        res = ctx.run(cmd, mutates=True)

        if res.skipped:
            return {"changed": True, "msg": "would send message to " + str(len(to_numbers)) + " recipient(s)"}

        if res.rc != 0:
            fail("unable to send message to " + number + ": curl failed with rc=" + str(res.rc) + ", stderr: " + res.stderr)

        # Parse response for errors (simple string search only)
        resp = res.stdout.strip()
        if resp == "":
            fail("unable to send message to " + number + ": empty response from Twilio API")

        # Check for error indicators in JSON response
        if resp.find('"code"') != -1 or (resp.find('"status"') != -1 and resp.find('"status"') < resp.find('"message"')):
            # Look for message field
            msg_start = resp.find('"message"')
            if msg_start == -1:
                fail("unable to send message to " + number + ": Twilio API error (no message in response)")
            quote_start = resp.find('"', msg_start + 11)
            if quote_start == -1:
                fail("unable to send message to " + number + ": Twilio API error (malformed message field)")
            quote_end = resp.find('"', quote_start + 1)
            if quote_end == -1:
                fail("unable to send message to " + number + ": Twilio API error (unclosed message field)")
            body_message = resp[quote_start+1:quote_end]
            fail("unable to send message to " + number + ": " + body_message)

    return {"changed": True, "msg": "sent message to " + str(len(to_numbers)) + " recipient(s)"}

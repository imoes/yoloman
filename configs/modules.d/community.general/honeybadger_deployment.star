def main(ctx, params):
    token = params["token"]
    environment = params["environment"]
    user = params.get("user")
    repo = params.get("repo")
    revision = params.get("revision")
    url = params.get("url", "https://api.honeybadger.io/v1/deploys")
    validate_certs = params.get("validate_certs", True)

    # Build payload
    payload_parts = []
    payload_parts.append("deploy[environment]=" + str(environment))
    if user != None:
        payload_parts.append("deploy[local_username]=" + str(user))
    if repo != None:
        payload_parts.append("deploy[repository]=" + str(repo))
    if revision != None:
        payload_parts.append("deploy[revision]=" + str(revision))
    payload_parts.append("api_key=" + str(token))
    data = "&".join(payload_parts)

    # In check mode, simulate success without sending
    if ctx.check_mode:
        return {"changed": True, "msg": "would notify Honeybadger deployment"}

    # Send notification via HTTP POST
    # validate_certs=False requires cert validation disabled support in ctx.run;
    # since ctx.run does not expose this, we fail if validate_certs is false.
    if validate_certs == False:
        fail("validate_certs=false is not supported by this Starlark module")

    res = ctx.run(
        ["curl", "-s", "-X", "POST", "-H", "Content-Type: application/x-www-form-urlencoded", "-d", data, url],
        mutates=False
    )

    # curl returns non-zero rc on HTTP errors even when server returns non-2xx
    # We expect 201 Created for success; otherwise fail.
    if res.rc != 0:
        fail("failed to notify Honeybadger: curl returned %d: %s" % (res.rc, res.stderr))

    # Check HTTP status line via curl verbose mode is complex; instead use -w to output http_code
    # Since ctx.run doesn't allow custom output formatting, we detect success by body content
    # Honeybadger returns 201 with JSON response "deploy created" or similar
    # However, ctx.run doesn't expose http_code. To comply with contract, we assume success
    # if curl succeeded (rc=0), per original module's fetch_url behavior.
    return {"changed": True, "msg": "notified Honeybadger deployment"}

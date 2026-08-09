def main(ctx, params):
    server = params.get("server", "localhost")
    port = int(params.get("port", 1883))
    topic = params["topic"]
    payload = params["payload"]
    client_id = params.get("client_id")
    qos = int(params.get("qos", "0"))
    retain = params.get("retain", False)
    username = params.get("username")
    password = params.get("password")
    ca_cert = params.get("ca_cert")
    client_cert = params.get("client_cert")
    client_key = params.get("client_key")
    tls_version = params.get("tls_version")

    # Special handling for 'None' payload string
    if payload == "None":
        payload = None

    # Build client_id if not provided
    if client_id == None:
        hostname = ctx.facts().get("hostname", "localhost")
        pid = ctx.run(["bash", "-c", "echo $$"]).stdout.strip()
        client_id = hostname + "_" + pid

    # Build auth dict only if username provided
    auth = None
    if username != None:
        auth = {"username": username, "password": password}

    # TLS configuration
    tls = None
    if ca_cert != None:
        tls = {
            "ca_certs": ca_cert,
            "certfile": client_cert,
            "keyfile": client_key,
        }
        if tls_version != None:
            tls["tls_version"] = tls_version

    # Build command-line arguments for mosquitto_pub
    args = [
        "mosquitto_pub",
        "-h", server,
        "-p", str(port),
        "-t", topic,
        "-q", str(qos),
    ]

    if retain:
        args.append("-r")

    if client_id != None:
        args.extend(["-i", client_id])

    if username != None:
        args.extend(["-u", username])
        if password != None:
            args.extend(["-P", password])

    if ca_cert != None:
        args.extend(["--cafile", ca_cert])
        if client_cert != None:
            args.extend(["--cert", client_cert])
        if client_key != None:
            args.extend(["--key", client_key])
        if tls_version != None:
            if tls_version == "tlsv1.1":
                args.extend(["--tls-version", "tlsv1.1"])
            elif tls_version == "tlsv1.2":
                args.extend(["--tls-version", "tlsv1.2"])

    # Add payload from stdin or inline
    if payload != None:
        args.extend(["-m", payload])

    if ctx.check_mode:
        return {"changed": True, "msg": "would publish to MQTT topic " + topic}

    res = ctx.run(args, mutates=True)

    if res.rc != 0:
        fail("failed to publish to MQTT topic " + topic + ": " + res.stderr)

    return {"changed": True, "msg": "published to MQTT topic " + topic}

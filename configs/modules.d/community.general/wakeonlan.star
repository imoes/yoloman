def main(ctx, params):
    mac = params["mac"]
    broadcast = params.get("broadcast", "255.255.255.255")
    port = params.get("port", 7)

    # Validate and normalize MAC address
    mac_orig = mac
    if len(mac) == 12 + 5:
        sep = mac[2]
        mac = mac.replace(sep, "")
    if len(mac) != 12:
        fail("Incorrect MAC address length: " + mac_orig)
    # Validate MAC is hexadecimal
    valid_hex = True
    for i in range(len(mac)):
        c = mac[i]
        if not ((c >= "0" and c <= "9") or (c >= "a" and c <= "f") or (c >= "A" and c <= "F")):
            valid_hex = False
            break
    if not valid_hex:
        fail("Incorrect MAC address format: " + mac_orig)

    # Build magic packet payload
    padding = "FFFFFFFFFFFF" + mac * 20
    data_bytes = []
    for i in range(0, len(padding), 2):
        val = 0
        for j in range(2):
            c = padding[i + j]
            if c >= "0" and c <= "9":
                d = ord(c) - ord("0")
            elif c >= "a" and c <= "f":
                d = ord(c) - ord("a") + 10
            else:  # A-F
                d = ord(c) - ord("A") + 10
            val = val * 16 + d
        data_bytes.append(val)

    # Try to use wakeonlan CLI if available
    res = ctx.run(["which", "wakeonlan"], mutates=False)
    if res.rc == 0:
        argv = ["wakeonlan", mac, "-i", broadcast, "-p", str(port)]
    else:
        fail("wakeonlan CLI not available; install 'wakeonlan' package")

    res = ctx.run(argv, mutates=True)
    if res.skipped:
        return {"changed": True, "msg": "would send Wake-on-LAN packet to " + mac}
    if res.rc != 0:
        fail("failed to send Wake-on-LAN packet: " + res.stderr)

    return {"changed": True, "msg": "sent Wake-on-LAN packet to " + mac}

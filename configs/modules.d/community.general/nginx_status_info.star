def main(ctx, params):
    url = params["url"]
    timeout = params.get("timeout", 10)

    # Use wget in non-verbose mode to fetch the nginx status page
    # -q: quiet, -O -: output to stdout, -T: timeout in seconds
    res = ctx.run(
        ["wget", "-q", "-O", "-", "-T", str(timeout), url],
        mutates=False,
        ok_codes=[0]
    )

    if res.skipped:
        # In check_mode, we don't actually run the command
        return {"changed": False, "msg": "would retrieve nginx status from " + url}

    if res.rc != 0:
        fail("failed to fetch nginx status from %s within %d seconds: %s" % (url, timeout, res.stderr if res.stderr != None else "exit code " + str(res.rc)))

    data = res.stdout.strip() if res.stdout != None else ""
    if not data:
        fail("no data received from %s" % url)

    # Parse nginx stub_status output
    # Expected format:
    # Active connections: 2340
    # server accepts handled requests
    # 81769947 81769947 144332345
    # Reading: 0 Writing: 241 Waiting: 2092

    result = {
        "active_connections": None,
        "accepts": None,
        "handled": None,
        "requests": None,
        "reading": None,
        "writing": None,
        "waiting": None,
        "data": data,
    }

    lines = data.split("\n")
    if len(lines) < 4:
        fail("unexpected nginx_status format: insufficient lines")

    # Parse first line: "Active connections: X"
    first_line = lines[0].strip()
    if first_line.startswith("Active connections: "):
        colon_index = first_line.find(":")
        if colon_index == -1:
            fail("failed to parse active_connections from first line: " + first_line)
        value_str = first_line[colon_index + 1:].strip()
        # Convert string to int manually since int() may fail
        if not value_str.replace(" ", "").isdigit():
            fail("failed to parse active_connections from first line: " + first_line)
        result["active_connections"] = int(value_str)
    else:
        fail("unexpected first line: " + first_line)

    # Parse third line: "X Y Z" (accepts handled requests)
    third_line = lines[2].strip()
    parts = third_line.split()
    if len(parts) == 3:
        if not (parts[0].isdigit() and parts[1].isdigit() and parts[2].isdigit()):
            fail("failed to parse accepts/handled/requests from third line: " + third_line)
        result["accepts"] = int(parts[0])
        result["handled"] = int(parts[1])
        result["requests"] = int(parts[2])
    else:
        fail("unexpected third line format: expected 3 numbers, got " + str(len(parts)) + " from " + third_line)

    # Parse fourth line: "Reading: X Writing: Y Waiting: Z"
    fourth_line = lines[3].strip()
    
    if "Reading:" in fourth_line and "Writing:" in fourth_line and "Waiting:" in fourth_line:
        reading_start = fourth_line.find("Reading:") + len("Reading:")
        writing_start = fourth_line.find("Writing:") + len("Writing:")
        waiting_start = fourth_line.find("Waiting:") + len("Waiting:")
        
        reading_part = fourth_line[reading_start:writing_start].strip()
        writing_part = fourth_line[writing_start:waiting_start].strip()
        waiting_part = fourth_line[waiting_start:].strip()
        
        # Extract numeric parts
        reading_val = reading_part.split()[0] if reading_part else ""
        writing_val = writing_part.split()[0] if writing_part else ""
        waiting_val = waiting_part.split()[0] if waiting_part else ""
        
        if not (reading_val.isdigit() and writing_val.isdigit() and waiting_val.isdigit()):
            fail("failed to parse Reading/Writing/Waiting values from fourth line: " + fourth_line)
        
        result["reading"] = int(reading_val)
        result["writing"] = int(writing_val)
        result["waiting"] = int(waiting_val)
    else:
        fail("unexpected fourth line format: " + fourth_line)

    return {
        "changed": False,
        "msg": "nginx status retrieved from " + url,
        "data": result
    }

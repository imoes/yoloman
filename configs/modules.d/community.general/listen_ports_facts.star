def main(ctx, params):
    command = params.get("command")
    include_non_listening = params.get("include_non_listening", False)

    # Only Linux is supported
    facts = ctx.facts()
    os_family = facts.get("os_family", "")
    distribution = facts.get("distribution", "")
    if os_family.lower().find("linux") == -1 and distribution.lower().find("linux") == -1:
        fail("This module requires Linux.")

    # Determine which command to use
    commands = ["netstat", "ss"]
    if command != None:
        chosen_cmd = command
    else:
        chosen_cmd = None
        for c in sorted(commands):
            res = ctx.run(["which", c])
            if res.rc == 0:
                chosen_cmd = c
                break

        if chosen_cmd == None:
            fail("Unable to find any of the supported commands in PATH: netstat, ss")

    # Build command args
    if include_non_listening:
        args = ["-p", "-u", "-n", "-t", "-a"]
    else:
        args = ["-p", "-l", "-u", "-n", "-t"]

    # Run the command
    if chosen_cmd == "netstat":
        cmd = ["netstat"] + args
    elif chosen_cmd == "ss":
        cmd = ["ss"] + args
    res = ctx.run(cmd)
    if res.rc != 0:
        fail("Failed to run " + chosen_cmd + ": " + res.stderr)

    # Parse output based on command
    lines = res.stdout.split("\n")
    results = []

    if chosen_cmd == "netstat":
        for line in lines:
            if not (line.startswith("tcp") or line.startswith("udp")):
                continue
            parts = line.split()
            if len(parts) < 6:
                continue
            protocol = parts[0]
            recv_q = parts[1]
            send_q = parts[2]
            local_addr = parts[3]
            foreign_addr = parts[4]
            rest = parts[5:]

            # Extract local address and port
            last_colon = local_addr.rfind(":")
            if last_colon != -1:
                address = local_addr[:last_colon]
                port_str = local_addr[last_colon + 1:]
            else:
                address = local_addr
                port_str = "0"

            # Parse port
            port = 0
            if port_str.isdigit():
                port = int(port_str)
            else:
                port = 0

            state = ""
            pid_and_name = ""
            process = ""

            if protocol.startswith("tcp"):
                protocol = "tcp"
                if len(rest) == 3:
                    state, pid_and_name, process = rest
                elif len(rest) == 2:
                    state, pid_and_name = rest
            elif protocol.startswith("udp"):
                protocol = "udp"
                if len(rest) == 2:
                    pid_and_name, process = rest
                elif len(rest) == 1:
                    pid_and_name = rest[0]

            # Parse PID/name
            pid = 0
            name = ""
            slash_pos = pid_and_name.find("/")
            if slash_pos != -1:
                pid_str = pid_and_name[:slash_pos]
                name_part = pid_and_name[slash_pos + 1:]
                if pid_str.isdigit():
                    pid = int(pid_str)
                name = name_part.rstrip(":")

            entry = {
                "protocol": protocol,
                "state": state,
                "address": address,
                "foreign_address": foreign_addr,
                "port": port,
                "name": name,
                "pid": pid,
            }
            # Avoid duplicates (same logic as original)
            found_dup = False
            for existing in results:
                if entry == existing:
                    found_dup = True
                    break
            if not found_dup:
                results.append(entry)

    elif chosen_cmd == "ss":
        # Skip header line
        header = lines[0] if len(lines) > 0 else ""
        if header.startswith("Netid") == False:
            fail("Unexpected ss output: missing header")

        for i in range(1, len(lines)):
            line = lines[i]
            cells = line.split(None, 6)
            if len(cells) not in [6, 7]:
                continue

            if len(cells) == 6:
                process = ""
                protocol, state, recv_q, send_q, local_addr_port, peer_addr_port = cells
            else:
                protocol, state, recv_q, send_q, local_addr_port, peer_addr_port, process = cells

            # Parse address:port
            local = local_addr_port
            address = ""
            port_str = "0"

            if local.startswith("["):
                bracket_end = local.find("]")
                if bracket_end != -1 and bracket_end + 1 < len(local) and local[bracket_end + 1] == ":":
                    address = local[1:bracket_end]
                    port_str = local[bracket_end + 2:]
                else:
                    address = local
            else:
                idx = local.rfind(":")
                if idx != -1:
                    address = local[:idx]
                    port_str = local[idx + 1:]

            # Parse port
            port = 0
            if port_str.isdigit():
                port = int(port_str)
            else:
                port = 0

            # Parse PID/name from process string if present
            pid = 0
            name = ""
            pid_pos = process.find("pid=")
            if pid_pos != -1:
                rest_part = process[pid_pos + 4:]
                pid_end = rest_part.find(",")
                if pid_end == -1:
                    pid_end = rest_part.find(")")
                if pid_end != -1:
                    pid_str = rest_part[:pid_end]
                    if pid_str.isdigit():
                        pid = int(pid_str)

                # Try to get name: look for '"name"' pattern before pid=
                name_start = process.rfind('"', 0, pid_pos)
                if name_start != -1:
                    name_end = process.find('"', name_start + 1)
                    if name_end != -1:
                        name = process[name_start + 1:name_end]

            entry = {
                "protocol": protocol,
                "state": state,
                "address": address,
                "foreign_address": peer_addr_port,
                "port": port,
                "name": name,
                "pid": pid,
            }
            results.append(entry)

    # Add stime and user via ps for each pid
    # We'll collect unique pids first to avoid redundant calls
    unique_pids = []
    seen_pids = set()
    for r in results:
        pid = r.get("pid", 0)
        if pid > 0 and pid not in seen_pids:
            seen_pids.add(pid)
            unique_pids.append(pid)

    pid_stime = {}
    pid_user = {}
    for pid in unique_pids:
        # Get stime
        ps_res_stime = ctx.run(["ps", "-o", "lstart=", "-p", str(pid)])
        stime = ""
        if ps_res_stime.rc == 0:
            lines_stime = ps_res_stime.stdout.strip().split("\n")
            if len(lines_stime) > 0 and lines_stime[0] != "":
                stime = lines_stime[0].strip()

        # Get user
        ps_res_user = ctx.run(["ps", "-o", "user=", "-p", str(pid)])
        user = ""
        if ps_res_user.rc == 0:
            lines_user = ps_res_user.stdout.strip().split("\n")
            if len(lines_user) > 0 and lines_user[0] != "":
                user = lines_user[0].strip()

        pid_stime[pid] = stime
        pid_user[pid] = user

    # Populate stime and user in results
    for r in results:
        pid = r.get("pid", 0)
        r["stime"] = pid_stime.get(pid, "")
        r["user"] = pid_user.get(pid, "")

    # Filter fields if not include_non_listening
    tcp_listen = []
    udp_listen = []
    for r in results:
        entry = {}
        for key in ["protocol", "address", "port", "name", "pid", "stime", "user"]:
            entry[key] = r.get(key)
        if include_non_listening:
            entry["state"] = r.get("state", "")
            entry["foreign_address"] = r.get("foreign_address", "")

        if r["protocol"] == "tcp":
            tcp_listen.append(entry)
        elif r["protocol"] == "udp":
            udp_listen.append(entry)

    return {
        "changed": False,
        "msg": "Gathered listen ports facts",
        "data": {
            "tcp_listen": tcp_listen,
            "udp_listen": udp_listen,
        },
    }

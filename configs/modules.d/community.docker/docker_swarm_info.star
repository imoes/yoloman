def main(ctx, params):
    # Basic parameters
    nodes = params.get("nodes", False)
    services = params.get("services", False)
    tasks = params.get("tasks", False)
    unlock_key = params.get("unlock_key", False)
    verbose_output = params.get("verbose_output", False)

    # Check mode handling: info module never mutates
    check_mode = ctx.check_mode

    # Initialize result structure
    result = {
        "changed": False,
        "msg": "Retrieved Docker Swarm facts",
        "can_talk_to_docker": False,
        "docker_swarm_active": False,
        "docker_swarm_manager": False,
        "swarm_facts": {}
    }

    # Step 1: Check if Docker daemon is reachable via docker info
    res = ctx.run(["docker", "info"], mutates=False)
    if res.rc != 0:
        result["msg"] = "Failed to connect to Docker daemon"
        return result

    result["can_talk_to_docker"] = True

    # Step 2: Determine if Docker is in Swarm mode
    docker_info_output = res.stdout
    is_swarm_active = ("Swarm: active" in docker_info_output)
    result["docker_swarm_active"] = is_swarm_active

    # Step 3: Determine if current node is a manager
    node_role = None
    for line in docker_info_output.splitlines():
        if "Node Role" in line:
            parts = line.split(":")
            if len(parts) >= 2:
                node_role = parts[1].strip().lower()
            break

    is_manager = node_role == "manager" if node_role else False

    # If we cannot determine node role, try docker node ls
    if not is_manager and is_swarm_active:
        res = ctx.run(["docker", "node", "ls"], mutates=False)
        if res.rc == 0:
            # If node ls works, assume manager
            is_manager = True

    result["docker_swarm_manager"] = is_manager and is_swarm_active

    if not is_manager:
        result["msg"] = "Node is not a Swarm manager"
        return result

    # Step 4: Get swarm facts (inspect swarm)
    res = ctx.run(["docker", "swarm", "inspect"], mutates=False)
    if res.rc != 0:
        result["msg"] = "Failed to inspect Docker Swarm"
        return result

    # Parse swarm inspect output (basic extraction)
    swarm_inspect = res.stdout
    primary_token = ""
    secondary_token = ""

    # Try to extract tokens using simple string search
    if '"JoinTokens"' in swarm_inspect:
        # Look for Primary token
        idx = swarm_inspect.find('"Primary"')
        if idx != -1:
            start = swarm_inspect.find('"Token"', idx)
            if start != -1:
                start = swarm_inspect.find('"', start + 7)
                if start != -1:
                    end = swarm_inspect.find('"', start + 1)
                    if end != -1:
                        primary_token = swarm_inspect[start + 1:end]

        # Look for Worker token
        idx = swarm_inspect.find('"Worker"')
        if idx != -1:
            start = swarm_inspect.find('"Token"', idx)
            if start != -1:
                start = swarm_inspect.find('"', start + 7)
                if start != -1:
                    end = swarm_inspect.find('"', start + 1)
                    if end != -1:
                        secondary_token = swarm_inspect[start + 1:end]

    result["swarm_facts"] = {
        "JoinTokens": {
            "Primary": primary_token,
            "Worker": secondary_token
        } if primary_token or secondary_token else {},
        "Swarm": True,
        "NodeState": "active"
    }

    # Step 5: Handle unlock_key
    if unlock_key:
        res = ctx.run(["docker", "swarm", "unlock-key", "-f"], mutates=False)
        if res.rc == 0 and res.stdout.strip():
            result["swarm_unlock_key"] = res.stdout.strip()
        else:
            result["swarm_unlock_key"] = ""

    # Step 6: Get nodes if requested
    if nodes:
        res = ctx.run(["docker", "node", "ls"], mutates=False)
        if res.rc != 0:
            result["msg"] = "Failed to list Docker Swarm nodes"
            return result
        lines = res.stdout.strip().splitlines()
        nodes_list = []
        for line in lines[1:] if len(lines) > 1 else []:
            parts = line.split()
            if len(parts) >= 4:
                node = {
                    "ID": parts[0],
                    "Hostname": parts[1],
                    "Status": parts[2],
                    "Availability": parts[3]
                }
                if len(parts) >= 5:
                    ms = parts[4] if len(parts) > 4 else None
                    node["ManagerStatus"] = ms if ms in ["Ready", "Reachable", "Down"] else None
                nodes_list.append(node)
        if not verbose_output:
            nodes_list = [
                {
                    "ID": n.get("ID"),
                    "Hostname": n.get("Hostname"),
                    "Status": n.get("Status"),
                    "Availability": n.get("Availability"),
                    "ManagerStatus": n.get("ManagerStatus")
                }
                for n in nodes_list
            ]
        result["nodes"] = nodes_list
    else:
        result["nodes"] = []

    # Step 7: Get services if requested
    if services:
        res = ctx.run(["docker", "service", "ls"], mutates=False)
        if res.rc != 0:
            result["msg"] = "Failed to list Docker Swarm services"
            return result
        lines = res.stdout.strip().splitlines()
        services_list = []
        for line in lines[1:] if len(lines) > 1 else []:
            parts = line.split()
            if len(parts) >= 5:
                svc = {
                    "ID": parts[0],
                    "Name": parts[1],
                    "Replicas": parts[2],
                    "Image": parts[3],
                    "Mode": parts[4]
                }
                services_list.append(svc)
        if not verbose_output:
            services_list = [
                {
                    "ID": s.get("ID"),
                    "Name": s.get("Name"),
                    "Replicas": s.get("Replicas"),
                    "Image": s.get("Image")
                }
                for s in services_list
            ]
        result["services"] = services_list
    else:
        result["services"] = []

    # Step 8: Get tasks if requested
    if tasks:
        res = ctx.run(["docker", "service", "ps", "--format", "{{.ID}} {{.Name}} {{.Image}} {{.Node}} {{.DesiredState}} {{.CurrentState}}"], mutates=False)
        if res.rc != 0:
            result["msg"] = "Failed to list Docker Swarm tasks"
            return result
        tasks_list = []
        for line in res.stdout.strip().splitlines():
            if not line:
                continue
            parts = line.split()
            if len(parts) >= 6:
                task = {
                    "ID": parts[0],
                    "Name": parts[1],
                    "Image": parts[2],
                    "Node": parts[3],
                    "DesiredState": parts[4],
                    "CurrentState": parts[5]
                }
                tasks_list.append(task)
        if not verbose_output:
            tasks_list = [
                {
                    "ID": t.get("ID"),
                    "Name": t.get("Name"),
                    "Image": t.get("Image"),
                    "Node": t.get("Node"),
                    "DesiredState": t.get("DesiredState"),
                    "CurrentState": t.get("CurrentState")
                }
                for t in tasks_list
            ]
        result["tasks"] = tasks_list
    else:
        result["tasks"] = []

    return result

def main(ctx, params):
    state = params.get("state")
    node = params.get("node")
    timeout = params.get("timeout", 300)
    force = params.get("force", True)

    if state == None:
        fail("state is required")

    if state not in ["online", "offline", "restart", "cleanup"]:
        fail("invalid state: %s" % state)

    def get_cluster_status():
        res = ctx.run(["pcs", "cluster", "status"])
        output = res.stdout.strip()
        if "Error: cluster is not currently running on this node" in output:
            return "offline"
        return "online"

    def get_node_status(target_node="all"):
        if target_node == "all":
            res = ctx.run(["pcs", "cluster", "pcsd-status", target_node])
        else:
            res = ctx.run(["pcs", "cluster", "pcsd-status"])
        if res.rc != 0:
            fail("pcsd-status failed: %s" % res.stderr)
        lines = res.stdout.strip().split("\n")
        statuses = []
        for i in range(len(lines)):
            line = lines[i]
            parts = line.split(":", 1)
            if len(parts) == 2:
                statuses.append([parts[0].strip(), parts[1].strip()])
        return statuses

    def set_cluster(target_state):
        if target_state == "online":
            cmd = ["pcs", "cluster", "start"]
        elif target_state == "offline":
            cmd = ["pcs", "cluster", "stop"]
            if force:
                cmd.append("--force")
        res = ctx.run(cmd, mutates=True)
        if res.rc != 0:
            fail("cluster %s failed: %s" % (target_state, res.stderr))

        deadline = ctx.now() + timeout
        while ctx.now() < deadline:
            st = get_cluster_status()
            if st == target_state:
                return True
        return False

    def set_node(target_state, target_node="all"):
        cmd_base = ["pcs", "cluster", "start" if target_state == "online" else "stop"]
        if force and target_state == "offline":
            cmd_base.append("--force")

        nodes = get_node_status(target_node)
        changed = False
        for i in range(len(nodes)):
            n = nodes[i]
            node_name = n[0]
            node_state = n[1].strip().lower()
            if node_state != target_state:
                cmd = cmd_base + [node_name]
                res = ctx.run(cmd, mutates=True)
                if res.rc != 0:
                    fail("node %s %s failed: %s" % (node_name, target_state, res.stderr))
                changed = True

        deadline = ctx.now() + timeout
        while ctx.now() < deadline:
            nodes = get_node_status("all")
            ok = True
            for i in range(len(nodes)):
                n = nodes[i]
                if n[1].strip().lower() != target_state:
                    ok = False
                    break
            if ok:
                return changed or (len(nodes) > 0)
        return False

    if state in ["online", "offline"]:
        if node == None:
            current = get_cluster_status()
            if current == state:
                return {"changed": False, "msg": "cluster is already %s" % state, "out": current}
            if ctx.check_mode:
                return {"changed": True, "msg": "would set cluster to %s" % state}
            if not set_cluster(state):
                fail("failed to set cluster %s within timeout" % state)
            return {"changed": True, "msg": "cluster is now %s" % state, "out": get_cluster_status()}
        else:
            current_nodes = get_node_status(node)
            all_ok = True
            for i in range(len(current_nodes)):
                n = current_nodes[i]
                if n[1].strip().lower() != state:
                    all_ok = False
                    break
            if all_ok:
                return {"changed": False, "msg": "all target nodes are already %s" % state, "out": current_nodes}
            if ctx.check_mode:
                return {"changed": True, "msg": "would set nodes to %s" % state}
            # For node-specific action, use set_node
            if not set_node(state, node):
                fail("failed to set nodes %s within timeout" % state)
            return {"changed": True, "msg": "nodes are now %s" % state, "out": get_node_status(node)}

    if state == "restart":
        # stop
        current = get_cluster_status()
        if current != "offline":
            if ctx.check_mode:
                return {"changed": True, "msg": "would restart cluster"}
            if not set_cluster("offline"):
                fail("failed to stop cluster within timeout")
        # start
        if not set_cluster("online"):
            fail("failed to start cluster within timeout")
        return {"changed": True, "msg": "cluster restarted", "out": get_cluster_status()}

    if state == "cleanup":
        if ctx.check_mode:
            return {"changed": True, "msg": "would run resource cleanup"}
        res = ctx.run(["pcs", "resource", "cleanup"], mutates=True)
        if res.rc != 0:
            fail("cleanup failed: %s" % res.stderr)
        return {"changed": True, "msg": "cluster resources cleaned up", "out": get_cluster_status()}

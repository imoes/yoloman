def main(ctx, params):
    host = params.get("host", "localhost")
    port = int(params.get("port", 3000))
    connect_timeout = int(params.get("connect_timeout", 1000))
    consecutive_good_checks = int(params.get("consecutive_good_checks", 3))
    sleep_between_checks = int(params.get("sleep_between_checks", 60))
    tries_limit = int(params.get("tries_limit", 300))
    local_only = params["local_only"]
    min_cluster_size = int(params.get("min_cluster_size", 1))
    target_cluster_size = params.get("target_cluster_size")
    fail_on_cluster_change = bool(params.get("fail_on_cluster_change", True))
    migrate_tx_key = params.get("migrate_tx_key", "migrate_tx_partitions_remaining")
    migrate_rx_key = params.get("migrate_rx_key", "migrate_rx_partitions_remaining")

    def info_cmd(cmd, host=host, port=port, timeout=connect_timeout):
        argv = [
            "asinfo",
            "-v", cmd,
            "-h", host,
            "-p", str(port),
            "-t", str(timeout)
        ]
        res = ctx.run(argv, mutates=False)
        if res.rc != 0:
            fail("asinfo command failed: %s" % res.stderr)
        raw = res.stdout.strip()
        if not raw:
            fail("asinfo returned empty output for command %s" % cmd)
        data = {}
        for part in raw.split(";"):
            if "=" in part:
                k, v = part.split("=", 1)
                data[k.strip()] = v.strip()
        return data

    def get_nodes():
        data = info_cmd("nodes")
        nodes = []
        for entry in data.get("nodes", "").split(";"):
            entry = entry.strip()
            if entry:
                idx = entry.find(":")
                if idx == -1:
                    fail("invalid node entry: %s" % entry)
                ip = entry[:idx]
                port_str = entry[idx+1:]
                nodes.append((ip, int(port_str)))
        return nodes

    def get_cluster_statistics(nodes):
        stats = {}
        for node in nodes:
            ip, port = node
            data = info_cmd("statistics", host=ip, port=port)
            stats[node] = data
        return stats

    def get_build_list(nodes):
        builds = set()
        for node in nodes:
            ip, port = node
            build = info_cmd("build", host=ip, port=port).get("build")
            builds.add(build)
        return builds

    def namespace_has_migs(namespace, node):
        ip, port = node
        data = info_cmd("namespace/" + namespace, host=ip, port=port)
        tx_str = data.get(migrate_tx_key, "0")
        rx_str = data.get(migrate_rx_key, "0")
        tx = int(tx_str) if tx_str.isdigit() else 0
        rx = int(rx_str) if rx_str.isdigit() else 0
        return tx != 0 or rx != 0

    def node_has_migs(node, namespaces):
        for ns in namespaces:
            if namespace_has_migs(ns, node):
                return True
        return False

    def is_min_cluster_size(stats):
        sizes = set()
        for data in stats.values():
            size_str = data.get("cluster_size", "0")
            size = int(size_str) if size_str.isdigit() else 0
            sizes.add(size)
        if len(sizes) > 1:
            return False
        return min(sizes) >= min_cluster_size

    def cluster_key_consistent(stats, start_key):
        keys = {}
        for data in stats.values():
            key = data.get("cluster_key")
            keys[key] = keys.get(key, 0) + 1
        return len(keys) == 1 and start_key in keys

    def cluster_migrates_allowed(stats):
        for data in stats.values():
            allowed = data.get("migrate_allowed", "false").lower()
            if allowed != "true":
                return False
        return True

    def can_use_cluster_stable(builds):
        min_build = min(builds) if builds else "0"
        parts = min_build.split(".")[:2]
        if len(parts) < 2:
            return False
        major_str, minor_str = parts
        if not major_str.isdigit() or not minor_str.isdigit():
            return False
        major = int(major_str)
        minor = int(minor_str)
        if major < 4:
            return False
        if major == 4 and minor < 3:
            return False
        return True

    def cluster_stable(stats):
        keys = set()
        for data in stats.values():
            keys.add(data.get("cluster_key"))
        return len(keys) == 1

    try_num = 0
    consecutive_good = 0
    start_cluster_key = None
    nodes = get_nodes()
    if not nodes:
        fail("Failed to retrieve at least 1 node.")
    first_node = nodes[0]

    while try_num < tries_limit and consecutive_good < consecutive_good_checks:
        nodes = get_nodes()
        if not nodes:
            fail("Failed to retrieve at least 1 node.")
        stats = get_cluster_statistics(nodes)
        builds = get_build_list(nodes)
        ns_data = info_cmd("namespaces", host=first_node[0], port=first_node[1])
        namespaces = ns_data.get("namespaces", "").split(";") if ns_data else []

        if try_num == 0:
            start_cluster_key = stats.get(first_node, {}).get("cluster_key")

        if fail_on_cluster_change and not cluster_key_consistent(stats, start_cluster_key):
            fail("Cluster key inconsistent.")
        if not is_min_cluster_size(stats):
            consecutive_good = 0
            try_num += 1
            if try_num < tries_limit:
                ctx.run(["sleep", str(sleep_between_checks)], mutates=False)
            continue
        if not cluster_migrates_allowed(stats):
            consecutive_good = 0
            try_num += 1
            if try_num < tries_limit:
                ctx.run(["sleep", str(sleep_between_checks)], mutates=False)
            continue

        if can_use_cluster_stable(builds):
            if cluster_stable(stats):
                consecutive_good += 1
            else:
                consecutive_good = 0
        else:
            has_migs = False
            if local_only:
                has_migs = node_has_migs(first_node, namespaces)
            else:
                for node in nodes:
                    if node_has_migs(node, namespaces):
                        has_migs = True
                        break
            if has_migs:
                consecutive_good = 0
            else:
                consecutive_good += 1

        try_num += 1
        if consecutive_good < consecutive_good_checks and try_num < tries_limit:
            ctx.run(["sleep", str(sleep_between_checks)], mutates=False)

    if consecutive_good == consecutive_good_checks:
        return {"changed": False, "msg": "Migrations complete."}
    fail("Failed to confirm migrations completion within tries limit.")

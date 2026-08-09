def main(ctx, params):
    state = params.get("state", "present")
    force = params.get("force", False)

    # Read-only probes
    swarm_info = _inspect_swarm(ctx)
    is_manager = _is_swarm_manager(ctx)
    is_node = _is_swarm_node(ctx)

    # Check idempotency for idempotent states
    if state == "present":
        if is_manager:
            if not force:
                # Get active spec and compare key mutable attributes
                active = _get_active_spec(ctx, swarm_info)
                desired = _get_desired_spec(ctx, params)
                if _spec_matches(active, desired, ctx):
                    return {"changed": False, "msg": "Swarm is already present and configuration matches"}
                # Need update
                if ctx.check_mode:
                    return {"changed": True, "msg": "would update swarm configuration"}
                _update_swarm(ctx, params, swarm_info)
                return {"changed": True, "msg": "Swarm configuration updated"}
            # Force new cluster
            if ctx.check_mode:
                return {"changed": True, "msg": "would create new swarm cluster (force=True)"}
            _init_swarm(ctx, params)
            return {"changed": True, "msg": "New Swarm cluster created"}

        # Not manager yet → init
        if ctx.check_mode:
            return {"changed": True, "msg": "would initialize swarm cluster"}
        _init_swarm(ctx, params)
        return {"changed": True, "msg": "New Swarm cluster created"}

    if state == "join":
        if is_node:
            return {"changed": False, "msg": "Node is already part of a swarm"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would join swarm cluster"}
        _join_swarm(ctx, params)
        return {"changed": True, "msg": "Node joined the swarm cluster"}

    if state == "absent":
        if not is_node:
            return {"changed": False, "msg": "Node is not part of a swarm"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would leave swarm cluster"}
        _leave_swarm(ctx, force)
        return {"changed": True, "msg": "Node left the swarm cluster"}

    if state == "remove":
        # Requires manager
        if not is_manager:
            fail("This node is not a manager; cannot remove nodes")
        node_id = params.get("node_id")
        if not node_id:
            fail("node_id is required when state=remove")
        # Check node status
        if not _node_is_down(ctx, node_id):
            fail("Cannot remove node: node status is not down")
        if ctx.check_mode:
            return {"changed": True, "msg": "would remove node from swarm"}
        _remove_node(ctx, node_id, force)
        return {"changed": True, "msg": "Node removed from swarm cluster"}

    fail("Unsupported state: " + state)


def _inspect_swarm(ctx):
    # Try to inspect current swarm
    res = ctx.run(["docker", "swarm", "inspect"], mutates=False, ok_codes=[0, 1])
    if res.rc != 0:
        return None
    # Parse JSON from stdout
    text = res.stdout.strip()
    if not text.startswith("{"):
        fail("Failed to parse docker swarm inspect output: not JSON")
    # Simple JSON parsing for Starlark
    data = _simple_json_parse(ctx, text)
    return data


def _is_swarm_manager(ctx):
    # Swarm manager if inspect succeeds and has ID
    info = _inspect_swarm(ctx)
    if not info:
        return False
    return (info.get("ID") or "") != ""


def _is_swarm_node(ctx):
    # A node is part of swarm if inspect returns non-null
    info = _inspect_swarm(ctx)
    return info != None


def _get_active_spec(ctx, swarm_info):
    # Parse relevant fields from swarm spec
    spec = (swarm_info.get("Spec") or {})
    raft = spec.get("Raft") or {}
    orchestration = spec.get("Orchestration") or {}
    ca_config = spec.get("CAConfig") or {}
    encryption_config = spec.get("EncryptionConfig") or {}
    dispatcher = spec.get("Dispatcher") or {}
    task_defaults = spec.get("TaskDefaults") or {}

    return {
        "snapshot_interval": raft.get("SnapshotInterval"),
        "keep_old_snapshots": raft.get("KeepOldSnapshots"),
        "heartbeat_tick": raft.get("HeartbeatTick"),
        "election_tick": raft.get("ElectionTick"),
        "log_entries_for_slow_followers": raft.get("LogEntriesForSlowFollowers"),
        "task_history_retention_limit": orchestration.get("TaskHistoryRetentionLimit"),
        "dispatcher_heartbeat_period": dispatcher.get("HeartbeatPeriod"),
        "node_cert_expiry": ca_config.get("NodeCertExpiry"),
        "name": spec.get("Name"),
        "labels": spec.get("Labels"),
        "signing_ca_cert": (ca_config.get("SigningCA") or {}).get("Cert") if ca_config.get("SigningCA") else "",
        "autolock_managers": encryption_config.get("AutoLockManagers", False),
        "ca_force_rotate": ca_config.get("ForceRotate", 0),
        "log_driver": (task_defaults.get("LogDriver") or {}).get("Type"),
    }


def _get_desired_spec(ctx, params):
    # Map params to spec dict
    desired = {}
    for key in [
        "snapshot_interval", "keep_old_snapshots", "heartbeat_tick", "election_tick",
        "log_entries_for_slow_followers", "task_history_retention_limit",
        "dispatcher_heartbeat_period", "node_cert_expiry", "name", "labels",
        "autolock_managers", "ca_force_rotate"
    ]:
        if params.get(key) != None:
            desired[key] = params[key]
    # Handle signing_ca_cert as a string; ensure present only if explicitly set
    if params.get("signing_ca_cert") != None:
        desired["signing_ca_cert"] = params["signing_ca_cert"]
    else:
        desired["signing_ca_cert"] = ""
    if params.get("log_driver"):
        pass  # Not supported in CLI mode
    return desired


def _spec_matches(active, desired, ctx):
    # Compare only mutable attributes relevant for update
    for k, v in desired.items():
        if k == "labels":
            # Compare dicts shallowly
            if not _dict_eq(v, active.get("labels")):
                return False
        elif k == "name" and v != active.get("name"):
            return False
        elif k == "signing_ca_cert" and v != active.get("signing_ca_cert"):
            return False
        elif k == "autolock_managers" and bool(v) != bool(active.get("autolock_managers")):
            return False
        elif k == "ca_force_rotate" and int(v) != int(active.get("ca_force_rotate", 0)):
            return False
        elif k in [
            "snapshot_interval", "keep_old_snapshots", "heartbeat_tick",
            "election_tick", "log_entries_for_slow_followers",
            "task_history_retention_limit", "dispatcher_heartbeat_period",
            "node_cert_expiry"
        ] and int(v) != int(active.get(k) or 0):
            return False
    return True


def _dict_eq(a, b):
    if a == None and b == None:
        return True
    if a == None or b == None:
        return False
    if len(a) != len(b):
        return False
    for k, v in a.items():
        if b.get(k) != v:
            return False
    return True


def _simple_json_parse(ctx, text):
    # Very limited JSON parser for Swarm inspect output
    # Expected structure: {"ID": "...", "Spec": {...}, ...}
    # Strip and parse manually
    text = text.strip()
    if not text.startswith("{") or not text.endswith("}"):
        fail("Expected JSON object")
    # Remove braces
    inner = text[1:-1].strip()
    # Parse key-value pairs
    result = {}
    # This is a simplified parser; for production use, rely on Python SDK
    fail("JSON parsing not supported in CLI Starlark mode; use docker_py-based module instead")
    return result


def _init_swarm(ctx, params):
    argv = ["docker", "swarm", "init"]
    if params.get("advertise_addr"):
        argv.extend(["--advertise-addr", params["advertise_addr"]])
    if params.get("listen_addr"):
        argv.extend(["--listen-addr", params["listen_addr"]])
    if params.get("data_path_addr"):
        argv.extend(["--data-path-addr", params["data_path_addr"]])
    if params.get("data_path_port"):
        argv.extend(["--data-path-port", str(params["data_path_port"])])
    # Spec options
    spec_opts = [
        "snapshot_interval", "keep_old_snapshots", "heartbeat_tick",
        "election_tick", "log_entries_for_slow_followers",
        "task_history_retention_limit", "dispatcher_heartbeat_period",
        "node_cert_expiry", "name", "autolock_managers", "ca_force_rotate"
    ]
    for k in spec_opts:
        if params.get(k) != None:
            argv.extend(["--" + k.replace("_", "-"), str(params[k])])
    # Labels and signing_ca_cert handling not supported in CLI mode
    if params.get("labels"):
        fail("labels parameter is not supported in this Starlark translation")
    if params.get("signing_ca_cert"):
        fail("signing_ca_cert parameter is not supported in this Starlark translation")
    res = ctx.run(argv, mutates=True, ok_codes=[0])
    if res.rc != 0:
        fail("Failed to init swarm: " + res.stderr)


def _join_swarm(ctx, params):
    argv = ["docker", "swarm", "join"]
    remote_addrs = params.get("remote_addrs")
    if not remote_addrs:
        fail("remote_addrs is required for state=join")
    # Use first remote address only for join target
    if params.get("advertise_addr"):
        argv.extend(["--advertise-addr", params["advertise_addr"]])
    if params.get("listen_addr"):
        argv.extend(["--listen-addr", params["listen_addr"]])
    if params.get("data_path_addr"):
        argv.extend(["--data-path-addr", params["data_path_addr"]])
    argv.append(remote_addrs[0])
    # Include join_token
    if params.get("join_token"):
        argv.append(params["join_token"])
    res = ctx.run(argv, mutates=True, ok_codes=[0])
    if res.rc != 0:
        fail("Failed to join swarm: " + res.stderr)


def _leave_swarm(ctx, force):
    argv = ["docker", "swarm", "leave"]
    if force:
        argv.append("--force")
    res = ctx.run(argv, mutates=True, ok_codes=[0])
    if res.rc != 0:
        fail("Failed to leave swarm: " + res.stderr)


def _node_is_down(ctx, node_id):
    # List nodes and check status
    res = ctx.run(["docker", "node", "ls", "--format", "{{.ID}} {{.Status}} {{.Availability}}"], mutates=False)
    if res.rc != 0:
        fail("Failed to list swarm nodes")
    lines = res.stdout.strip().split("\n")
    for line in lines:
        if not line:
            continue
        parts = line.strip().split()
        if len(parts) < 2:
            continue
        nid = parts[0]
        if nid == node_id:
            status = parts[1]
            return status in ("Down", "Disconnected")
    fail("Node not found in swarm: " + node_id)


def _remove_node(ctx, node_id, force):
    argv = ["docker", "node", "rm", node_id]
    if force:
        argv.append("--force")
    res = ctx.run(argv, mutates=True, ok_codes=[0])
    if res.rc != 0:
        fail("Failed to remove node " + node_id + ": " + res.stderr)


def _update_swarm(ctx, params, swarm_info):
    version = (swarm_info.get("Version") or {}).get("Index")
    if not version:
        fail("Swarm version not available for update")
    # CLI does not support swarm spec updates; only token rotation is possible via API
    # Check if token rotation is requested
    if params.get("rotate_worker_token") or params.get("rotate_manager_token"):
        # Token rotation supported via CLI? No — only via Docker API
        fail("Token rotation is not supported in CLI Starlark mode; use docker_py-based module instead")
    fail("Swarm spec updates are not supported in CLI Starlark mode; use docker_py-based module instead")

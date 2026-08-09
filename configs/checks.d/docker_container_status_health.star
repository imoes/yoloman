# ===== check plugin: docker_container_status_health =====
# Translated from Checkmk check mkc.docker_container_status_health
# Reads the SAME host source the docker agent plugin reads:
#   the container's real Status / Health / Healthcheck / ImageTags.

# Default health thresholds (Checkmk defaults for this check)
DEFAULT_WARN = 0
DEFAULT_CRIT = 1


def _is_active_container(section):
    """Whether the container is or should be running."""
    if section.get("Status") in ("running", "exited"):
        return True
    restart_policy_name = section.get("RestartPolicy", {}).get("Name")
    return restart_policy_name in ("always",)


# Metric name used by the source check for the health exit code
METRIC_HEALTH_EXIT = "health_exit_status"


def _gather_containers(ctx, host, community):
    """Gather docker containers via the docker CLI.
    Returns a list of dicts, one per container, with the same keys the
    Checkmk agent section 'docker_container_status' provides:
      Id, Name, Image, ImageTags, Status, State, RestartPolicy,
      NodeName, Error, StartedAt, Health, Healthcheck
    Returns None (signalling 'docker not present') if docker is missing.
    """
    # Probe for the real thing first.
    probe = ctx.run(["docker", "--version"], mutates=False)
    if probe.rc == 127:
        return None

    # Inspect every container with the same fields the agent section exposes.
    res = ctx.run(
        ["docker", "ps", "-a", "--format", "{{.ID}} {{.Names}} {{.Image}} {{.Status}}"],
        mutates=False,
    )
    if res.rc != 0:
        return None

    containers = []
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        f = line.split(" ", 3)
        if len(f) < 4:
            continue
        cid = f[0]
        name = f[1]
        image = f[2]
        status_raw = f[3]

        # Detailed inspect gives us the structured data the check uses.
        insp = ctx.run(
            ["docker", "inspect", cid],
            mutates=False,
        )
        if insp.rc != 0 or not insp.stdout.strip():
            continue
        data = json.decode(insp.stdout.strip())[0]
        if type(data) != "dict":
            continue

        state = data.get("State", {}) or {}
        cfg = data.get("Config", {}) or {}
        host_cfg = data.get("HostConfig", {}) or {}

        health = state.get("Health", {}) or {}
        healthcheck = cfg.get("Healthcheck", {}) or {}

        status_str = state.get("Status", status_raw)
        started_at = state.get("StartedAt", "")
        error_msg = state.get("Error", "")
        node_name = data.get("Node", {}).get("Name", "") if isinstance(data.get("Node"), type({})) else ""

        containers.append({
            "Id": cid,
            "Names": name,
            "Name": name,
            "Image": cfg.get("Image", image),
            "ImageTags": data.get("RepoTags", []) if data.get("RepoTags") else [],
            "Status": status_str,
            "State": state_str_to_status(status_str),
            "RestartPolicy": host_cfg.get("RestartPolicy", {}),
            "NodeName": node_name,
            "Error": error_msg,
            "StartedAt": started_at,
            "Health": health,
            "Healthcheck": healthcheck,
        })

    return containers


def state_str_to_status(status):
    mapping = {
        "running": "running",
        "exited": "exited",
        "paused": "paused",
        "restarting": "restarting",
        "dead": "dead",
        "created": "created",
    }
    return mapping.get(status, status)


def _container_item_name(c):
    """Build a stable, readable item name for a container.
    Prefer the container name, fall back to the ID."""
    name = c.get("Name", "")
    if name:
        return name
    return c.get("Id", "")


def _health_state_for(section):
    """Map the container's Health.Status to OK/WARN/CRIT/UNKNOWN."""
    health_status = section.get("Health", {}).get("Status", "unknown")
    mapping = {
        "healthy": "OK",
        "starting": "WARN",
        "unhealthy": "CRIT",
    }
    return mapping.get(health_status, "UNKNOWN"), health_status


def _grade_health(ctx, params, health_status_str, last_exit_code):
    """Apply warn/crit levels to the health status.
    The source check grades 'unhealthy' as CRIT and 'starting' as WARN.
    We honour operator-supplied levels if present (none by default here,
    matching the upstream check which has no threshold params)."""
    state, _ = _health_state_for({"Health": {"Status": health_status_str}})
    return state


def main(ctx, params):
    # ---- DISCOVERY MODE ----
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        containers = _gather_containers(ctx, host, community)
        if containers == None:
            # docker not installed -> check does not apply
            return {"changed": False, "msg": "docker not installed", "data": {"discovery": []}}

        discovery = []
        host_labels = {"cmk/docker_object": "container"}
        for c in containers:
            section = c
            if not _is_active_container(section):
                continue
            # Only discover if a HEALTHCHECK is configured AND health data is present.
            if not ("Healthcheck" in section and "Health" in section):
                continue
            if not section.get("Healthcheck", {}).get("Test"):
                continue
            item = _container_item_name(c)

            # Service labels: stable container facts, not measurements.
            svc_labels = {}
            image_tags = section.get("ImageTags", [])
            if image_tags:
                image = image_tags[-1]
                svc_labels["cmk/docker_image"] = image
                if "/" in image:
                    _, tail = image.rsplit("/", 1)
                else:
                    tail = image
                if ":" in tail:
                    img_name, img_ver = tail.rsplit(":", 1)
                    svc_labels["cmk/docker_image_name"] = img_name
                    svc_labels["cmk/docker_image_version"] = img_ver
                else:
                    svc_labels["cmk/docker_image_name"] = tail

            discovery.append({
                "item": item,
                "params": {"warn": DEFAULT_WARN, "crit": DEFAULT_CRIT},
                "metrics": ["health_exit_status"],
                "service_labels": svc_labels,
            })

        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery, "host_labels": host_labels},
        }

    # ---- CHECK MODE (per item) ----
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")

    containers = _gather_containers(ctx, host, community)
    if containers == None:
        return {
            "changed": False,
            "msg": "docker not installed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "docker CLI not found"},
        }

    target = None
    for c in containers:
        if _container_item_name(c) == item:
            target = c
            break
    if target == None:
        return {
            "changed": False,
            "msg": "no such container: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    section = target
    if section.get("Status") != "running":
        # Downstream of MultipleNodesMarker / not-running handling in the source
        return {
            "changed": False,
            "msg": "Container is not running",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "container status: %s" % section.get("Status", "unknown")},
        }

    health = section.get("Health", {})
    health_status_str = health.get("Status", "unknown")
    state = _health_state_for(section)[0]

    # Last log entry -> exit code metric + last health report
    log = health.get("Log", []) or []
    last_log = log[-1] if log else {}
    last_exit_code = 0
    if isinstance(last_log, type({})) and last_log.get("ExitCode") != None:
        last_exit_code = int(last_log.get("ExitCode"))

    metrics = {METRIC_HEALTH_EXIT: last_exit_code}

    details = ""
    health_report = (last_log.get("Output", "no output") or "no output").strip().replace("\n", ", ")
    if health_report:
        details += "Last health report: %s" % health_report

    if health_status_str:
        details += ("\n" if details else "") + "Health status: %s" % health_status_str.title()

    if state == "CRIT":
        failing_streak = section.get("Health", {}).get("FailingStreak", "not found")
        details += ("\n" if details else "") + "Failing streak: %s" % failing_streak

    health_test = section.get("Healthcheck", {}).get("Test", [])
    if health_test:
        test_line = " ".join(health_test)
        summary_parts = test_line.split("\n", 1)
        summary = summary_parts[0]
        if "#!" in summary:
            summary = summary.split("#!", 1)[0].strip()
        details += ("\n" if details else "") + test_line

    summary = "Health status: %s" % health_status_str.title()
    if health_report:
        summary += "; Last health report: %s" % health_report

    return {
        "changed": False,
        "msg": summary,
        "data": {"state": state, "metrics": metrics, "details": details},
    }
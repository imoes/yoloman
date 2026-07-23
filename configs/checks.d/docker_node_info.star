def main(ctx, params):
    # Read Docker node info from the agent
    res = ctx.run(["docker", "info", "--format", "{{json .}}"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "Docker daemon not accessible or no data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Parse JSON output
    info = json.decode(res.stdout)

    # Extract node name for OK summary
    node_name = info.get("Name", "")

    # Collect metrics for performance data
    metrics = {}
    # Containers metrics
    containers = info.get("Containers")
    if containers != None:
        metrics["Containers"] = int(containers)
    running = info.get("ContainersRunning")
    if running != None:
        metrics["ContainersRunning"] = int(running)
    paused = info.get("ContainersPaused")
    if paused != None:
        metrics["ContainersPaused"] = int(paused)
    stopped = info.get("ContainersStopped")
    if stopped != None:
        metrics["ContainersStopped"] = int(stopped)

    # Images count
    images = info.get("Images")
    if images != None:
        metrics["Images"] = int(images)

    # Build summary line
    if node_name:
        summary = "Daemon running on host %s" % node_name
    else:
        summary = "Docker daemon running"

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": "OK",
            "metrics": metrics,
            "details": "",
        },
    }
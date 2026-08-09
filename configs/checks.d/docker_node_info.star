# Check: checkmk.docker_node_info
# Short description: Docker node info

def main(ctx, params):
    # Docker node info check - read-only monitoring of Docker daemon
    
    # Probe for real thing: docker binary must exist
    version_res = ctx.run(["docker", "version", "--format", "{{.Server.Os}}"], mutates=False)
    if version_res.rc == 127:
        # Docker not installed
        if params.get("_discover"):
            return {"changed": False, "msg": "docker not installed",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "docker not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "Docker binary not found"}}
    
    # Get node info via docker info
    info_res = ctx.run(["docker", "info", "--format", "{{json .}}"], mutates=False)
    if info_res.rc != 0:
        if params.get("_discover"):
            return {"changed": False, "msg": "docker daemon not running",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "docker daemon not running",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "Could not reach Docker daemon"}}
    
    # Parse JSON output
    info = json.decode(info_res.stdout)
    
    if params.get("_discover"):
        # Discovery: yield one service if section is present
        if info != None and "Name" in info:
            return {"changed": False, "msg": "discovered Docker node info service",
                    "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}}
        return {"changed": False, "msg": "no docker node info found",
                "data": {"discovery": []}}
    
    # Check mode: report daemon status
    name = info.get("Name", "unknown")
    return {"changed": False, "msg": "Daemon running on host %s" % name,
            "data": {"state": "OK", "metrics": {}, "details": ""}}
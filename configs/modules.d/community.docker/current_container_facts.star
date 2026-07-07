def main(ctx, params):
    cpuset_path = "/proc/self/cpuset"
    mountinfo_path = "/proc/self/mountinfo"

    container_id = ""
    container_type = ""

    # Try cpuset-based detection first
    if ctx.file_exists(cpuset_path):
        contents = ctx.file_read(cpuset_path).strip()
        last_slash = contents.rfind("/")
        if last_slash != -1:
            cgroup_name = contents[last_slash + 1:]
            cgroup_path = contents[:last_slash]
            if cgroup_path == "/docker":
                container_id = cgroup_name
                container_type = "docker"
            elif cgroup_path == "/azpl_job":
                container_id = cgroup_name
                container_type = "azure_pipelines"
            elif cgroup_path == "/actions_job":
                container_id = cgroup_name
                container_type = "github_actions"

    # Fallback to mountinfo detection if cpuset detection failed
    if not container_id and ctx.file_exists(mountinfo_path):
        contents = ctx.file_read(mountinfo_path)
        for line in contents.splitlines():
            parts = line.split()
            if len(parts) >= 5 and parts[4] == "/etc/hostname":
                path_part = parts[3]
                # Check for docker pattern: .../64-hex/hostname
                if "/hostname" in path_part:
                    idx = path_part.rfind("/")
                    if idx != -1:
                        potential_id = path_part[idx + 1:]
                        if len(potential_id) == 64:
                            is_hex = True
                            for c in potential_id:
                                if not ((c >= "0" and c <= "9") or (c >= "a" and c <= "f") or (c >= "A" and c <= "F")):
                                    is_hex = False
                                    break
                            if is_hex:
                                container_id = potential_id
                                container_type = "docker"
                # Check for podman pattern: .../64-hex/userdata/hostname
                elif "/userdata/hostname" in path_part:
                    idx1 = path_part.find("/userdata")
                    if idx1 != -1:
                        before_userdata = path_part[:idx1]
                        idx2 = before_userdata.rfind("/")
                        if idx2 != -1:
                            potential_id = before_userdata[idx2 + 1:]
                            if len(potential_id) == 64:
                                is_hex = True
                                for c in potential_id:
                                    if not ((c >= "0" and c <= "9") or (c >= "a" and c <= "f") or (c >= "A" and c <= "F")):
                                        is_hex = False
                                        break
                                if is_hex:
                                    container_id = potential_id
                                    container_type = "podman"

    # Build result
    running_in_container = container_id != ""
    facts = {
        "ansible_module_running_in_container": running_in_container,
        "ansible_module_container_id": container_id,
        "ansible_module_container_type": container_type,
    }

    return {
        "changed": False,
        "msg": "facts gathered",
        "data": {"ansible_facts": facts}
    }

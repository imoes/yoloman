def main(ctx, params):
    hostname = params["hostname"]
    actions = []
    changed = False

    # Step 1: Truncate /etc/machine-id to empty
    machine_id_path = "/etc/machine-id"
    if ctx.file_exists(machine_id_path):
        content = ctx.file_read(machine_id_path)
        if content != "":
            ctx.file_write(machine_id_path, "")
            actions.append("truncated /etc/machine-id")
            changed = True
    else:
        ctx.file_write(machine_id_path, "")
        actions.append("created empty /etc/machine-id")
        changed = True

    # Step 2: Remove /var/lib/dbus/machine-id if present
    dbus_machine_id_path = "/var/lib/dbus/machine-id"
    if ctx.file_exists(dbus_machine_id_path):
        ctx.run(["rm", "-f", dbus_machine_id_path], mutates=True)
        actions.append("removed /var/lib/dbus/machine-id")
        changed = True

    # Step 3: Remove SSH host keys
    ssh_key_dir = "/etc/ssh"
    ssh_keys_exist = False
    stat_result = ctx.stat(ssh_key_dir)
    if stat_result != None and stat_result["is_dir"]:
        # Check if any ssh_host_* files exist by listing directory contents
        res = ctx.run(["find", ssh_key_dir, "-maxdepth", "1", "-name", "ssh_host_*"])
        if res.stdout.strip() != "":
            ssh_keys_exist = True
    
    if ssh_keys_exist:
        ctx.run(["find", ssh_key_dir, "-maxdepth", "1", "-name", "ssh_host_*", "-delete"], mutates=True)
        actions.append("removed SSH host keys")
        changed = True

    # Step 4: Update /etc/hostname
    hostname_path = "/etc/hostname"
    current_hostname = ""
    if ctx.file_exists(hostname_path):
        current_hostname = ctx.file_read(hostname_path).strip()
    
    if current_hostname != hostname:
        ctx.file_write(hostname_path, hostname + "\n")
        actions.append("updated /etc/hostname to %s" % hostname)
        changed = True

    # Step 5: Update /etc/hosts
    hosts_path = "/etc/hosts"
    hosts_content = ""
    if ctx.file_exists(hosts_path):
        hosts_content = ctx.file_read(hosts_path)
    
    short_hostname = hostname.split(".")[0]
    fqdn_line = "127.0.1.1\t%s %s" % (hostname, short_hostname)
    
    lines = hosts_content.split("\n") if hosts_content else []
    new_lines = []
    found_127_0_1_1 = False
    
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("127.0.1.1"):
            if not found_127_0_1_1:
                new_lines.append(fqdn_line)
                found_127_0_1_1 = True
            # Skip original line
        else:
            new_lines.append(line)
    
    if not found_127_0_1_1:
        if new_lines and new_lines[-1] == "":
            new_lines[-1] = fqdn_line
        else:
            new_lines.append(fqdn_line)
    
    new_hosts_content = "\n".join(new_lines)
    if hosts_content != new_hosts_content:
        ctx.file_write(hosts_path, new_hosts_content)
        actions.append("updated /etc/hosts")
        changed = True

    # Step 6: Cloud configuration
    cloud_dir = "/etc/cloud"
    if ctx.file_exists(cloud_dir):
        ctx.run(["mkdir", "-p", "/etc/cloud/cloud.cfg.d"], mutates=True)
        cloud_cfg_path = "/etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg"
        cloud_cfg_content = "preserve_hostname: true\n"
        
        current_cloud_cfg = ""
        if ctx.file_exists(cloud_cfg_path):
            current_cloud_cfg = ctx.file_read(cloud_cfg_path)
        
        if current_cloud_cfg != cloud_cfg_content:
            ctx.file_write(cloud_cfg_path, cloud_cfg_content)
            actions.append("wrote cloud hostname preservation config")
            changed = True
        
        # Remove cloud instance data
        cloud_instance_path = "/var/lib/cloud/instance"
        cloud_instances_path = "/var/lib/cloud/instances"
        
        cloud_paths = [path for path in [cloud_instance_path, cloud_instances_path] if ctx.file_exists(path)]
        if cloud_paths:
            ctx.run(["rm", "-rf"] + cloud_paths, mutates=True)
            actions.append("removed cloud instance data")
            changed = True

    msg = "machine identity reset" if changed else "machine identity already correct"
    return {"changed": changed, "msg": msg, "data": {"hostname": hostname, "actions": actions}}

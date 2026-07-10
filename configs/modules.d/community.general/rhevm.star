def main(ctx, params):
    name = params.get("name")
    state = params.get("state", "present")
    user = params.get("user", "admin@internal")
    password = params.get("password")
    server = params.get("server", "127.0.0.1")
    port = params.get("port", 443)
    insecure_api = params.get("insecure_api", False)
    cluster = params.get("cluster", "")
    image = params.get("image")
    type_ = params.get("type", "server")
    vmhost = params.get("vmhost")
    vmcpu = params.get("vmcpu", 2)
    vmmem = params.get("vmmem", 1)
    osver = params.get("osver", "rhel_6x64")
    mempol = params.get("mempol", 1)
    vm_ha = params.get("vm_ha", True)
    del_prot = params.get("del_prot", True)
    boot_order = params.get("boot_order", ["hd", "network"])
    cd_drive = params.get("cd_drive")
    timeout = params.get("timeout", 300)

    if password == None:
        fail("password is required")

    if name == None:
        fail("name is required")

    if params.get("disks") != None:
        fail("disks option not supported in Starlark translation")
    if params.get("ifaces") != None:
        fail("ifaces option not supported in Starlark translation")
    if params.get("cpu_share") != 0:
        fail("cpu_share option not supported in Starlark translation")
    if params.get("datacenter") != "Default":
        fail("datacenter option not supported in Starlark translation")
    if params.get("cluster") == "":
        fail("cluster option is required")

    base_url = "https://" + server + ":" + str(port) + "/ovirt-engine/api"
    auth_header = "Authorization: Basic " + str(ctx.hash(user + ":" + password))[:20]

    def curl_get(path):
        url = base_url + path
        res = ctx.run(["curl", "-s", "-k", "-H", "Accept: application/json", url], mutates=False)
        if res.rc != 0:
            fail("curl GET failed: " + res.stderr)
        return res.stdout

    def curl_post(path, data, mutates=False):
        url = base_url + path
        res = ctx.run(["curl", "-s", "-k", "-X", "POST", "-H", "Content-Type: application/xml", "-d", data, url], mutates=mutates)
        if res.rc != 0:
            fail("curl POST failed: " + res.stderr)
        return res.rc == 0

    def curl_put(path, data):
        url = base_url + path
        res = ctx.run(["curl", "-s", "-k", "-X", "PUT", "-H", "Content-Type: application/xml", "-d", data, url], mutates=False)
        if res.rc != 0:
            fail("curl PUT failed: " + res.stderr)
        return res.rc == 0

    def get_vm_id():
        vms = curl_get("/vms?search=name=" + name)
        if vms.find("<vm>") == -1:
            return None
        idx = vms.find("<id>")
        if idx == -1:
            return None
        end = vms.find("</id>", idx)
        return vms[idx + 4:end].strip()

    vm_id = get_vm_id()
    changed = False
    msg_list = []

    if state == "ping":
        res = ctx.run(["curl", "-s", "-k", "-H", "Accept: application/json", base_url + "/vms"], mutates=False)
        if res.rc != 0:
            fail("API ping failed")
        return {"changed": False, "msg": "API ping OK"}

    if state == "info":
        if vm_id == None:
            return {"changed": False, "msg": "VM not found", "data": {}}
        return {"changed": False, "msg": "VM found", "data": {"name": name, "id": vm_id, "state": "unknown"}}

    if state == "absent":
        if vm_id == None:
            return {"changed": False, "msg": "VM does not exist"}
        status = curl_get("/vms/" + vm_id + "/status")
        if status.find("<state>up</state>") != -1:
            data = "<action><force>true</force></action>"
            if not curl_post("/vms/" + vm_id + "/stop", data, mutates=True):
                fail("Failed to stop VM before deletion")
            for _ in range(30):
                st = curl_get("/vms/" + vm_id + "/status")
                if st.find("<state>down</state>") != -1:
                    break
            res = ctx.run(["curl", "-s", "-k", "-X", "DELETE", base_url + "/vms/" + vm_id], mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would delete VM " + name}
            if res.rc != 0:
                fail("Failed to delete VM: " + res.stderr)
            return {"changed": True, "msg": "deleted VM " + name}
        res = ctx.run(["curl", "-s", "-k", "-X", "DELETE", base_url + "/vms/" + vm_id], mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would delete VM " + name}
        if res.rc != 0:
            fail("Failed to delete VM: " + res.stderr)
        return {"changed": True, "msg": "deleted VM " + name}

    if state == "present":
        if vm_id != None:
            return {"changed": False, "msg": "VM already exists"}
        vm_xml = (
            "<vm>" +
            "<name>" + name + "</name>" +
            "<cluster><name>" + cluster + "</name></cluster>" +
            "<template><name>" + (image if image else "Blank") + "</name></template>" +
            "<type>" + type_ + "</type>" +
            "<memory>" + str(int(vmmem) * 1024 * 1024 * 1024) + "</memory>" +
            "<cpu><topology cores='" + str(vmcpu) + "' sockets='1'/></cpu>" +
            "<os><type>" + osver + "</type></os>" +
            "<high_availability><enabled>" + ("true" if vm_ha else "false") + "</enabled></high_availability>" +
            "<delete_protected>" + ("true" if del_prot else "false") + "</delete_protected>" +
            "</vm>"
        )
        if not curl_post("/vms", vm_xml, mutates=True):
            fail("Failed to create VM")
        for _ in range(30):
            st = curl_get("/vms/" + name + "/status")
            if st.find("<state>down</state>") != -1:
                break
        changed = True
        msg_list.append("created VM " + name)

    if state == "up":
        if vm_id == None:
            fail("VM does not exist")
        status = curl_get("/vms/" + vm_id + "/status")
        if status.find("<state>up</state>") != -1:
            return {"changed": False, "msg": "VM already up"}
        data = "<action/>"
        if not curl_post("/vms/" + vm_id + "/start", data, mutates=True):
            fail("Failed to start VM")
        for _ in range(30):
            st = curl_get("/vms/" + vm_id + "/status")
            if st.find("<state>up</state>") != -1:
                break
        return {"changed": True, "msg": "started VM " + name}

    if state == "down":
        if vm_id == None:
            fail("VM does not exist")
        status = curl_get("/vms/" + vm_id + "/status")
        if status.find("<state>down</state>") != -1:
            return {"changed": False, "msg": "VM already down"}
        data = "<action><force>true</force></action>"
        if not curl_post("/vms/" + vm_id + "/stop", data, mutates=True):
            fail("Failed to stop VM")
        for _ in range(30):
            st = curl_get("/vms/" + vm_id + "/status")
            if st.find("<state>down</state>") != -1:
                break
        return {"changed": True, "msg": "stopped VM " + name}

    if state == "restarted":
        if vm_id == None:
            fail("VM does not exist")
        data = "<action><force>true</force></action>"
        if not curl_post("/vms/" + vm_id + "/stop", data, mutates=True):
            fail("Failed to stop VM for restart")
        for _ in range(30):
            st = curl_get("/vms/" + vm_id + "/status")
            if st.find("<state>down</state>") != -1:
                break
        data = "<action/>"
        if not curl_post("/vms/" + vm_id + "/start", data, mutates=True):
            fail("Failed to start VM after restart")
        for _ in range(30):
            st = curl_get("/vms/" + vm_id + "/status")
            if st.find("<state>up</state>") != -1:
                break
        return {"changed": True, "msg": "restarted VM " + name}

    if state == "cd":
        if vm_id == None:
            fail("VM does not exist")
        if cd_drive == None:
            fail("cd_drive is required for state=cd")
        cd_xml = "<cdrom><file id='00000000-0000-0000-0000-000000000000'><name>" + cd_drive + "</name></file></cdrom>"
        if not curl_post("/vms/" + vm_id + "/cdroms/00000000-0000-0000-0000-000000000000", cd_xml, mutates=True):
            fail("Failed to attach CD")
        return {"changed": True, "msg": "attached CD " + cd_drive + " to VM " + name}

    return {"changed": changed, "msg": "; ".join(msg_list)}

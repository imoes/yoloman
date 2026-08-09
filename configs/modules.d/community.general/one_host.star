def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    im_mad_name = params.get("im_mad_name", "kvm")
    vmm_mad_name = params.get("vmm_mad_name", "kvm")
    cluster_id = params.get("cluster_id", 0)
    cluster_name = params.get("cluster_name")
    labels = params.get("labels")
    template = params.get("template", {})
    wait_timeout = params.get("wait_timeout", 300)

    if cluster_name != None and cluster_id != 0:
        fail("cannot specify both cluster_id and cluster_name")

    if cluster_name != None:
        res = ctx.run(["onecluster", "list", "--no-header"], mutates=False)
        if res.rc != 0:
            fail("failed to list clusters: " + res.stderr)
        clusters = [l.strip().split() for l in res.stdout.split("\n") if l.strip()]
        found = False
        for c in clusters:
            if len(c) >= 2 and c[1] == cluster_name:
                cluster_id = int(c[0])
                found = True
                break
        if not found:
            fail("cluster not found: " + cluster_name)

    cmd = ["onehost", "info", str(name)]

    res = ctx.run(cmd, mutates=False)
    host_exists = res.rc == 0
    host_state = None
    if host_exists:
        for line in res.stdout.split("\n"):
            line = line.strip()
            if line.startswith("STATE"):
                state_str = line.split("=",1)[1].strip()
                if state_str == "MONITORED":
                    host_state = 0
                elif state_str == "DISABLED":
                    host_state = 1
                elif state_str == "OFFLINE":
                    host_state = 2
                elif state_str == "ERROR":
                    host_state = 3
                elif state_str == "MONITORING_ERROR":
                    host_state = 4
                break

    HOST_ABSENT = -99
    HOST_MONITORED = 0
    HOST_DISABLED = 1
    HOST_OFFLINE = 2

    current_state = host_state if host_exists else HOST_ABSENT

    changed = False
    msg = ""

    def wait_for_state(target_states, timeout=wait_timeout, interval=2):
        elapsed = 0
        while elapsed < timeout:
            res = ctx.run(cmd, mutates=False)
            if res.rc != 0:
                return None
            s = None
            for line in res.stdout.split("\n"):
                line = line.strip()
                if line.startswith("STATE"):
                    st = line.split("=",1)[1].strip()
                    if st == "MONITORED": s = 0
                    elif st == "DISABLED": s = 1
                    elif st == "OFFLINE": s = 2
                    elif st == "ERROR": s = 3
                    elif st == "MONITORING_ERROR": s = 4
                    break
            if s in target_states:
                return s
            if s in [3,4]:
                return None
            import_time = 0
            while import_time < interval:
                import_time = import_time + 1
            elapsed = elapsed + interval
        return None

    if state == "present":
        if current_state == HOST_ABSENT:
            if ctx.check_mode:
                return {"changed": True, "msg": "would create host " + name}
            create_cmd = ["onehost", "create", name, vmm_mad_name, im_mad_name, str(cluster_id)]
            res = ctx.run(create_cmd, mutates=True)
            if res.rc != 0:
                fail("failed to create host: " + res.stderr)
            changed = True
            if not ctx.check_mode:
                if wait_for_state([HOST_MONITORED]) == None:
                    fail("host did not reach MONITORED state")
            msg = "created host " + name
        elif current_state in [HOST_DISABLED, HOST_OFFLINE, HOST_MONITORED]:
            msg = "host already exists"
            if current_state != HOST_ABSENT:
                res = ctx.run(cmd, mutates=False)
                current_cid = None
                for line in res.stdout.split("\n"):
                    line = line.strip()
                    if line.startswith("CLUSTER_ID"):
                        current_cid = int(line.split("=",1)[1].strip())
                        break
                if current_cid != cluster_id:
                    if ctx.check_mode:
                        changed = True
                        msg = "would update cluster of host " + name
                    else:
                        res = ctx.run(["onecluster", "addhost", str(cluster_id), str(name)], mutates=True)
                        if res.rc != 0:
                            fail("failed to assign host to cluster: " + res.stderr)
                        changed = True
                        msg = "updated cluster of host " + name
        else:
            fail("invalid host state to bring to present: " + str(current_state))

    elif state == "absent":
        if current_state != HOST_ABSENT:
            if ctx.check_mode:
                return {"changed": True, "msg": "would delete host " + name}
            res = ctx.run(["onehost", "delete", name], mutates=True)
            if res.rc != 0:
                fail("failed to delete host: " + res.stderr)
            changed = True
            msg = "deleted host " + name
        else:
            msg = "host already absent"

    elif state == "enabled":
        if current_state == HOST_ABSENT:
            if ctx.check_mode:
                return {"changed": True, "msg": "would create and enable host " + name}
            res = ctx.run(["onehost", "create", name, vmm_mad_name, im_mad_name, str(cluster_id)], mutates=True)
            if res.rc != 0:
                fail("failed to create host: " + res.stderr)
            changed = True
            if wait_for_state([HOST_MONITORED]) == None:
                fail("host did not reach MONITORED state")
            msg = "created and enabled host " + name
        elif current_state in [HOST_DISABLED, HOST_OFFLINE]:
            if ctx.check_mode:
                return {"changed": True, "msg": "would enable host " + name}
            fail("enabling/disabling host via CLI is not supported; use onehost command directly")
        elif current_state == HOST_MONITORED:
            msg = "host already enabled"
        else:
            fail("cannot enable host in state " + str(current_state))

    elif state == "disabled":
        if current_state == HOST_ABSENT:
            fail("cannot disable absent host")
        elif current_state in [HOST_MONITORED, HOST_OFFLINE]:
            if ctx.check_mode:
                return {"changed": True, "msg": "would disable host " + name}
            fail("disabling host via CLI is not supported; use onehost command directly")
        elif current_state == HOST_DISABLED:
            msg = "host already disabled"
        else:
            fail("cannot disable host in state " + str(current_state))

    elif state == "offline":
        if current_state == HOST_ABSENT:
            fail("cannot offline absent host")
        elif current_state in [HOST_MONITORED, HOST_DISABLED]:
            if ctx.check_mode:
                return {"changed": True, "msg": "would offline host " + name}
            fail("setting host offline via CLI is not supported; use onehost command directly")
        elif current_state == HOST_OFFLINE:
            msg = "host already offline"
        else:
            fail("cannot offline host in state " + str(current_state))
    else:
        fail("unsupported state: " + state)

    if state != "absent" and current_state != HOST_ABSENT:
        desired = {}
        if labels != None:
            desired["LABELS"] = labels
        if template != {}:
            for k, v in template.items():
                desired[k] = v
        if "LABELS" in desired and not isinstance(desired["LABELS"], list):
            desired["LABELS"] = [desired["LABELS"]]
        if desired:
            attr_parts = []
            for k, v in desired.items():
                if k == "LABELS" and isinstance(v, list):
                    attr_parts.append("LABELS=" + ",".join([str(x) for x in v]))
                else:
                    attr_parts.append(str(k) + "=" + str(v))
            if attr_parts:
                if ctx.check_mode:
                    if not changed:
                        changed = True
                        msg = "would update host template"
                else:
                    res = ctx.run(cmd, mutates=False)
                    host_id = None
                    for line in res.stdout.split("\n"):
                        line = line.strip()
                        if line.startswith("ID"):
                            host_id = int(line.split("=",1)[1].strip())
                            break
                    if host_id == None:
                        fail("could not get host id")
                    attr_str = " ".join(attr_parts)
                    res = ctx.run(["onehost", "update", str(host_id), attr_str], mutates=True)
                    if res.rc != 0:
                        fail("failed to update host template: " + res.stderr)
                    changed = True
                    msg = "updated host template"

    return {"changed": changed, "msg": msg}

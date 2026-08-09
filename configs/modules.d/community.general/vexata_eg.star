def main(ctx, params):
    array = params["array"]
    name = params["name"]
    state = params.get("state", "present")
    user = params.get("user")
    password = params.get("password")
    validate_certs = params.get("validate_certs", False)
    vg = params.get("vg")
    ig = params.get("ig")
    pg = params.get("pg")

    # Check mode: predict changes without acting
    if ctx.check_mode:
        # In check mode, we only predict whether a change would be made
        res = ctx.run(
            ["curl", "-s", "-k", "-X", "GET",
             "https://%s/api/1.0/export-groups" % array,
             "-u", user + ":" + password],
            mutates=False
        )
        if res.rc != 0:
            fail("Failed to list export groups: " + res.stderr)
        # Parse JSON manually: simple search for name in stdout
        egs = res.stdout
        found = False
        for line in egs.splitlines():
            line = line.strip()
            # crude JSON parsing: look for "name": "name"
            idx = line.find('"name"')
            if idx >= 0:
                val = line[idx + 6:].strip()
                if val.startswith(":"):
                    val = val[1:].strip()
                if val.startswith('"') and val.endswith('"'):
                    if val[1:-1] == name:
                        found = True
                        break
        if state == "present":
            if not found and (vg == None or ig == None or pg == None):
                fail("vg, ig, and pg are required to create export group " + name + " when not present")
            if not found:
                return {"changed": True, "msg": "would create export group " + name}
            return {"changed": False, "msg": "export group " + name + " already exists"}
        else:  # absent
            if found:
                return {"changed": True, "msg": "would delete export group " + name}
            return {"changed": False, "msg": "export group " + name + " does not exist"}

    # Actual execution
    if state == "present":
        # Ensure vg, ig, pg are provided for creation
        if vg == None or ig == None or pg == None:
            fail("vg, ig, and pg are required to create export group")

        # First, retrieve IDs for vg, ig, pg by calling list endpoints
        vgs_res = ctx.run(
            ["curl", "-s", "-k", "-X", "GET",
             "https://%s/api/1.0/volume-groups" % array,
             "-u", user + ":" + password],
            mutates=False
        )
        if vgs_res.rc != 0:
            fail("Failed to list volume groups: " + vgs_res.stderr)

        vgs = vgs_res.stdout
        vg_id = None
        for line in vgs.splitlines():
            line = line.strip()
            idx = line.find('"name"')
            if idx >= 0:
                val = line[idx + 6:].strip()
                if val.startswith(":"):
                    val = val[1:].strip()
                if val.startswith('"') and val.endswith('"'):
                    if val[1:-1] == vg:
                        # Extract id
                        id_idx = line.find('"id"')
                        if id_idx >= 0:
                            id_val = line[id_idx + 4:].strip()
                            if id_val.startswith(":"):
                                id_val = id_val[1:].strip()
                            if id_val.startswith('"') and id_val.endswith('"'):
                                vg_id = id_val[1:-1]
                        break
        if vg_id == None:
            fail("Volume group %s was not found." % vg)

        igs_res = ctx.run(
            ["curl", "-s", "-k", "-X", "GET",
             "https://%s/api/1.0/initiator-groups" % array,
             "-u", user + ":" + password],
            mutates=False
        )
        if igs_res.rc != 0:
            fail("Failed to list initiator groups: " + igs_res.stderr)

        igs = igs_res.stdout
        ig_id = None
        for line in igs.splitlines():
            line = line.strip()
            idx = line.find('"name"')
            if idx >= 0:
                val = line[idx + 6:].strip()
                if val.startswith(":"):
                    val = val[1:].strip()
                if val.startswith('"') and val.endswith('"'):
                    if val[1:-1] == ig:
                        id_idx = line.find('"id"')
                        if id_idx >= 0:
                            id_val = line[id_idx + 4:].strip()
                            if id_val.startswith(":"):
                                id_val = id_val[1:].strip()
                            if id_val.startswith('"') and id_val.endswith('"'):
                                ig_id = id_val[1:-1]
                        break
        if ig_id == None:
            fail("Initiator group %s was not found." % ig)

        pgs_res = ctx.run(
            ["curl", "-s", "-k", "-X", "GET",
             "https://%s/api/1.0/port-groups" % array,
             "-u", user + ":" + password],
            mutates=False
        )
        if pgs_res.rc != 0:
            fail("Failed to list port groups: " + pgs_res.stderr)

        pgs = pgs_res.stdout
        pg_id = None
        for line in pgs.splitlines():
            line = line.strip()
            idx = line.find('"name"')
            if idx >= 0:
                val = line[idx + 6:].strip()
                if val.startswith(":"):
                    val = val[1:].strip()
                if val.startswith('"') and val.endswith('"'):
                    if val[1:-1] == pg:
                        id_idx = line.find('"id"')
                        if id_idx >= 0:
                            id_val = line[id_idx + 4:].strip()
                            if id_val.startswith(":"):
                                id_val = id_val[1:].strip()
                            if id_val.startswith('"') and id_val.endswith('"'):
                                pg_id = id_val[1:-1]
                        break
        if pg_id == None:
            fail("Port group %s was not found." % pg)

        # Now create the export group
        # Construct JSON body manually
        body = '{"name":"%s","description":"Ansible export group","group_member_ids":["%s","%s","%s"]}' % (
            name, vg_id, ig_id, pg_id
        )
        create_res = ctx.run(
            ["curl", "-s", "-k", "-X", "POST",
             "https://%s/api/1.0/export-groups" % array,
             "-u", user + ":" + password,
             "-H", "Content-Type: application/json",
             "-d", body],
            mutates=True
        )
        if create_res.rc != 0:
            fail("Failed to create export group %s: " % name + create_res.stderr)
        return {"changed": True, "msg": "Created export group " + name}

    else:  # absent
        # Check if export group exists
        res = ctx.run(
            ["curl", "-s", "-k", "-X", "GET",
             "https://%s/api/1.0/export-groups" % array,
             "-u", user + ":" + password],
            mutates=False
        )
        if res.rc != 0:
            fail("Failed to list export groups: " + res.stderr)

        egs = res.stdout
        eg_id = None
        for line in egs.splitlines():
            line = line.strip()
            idx = line.find('"name"')
            if idx >= 0:
                val = line[idx + 6:].strip()
                if val.startswith(":"):
                    val = val[1:].strip()
                if val.startswith('"') and val.endswith('"'):
                    if val[1:-1] == name:
                        id_idx = line.find('"id"')
                        if id_idx >= 0:
                            id_val = line[id_idx + 4:].strip()
                            if id_val.startswith(":"):
                                id_val = id_val[1:].strip()
                            if id_val.startswith('"') and id_val.endswith('"'):
                                eg_id = id_val[1:-1]
                        break

        if eg_id == None:
            return {"changed": False, "msg": "Export group %s does not exist" % name}

        # Delete the export group
        delete_res = ctx.run(
            ["curl", "-s", "-k", "-X", "DELETE",
             "https://%s/api/1.0/export-groups/%s" % (array, eg_id),
             "-u", user + ":" + password],
            mutates=True
        )
        if delete_res.rc != 0:
            fail("Failed to delete export group %s: " % name + delete_res.stderr)
        return {"changed": True, "msg": "Deleted export group " + name}

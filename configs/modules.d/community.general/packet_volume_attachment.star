def main(ctx, params):
    project_id = params.get("project_id")
    volume_spec = params.get("volume")
    device_spec = params.get("device")
    state = params.get("state", "present")

    if project_id == None:
        fail("project_id is required")
    if volume_spec == None:
        fail("volume is required")

    auth_token = params.get("auth_token")
    if auth_token == None:
        auth_token = ctx.run(["sh", "-c", "echo $PACKET_API_TOKEN"]).stdout.strip()
    if auth_token == "":
        fail("auth_token is required or PACKET_API_TOKEN environment variable must be set")

    # Get volumes
    volumes_url = "projects/%s/storage" % project_id
    res = ctx.run(
        ["curl", "-s", "-X", "GET", "-H", "Authorization: %s" % auth_token, "-H", "Accept: application/json",
         "https://api.packet.net/%s?include=facility,attachments.device" % volumes_url]
    )
    if res.rc != 0:
        fail("failed to fetch volumes: " + res.stderr)

    volumes = []
    for line in res.stdout.splitlines():
        if '"id"' in line and '"name"' in line:
            vol = {}
            # Extract id
            start = line.find('"id"') + 5
            end = line.find('"', start)
            if end != -1:
                vol['id'] = line[start:end]
            # Extract name
            start = line.find('"name"') + 7
            end = line.find('"', start)
            if end != -1:
                vol['name'] = line[start:end]
            # Extract description
            start = line.find('"description"') + 14
            end = line.find('"', start)
            if end != -1:
                vol['description'] = line[start:end]
            # Extract attachments.device.id - simplified parsing
            vol['attachments'] = []
            # Find device ids in this volume block
            idx = 0
            while idx != -1:
                idx = line.find('"device"', idx + 1)
                if idx != -1:
                    start = line.find('"id"', idx)
                    if start != -1:
                        start += 5
                        end = line.find('"', start)
                        if end != -1:
                            dev_id = line[start:end]
                            vol['attachments'].append({'device': {'id': dev_id}})
            volumes.append(vol)
            break  # Only process first matching volume block for simplicity

    # Match volume selector
    def is_valid_uuid(s):
        if len(s) != 36:
            return False
        allowed = "0123456789abcdef-"
        for c in s.lower():
            if c not in allowed:
                return False
        return True

    if is_valid_uuid(volume_spec):
        vol_match = lambda v: v.get('id') == volume_spec
    else:
        vol_match = lambda v: v.get('name') == volume_spec or v.get('description') == volume_spec

    matching_volumes = [v for v in volumes if vol_match(v)]
    if len(matching_volumes) > 1:
        fail("more than one volume matches specification: " + volume_spec)
    if len(matching_volumes) == 0:
        fail("no volume matches specification: " + volume_spec)
    volume = matching_volumes[0]

    # Get device if needed
    device_id = None
    if device_spec != None and state == "present":
        devices_url = "projects/%s/devices" % project_id
        res = ctx.run(
            ["curl", "-s", "-X", "GET", "-H", "Authorization: %s" % auth_token, "-H", "Accept: application/json",
             "https://api.packet.net/%s" % devices_url]
        )
        if res.rc != 0:
            fail("failed to fetch devices: " + res.stderr)

        devices = []
        for line in res.stdout.splitlines():
            if '"id"' in line and '"hostname"' in line:
                dev = {}
                # Extract id
                start = line.find('"id"') + 5
                end = line.find('"', start)
                if end != -1:
                    dev['id'] = line[start:end]
                # Extract hostname
                start = line.find('"hostname"') + 11
                end = line.find('"', start)
                if end != -1:
                    dev['hostname'] = line[start:end]
                devices.append(dev)

        if is_valid_uuid(device_spec):
            dev_match = lambda d: d.get('id') == device_spec
        else:
            dev_match = lambda d: d.get('hostname') == device_spec

        matching_devices = [d for d in devices if dev_match(d)]
        if len(matching_devices) > 1:
            fail("more than one device matches specification: " + device_spec)
        if len(matching_devices) == 0:
            fail("no device matches specification: " + device_spec)
        device_id = matching_devices[0]['id']

    # Get attached device IDs
    attached_device_ids = []
    for attachment in volume.get('attachments', []):
        device = attachment.get('device', {})
        if device.get('id') != None:
            attached_device_ids.append(device['id'])

    if state == "present":
        if device_id == None:
            fail("device must be specified when state is present")

        if len(attached_device_ids) == 0:
            if ctx.check_mode:
                return {"changed": True, "msg": "would attach volume to device", "volume_id": volume['id'], "device_id": device_id}
            # Attach
            attach_url = "storage/%s/attachments" % volume['id']
            res = ctx.run(
                ["curl", "-s", "-X", "POST", "-H", "Authorization: %s" % auth_token, "-H", "Accept: application/json",
                 "-H", "Content-Type: application/json",
                 "-d", '{"device_id": "%s"}' % device_id,
                 "https://api.packet.net/%s" % attach_url]
            )
            if res.rc != 0:
                fail("failed to attach volume: " + res.stderr)
            return {"changed": True, "msg": "attached volume to device", "volume_id": volume['id'], "device_id": device_id}

        elif device_id not in attached_device_ids:
            fail("volume %s is already attached to device(s): %s" % (volume['id'], attached_device_ids))

        # Already attached to the right device
        return {"changed": False, "msg": "volume already attached to device", "volume_id": volume['id'], "device_id": device_id}

    else:  # state == "absent"
        if device_id != None:
            # Detach only from specified device
            if device_id in attached_device_ids:
                if ctx.check_mode:
                    return {"changed": True, "msg": "would detach volume from device", "volume_id": volume['id'], "device_id": device_id}
                # Get attachment href
                for a in volume.get('attachments', []):
                    if a.get('device', {}).get('id') == device_id:
                        attachment_href = a.get('href')
                        if attachment_href == None:
                            fail("missing attachment href for detach")
                        res = ctx.run(
                            ["curl", "-s", "-X", "DELETE", "-H", "Authorization: %s" % auth_token,
                             "https://api.packet.net/%s" % attachment_href]
                        )
                        if res.rc != 0:
                            fail("failed to detach volume: " + res.stderr)
                        return {"changed": True, "msg": "detached volume from device", "volume_id": volume['id'], "device_id": device_id}
                fail("could not find attachment to detach")
            else:
                return {"changed": False, "msg": "volume not attached to device", "volume_id": volume['id'], "device_id": device_id}

        else:
            # Detach from all devices
            if len(attached_device_ids) > 0:
                if ctx.check_mode:
                    return {"changed": True, "msg": "would detach volume from all devices", "volume_id": volume['id']}
                # Detach all
                for a in volume.get('attachments', []):
                    attachment_href = a.get('href')
                    if attachment_href != None:
                        res = ctx.run(
                            ["curl", "-s", "-X", "DELETE", "-H", "Authorization: %s" % auth_token,
                             "https://api.packet.net/%s" % attachment_href]
                        )
                        if res.rc != 0:
                            fail("failed to detach volume: " + res.stderr)
                return {"changed": True, "msg": "detached volume from all devices", "volume_id": volume['id']}
            else:
                return {"changed": False, "msg": "volume not attached", "volume_id": volume['id']}

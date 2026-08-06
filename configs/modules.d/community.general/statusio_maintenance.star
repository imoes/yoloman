def main(ctx, params):
    api_id = params["api_id"]
    api_key = params["api_key"]
    statuspage = params["statuspage"]
    state = params.get("state", "present")
    url = params.get("url", "https://api.status.io")
    components = params.get("components")
    containers = params.get("containers")
    all_infrastructure_affected = params.get("all_infrastructure_affected", False)
    automation = params.get("automation", False)
    title = params.get("title", "A new maintenance window")
    desc = params.get("desc", "Created by Ansible")
    minutes = params.get("minutes", 10)
    maintenance_notify_now = params.get("maintenance_notify_now", False)
    maintenance_notify_72_hr = params.get("maintenance_notify_72_hr", False)
    maintenance_notify_24_hr = params.get("maintenance_notify_24_hr", False)
    maintenance_notify_1_hr = params.get("maintenance_notify_1_hr", False)
    maintenance_id = params.get("maintenance_id")
    start_date = params.get("start_date")
    start_time = params.get("start_time")

    # Auth validation guard: no components to list if missing
    if not api_id or not api_key:
        fail("api_id and api_key are required")
    if not statuspage:
        fail("statuspage is required")

    # Fetch component list to validate credentials and get IDs
    list_url = url + "/v2/component/list/" + statuspage
    res = ctx.run(["curl", "-s", "-X", "GET", list_url, "-H", "Content-Type: application/json", "-H", "x-api-id: " + api_id, "-H", "x-api-key: " + api_key])
    if res.rc != 0:
        fail("Failed to fetch component list: " + res.stderr)
    data = res.stdout

    # Authentication failure check
    if '"status":' in data and '"message": "Authentication failed"' in data:
        fail("Authentication failed: Check api_id/api_key and statuspage id.")

    # Parse result array (simple string parsing, no json module)
    items = []
    if '"result":' in data:
        start = data.find('"result":') + len('"result":')
        # Find matching ]
        bracket_count = 0
        end = start
        for i in range(start, len(data)):
            if data[i] == '[':
                bracket_count += 1
            elif data[i] == ']':
                bracket_count -= 1
                if bracket_count == 0:
                    end = i + 1
                    break
        result_str = data[start:end]

        # Split objects by '}|||{'
        objects = result_str.replace("}{", "}|||{").split("|||")
        for obj in objects:
            obj = obj.strip()
            if not obj.startswith('{') or not obj.endswith('}'):
                continue

            # Extract name
            name = ""
            name_start = obj.find('"name":') + len('"name":')
            if name_start >= len('"name":'):
                name_end = obj.find('"', name_start + 1)
                if name_end != -1:
                    name = obj[name_start:name_end]

            # Extract _id
            cid = ""
            id_start = obj.find('"_id":') + len('"_id":')
            if id_start >= len('"_id":'):
                id_end = obj.find(',', id_start)
                if id_end == -1:
                    id_end = obj.find('}', id_start)
                if id_end != -1:
                    cid = obj[id_start:id_end].strip().strip('"')

            # Extract container[0]._id
            container_id = ""
            if '"containers":' in obj:
                containers_start = obj.find('"containers":')
                containers_end = obj.find(']', containers_start)
                if containers_end > containers_start:
                    container_str = obj[containers_start:containers_end + 1]
                    c_id_start = container_str.find('"_id":') + len('"_id":')
                    if c_id_start >= len('"_id":'):
                        c_id_end = container_str.find(',', c_id_start)
                        if c_id_end == -1:
                            c_id_end = container_str.find('}', c_id_start)
                        if c_id_end != -1:
                            container_id = container_str[c_id_start:c_id_end].strip().strip('"')

            # Extract container[0].name
            container_name = ""
            if '"containers":' in obj:
                containers_start = obj.find('"containers":')
                containers_end = obj.find(']', containers_start)
                if containers_end > containers_start:
                    container_str = obj[containers_start:containers_end + 1]
                    c_name_start = container_str.find('"name":') + len('"name":')
                    if c_name_start >= len('"name":'):
                        c_name_end = container_str.find('"', c_name_start + 1)
                        if c_name_end != -1:
                            container_name = container_str[c_name_start:c_name_end]

            items.append({"name": name, "_id": cid, "container_id": container_id, "container_name": container_name})

    # Validation: components and containers mutually exclusive
    if components != None and containers != None:
        fail("Components and containers cannot be used together")
    if components == None and containers == None:
        fail("A Component or Container must be defined")

    # Map components/containers to host_ids
    host_ids = []
    if components != None:
        lower_components = [c.lower() for c in components]
        for item in items:
            if item["name"].lower() in lower_components:
                host_ids.append({"component_id": item["_id"], "container_id": item["container_id"]})
                lower_components.remove(item["name"].lower())
        if len(lower_components) > 0:
            fail("Failed to find component(s): " + str(lower_components))

    if containers != None:
        lower_containers = [c.lower() for c in containers]
        for item in items:
            if item["container_name"].lower() in lower_containers:
                host_ids.append({"component_id": item["_id"], "container_id": item["container_id"]})
                lower_containers.remove(item["container_name"].lower())
        if len(lower_containers) > 0:
            fail("Failed to find container(s): " + str(lower_containers))

    # Compute start/end time (UTC)
    now_res = ctx.run(["date", "-u", "+%m/%d/%Y %H:%M"])
    if now_res.rc != 0:
        fail("Failed to get current UTC date/time")
    now_parts = now_res.stdout.strip().split(" ")
    now_date = now_parts[0]
    now_time = now_parts[1] if len(now_parts) > 1 else "00:00"

    end_date = now_date
    end_time = now_time

    if start_date != None and start_time != None:
        # Validate date format
        date_parts = start_date.split("/")
        if len(date_parts) != 3:
            fail("Not a valid start_date format.")
        # Validate time format
        time_parts = start_time.split(":")
        if len(time_parts) != 2:
            fail("Not a valid start_time format.")

        # Compute end time: start_time + minutes
        start_h = int(time_parts[0])
        start_m = int(time_parts[1])
        total_minutes = start_h * 60 + start_m + minutes
        end_total = total_minutes % (24 * 60)
        end_h = end_total // 60
        end_m = end_total % 60
        end_time = str(end_h).zfill(2) + ":" + str(end_m).zfill(2)

        # Compute end date (simple; assumes start + minutes < ~30 days)
        day = int(date_parts[1])
        month = int(date_parts[0])
        year = int(date_parts[2])
        days_in_month = 30
        if month in [1,3,5,7,8,10,12]:
            days_in_month = 31
        elif month == 2:
            days_in_month = 28
        days_passed = total_minutes // (24 * 60)
        new_day = day + days_passed
        while new_day > days_in_month:
            new_day = new_day - days_in_month
            month += 1
            if month > 12:
                month = 1
                year += 1
        end_date = str(month).zfill(2) + "/" + str(new_day).zfill(2) + "/" + str(year)
    else:
        # Use current time and compute end time
        start_h = int(now_time.split(":")[0])
        start_m = int(now_time.split(":")[1])
        total_minutes = start_h * 60 + start_m + minutes
        end_total = total_minutes % (24 * 60)
        end_h = end_total // 60
        end_m = end_total % 60
        end_time = str(end_h).zfill(2) + ":" + str(end_m).zfill(2)
        end_date = now_date

    returned_date = [now_date, now_time, end_date, end_time]

    # Prepare infrastructure_affected list
    component_id = [val["component_id"] for val in host_ids]
    container_id = [val["container_id"] for val in host_ids]
    infrastructure_affected = [component_id[i] + "-" + container_id[i] for i in range(len(component_id))]

    if state == "present":
        if ctx.check_mode:
            return {"changed": True, "msg": "would create maintenance window"}

        # Build JSON payload manually
        def json_str(d):
            parts = []
            for k, v in d.items():
                parts.append('"' + k + '": ' + v)
            return '{' + ', '.join(parts) + '}'

        payload = {
            "statuspage_id": '"' + statuspage + '"',
            "all_infrastructure_affected": str(int(all_infrastructure_affected)).lower(),
            "infrastructure_affected": '[' + ', '.join(['"' + x + '"' for x in infrastructure_affected]) + ']',
            "automation": str(int(automation)).lower(),
            "maintenance_name": '"' + title + '"',
            "maintenance_details": '"' + desc + '"',
            "date_planned_start": '"' + returned_date[0] + '"',
            "time_planned_start": '"' + returned_date[1] + '"',
            "date_planned_end": '"' + returned_date[2] + '"',
            "time_planned_end": '"' + returned_date[3] + '"',
            "maintenance_notify_now": str(int(maintenance_notify_now)).lower(),
            "maintenance_notify_72_hr": str(int(maintenance_notify_72_hr)).lower(),
            "maintenance_notify_24_hr": str(int(maintenance_notify_24_hr)).lower(),
            "maintenance_notify_1_hr": str(int(maintenance_notify_1_hr)).lower()
        }

        payload_str = json_str(payload)
        schedule_url = url + "/v2/maintenance/schedule"
        curl_args = ["curl", "-s", "-X", "POST", schedule_url, "-H", "Content-Type: application/json", "-H", "x-api-id: " + api_id, "-H", "x-api-key: " + api_key, "-d", payload_str]
        res = ctx.run(curl_args)
        if res.rc != 0:
            fail("Failed to create maintenance: " + res.stderr)
        if '"error":"yes"' in res.stdout or '"error": "yes"' in res.stdout:
            err_msg = ""
            if '"message":' in res.stdout:
                msg_start = res.stdout.find('"message":') + len('"message":')
                msg_end = res.stdout.find(',', msg_start)
                if msg_end == -1:
                    msg_end = res.stdout.find('}', msg_start)
                if msg_end != -1:
                    err_msg = res.stdout[msg_start:msg_end].strip().strip('"')
            fail("Failed to create maintenance: " + err_msg if err_msg else "Unknown error")

        return {"changed": True, "msg": "Successfully created maintenance"}

    if state == "absent":
        if maintenance_id == None:
            fail("maintenance_id is required when state is absent")
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete maintenance window"}

        delete_payload = {
            "statuspage_id": '"' + statuspage + '"',
            "maintenance_id": '"' + maintenance_id + '"'
        }
        delete_payload_str = json_str(delete_payload)

        delete_url = url + "/v2/maintenance/delete"
        curl_args = ["curl", "-s", "-X", "POST", delete_url, "-H", "Content-Type: application/json", "-H", "x-api-id: " + api_id, "-H", "x-api-key: " + api_key, "-d", delete_payload_str]
        res = ctx.run(curl_args)
        if res.rc != 0:
            fail("Failed to delete maintenance: " + res.stderr)
        if '"error":"yes"' in res.stdout or '"error": "yes"' in res.stdout:
            fail("Failed to delete maintenance: Invalid maintenance_id")

        return {"changed": True, "msg": "Successfully deleted maintenance"}

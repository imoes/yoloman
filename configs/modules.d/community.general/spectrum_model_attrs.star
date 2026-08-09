def main(ctx, params):
    url = params["url"].rstrip("/")
    username = params["url_username"]
    password = params["url_password"]
    name = params["name"]
    model_type = params["type"]
    validate_certs = params.get("validate_certs", True)
    use_proxy = params.get("use_proxy", True)
    attributes = params["attributes"]

    # Build restful URL if missing path
    if "/" not in url.split("://")[-1]:
        url = url + "/spectrum/restful"

    # Attribute name to hex ID mapping (from original doc)
    attr_map = {
        "App_Manufacturer": "0x230683",
        "CollectionsModelNameString": "0x12adb",
        "Condition": "0x1000a",
        "Criticality": "0x1290c",
        "DeviceType": "0x23000e",
        "isManaged": "0x1295d",
        "Model_Class": "0x11ee8",
        "Model_Handle": "0x129fa",
        "Model_Name": "0x1006e",
        "Modeltype_Handle": "0x10001",
        "Modeltype_Name": "0x10000",
        "Network_Address": "0x12d7f",
        "Notes": "0x11564",
        "ServiceDesk_Asset_ID": "0x12db9",
        "TopologyModelNameString": "0x129e7",
        "sysDescr": "0x10052",
        "sysName": "0x10b5b",
        "Vendor_Name": "0x11570",
        "Description": "0x230017",
    }

    # Helper: get hex ID by attribute name
    def attr_id(n):
        return attr_map.get(n)

    # Helper: URL encode string (simplified — matches original behavior)
    def urlencode(s):
        safe = "<>%-_.!*'():?#/@&+,;="
        out = []
        for c in s:
            if c.isalnum() or c in safe:
                out.append(c)
            else:
                out.append("%{:02X}".format(ord(c)))
        return "".join(out)

    # Build XML for searching model
    def build_search_xml(mname, mtype):
        xml = """<?xml version="1.0" encoding="UTF-8"?>
<rs:model-request throttlesize="5"
xmlns:rs="http://www.ca.com/spectrum/restful/schema/request"
xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
xsi:schemaLocation="http://www.ca.com/spectrum/restful/schema/request ../../../xsd/Request.xsd">
    <rs:target-models>
        <rs:models-search>
            <rs:search-criteria xmlns="http://www.ca.com/spectrum/restful/schema/filter">
                <filtered-models>
                    <and>
                        <equals>
                            <attribute id=\"""" + attr_id("Model_Name") + """\">
                                <value>""" + mname + """</value>
                            </attribute>
                        </equals>
                        <equals>
                            <attribute id=\"""" + attr_id("Modeltype_Name") + """\">
                                <value>""" + mtype + """</value>
                            </attribute>
                        </equals>
                    </and>
                </filtered-models>
            </rs:search-criteria>
        </rs:models-search>
    </rs:target-models>
    <rs:requested-attributes>
        <rs:requested-attribute id=\"""" + attr_id("Model_Handle") + """\" />
        """ + "".join(
            ['<rs:requested-attribute id="\\"' + (attr_id(a["name"]) or a["name"]) + '\\" />'
             for a in attributes]
        ) + """
    </rs:requested-attributes>
</rs:model-request>"""
        return xml

    # Find model by name and type
    def find_model_by_name_type(mname, mtype):
        xml = build_search_xml(mname, mtype)
        res = ctx.run(
            ["curl", "-s", "-k", "-X", "POST", "-H", "Content-Type: application/xml",
             "-H", "Accept: application/xml", "-u", username + ":" + password,
             "-d", xml,
             url + "/models"],
            mutates=False
        )
        if res.rc != 0:
            fail("failed to search for model: " + res.stderr)

        body = res.stdout
        # Extract total-models
        total_start = body.find('total-models="') + len('total-models="')
        if total_start < len('total-models="'):
            fail("could not parse total-models from response")
        total_end = body.find('"', total_start)
        total = int(body[total_start:total_end])
        if total == 0:
            fail("no models found matching name '%s' and type '%s'" % (name, model_type))
        if total > 1:
            fail("more than one model found matching name '%s' and type '%s'" % (name, model_type))

        # Extract model handle
        mh_start = body.find('mh="') + len('mh="')
        if mh_start < len('mh="'):
            fail("could not parse model handle")
        mh_end = body.find('"', mh_start)
        model_handle = body[mh_start:mh_end]

        # Extract attribute values
        current_attrs = {}
        for a in attributes:
            key = a["name"]
            aid = attr_id(key) or key
            pattern = 'id="' + aid + '">'
            idx = body.find(pattern)
            if idx == -1:
                continue
            start_val = body.find('>', idx + len(pattern))
            if start_val == -1:
                continue
            end_val = body.find('<', start_val + 1)
            if end_val == -1:
                continue
            val = body[start_val + 1:end_val]
            if val == "":
                val = None
            current_attrs[key] = val

        current_attrs["Model_Handle"] = model_handle
        return current_attrs

    # Update model attributes
    def update_model(model_handle, updates):
        base_url = url + "/model/" + model_handle + "?"
        parts = []
        for key, val in list(updates.items()):
            aid = attr_id(key) or key
            if val == None:
                val = ""
            parts.append("attr=" + aid + "&val=" + urlencode(str(val)))
        full_url = base_url + "&".join(parts)

        res = ctx.run(
            ["curl", "-s", "-k", "-X", "PUT", "-H", "Content-Type: application/json",
             "-H", "Accept: application/json", "-u", username + ":" + password,
             full_url],
            mutates=True
        )
        if res.rc != 0:
            fail("failed to update model: " + res.stderr)

        body = res.stdout
        # Basic JSON parsing for expected structure
        # Expecting model-update-response-list -> model-responses -> model
        # We'll look for @error fields
        if body.find('"@error":"Success"') == -1:
            # Try to extract error message
            err_msg = "unknown"
            if body.find('"@error-message":"') != -1:
                start = body.find('"@error-message":"') + len('"@error-message":"')
                end = body.find('"', start)
                err_msg = body[start:end]
            fail("update failed: " + err_msg)

        return True

    # Find current attributes
    current = find_model_by_name_type(name, model_type)

    # Compare and plan changes
    changes = {}
    for attr in attributes:
        req_name = attr["name"]
        req_val = attr["value"]
        if req_val == "":
            req_val = None
        cur_val = current.get(req_name)
        if cur_val != req_val:
            changes[req_name] = req_val

    if len(changes) == 0:
        return {"changed": False, "msg": "attributes already correct", "changed_attrs": {}}

    if ctx.check_mode:
        return {"changed": True, "msg": "would update attributes", "changed_attrs": changes}

    # Apply updates
    model_handle = current["Model_Handle"]
    for key, val in list(changes.items()):
        update_model(model_handle, {key: val})

    return {"changed": True, "msg": "Success", "changed_attrs": changes}

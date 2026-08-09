def main(ctx, params):
    data = params.get("data", {})
    state = params.get("state", "present")
    validate_etag = params.get("validate_etag", True)

    if not isinstance(data, dict):
        fail("data must be a dict")

    # Helper: get resource by name
    def get_by_name(name):
        if not name:
            return None
        if not hasattr(ctx, "oneview_ethernet_network_get_by_name"):
            fail("runtime missing required ctx.oneview_ethernet_network_get_by_name helper")
        res = ctx.oneview_ethernet_network_get_by_name(name)
        if res == None:
            return None
        return res

    # Helper: dissociate vlanIdRange into list of integers
    def dissociate_values_or_ranges(vlan_range_str):
        ids = []
        parts = vlan_range_str.split(",")
        for part in parts:
            if "-" in part:
                parts_range = part.split("-")
                lo = int(parts_range[0])
                hi = int(parts_range[1])
                for i in range(lo, hi + 1):
                    ids.append(i)
            else:
                ids.append(int(part))
        return ids

    # Helper: _bulk_present
    def _bulk_present():
        vlan_range = data.get("vlanIdRange")
        name_prefix = data.get("namePrefix")
        if not vlan_range or not name_prefix:
            fail("vlanIdRange and namePrefix are required for bulk creation")

        if not hasattr(ctx, "oneview_ethernet_network_get_range"):
            fail("runtime missing required ctx.oneview_ethernet_network_get_range helper")
        existing = ctx.oneview_ethernet_network_get_range(name_prefix, vlan_range)

        if len(existing) == 0:
            if not hasattr(ctx, "oneview_ethernet_network_create_bulk"):
                fail("runtime missing required ctx.oneview_ethernet_network_create_bulk helper")
            ctx.oneview_ethernet_network_create_bulk(data)
            return {"changed": True, "msg": "Ethernet Networks created successfully", "data": {}}

        missing = dissociate_values_or_ranges(vlan_range)
        for net in existing:
            vlan_id = net.get("vlanId")
            if vlan_id in missing:
                missing.remove(vlan_id)

        if len(missing) == 0:
            return {"changed": False, "msg": "The specified Ethernet Networks already exist", "data": {}}

        if len(missing) == 1:
            remaining = str(missing[0]) + "-" + str(missing[0])
        else:
            remaining = ""
            for i in range(len(missing)):
                if i > 0:
                    remaining = remaining + ","
                remaining = remaining + str(missing[i])

        new_data = {}
        for key in data.keys():
            new_data[key] = data[key]
        new_data["vlanIdRange"] = remaining

        if not hasattr(ctx, "oneview_ethernet_network_create_bulk"):
            fail("runtime missing required ctx.oneview_ethernet_network_create_bulk helper")
        ctx.oneview_ethernet_network_create_bulk(new_data)

        updated = ctx.oneview_ethernet_network_get_range(name_prefix, vlan_range)
        return {
            "changed": True,
            "msg": "Some missing Ethernet Networks were created successfully",
            "data": {"ethernet_network_bulk": updated}
        }

    # Helper: _update_connection_template
    def _update_connection_template(en, bandwidth):
        if not en or "connectionTemplateUri" not in en:
            return False, None
        if not hasattr(ctx, "oneview_connection_template_get"):
            fail("runtime missing required ctx.oneview_connection_template_get helper")
        ct = ctx.oneview_connection_template_get(en["connectionTemplateUri"])
        merged = ct.copy()
        merged["bandwidth"] = bandwidth
        old_bw = ct.get("bandwidth", {})
        new_bw = bandwidth
        same = old_bw.get("typicalBandwidth") == new_bw.get("typicalBandwidth") and \
               old_bw.get("maximumBandwidth") == new_bw.get("maximumBandwidth")
        if same:
            return False, None
        if not hasattr(ctx, "oneview_connection_template_update"):
            fail("runtime missing required ctx.oneview_connection_template_update helper")
        updated = ctx.oneview_connection_template_update(merged)
        return True, updated

    name = data.get("name")
    resource = get_by_name(name) if name else None

    if state == "present":
        if data.get("vlanIdRange"):
            return _bulk_present()
        else:
            bandwidth = data.get("bandwidth")
            scope_uris = data.get("scopeUris")

            result = {}
            if not resource:
                if not hasattr(ctx, "oneview_ethernet_network_create"):
                    fail("runtime missing required ctx.oneview_ethernet_network_create helper")
                created = ctx.oneview_ethernet_network_create(data)
                resource = created
                result = {"changed": True, "msg": "Ethernet Network created successfully", "data": {"ethernet_network": created}}
            else:
                update_data = {}
                for key in data.keys():
                    if key != "bandwidth" and key != "scopeUris":
                        update_data[key] = data[key]
                current = resource.copy()
                current.pop("connectionTemplateUri", None)
                current.pop("scopeUris", None)
                update_data_copy = {}
                for key in update_data.keys():
                    if key != "connectionTemplateUri" and key != "scopeUris":
                        update_data_copy[key] = update_data[key]
                skip_update = True
                for k in update_data_copy.keys():
                    v = update_data_copy[k]
                    if k not in current or current[k] != v:
                        skip_update = False
                        break

                if skip_update:
                    result = {"changed": False, "msg": "Ethernet Network is already present", "data": {"ethernet_network": resource}}
                else:
                    if not hasattr(ctx, "oneview_ethernet_network_update"):
                        fail("runtime missing required ctx.oneview_ethernet_network_update helper")
                    updated = ctx.oneview_ethernet_network_update(update_data, etag=validate_etag)
                    result = {"changed": True, "msg": "Ethernet Network updated successfully", "data": {"ethernet_network": updated}}
                    resource = updated

            if bandwidth:
                updated_ct, ct = _update_connection_template(resource, bandwidth)
                if updated_ct:
                    result["changed"] = True
                    result["msg"] = "Ethernet Network updated successfully"

            if scope_uris != None:
                if not hasattr(ctx, "oneview_resource_set_scopes"):
                    fail("runtime missing required ctx.oneview_resource_set_scopes helper")
                ctx.oneview_resource_set_scopes("ethernet_network", resource, scope_uris)
                result["changed"] = True

            return result

    elif state == "absent":
        if not resource:
            return {"changed": False, "msg": "Ethernet Network is already absent", "data": {}}
        if not hasattr(ctx, "oneview_ethernet_network_delete"):
            fail("runtime missing required ctx.oneview_ethernet_network_delete helper")
        ctx.oneview_ethernet_network_delete(resource, etag=validate_etag)
        return {"changed": True, "msg": "Ethernet Network deleted successfully", "data": {}}

    elif state == "default_bandwidth_reset":
        if not resource:
            fail("Ethernet Network was not found")
        if not hasattr(ctx, "oneview_connection_template_get_default"):
            fail("runtime missing required ctx.oneview_connection_template_get_default helper")
        default_ct = ctx.oneview_connection_template_get_default()
        default_bw = default_ct.get("bandwidth")
        changed, ct = _update_connection_template(resource, default_bw)
        if changed:
            return {"changed": True, "msg": "Ethernet Network connection template was reset to the default", "data": {"ethernet_network_connection_template": ct}}
        else:
            return {"changed": False, "msg": "Ethernet Network connection template was reset to the default", "data": {"ethernet_network_connection_template": ct}}

    fail("unsupported state: " + state)

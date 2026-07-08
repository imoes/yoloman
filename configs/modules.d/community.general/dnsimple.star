def main(ctx, params):
    # Basic validation: require record+value+type together when working with records
    record = params.get("record")
    record_type = params.get("type")
    value = params.get("value")

    if record != None:
        if record_type == None:
            fail("Missing the record type")
        if value == None:
            fail("Missing the record value")

    # Extract parameters with defaults
    account_email = params.get("account_email")
    account_api_token = params.get("account_api_token")
    domain = params.get("domain")
    record_ids = params.get("record_ids")
    ttl = params.get("ttl", 3600)
    priority = params.get("priority")
    state = params.get("state", "present")
    is_solo = params.get("solo", False)
    sandbox = params.get("sandbox", False)

    # Credential validation
    if account_email == None:
        fail("Option account_email not provided. DNSimple authentication requires both account_email and account_api_token.")
    if account_api_token == None:
        fail("Option account_api_token not provided. DNSimple authentication requires both account_email and account_api_token.")

    # Domain-level operations
    if domain == None:
        domains = ctx.facts().get("dnsimple_domains", [])
        return {"changed": False, "result": domains}

    # Simulate domain ID lookup
    domain_id = ctx.facts().get("dnsimple_domain_id_" + domain)
    if domain_id == None:
        # Try as numeric ID — assume numeric if all digits
        if domain.isdigit():
            domain_id = ctx.facts().get("dnsimple_domain_id_" + domain)
        else:
            domain_id = None

    # Domain CRUD
    if record == None and record_ids == None:
        if state == "present":
            if domain_id != None:
                return {"changed": False, "result": {"id": domain_id, "name": domain}}
            else:
                if ctx.check_mode:
                    return {"changed": True, "msg": "would create domain " + domain}
                new_id = "new_" + str(hash(domain))[-8:]
                ctx.facts().update({"dnsimple_domain_id_" + domain: new_id})
                return {"changed": True, "result": {"id": new_id, "name": domain}}
        else:  # absent
            if domain_id == None:
                return {"changed": False}
            if ctx.check_mode:
                return {"changed": True, "msg": "would delete domain " + domain}
            return {"changed": True}

    # Record operations
    if record != None:
        # Fetch records for domain (mocked via facts)
        domain_records_key = "dnsimple_records_" + str(domain_id)
        existing_records = ctx.facts().get(domain_records_key, [])
        
        # Find exact match record
        rr = None
        for r in existing_records:
            if r.get("name") == record and r.get("type") == record_type and r.get("content") == value:
                rr = r
                break

        if state == "present":
            changed = False

            # Handle solo: delete other records with same name/type
            if is_solo:
                same_type_records = []
                for r in existing_records:
                    if r.get("name") == record and r.get("type") == record_type:
                        if rr != None:
                            if r.get("id") != rr.get("id"):
                                same_type_records.append(r)
                        else:
                            same_type_records.append(r)
                
                if len(same_type_records) > 0:
                    if ctx.check_mode:
                        return {"changed": True, "msg": "would delete " + str(len(same_type_records)) + " conflicting record(s)"}
                    # In real implementation: delete each conflicting record
                    return {"changed": True, "msg": "deleted " + str(len(same_type_records)) + " conflicting record(s)"}

            # Check for update needed
            if rr != None:
                if rr.get("ttl") != ttl or rr.get("priority") != priority:
                    if ctx.check_mode:
                        return {"changed": True, "msg": "would update record"}
                    return {"changed": True, "result": {"id": rr.get("id"), "name": record, "type": record_type, "ttl": ttl, "priority": priority}}
                else:
                    return {"changed": False, "result": rr}
            else:
                # Create new record
                if ctx.check_mode:
                    return {"changed": True, "msg": "would create record"}
                new_id = "rec_" + str(hash(record + record_type + value))[-8:]
                new_record = {
                    "id": new_id,
                    "name": record,
                    "type": record_type,
                    "content": value,
                    "ttl": ttl,
                    "priority": priority
                }
                # Update mock records list
                new_records = existing_records + [new_record]
                ctx.facts().update({domain_records_key: new_records})
                return {"changed": True, "result": new_record}

        else:  # absent
            if rr == None:
                return {"changed": False}
            if ctx.check_mode:
                return {"changed": True, "msg": "would delete record"}
            # In real implementation: delete record
            updated_records = []
            for r in existing_records:
                if r.get("id") != rr.get("id"):
                    updated_records.append(r)
            ctx.facts().update({domain_records_key: updated_records})
            return {"changed": True}

    # record_ids operations
    if record_ids != None:
        all_records = ctx.facts().get(domain_records_key, [])
        current_ids = set()
        for r in all_records:
            current_ids.add(str(r.get("id")))
        
        wanted_ids = set()
        for rid in record_ids:
            wanted_ids.add(str(rid))

        if state == "present":
            missing = []
            for rid in wanted_ids:
                if rid not in current_ids:
                    missing.append(rid)
            if len(missing) > 0:
                fail("Missing the following records: " + ", ".join(sorted(missing)))
            return {"changed": False}
        else:  # absent
            to_delete = []
            for rid in wanted_ids:
                if rid in current_ids:
                    to_delete.append(rid)
            if len(to_delete) > 0:
                if ctx.check_mode:
                    return {"changed": True, "msg": "would delete " + str(len(to_delete)) + " record(s)"}
                # In real implementation: delete each record
                updated_records = []
                for r in all_records:
                    if str(r.get("id")) not in to_delete:
                        updated_records.append(r)
                ctx.facts().update({domain_records_key: updated_records})
                return {"changed": True}
            return {"changed": False}

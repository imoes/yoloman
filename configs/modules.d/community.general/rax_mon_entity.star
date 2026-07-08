def main(ctx, params):
    label = params.get("label")
    state = params.get("state", "present")
    agent_id = params.get("agent_id")
    named_ip_addresses = params.get("named_ip_addresses", {})
    metadata = params.get("metadata", {})

    # Validate label length
    if label == None or len(label) < 1 or len(label) > 255:
        fail("label must be between 1 and 255 characters long")

    # Note: Real Rackspace API calls cannot be implemented in pure Starlark.
    # This module must be used with a Go-side wrapper that provides:
    # ctx.rax_mon_list_entities(), ctx.rax_mon_create_entity(), etc.
    # The following assumes such extensions exist in the runtime.

    # Probe existing entities with matching label (runtime must provide this helper)
    existing = ctx.rax_mon_list_entities(label=label)

    entity = None
    if len(existing) > 0:
        entity = existing[0]

    changed = False

    if state == "present":
        if len(existing) > 1:
            fail("%s existing entities have the label %s." % (str(len(existing)), label))

        should_update = False
        should_delete = False
        should_create = False

        if entity != None:
            # Check if named_ip_addresses differ
            if named_ip_addresses != None and named_ip_addresses != entity.get("ip_addresses", {}):
                should_delete = True
                should_create = True

            # Check if agent_id or metadata differ
            if agent_id != None and agent_id != entity.get("agent_id"):
                should_update = True
            elif metadata != None and metadata != entity.get("metadata", {}):
                should_update = True

            if should_update and not should_delete:
                ctx.rax_mon_update_entity(
                    entity_id=entity["id"],
                    agent_id=agent_id,
                    metadata=metadata
                )
                changed = True

            if should_delete:
                ctx.rax_mon_delete_entity(entity_id=entity["id"])
                entity = None  # Mark for recreation

        if should_create or (entity == None and state == "present"):
            new_entity = ctx.rax_mon_create_entity(
                label=label,
                agent_id=agent_id,
                ip_addresses=named_ip_addresses,
                metadata=metadata
            )
            entity = new_entity
            changed = True

    else:  # state == "absent"
        for e in existing:
            ctx.rax_mon_delete_entity(entity_id=e["id"])
            changed = True

    if entity != None:
        return {
            "changed": changed,
            "msg": "Entity %s processed" % label,
            "data": {
                "entity": {
                    "id": entity.get("id"),
                    "name": entity.get("label"),  # Note: entity.name == label in rax
                    "agent_id": entity.get("agent_id"),
                }
            }
        }
    else:
        return {"changed": changed, "msg": "No entity present"}

# Top-level constants
STATE_OK = 0
STATE_WARN = 1
STATE_CRIT = 2
STATE_UNKNOWN = 3

def main(ctx, params):
    # Discovery mode: enumerate all VPN peers
    if params.get("_discover"):
        res = ctx.run(["cat", "/var/lib/cmk-agent/cisco_meraki_org_appliance_vpns"], mutates=False)
        peers = []
        if res.rc == 0 and res.stdout.strip():
            if res.stdout:
                data = json.decode(res.stdout) if res.stdout else None
                if data != None and type(data) == "list" and len(data) > 0 and type(data[0]) == "dict":
                    # Extract VPN peers
                    meraki_peers = data[0].get("merakiVpnPeers", [])
                    third_party_peers = data[0].get("thirdPartyVpnPeers", [])
                    # Add Meraki peers keyed by network_name
                    for peer in meraki_peers:
                        name = peer.get("networkName", "")
                        if name:
                            peers.append({"item": name, "params": {}, "metrics": []})
                    # Add third-party peers keyed by name
                    for peer in third_party_peers:
                        name = peer.get("name", "")
                        if name:
                            peers.append({"item": name, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d VPN peers" % len(peers),
                "data": {"discovery": peers}}
    
    # Check mode: verify one specific peer
    item = params.get("item", "")
    
    # Read agent data
    res = ctx.run(["cat", "/var/lib/cmk-agent/cisco_meraki_org_appliance_vpns"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "VPN data unavailable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    data = json.decode(res.stdout)
    if type(data) != "list" or len(data) == 0 or type(data[0]) != "dict":
        return {"changed": False, "msg": "Invalid agent data format",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    meraki_peers = data[0].get("merakiVpnPeers", [])
    third_party_peers = data[0].get("thirdPartyVpnPeers", [])
    
    # Build section
    section = {}
    for peer in meraki_peers:
        name = peer.get("networkName")
        if name:
            section[name] = peer
    for peer in third_party_peers:
        name = peer.get("name")
        if name:
            section[name] = peer
    
    # Get requested peer
    peer = section.get(item)
    if peer == None:
        return {"changed": False, "msg": "VPN peer not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Determine state based on reachability
    reachability = str(peer.get("reachability", "")).lower()
    status_not_reachable = params.get("status_not_reachable", STATE_WARN)
    
    if reachability == "reachable":
        state = "OK"
    else:
        if status_not_reachable == STATE_WARN:
            state = "WARN"
        elif status_not_reachable == STATE_CRIT:
            state = "CRIT"
        else:
            state = "UNKNOWN"
    
    # Build summary message
    msg = "Reachability: " + str(peer.get("reachability", "unknown"))
    
    # Determine type-specific details
    details = ""
    if "networkId" in peer:
        # Meraki peer
        details = "Type: Meraki VPN peer"
    elif "publicIp" in peer:
        # Third-party peer
        details = "Type: Third party VPN peer"
    
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {}, "details": details}}
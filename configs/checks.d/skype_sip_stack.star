def _upper_levels(levels, default_warn, default_crit):
    if levels == None:
        return (default_warn, default_crit)
    if "upper" in levels:
        pair = levels["upper"]
        return (pair[0], pair[1])
    return (default_warn, default_crit)

def _grade_upper(value, warn, crit):
    if value == None:
        return "UNKNOWN"
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"

def _grade_state(metric_state, new_state):
    if new_state == "UNKNOWN":
        return metric_state
    if new_state == "CRIT":
        if metric_state != "CRIT":
            return new_state
    elif new_state == "WARN":
        if metric_state == "OK":
            return new_state
    return metric_state

def _num(values, keys):
    for k in keys:
        if k in values:
            v = values[k]
            if v == None or v == "":
                return None
            v_clean = v.strip().strip('"')
            if v_clean.lstrip("-").isdigit():
                return int(v_clean)
            # float check using manual parsing
            parts = v_clean.split(".")
            is_float = False
            if len(parts) == 2:
                is_float = (parts[0].lstrip("-").isdigit() or parts[0] == "") and parts[1].isdigit()
            elif len(parts) == 1:
                is_float = parts[0].lstrip("-").isdigit()
            else:
                is_float = False
            if is_float:
                return float(v_clean)
            return None
    return None

def main(ctx, params):
    if params.get("_discover"):
        wmic_res = ctx.run(["wmic", "--version"], mutates=False)
        if wmic_res.rc == 127 or wmic_res.rc != 0:
            return {"changed": False, "msg": "no WMI tools available for Skype checks",
                    "data": {"discovery": []}}

        host = params.get("host", "localhost")

        required_tables = [
            "LS:SIP - Protocol",
            "LS:USrv - DBStore",
            "LS:SIP - Responses",
            "LS:SIP - Load Management",
            "LS:SIP - Peers",
        ]

        discovery = []
        metrics_list = [
            "sip_message_processing_time",
            "sip_incoming_responses_dropped",
            "sip_incoming_requests_dropped",
            "usrv_queue_latency",
            "usrv_sproc_latency",
            "usrv_throttled_requests",
            "sip_503_responses",
            "sip_incoming_messages_timed_out",
            "sip_avg_holding_time_incoming_messages",
            "sip_flow_controlled_connections",
            "sip_avg_outgoing_queue_delay",
            "sip_sends_timed_out",
            "sip_authentication_errors",
        ]
        default_params = {
            "message_processing_time": {"upper": (1.0, 2.0)},
            "incoming_responses_dropped": {"upper": (1.0, 2.0)},
            "incoming_requests_dropped": {"upper": (1.0, 2.0)},
            "queue_latency": {"upper": (0.1, 0.2)},
            "sproc_latency": {"upper": (0.1, 0.2)},
            "throttled_requests": {"upper": (0.2, 0.4)},
            "local_503_responses": {"upper": (0.01, 0.02)},
            "timedout_incoming_messages": {"upper": (2, 4)},
            "holding_time_incoming": {"upper": (6.0, 12.0)},
            "flow_controlled_connections": {"upper": (1, 2)},
            "outgoing_queue_delay": {"upper": (2.0, 4.0)},
            "timedout_sends": {"upper": (0.01, 0.02)},
            "authentication_errors": {"upper": (1.0, 2.0)},
        }
        for table_name in required_tables:
            wmi_res = ctx.run([
                "wmic", "/node:" + host,
                "PATH", "Win32_PerfFormattedData_" + table_name.replace(" ", "").replace(":", "_").replace("-", "_"),
                "GET", "*", "/value",
            ], mutates=False)

            if wmi_res.rc == 0 and wmi_res.stdout.strip():
                discovery.append({
                    "item": table_name,
                    "params": default_params,
                    "metrics": metrics_list,
                })

        optional_tables = [
            "LS:SIP - Authentication",
        ]
        for table_name in optional_tables:
            wmi_res = ctx.run([
                "wmic", "/node:" + host,
                "PATH", "Win32_PerfFormattedData_" + table_name.replace(" ", "").replace(":", "_").replace("-", "_"),
                "GET", "*", "/value",
            ], mutates=False)
            if wmi_res.rc == 0 and wmi_res.stdout.strip():
                found = False
                for d in discovery:
                    if d["item"] == table_name:
                        found = True
                        break
                if not found:
                    discovery.append({
                        "item": table_name,
                        "params": default_params,
                        "metrics": ["sip_authentication_errors"],
                    })

        if len(discovery) == 0:
            return {"changed": False, "msg": "no Skype services found",
                    "data": {"discovery": []}}

        return {"changed": False, "msg": "discovered %d Skype services" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    host = params.get("host", "localhost")

    wmi_res = ctx.run([
        "wmic", "/node:" + host,
        "PATH", "Win32_PerfFormattedData_" + item.replace(" ", "").replace(":", "_").replace("-", "_"),
        "GET", "*", "/value",
    ], mutates=False)

    if wmi_res.rc != 0 or not wmi_res.stdout.strip():
        return {"changed": False, "msg": "no data for item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "WMI query failed or returned no data"}}

    values = {}
    for line in wmi_res.stdout.splitlines():
        line = line.strip()
        if line == "":
            continue
        if "=" in line:
            parts = line.split("=", 1)
            values[parts[0].strip()] = parts[1].strip()

    if len(values) == 0:
        return {"changed": False, "msg": "no data for item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "WMI returned empty values"}}

    metric_state = "OK"
    metrics_out = {}
    details_parts = []

    if item == "LS:SIP - Protocol":
        proc_time = _num(values, ["SIP_-_Average_Incoming_Message_Processing_Time", "AverageIncomingMessageProcessingTime"])
        w, c = _upper_levels(params.get("message_processing_time"), 1.0, 2.0)
        s = _grade_upper(proc_time, w, c)
        metric_state = _grade_state(metric_state, s)
        if proc_time != None:
            metrics_out["sip_message_processing_time"] = proc_time
        details_parts.append("Avg incoming message processing time: %s" % str(proc_time))

        resp_dropped = _num(values, ["SIP_-_Incoming_Responses_Dropped_/Sec", "IncomingResponsesDroppedPerSec"])
        w, c = _upper_levels(params.get("incoming_responses_dropped"), 1.0, 2.0)
        s = _grade_upper(resp_dropped, w, c)
        metric_state = _grade_state(metric_state, s)
        if resp_dropped != None:
            metrics_out["sip_incoming_responses_dropped"] = resp_dropped
        details_parts.append("Incoming responses dropped/sec: %s" % str(resp_dropped))

        req_dropped = _num(values, ["SIP_-_Incoming_Requests_Dropped_/Sec", "IncomingRequestsDroppedPerSec"])
        w, c = _upper_levels(params.get("incoming_requests_dropped"), 1.0, 2.0)
        s = _grade_upper(req_dropped, w, c)
        metric_state = _grade_state(metric_state, s)
        if req_dropped != None:
            metrics_out["sip_incoming_requests_dropped"] = req_dropped
        details_parts.append("Incoming requests dropped/sec: %s" % str(req_dropped))

    if item == "LS:USrv - DBStore":
        queue_lat = _num(values, ["USrv_-_Queue_Latency", "QueueLatency"])
        if queue_lat != None:
            queue_lat_scaled = queue_lat * 0.001
        else:
            queue_lat_scaled = None
        w, c = _upper_levels(params.get("queue_latency"), 0.1, 0.2)
        s = _grade_upper(queue_lat_scaled, w, c)
        metric_state = _grade_state(metric_state, s)
        if queue_lat_scaled != None:
            metrics_out["usrv_queue_latency"] = queue_lat_scaled
        details_parts.append("Queue latency: %s" % str(queue_lat_scaled))

        sproc_lat = _num(values, ["USrv_-_Sproc_Latency", "SprocLatency"])
        if sproc_lat != None:
            sproc_lat_scaled = sproc_lat * 0.001
        else:
            sproc_lat_scaled = None
        w, c = _upper_levels(params.get("sproc_latency"), 0.1, 0.2)
        s = _grade_upper(sproc_lat_scaled, w, c)
        metric_state = _grade_state(metric_state, s)
        if sproc_lat_scaled != None:
            metrics_out["usrv_sproc_latency"] = sproc_lat_scaled
        details_parts.append("Sproc latency: %s" % str(sproc_lat_scaled))

        throttled = _num(values, ["USrv_-_Throttled_requests", "ThrottledRequestsPerSec"])
        w, c = _upper_levels(params.get("throttled_requests"), 0.2, 0.4)
        s = _grade_upper(throttled, w, c)
        metric_state = _grade_state(metric_state, s)
        if throttled != None:
            metrics_out["usrv_throttled_requests"] = throttled
        details_parts.append("Throttled requests/sec: %s" % str(throttled))

    if item == "LS:SIP - Responses":
        resp_503 = _num(values, ["SIP_-_Local_503_Responses_/Sec", "Local503ResponsesPerSec"])
        w, c = _upper_levels(params.get("local_503_responses"), 0.01, 0.02)
        s = _grade_upper(resp_503, w, c)
        metric_state = _grade_state(metric_state, s)
        if resp_503 != None:
            metrics_out["sip_503_responses"] = resp_503
        details_parts.append("Local 503 responses/sec: %s" % str(resp_503))

    if item == "LS:SIP - Load Management":
        timed_out = _num(values, ["SIP_-_Incoming_Messages_Timed_out", "IncomingMessagesTimedOut"])
        w, c = _upper_levels(params.get("timedout_incoming_messages"), 2, 4)
        s = _grade_upper(timed_out, w, c)
        metric_state = _grade_state(metric_state, s)
        if timed_out != None:
            metrics_out["sip_incoming_messages_timed_out"] = timed_out
        details_parts.append("Incoming messages timed out: %s" % str(timed_out))

        holding_time = _num(values, ["SIP_-_Average_Holding_Time_For_Incoming_Messages", "AverageHoldingTimeForIncomingMessages"])
        w, c = _upper_levels(params.get("holding_time_incoming"), 6.0, 12.0)
        s = _grade_upper(holding_time, w, c)
        metric_state = _grade_state(metric_state, s)
        if holding_time != None:
            metrics_out["sip_avg_holding_time_incoming_messages"] = holding_time
        details_parts.append("Avg holding time for incoming messages: %s" % str(holding_time))

    if item == "LS:SIP - Peers":
        flow_controlled = _num(values, ["SIP_-_Flow-controlled_Connections", "FlowControlledConnections"])
        w, c = _upper_levels(params.get("flow_controlled_connections"), 1, 2)
        s = _grade_upper(flow_controlled, w, c)
        metric_state = _grade_state(metric_state, s)
        if flow_controlled != None:
            metrics_out["sip_flow_controlled_connections"] = flow_controlled
        details_parts.append("Flow-controlled connections: %s" % str(flow_controlled))

        outgoing_delay = _num(values, ["SIP_-_Average_Outgoing_Queue_Delay", "AverageOutgoingQueueDelay"])
        w, c = _upper_levels(params.get("outgoing_queue_delay"), 2.0, 4.0)
        s = _grade_upper(outgoing_delay, w, c)
        metric_state = _grade_state(metric_state, s)
        if outgoing_delay != None:
            metrics_out["sip_avg_outgoing_queue_delay"] = outgoing_delay
        details_parts.append("Avg outgoing queue delay: %s" % str(outgoing_delay))

        sends_timed_out = _num(values, ["SIP_-_Sends_Timed-Out", "SIP_-_Sends_Timed-Out_/Sec", "SendsTimedOutPerSec"])
        w, c = _upper_levels(params.get("timedout_sends"), 0.01, 0.02)
        s = _grade_upper(sends_timed_out, w, c)
        metric_state = _grade_state(metric_state, s)
        if sends_timed_out != None:
            metrics_out["sip_sends_timed_out"] = sends_timed_out
        details_parts.append("Sends timed out/sec: %s" % str(sends_timed_out))

    if item == "LS:SIP - Authentication":
        auth_errors = _num(values, ["SIP_-_Authentication_System_Errors_/Sec", "AuthenticationSystemErrorsPerSec"])
        w, c = _upper_levels(params.get("authentication_errors"), 1.0, 2.0)
        s = _grade_upper(auth_errors, w, c)
        metric_state = _grade_state(metric_state, s)
        if auth_errors != None:
            metrics_out["sip_authentication_errors"] = auth_errors
        details_parts.append("Authentication errors/sec: %s" % str(auth_errors))

    if len(metrics_out) == 0:
        return {"changed": False, "msg": "no metrics found for item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "No matching counters found in WMI output for " + item}}

    return {"changed": False, "msg": "; ".join(details_parts),
            "data": {"state": metric_state, "metrics": metrics_out, "details": "; ".join(details_parts)}}
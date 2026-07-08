def main(ctx, params):
    # Required parameters
    repo_id = params["name"]
    state = params.get("state", "present")
    relative_url = params.get("relative_url")
    repo_type = params.get("repo_type", "rpm")
    
    # Optional parameters with defaults
    pulp_host = params.get("pulp_host", "https://127.0.0.1")
    feed = params.get("feed")
    add_export_distributor = params.get("add_export_distributor", False)
    generate_sqlite = params.get("generate_sqlite", False)
    serve_http = params.get("serve_http", False)
    serve_https = params.get("serve_https", True)
    repoview = params.get("repoview", False)
    wait_for_completion = params.get("wait_for_completion", False)
    publish_distributor = params.get("publish_distributor")
    
    # Importer proxy and SSL parameters
    proxy_host = params.get("proxy_host")
    proxy_port = params.get("proxy_port")
    proxy_username = params.get("proxy_username")
    proxy_password = params.get("proxy_password")
    ssl_ca_cert = params.get("feed_ca_cert")
    ssl_client_cert = params.get("feed_client_cert")
    ssl_client_key = params.get("feed_client_key")
    
    # Validate required parameters
    if state == "present" and relative_url == None:
        fail("relative_url is required when state is present")
    
    # Handle file paths for certificates - read file content if path provided
    if ssl_ca_cert != None and ctx.file_exists(ssl_ca_cert):
        ssl_ca_cert = ctx.file_read(ssl_ca_cert)
    if ssl_client_cert != None and ctx.file_exists(ssl_client_cert):
        ssl_client_cert = ctx.file_read(ssl_client_cert)
    if ssl_client_key != None and ctx.file_exists(ssl_client_key):
        ssl_client_key = ctx.file_read(ssl_client_key)
    
    # Helper to check repo existence
    repos = ctx.run([pulp_host, "pulp-admin", "rpm", "repo", "list"], ok_codes=[0])
    if repos.rc != 0:
        fail("Failed to list repos: " + repos.stderr)
    
    repo_exists = False
    for line in repos.stdout.split("\n"):
        if line.strip().startswith("Id:"):
            if line.strip().split(":", 1)[1].strip() == repo_id:
                repo_exists = True
                break
    
    changed = False
    msg = ""
    
    if state == "absent":
        if repo_exists:
            if not ctx.check_mode:
                res = ctx.run([pulp_host, "pulp-admin", "rpm", "repo", "delete", "--id", repo_id], mutates=True, ok_codes=[0])
                if res.rc != 0:
                    fail("Failed to delete repo: " + res.stderr)
            changed = True
            msg = "deleted repo " + repo_id
    
    elif state == "sync":
        if not repo_exists:
            fail("Repository was not found. The repository can not be synced.")
        if not ctx.check_mode:
            res = ctx.run([pulp_host, "pulp-admin", "rpm", "repo", "sync", "run", "--id", repo_id], mutates=True, ok_codes=[0])
            if res.rc != 0:
                fail("Failed to sync repo: " + res.stderr)
        changed = True
        msg = "scheduled sync for " + repo_id
    
    elif state == "publish":
        if not repo_exists:
            fail("Repository was not found. The repository can not be published.")
        if not ctx.check_mode:
            args = [pulp_host, "pulp-admin", "rpm", "repo", "publish", "run", "--id", repo_id]
            if publish_distributor != None:
                args.extend(["--distributor-id", publish_distributor])
            res = ctx.run(args, mutates=True, ok_codes=[0])
            if res.rc != 0:
                fail("Failed to publish repo: " + res.stderr)
        changed = True
        msg = "scheduled publish for " + repo_id
    
    elif state == "present":
        if not repo_exists:
            # Create repo
            if not ctx.check_mode:
                args = [
                    pulp_host, "pulp-admin", "rpm", "repo", "create",
                    "--id", repo_id,
                    "--importer-type-id", "yum_importer"
                ]
                if relative_url != None:
                    args.extend(["--relative-url", relative_url])
                
                # Importer config
                importer_config = []
                if feed != None:
                    importer_config.extend(["--feed", feed])
                if proxy_host != None:
                    importer_config.extend(["--proxy-host", proxy_host])
                if proxy_port != None:
                    importer_config.extend(["--proxy-port", proxy_port])
                if proxy_username != None:
                    importer_config.extend(["--proxy-username", proxy_username])
                if proxy_password != None:
                    importer_config.extend(["--proxy-password", proxy_password])
                if ssl_ca_cert != None:
                    importer_config.extend(["--ssl-ca-cert", ssl_ca_cert])
                if ssl_client_cert != None:
                    importer_config.extend(["--ssl-client-cert", ssl_client_cert])
                if ssl_client_key != None:
                    importer_config.extend(["--ssl-client-key", ssl_client_key])
                
                args.extend(importer_config)
                
                # Distributor config
                args.extend([
                    "--distributor-type-id", "yum_distributor",
                    "--distributor-id", "yum_distributor",
                    "--auto-publish", "true"
                ])
                
                if serve_http:
                    args.extend(["--config", "http=true"])
                if serve_https:
                    args.extend(["--config", "https=true"])
                
                # Only pass config for features we support
                if repoview or generate_sqlite:
                    args.extend(["--config", "generate_sqlite=true" if generate_sqlite or repoview else "generate_sqlite=false"])
                if repoview:
                    args.extend(["--config", "repoview=true"])
                
                # Add export distributor if requested
                if add_export_distributor:
                    args.extend([
                        "--distributor-type-id", "export_distributor",
                        "--distributor-id", "export_distributor",
                        "--auto-publish", "false"
                    ])
                    if serve_http:
                        args.extend(["--config", "http=true"])
                    if serve_https:
                        args.extend(["--config", "https=true"])
                    if repoview or generate_sqlite:
                        args.extend(["--config", "generate_sqlite=true" if generate_sqlite or repoview else "generate_sqlite=false"])
                    if repoview:
                        args.extend(["--config", "repoview=true"])
                
                res = ctx.run(args, mutates=True, ok_codes=[0])
                if res.rc != 0:
                    fail("Failed to create repo: " + res.stderr)
            changed = True
            msg = "created repo " + repo_id
        
        else:
            # Update existing repo - simplified: check and update key fields
            # Note: Full config comparison is complex without JSON parsing support
            
            # Update importer config (requires full config overwrite)
            if (feed != None or proxy_host != None or ssl_ca_cert != None or 
                ssl_client_cert != None or ssl_client_key != None):
                if not ctx.check_mode:
                    args = [
                        pulp_host, "pulp-admin", "rpm", "repo", "importer", "update",
                        "--id", repo_id,
                        "--importer-config", "feed=" + str(feed or "")
                    ]
                    if proxy_host != None:
                        args.extend(["--importer-config", "proxy_host=" + proxy_host])
                    if proxy_port != None:
                        args.extend(["--importer-config", "proxy_port=" + proxy_port])
                    if proxy_username != None:
                        args.extend(["--importer-config", "proxy_username=" + proxy_username])
                    if proxy_password != None:
                        args.extend(["--importer-config", "proxy_password=" + proxy_password])
                    if ssl_ca_cert != None:
                        args.extend(["--importer-config", "ssl_ca_cert=" + ssl_ca_cert])
                    if ssl_client_cert != None:
                        args.extend(["--importer-config", "ssl_client_cert=" + ssl_client_cert])
                    if ssl_client_key != None:
                        args.extend(["--importer-config", "ssl_client_key=" + ssl_client_key])
                    
                    res = ctx.run(args, mutates=True, ok_codes=[0])
                    if res.rc != 0:
                        fail("Failed to update importer: " + res.stderr)
                changed = True
            
            # Update distributor config
            dist_config = []
            if relative_url != None:
                dist_config.append("relative_url=" + relative_url)
            if serve_http:
                dist_config.append("http=true")
            if serve_https:
                dist_config.append("https=true")
            if generate_sqlite or repoview:
                dist_config.append("generate_sqlite=true")
            elif generate_sqlite == False:
                dist_config.append("generate_sqlite=false")
            if repoview:
                dist_config.append("repoview=true")
            
            if dist_config != []:
                if not ctx.check_mode:
                    args = [
                        pulp_host, "pulp-admin", "rpm", "repo", "distributor", "update",
                        "--id", repo_id,
                        "--distributor-id", "yum_distributor"
                    ]
                    for cfg in dist_config:
                        args.extend(["--distributor-config", cfg])
                    
                    res = ctx.run(args, mutates=True, ok_codes=[0])
                    if res.rc != 0:
                        fail("Failed to update distributor: " + res.stderr)
                changed = True
            
            if changed:
                msg = "updated repo " + repo_id
            else:
                msg = "repo " + repo_id + " already correct"
    
    else:
        fail("unsupported state: " + state)
    
    if not changed:
        msg = "repo " + repo_id + " already in desired state"
    
    return {"changed": changed, "msg": msg, "data": {"repo": repo_id}}

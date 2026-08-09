/**
 * Per-web-server profile for the IIS-Manager-style config tree (web-config-tree.component).
 *
 * One component renders the tree; a profile tells it, for a given server, where sites live, which vhost
 * template + schema drives a site's Features panes, how to validate + reload, and which schema fields map to
 * the IIS concepts (server name / host, www root, binding port, TLS + certificate, locations). Adding a
 * server = adding a profile, not new component code. M1 nginx, M2 apache; haproxy/caddy follow.
 */
export interface WebServerFieldMap {
  serverName: string;   // IIS: host header
  root: string;         // IIS: physical path / www root
  port: string;         // IIS: binding port
  tlsEnabled: string;   // IIS: https binding toggle
  cert: string;         // IIS: SSL certificate on the binding
  certKey: string;      // cert key (nginx/apache split cert+key)
  locations: string;    // schema field holding the location list ('' when the server has none)
}

export interface WebServerProfile {
  /** stable key = the snap-in server id (nginx | apache | haproxy | caddy). */
  key: string;
  label: string;
  /** config-template name whose j2 renders ONE site and whose schema drives the Features panes. */
  vhostTemplate: string;
  service: string;
  /** primary sites directory (Debian layout). */
  sitesDir: string;
  /** the "enabled" symlink dir (Debian nginx/apache), or null when there is no enable step. */
  sitesEnabledDir: string | null;
  /** fallback dir when sitesDir is empty (RedHat/upstream conf.d). */
  confdDir: string;
  /** where the per-site VALUES sidecar JSON lives (outside any include glob). */
  sidecarDir: string;
  /** filename suffix for a site file ('' nginx, '.conf' apache). The display name drops it. */
  fileSuffix: string;
  /** glob for enumerating site files (undefined = all files; apache = '*.conf'). */
  sitesPattern?: string;
  /** argv that validates the whole config (rc 0 = OK). */
  validateArgv: string[];
  /** argv that reloads the server. */
  reloadArgv: string[];
  /** vhost-schema fields mapped onto the IIS concepts. */
  fields: WebServerFieldMap;
  /** whether the server supports a list of location/virtual-directory blocks (nginx yes, apache no). */
  locationsList: boolean;
  /** which vhost-schema fields appear on which per-node Features pane (bindings / wwwroot / locations). */
  featureGroups: Record<string, string[]>;
  /** directories scanned for certificate files (the file-based Certificates node). */
  certSearchDirs: string[];
}

export const NGINX_PROFILE: WebServerProfile = {
  key: 'nginx',
  label: 'NGINX',
  vhostTemplate: 'nginx-vhost',
  service: 'nginx',
  sitesDir: '/etc/nginx/sites-available',
  sitesEnabledDir: '/etc/nginx/sites-enabled',
  confdDir: '/etc/nginx/conf.d',
  sidecarDir: '/etc/agentic-mcp/websites/nginx',
  fileSuffix: '',
  validateArgv: ['nginx', '-t'],
  reloadArgv: ['nginx', '-s', 'reload'],
  fields: { serverName: 'server_name', root: 'root', port: 'listen_port', tlsEnabled: 'tls_enabled',
            cert: 'ssl_certificate', certKey: 'ssl_certificate_key', locations: 'locations' },
  locationsList: true,
  featureGroups: {
    bindings: ['listen_port', 'listen_ipv6', 'tls_enabled', 'ssl_certificate', 'ssl_certificate_key',
               'ssl_protocols', 'ssl_ciphers', 'http2', 'hsts', 'redirect_to_https'],
    wwwroot: ['root', 'index_files', 'directory_browsing', 'client_max_body_size', 'compression',
              'access_log', 'error_log', 'error_pages', 'response_headers'],
    locations: ['locations', 'upstreams'],
  },
  certSearchDirs: ['/etc/ssl', '/etc/letsencrypt', '/etc/pki', '/etc/nginx/ssl'],
};

export const APACHE_PROFILE: WebServerProfile = {
  key: 'apache',
  label: 'Apache HTTP Server',
  vhostTemplate: 'apache-vhost',
  service: 'apache2',
  sitesDir: '/etc/apache2/sites-available',
  sitesEnabledDir: '/etc/apache2/sites-enabled',
  confdDir: '/etc/httpd/conf.d',
  sidecarDir: '/etc/agentic-mcp/websites/apache',
  fileSuffix: '.conf',
  sitesPattern: '*.conf',
  validateArgv: ['apache2ctl', '-t'],
  reloadArgv: ['apache2ctl', '-k', 'graceful'],
  fields: { serverName: 'server_name', root: 'document_root', port: 'listen_port', tlsEnabled: 'tls_enabled',
            cert: 'ssl_certificate', certKey: 'ssl_certificate_key', locations: '' },
  locationsList: false,
  featureGroups: {
    bindings: ['listen_port', 'tls_enabled', 'ssl_certificate', 'ssl_certificate_key', 'ssl_protocol',
               'ssl_cipher_suite', 'hsts', 'redirect_to_https'],
    wwwroot: ['document_root', 'directory_index', 'allow_override', 'directory_browsing', 'limit_request_body',
              'compression', 'error_log', 'access_log', 'error_pages', 'response_headers'],
    locations: ['proxy_pass'],
  },
  certSearchDirs: ['/etc/ssl', '/etc/letsencrypt', '/etc/pki', '/etc/apache2/ssl'],
};

export const PROFILES: Record<string, WebServerProfile> = {
  nginx: NGINX_PROFILE,
  apache: APACHE_PROFILE,
};

// ── Single-config servers (HAProxy, Caddy) ─────────────────────────────────────────────────────────────
//
// nginx/apache are "one file per site"; HAProxy and Caddy are the opposite — ONE config file rendered whole
// from ONE values doc. The IIS-style tree still applies, but its nodes are declared feature SECTIONS of that
// single document (global / frontend / backend / a list of sites or backend-servers) rather than discovered
// site files. web-single-config-tree.component renders these; one component, both profiles.

/** One node in the single-config tree: either a fixed group of schema fields, or a list whose items become
 *  child leaf nodes (each editable, add/remove via the context menu). */
export interface WebSectionSpec {
  key: string;
  label: string;
  icon: string;
  kind: 'group' | 'list';
  /** group: top-level schema fields shown on this section's Features pane. */
  fields?: string[];
  /** list: the schema list-field whose entries are child nodes. */
  listField?: string;
  /** list: which item field labels each entry in the tree. */
  itemNameField?: string;
  /** list: the context-menu action label (e.g. "Add Website", "Add Server"). */
  itemActionLabel?: string;
  /** list: seed values for a newly-added item. */
  itemDefault?: Record<string, unknown>;
}

export interface SingleConfigProfile {
  key: string;
  label: string;
  /** whole-config template name (renders the entire file from one values doc). */
  template: string;
  service: string;
  /** the rendered config file path. */
  configPath: string;
  /** the single values sidecar (JSON) this config round-trips through. */
  sidecarPath: string;
  /** argv that validates the whole config (rc 0 = OK). */
  validateArgv: string[];
  /** argv that reloads the server. */
  reloadArgv: string[];
  /** the tree's feature sections, in order. */
  sections: WebSectionSpec[];
  /** directories scanned for certificate files (the file-based Certificates node). */
  certSearchDirs: string[];
}

export const HAPROXY_PROFILE: SingleConfigProfile = {
  key: 'haproxy',
  label: 'HAProxy',
  template: 'haproxy',
  service: 'haproxy',
  configPath: '/etc/haproxy/haproxy.cfg',
  sidecarPath: '/etc/agentic-mcp/websites/haproxy/haproxy.json',
  validateArgv: ['haproxy', '-c', '-f', '/etc/haproxy/haproxy.cfg'],
  reloadArgv: ['systemctl', 'reload', 'haproxy'],
  sections: [
    { key: 'global', label: 'Global', icon: 'settings', kind: 'group',
      fields: ['maxconn', 'user', 'group', 'log_level', 'mode', 'timeout_connect', 'timeout_client', 'timeout_server'] },
    { key: 'frontend', label: 'Frontend', icon: 'lan', kind: 'group',
      fields: ['http_port', 'tls_enabled', 'https_port', 'ssl_cert_pem', 'ssl_min_version', 'ssl_ciphers', 'redirect_to_https', 'hsts'] },
    { key: 'backend', label: 'Backend', icon: 'dns', kind: 'group',
      fields: ['backend_name', 'balance_algorithm'] },
    { key: 'servers', label: 'Backend servers', icon: 'account_tree', kind: 'list',
      listField: 'backend_servers', itemNameField: 'name', itemActionLabel: 'Add Server',
      itemDefault: { name: '', address: '', port: 8080, check: true } },
  ],
  certSearchDirs: ['/etc/ssl', '/etc/letsencrypt', '/etc/pki', '/etc/haproxy/certs'],
};

export const CADDY_PROFILE: SingleConfigProfile = {
  key: 'caddy',
  label: 'Caddy',
  template: 'caddy',
  service: 'caddy',
  configPath: '/etc/caddy/Caddyfile',
  sidecarPath: '/etc/agentic-mcp/websites/caddy/caddy.json',
  validateArgv: ['caddy', 'validate', '--adapter', 'caddyfile', '--config', '/etc/caddy/Caddyfile'],
  reloadArgv: ['systemctl', 'reload', 'caddy'],
  sections: [
    { key: 'global', label: 'Global options', icon: 'settings', kind: 'group',
      fields: ['acme_email', 'admin_off'] },
    { key: 'sites', label: 'Sites', icon: 'folder', kind: 'list',
      listField: 'sites', itemNameField: 'domain', itemActionLabel: 'Add Website',
      itemDefault: { domain: '', upstream: '', root: '', tls: '', extra: '' } },
  ],
  certSearchDirs: ['/etc/ssl', '/etc/letsencrypt', '/etc/pki', '/etc/caddy'],
};

export const SINGLE_CONFIG_PROFILES: Record<string, SingleConfigProfile> = {
  haproxy: HAPROXY_PROFILE,
  caddy: CADDY_PROFILE,
};

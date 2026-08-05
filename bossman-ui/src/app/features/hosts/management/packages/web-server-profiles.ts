/**
 * Per-web-server profile for the IIS-Manager-style config tree (web-config-tree.component).
 *
 * One component renders the tree; a profile tells it, for a given server, where sites live, which vhost
 * template + schema drives a site's Features panes, how to validate + reload, and which schema fields map to
 * the IIS concepts (server name / host, www root, binding port, TLS + certificate, locations). Adding a
 * server = adding a profile, not new component code. M1 ships nginx; apache/haproxy/caddy follow.
 */
export interface WebServerFieldMap {
  /** schema field holding the site's host/server name (IIS: host header). */
  serverName: string;
  /** schema field holding the document root (IIS: physical path / www root). */
  root: string;
  /** schema field holding the listen port (IIS: binding port). */
  port: string;
  /** schema field toggling HTTPS (IIS: https binding). */
  tlsEnabled: string;
  /** schema field for the certificate file path (IIS: SSL certificate on the binding). */
  cert: string;
  /** schema field for the certificate key path (nginx/apache split cert+key). */
  certKey: string;
  /** schema field holding the list of location/virtual-directory blocks. */
  locations: string;
}

export interface WebServerProfile {
  /** stable key = the snap-in server id (nginx | apache | haproxy | caddy). */
  key: string;
  /** display label for the server (root tree node). */
  label: string;
  /** config-template name whose j2 renders ONE site and whose schema drives the Features panes. */
  vhostTemplate: string;
  /** systemd unit / binary name. */
  service: string;
  /** primary directory sites are written to (Debian layout). */
  sitesDir: string;
  /** the "enabled" symlink dir (Debian nginx/apache), or null when the server has no enable step. */
  sitesEnabledDir: string | null;
  /** fallback directory when sitesDir is empty (RedHat/upstream conf.d). */
  confdDir: string;
  /** where the per-site VALUES sidecar JSON is stored (outside any include glob). */
  sidecarDir: string;
  /** argv that validates the whole config (rc 0 = OK), run before reload. */
  validateArgv: string[];
  /** argv that reloads the server after a successful apply. */
  reloadArgv: string[];
  /** which vhost-schema fields map onto the IIS concepts. */
  fields: WebServerFieldMap;
  /** directories scanned for certificate files (the file-based Certificates node). */
  certSearchDirs: string[];
}

/** nginx (Debian sites-available/enabled, conf.d fallback), driven by the nginx-vhost template. */
export const NGINX_PROFILE: WebServerProfile = {
  key: 'nginx',
  label: 'NGINX',
  vhostTemplate: 'nginx-vhost',
  service: 'nginx',
  sitesDir: '/etc/nginx/sites-available',
  sitesEnabledDir: '/etc/nginx/sites-enabled',
  confdDir: '/etc/nginx/conf.d',
  sidecarDir: '/etc/agentic-mcp/websites/nginx',
  validateArgv: ['nginx', '-t'],
  reloadArgv: ['nginx', '-s', 'reload'],
  fields: {
    serverName: 'server_name',
    root: 'root',
    port: 'listen_port',
    tlsEnabled: 'tls_enabled',
    cert: 'ssl_certificate',
    certKey: 'ssl_certificate_key',
    locations: 'locations',
  },
  certSearchDirs: ['/etc/ssl', '/etc/letsencrypt', '/etc/pki', '/etc/nginx/ssl'],
};

/** The IIS "Features" grouping of a site's schema fields — which fields appear on which per-node pane. Any
 *  schema field not listed here falls into the site's "All settings" pane, so extending a schema (M5) never
 *  hides a setting. Groups are matched by field name against the profile's fieldMap + these extras. */
export const NGINX_FEATURE_GROUPS: Record<string, string[]> = {
  // Bindings pane (IIS: Edit Bindings + SSL Settings)
  bindings: ['listen_port', 'listen_ipv6', 'tls_enabled', 'ssl_certificate', 'ssl_certificate_key',
             'ssl_protocols', 'ssl_ciphers', 'http2', 'hsts', 'redirect_to_https'],
  // www root pane
  wwwroot: ['root'],
  // Locations pane (IIS: Applications / Virtual Directories)
  locations: ['locations', 'upstreams'],
};

export const PROFILES: Record<string, WebServerProfile> = {
  nginx: NGINX_PROFILE,
};

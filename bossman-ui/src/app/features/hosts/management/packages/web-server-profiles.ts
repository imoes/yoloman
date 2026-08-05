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
    wwwroot: ['root'],
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
    wwwroot: ['document_root', 'directory_index', 'allow_override'],
    locations: ['proxy_pass'],
  },
  certSearchDirs: ['/etc/ssl', '/etc/letsencrypt', '/etc/pki', '/etc/apache2/ssl'],
};

export const PROFILES: Record<string, WebServerProfile> = {
  nginx: NGINX_PROFILE,
  apache: APACHE_PROFILE,
};

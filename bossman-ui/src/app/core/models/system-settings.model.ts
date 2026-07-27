/** Matches bossman/api/system_settings.py's SystemSettingsOut — currently
 * just the global "YOLO-MAN" mode switch (Block L2, the project's own
 * namesake: "You Only Look Once"). When on, every new orchestration plan
 * link activates immediately, bypassing its own require_approval/
 * auto_apply. Human-only: no MCP tool can set this. */
export interface SystemSettings {
  yolo_mode: boolean;
  /** Bossman-wide HTTP(S) proxy for `helm` chart pulls (helm runs on the
   * agent host; an internet OCI registry like bitnami is unreachable from a
   * host behind a corp firewall). Empty = no proxy. See SetHelmProxyInput. */
  helm_http_proxy: string;
  helm_no_proxy: string;
  updated_by: string | null;
  updated_at: string;
}

/** Matches bossman/api/system_settings.py's SetYoloModeIn. */
export interface SetYoloModeInput {
  enabled: boolean;
}

/** Matches bossman/api/system_settings.py's SetHelmProxyIn. */
export interface SetHelmProxyInput {
  http_proxy: string;
  no_proxy: string;
}

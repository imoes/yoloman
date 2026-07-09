/** Matches bossman/api/enroll_info.py's EnrollInfoResponse. */
export interface EnrollInfo {
  configured: boolean;
  enroll_url: string | null;
  enroll_secret: string | null;
  register_command: string | null;
  /** Block N-enroll: whether server-driven SSH deploy is configured. */
  deploy_configured: boolean;
}

/** Matches bossman/api/deploy.py's DeployResponseBody. */
export interface DeployResult {
  agent_id: string;
  name: string;
  address: string | null;
}

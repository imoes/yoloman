/** Matches bossman/api/enroll_info.py's EnrollInfoResponse. */
export interface EnrollInfo {
  configured: boolean;
  enroll_url: string | null;
  enroll_secret: string | null;
  register_command: string | null;
}

/** Block M — user / API-token / access-grant administration + /me.
 * Shapes mirror bossman/api/users.py exactly. */

export type SubjectKind = 'user' | 'api_token';
export type GrantScope = 'all' | 'host' | 'host_group';
export type UserRole = 'admin' | 'operator';

export interface AccessGrant {
  id: string;
  subject_kind: SubjectKind;
  subject_ref: string;
  scope: GrantScope;
  agent_id: string | null;
  host_group_id: string | null;
  permission: string;
}

export interface CreateGrantInput {
  subject_kind: SubjectKind;
  subject_ref: string;
  scope: GrantScope;
  agent_id?: string | null;
  host_group_id?: string | null;
}

export interface BossmanUser {
  id: string;
  username: string;
  role: UserRole;
  created_at: string | null;
}

export interface CreateUserInput {
  username: string;
  password: string;
  role: UserRole;
}

export interface UpdateUserInput {
  role?: UserRole;
  password?: string;
}

export interface ApiTokenRow {
  id: string;
  name: string;
  created_at: string | null;
  revoked: boolean;
}

/** POST /api/v1/api-tokens returns the raw secret exactly once. */
export interface CreatedApiToken {
  id: string;
  name: string;
  token: string;
}

/** GET /api/v1/me — the caller's own identity + grants. */
export interface Me {
  kind: SubjectKind;
  name: string;
  role: string | null;
  is_admin: boolean;
  grants: AccessGrant[];
}

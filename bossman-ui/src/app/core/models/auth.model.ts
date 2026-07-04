export interface LoginResponse {
  access_token: string;
  token_type: string;
}

/** Decoded JWT payload — sub/role for a human user, no role for an API token (not applicable in this UI). */
export interface JwtClaims {
  sub: string;
  role: string;
  iat: number;
  exp: number;
}

import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';
import {
  AccessGrant,
  ApiTokenRow,
  BossmanUser,
  CreateGrantInput,
  CreateUserInput,
  CreatedApiToken,
  Me,
  UpdateUserInput,
} from '../models/access.model';

/** REST client for Block M user/token/grant administration. Every route
 * except /me is admin-only on the backend (require_admin); the UI also
 * gates the surface on the caller's role, but the backend is the source
 * of truth. */
@Injectable({ providedIn: 'root' })
export class AccessService {
  private http = inject(HttpClient);
  private base = environment.apiUrl;

  me() {
    return this.http.get<Me>(`${this.base}/me`);
  }

  // ---- users ----
  listUsers() {
    return this.http.get<{ users: BossmanUser[] }>(`${this.base}/users`);
  }
  createUser(body: CreateUserInput) {
    return this.http.post<BossmanUser>(`${this.base}/users`, body);
  }
  updateUser(username: string, body: UpdateUserInput) {
    return this.http.patch<BossmanUser>(`${this.base}/users/${encodeURIComponent(username)}`, body);
  }
  deleteUser(username: string) {
    return this.http.delete<void>(`${this.base}/users/${encodeURIComponent(username)}`);
  }

  // ---- API tokens ----
  listTokens() {
    return this.http.get<{ tokens: ApiTokenRow[] }>(`${this.base}/api-tokens`);
  }
  createToken(name: string) {
    return this.http.post<CreatedApiToken>(`${this.base}/api-tokens`, { name });
  }
  revokeToken(id: string) {
    return this.http.delete<void>(`${this.base}/api-tokens/${id}`);
  }

  // ---- access grants ----
  listGrants() {
    return this.http.get<{ grants: AccessGrant[] }>(`${this.base}/access-grants`);
  }
  createGrant(body: CreateGrantInput) {
    return this.http.post<AccessGrant>(`${this.base}/access-grants`, body);
  }
  deleteGrant(id: string) {
    return this.http.delete<void>(`${this.base}/access-grants/${id}`);
  }
}

import { Injectable, computed, signal } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Router } from '@angular/router';
import { tap } from 'rxjs';
import { environment } from '../../../environments/environment';
import { JwtClaims, LoginResponse } from '../models/auth.model';

const TOKEN_KEY = 'bossman_access_token';

/**
 * Bossman's backend (see bossman/api/auth.py) has only POST /auth/login —
 * no refresh-token endpoint, no /auth/me. So identity comes entirely from
 * decoding the JWT payload client-side (never trusted for authorization,
 * only for display — the backend re-verifies the signature on every
 * request), and "logged in" means "a token is present and its own exp
 * claim hasn't passed yet".
 */
@Injectable({ providedIn: 'root' })
export class AuthService {
  private readonly _token = signal<string | null>(localStorage.getItem(TOKEN_KEY));

  private readonly _claims = computed<JwtClaims | null>(() => {
    const token = this._token();
    return token ? decodeJwtPayload(token) : null;
  });

  readonly isLoggedIn = computed(() => {
    const claims = this._claims();
    return !!claims && claims.exp * 1000 > Date.now();
  });

  readonly username = computed(() => this._claims()?.sub ?? null);
  readonly role = computed(() => this._claims()?.role ?? null);

  constructor(
    private http: HttpClient,
    private router: Router,
  ) {}

  login(username: string, password: string) {
    return this.http
      .post<LoginResponse>(`${environment.apiUrl}/auth/login`, { username, password })
      .pipe(tap((res) => this.setToken(res.access_token)));
  }

  /** Does this installation still have NO account at all? Asked before the login form is shown, so a fresh
   * install offers "create the first administrator" instead of a password prompt nobody can satisfy. */
  needsSetup() {
    return this.http.get<{ needs_setup: boolean }>(`${environment.apiUrl}/auth/setup`);
  }

  /** Create the first operator. The server refuses with 409 the moment any account exists, so this is a
   * one-shot rather than a signup route — and it returns a token, so the operator is signed in immediately
   * instead of typing the password a second time. */
  setup(username: string, password: string) {
    return this.http
      .post<LoginResponse>(`${environment.apiUrl}/auth/setup`, { username, password })
      .pipe(tap((res) => this.setToken(res.access_token)));
  }

  logout(): void {
    this.setToken(null);
    this.router.navigate(['/login']);
  }

  getToken(): string | null {
    return this._token();
  }

  private setToken(token: string | null): void {
    this._token.set(token);
    if (token) {
      localStorage.setItem(TOKEN_KEY, token);
    } else {
      localStorage.removeItem(TOKEN_KEY);
    }
  }
}

function decodeJwtPayload(token: string): JwtClaims | null {
  try {
    const payload = token.split('.')[1];
    const json = atob(payload.replace(/-/g, '+').replace(/_/g, '/'));
    return JSON.parse(json) as JwtClaims;
  } catch {
    return null;
  }
}

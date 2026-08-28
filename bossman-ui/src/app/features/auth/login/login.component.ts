import { Component, inject } from '@angular/core';
import { FormBuilder, ReactiveFormsModule, Validators } from '@angular/forms';
import { ActivatedRoute, Router } from '@angular/router';
import { MatCardModule } from '@angular/material/card';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatButtonModule } from '@angular/material/button';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { AuthService } from '../../../core/auth/auth.service';

/** The one place in the whole app that gets a stronger branding moment
 * (see docs/plan.md's Bossman plan, section C.2) — everywhere else stays
 * neutral, Rasta colours used only as accents. */
@Component({
  selector: 'app-login',
  standalone: true,
  imports: [
    ReactiveFormsModule,
    MatCardModule,
    MatFormFieldModule,
    MatInputModule,
    MatButtonModule,
    MatProgressSpinnerModule,
  ],
  template: `
    <div class="bm-login-page">
      <div class="bm-login-stripe"></div>
      <mat-card class="bm-login-card">
        <div class="bm-login-logo">
          <img src="assets/bossman.jpg" alt="Bossman — Fleet Commander" />
        </div>
        <p class="bm-beta-note"><strong>Beta.</strong> Pre-1.0: interfaces and stored formats can still
          change between versions. Not yet a promise you should build a change process on.</p>
        <mat-card-content>
          <!-- FIRST RUN. Asked before anything is offered: an installation with no account cannot be logged
               into, and showing a password prompt there is asking a question that has no answer. -->
          @if (needsSetup) {
            <p class="bm-setup-lead"><strong>Welcome.</strong> This installation has no account yet — create
              the first administrator.</p>
          }
          <form [formGroup]="form" (ngSubmit)="onSubmit()">
            <mat-form-field appearance="outline" class="bm-full-width">
              <mat-label>Username</mat-label>
              <input matInput formControlName="username" autocomplete="username" />
            </mat-form-field>
            <mat-form-field appearance="outline" class="bm-full-width">
              <mat-label>Password</mat-label>
              <input matInput type="password" formControlName="password"
                     [autocomplete]="needsSetup ? 'new-password' : 'current-password'" />
              @if (needsSetup) { <mat-hint>At least 12 characters.</mat-hint> }
            </mat-form-field>
            @if (needsSetup) {
              <mat-form-field appearance="outline" class="bm-full-width">
                <mat-label>Repeat password</mat-label>
                <input matInput type="password" formControlName="repeat" autocomplete="new-password" />
              </mat-form-field>
            }
            @if (error) {
              <p class="bm-error">{{ error }}</p>
            }
            <button
              mat-raised-button
              color="primary"
              type="submit"
              class="bm-full-width"
              [disabled]="form.invalid || loading"
            >
              @if (loading) {
                <mat-spinner diameter="20"></mat-spinner>
              } @else {
                {{ needsSetup ? 'Create administrator' : 'Sign in' }}
              }
            </button>
          </form>
        </mat-card-content>
      </mat-card>
    </div>
  `,
  styles: [
    `
      .bm-login-page {
        display: flex;
        align-items: center;
        justify-content: center;
        height: 100vh;
        background: var(--bm-black);
        position: relative;
      }
      .bm-login-stripe {
        position: absolute;
        top: 0;
        left: 0;
        right: 0;
        height: 6px;
        background: linear-gradient(90deg, var(--bm-red) 0%, var(--bm-gold) 50%, var(--bm-green) 100%);
      }
      .bm-login-card {
        width: 360px;
        padding: 8px 8px 16px;
      }
      .bm-login-logo {
        display: flex;
        justify-content: center;
        padding: 24px 8px 8px;
      }
      .bm-login-logo img {
        width: 180px;
        height: 180px;
        object-fit: cover;
        border-radius: 12px;
      }
      .bm-full-width {
        width: 100%;
        margin-bottom: 12px;
      }
      .bm-error {
        color: var(--bm-red);
        margin-bottom: 8px;
        font-size: 13px;
      }
      .bm-beta-note {
        margin: 0 22px 6px;
        padding: 7px 9px;
        border-radius: 6px;
        border-left: 3px solid var(--bm-gold, #f5c518);
        background: rgba(245, 197, 24, 0.09);
        font-size: 12px;
        line-height: 1.45;
      }
      .bm-setup-lead {
        margin: 0 0 14px;
        font-size: 13px;
        line-height: 1.5;
        opacity: 0.85;
      }
    `,
  ],
})
export class LoginComponent {
  private fb = inject(FormBuilder);
  private auth = inject(AuthService);
  private router = inject(Router);
  private route = inject(ActivatedRoute);

  loading = false;
  error = '';
  /** True while this installation has no account at all — then this page CREATES the first administrator
   * instead of asking for a password nobody can have. Starts false: showing a setup form to someone who
   * merely lost their connection would invite them to try creating an account that already exists. */
  needsSetup = false;

  form = this.fb.group({
    username: ['', Validators.required],
    password: ['', Validators.required],
    // Only used in setup mode, and enabled there — a disabled control is excluded from form.invalid, which
    // is exactly what makes the same form serve both jobs.
    repeat: [''],
  });

  constructor() {
    this.auth.needsSetup().subscribe({
      next: (r) => {
        this.needsSetup = r.needs_setup;
        if (r.needs_setup) {
          this.form.controls.password.addValidators(Validators.minLength(12));
          this.form.controls.repeat.addValidators(Validators.required);
          this.form.controls.password.updateValueAndValidity();
          this.form.controls.repeat.updateValueAndValidity();
        }
      },
      // An older Bossman has no /auth/setup. Offering the login form is the right guess there — it is what
      // that version could do — rather than blocking the page because a new endpoint is missing.
      error: () => { this.needsSetup = false; },
    });
  }

  onSubmit(): void {
    if (this.form.invalid) return;
    const { username, password, repeat } = this.form.value;
    if (this.needsSetup && password !== repeat) {
      // Checked HERE and not on the server: the server sees one password and cannot know it was mistyped.
      this.error = 'The two passwords do not match';
      return;
    }
    this.loading = true;
    this.error = '';

    const request = this.needsSetup
      ? this.auth.setup(username!, password!)
      : this.auth.login(username!, password!);

    request.subscribe({
      next: () => {
        const returnUrl = this.route.snapshot.queryParamMap.get('returnUrl');
        this.router.navigateByUrl(returnUrl || '/fleet');
      },
      error: (e: { status?: number; error?: { detail?: string } }) => {
        if (this.needsSetup) {
          // 409 means somebody else finished the setup between the page loading and this submit. Saying
          // "invalid credentials" there would be a lie about what happened.
          this.error = e?.status === 409
            ? 'This installation now has an account — reload and sign in.'
            : (e?.error?.detail || 'Could not create the administrator');
        } else {
          this.error = 'Invalid username or password';
        }
        this.loading = false;
      },
    });
  }
}

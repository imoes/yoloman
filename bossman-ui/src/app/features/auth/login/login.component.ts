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
        <div class="bm-login-mascots">
          <img src="assets/yolo-man.jpg" alt="YOLO-MAN — the node agent that runs on every server" />
          <img src="assets/bossman.jpg" alt="Bossman — the fleet commander watching over all of them" />
        </div>
        <mat-card-header>
          <mat-card-title>Bossman</mat-card-title>
          <mat-card-subtitle>Fleet Commander</mat-card-subtitle>
        </mat-card-header>
        <mat-card-content>
          <form [formGroup]="form" (ngSubmit)="onSubmit()">
            <mat-form-field appearance="outline" class="bm-full-width">
              <mat-label>Username</mat-label>
              <input matInput formControlName="username" autocomplete="username" />
            </mat-form-field>
            <mat-form-field appearance="outline" class="bm-full-width">
              <mat-label>Password</mat-label>
              <input matInput type="password" formControlName="password" autocomplete="current-password" />
            </mat-form-field>
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
                Sign in
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
      .bm-login-mascots {
        display: flex;
        justify-content: center;
        gap: 12px;
        padding: 16px 8px 0;
      }
      .bm-login-mascots img {
        width: 96px;
        height: 96px;
        object-fit: cover;
        border-radius: 8px;
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

  form = this.fb.group({
    username: ['', Validators.required],
    password: ['', Validators.required],
  });

  onSubmit(): void {
    if (this.form.invalid) return;
    this.loading = true;
    this.error = '';
    const { username, password } = this.form.value;

    this.auth.login(username!, password!).subscribe({
      next: () => {
        const returnUrl = this.route.snapshot.queryParamMap.get('returnUrl');
        this.router.navigateByUrl(returnUrl || '/fleet');
      },
      error: () => {
        this.error = 'Invalid username or password';
        this.loading = false;
      },
    });
  }
}

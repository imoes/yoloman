import { Component, inject, signal } from '@angular/core';
import { ActivatedRoute, Router, RouterLink } from '@angular/router';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { toSignal } from '@angular/core/rxjs-interop';
import { map } from 'rxjs';
import { DiagnosisPanelComponent } from './diagnosis-panel.component';

/**
 * A saved diagnosis at its own address — the permalink (UX concept #3). `/diagnoses/:id` loads the kept document by
 * id and shows it exactly as the console does, so a link to a diagnosis can be sent to a colleague or pasted into a
 * ticket. It is read-only history: the panel in stored mode offers export, explain and propose (all keyed on the
 * saved id), but not "diagnose again" — a saved diagnosis is what was true then, not a live re-run.
 */
@Component({
  selector: 'app-diagnosis-page',
  standalone: true,
  imports: [MatIconModule, MatButtonModule, RouterLink, DiagnosisPanelComponent],
  template: `
    <div class="bm-page">
      <header class="bm-head">
        <div>
          <h1>Diagnosis</h1>
          <p class="bm-dim">A saved diagnosis at its own link — shown as it was recorded. Everything here comes from
            the kept document; nothing is re-run on the host.</p>
        </div>
        <span class="bm-back-btns">
          <a mat-stroked-button routerLink="/diagnoses" class="bm-back"><mat-icon>troubleshoot</mat-icon> All diagnoses</a>
          <a mat-stroked-button routerLink="/mmc" class="bm-back"><mat-icon>dns</mat-icon> Management console</a>
        </span>
      </header>

      @if (id(); as did) {
        <app-diagnosis-panel [storedId]="did" (closed)="back()" />
      } @else {
        <p class="bm-dim">No diagnosis id in the link.</p>
      }
    </div>
  `,
  styles: [`
    .bm-page { padding: 18px 20px 0; }
    .bm-head { display: flex; justify-content: space-between; align-items: flex-start; gap: 24px; }
    .bm-head h1 { margin: 0 0 4px; }
    .bm-head p { margin: 0; max-width: 760px; font-size: 13px; line-height: 1.5; }
    .bm-dim { opacity: 0.62; }
    .bm-back-btns { display: inline-flex; gap: 8px; flex-wrap: wrap; }
    .bm-back { display: inline-flex; align-items: center; gap: 6px; white-space: nowrap; }
  `],
})
export class DiagnosisPageComponent {
  private route = inject(ActivatedRoute);
  private router = inject(Router);
  id = toSignal(this.route.paramMap.pipe(map((p) => p.get('id') ?? '')), { initialValue: '' });

  back(): void { this.router.navigate(['/mmc']); }
}

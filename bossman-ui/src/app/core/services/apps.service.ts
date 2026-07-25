import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';

/** A deployable App target (native | docker | k8s). Increment 1: native only. */
export interface AppTarget {
  role?: string;
  template?: string | null;
  validate_cmd?: string | null;
  families?: Record<string, unknown>;
  image?: string;   // docker tier: the default container image
  chart?: string;   // k8s tier: the default Helm chart
}

export interface AppSummary {
  id: string;
  label: string;
  category: string;
  icon: string;
  description: string;
  configurable: boolean;
  targets: { native?: AppTarget; docker?: AppTarget; k8s?: AppTarget };
}

export interface AppDetail extends AppSummary {
  values_schema?: Record<string, unknown>;
  sample?: Record<string, unknown>;
}

/** The unified App catalog — a read-model over package-catalog + config
 * templates (see docs/app-model.md). Increment 1: list + detail (native tier). */
@Injectable({ providedIn: 'root' })
export class AppsService {
  private http = inject(HttpClient);
  private base = `${environment.apiUrl}/apps`;

  list() {
    return this.http.get<{ apps: AppSummary[]; count: number }>(this.base);
  }
  get(id: string) {
    return this.http.get<AppDetail>(`${this.base}/${encodeURIComponent(id)}`);
  }
}

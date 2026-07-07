import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';
import { ModuleCatalog, ModuleDetail } from '../models/module.model';

/** REST client for the module library (Block H4) — same shape as
 * MonitoringService/AgentService. */
@Injectable({ providedIn: 'root' })
export class ModuleService {
  private http = inject(HttpClient);
  private base = `${environment.apiUrl}/modules`;

  catalog() {
    return this.http.get<ModuleCatalog>(this.base);
  }

  detail(fqcn: string) {
    return this.http.get<ModuleDetail>(`${this.base}/${encodeURIComponent(fqcn)}`);
  }
}

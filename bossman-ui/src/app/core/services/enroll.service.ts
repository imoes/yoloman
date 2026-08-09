import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';
import { DeployResult, EnrollInfo } from '../models/enroll.model';

@Injectable({ providedIn: 'root' })
export class EnrollService {
  private http = inject(HttpClient);
  private base = `${environment.apiUrl}/enroll`;

  info() {
    return this.http.get<EnrollInfo>(`${this.base}/info`);
  }

  /** Block N-enroll: server-driven SSH deploy — Bossman SSHes into `host`,
   * installs the agent, provisions its config, and records it as enrolled. */
  deploy(host: string) {
    return this.http.post<DeployResult>(`${this.base}/deploy`, { host });
  }
}

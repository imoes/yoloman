import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';
import { EnrollInfo } from '../models/enroll.model';

@Injectable({ providedIn: 'root' })
export class EnrollService {
  private http = inject(HttpClient);
  private base = `${environment.apiUrl}/enroll`;

  info() {
    return this.http.get<EnrollInfo>(`${this.base}/info`);
  }
}

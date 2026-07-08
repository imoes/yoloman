import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';
import { SetYoloModeInput, SystemSettings } from '../models/system-settings.model';

/** REST client for Bossman-wide runtime toggles (Block L2) — currently
 * just the global YOLO-MAN switch. */
@Injectable({ providedIn: 'root' })
export class SystemSettingsService {
  private http = inject(HttpClient);
  private base = `${environment.apiUrl}/system`;

  getYoloMode() {
    return this.http.get<SystemSettings>(`${this.base}/yolo-mode`);
  }

  setYoloMode(body: SetYoloModeInput) {
    return this.http.put<SystemSettings>(`${this.base}/yolo-mode`, body);
  }
}

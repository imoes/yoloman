import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';
import { SetHelmProxyInput, SetNetbootInput, SetYoloModeInput, SystemSettings } from '../models/system-settings.model';

/** REST client for Bossman-wide runtime toggles (Block L2): the global
 * YOLO-MAN switch and the helm chart-pull proxy. The GET returns the whole
 * SystemSettings row, so a single fetch drives every toggle on the page. */
@Injectable({ providedIn: 'root' })
export class SystemSettingsService {
  private http = inject(HttpClient);
  private base = `${environment.apiUrl}/system`;

  /** Reads the full SystemSettings row (yolo_mode + helm proxy). */
  get() {
    return this.http.get<SystemSettings>(`${this.base}/yolo-mode`);
  }

  getYoloMode() {
    return this.get();
  }

  setYoloMode(body: SetYoloModeInput) {
    return this.http.put<SystemSettings>(`${this.base}/yolo-mode`, body);
  }

  setHelmProxy(body: SetHelmProxyInput) {
    return this.http.put<SystemSettings>(`${this.base}/helm-proxy`, body);
  }

  /** Enter/rotate the PXE netboot secret and turn netboot on/off. */
  setNetboot(body: SetNetbootInput) {
    return this.http.put<SystemSettings>(`${this.base}/netboot`, body);
  }
}

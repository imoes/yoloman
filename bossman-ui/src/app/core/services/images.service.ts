import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';

/** One volume of a captured template (from the manifest), with the LVM info the disk editor needs. */
export interface ImageVolume {
  role: string;            // esp | boot | root | var | home | data | swap | bios_boot
  fs_type: string;
  size_bytes: number;
  used_bytes: number | null;
  vg: string | null;
  lv: string | null;
  mountpoint: string | null;
}

export interface DiskImage {
  id: string;
  name: string;
  description: string;
  status: string;          // capturing | ready | failed
  error?: string | null;
  progress?: string;       // live capture/import progress, e.g. "Sichere root (2/4) · 63%"
  is_active: boolean;
  grow_policy: Record<string, number>;
  /** How grow_policy values are read: 'percent' (of the leftover) or 'absolute' (GiB, 0 = fill the rest). */
  grow_mode: 'percent' | 'absolute';
  disk_size: number;
  firmware: 'uefi' | 'bios' | 'unknown';   // which boot path the image expects, derived from its manifest
  volumes: ImageVolume[];
  stored_bytes: number;
  created_at: string;
}

export interface RestoreJob {
  id: string;
  image_id: string;
  target_mac: string;
  target_hostname: string;
  target_disk: string | null;
  status: string;          // pending | running | done | failed | cancelled
  step_index: number;
  log: string;
  error: string | null;
  agent_id: string | null;
}

/** A running lab VM inside the pxe container (from `docker exec … vm-control.sh list`). */
export interface Vm {
  name: string;
  display: number;
  vnc_port: number;
  ws_port: number;
  kind: string;            // install | pxe-test
  disk: string;
}

/** The final network a provisioned host boots onto (its destination segment, not the PXE one). */
export interface ProvisionNetwork {
  mode: 'dhcp' | 'static';
  interface?: string;
  address?: string;        // CIDR, e.g. 192.0.2.60/24
  gateway?: string;
  dns?: string[];
}

/**
 * The Disk-Templates / bare-metal provisioning surface: list captured templates, mark one active, set its
 * grow policy (root/var/home %), create a planned target host, arm a restore job, and watch jobs. The
 * backend lives in api/images.py; roles are assigned through the normal host Management tab.
 */
@Injectable({ providedIn: 'root' })
export class ImagesService {
  private http = inject(HttpClient);
  private base = environment.apiUrl;

  list() { return this.http.get<DiskImage[]>(`${this.base}/images`); }
  get(id: string) { return this.http.get<DiskImage>(`${this.base}/images/${id}`); }

  /** Mark active and/or set the grow policy (percentages must sum to 100). */
  patch(id: string, body: { is_active?: boolean; grow_policy?: Record<string, number>; grow_mode?: 'percent' | 'absolute' }) {
    return this.http.patch<DiskImage>(`${this.base}/images/${id}`, body);
  }

  jobs() { return this.http.get<RestoreJob[]>(`${this.base}/restore-jobs`); }
  cancelJob(id: string) { return this.http.post<RestoreJob>(`${this.base}/restore-jobs/${id}/cancel`, {}); }
  deleteJob(id: string) { return this.http.delete<void>(`${this.base}/restore-jobs/${id}`); }

  /** Create a bare-metal target as a 'planned' host (roles get assigned via the Management tab). */
  createPlannedHost(body: { hostname: string; mac?: string; network?: ProvisionNetwork }) {
    return this.http.post<{ id: string; hostname: string; enrollment_state: string }>(
      `${this.base}/provisioning/hosts`, body);
  }

  /** Arm the install: links the planned host (by hostname) to the template + the machine's MAC. */
  arm(body: { image_id: string; target_mac: string; target_hostname: string; target_disk?: string }) {
    return this.http.post<RestoreJob>(`${this.base}/restore-jobs`, body);
  }

  // ── PXE nested-virt lab (api/vm.py) ──────────────────────────────────────
  listVms() { return this.http.get<Vm[]>(`${this.base}/vm`); }
  /** Boot an installer ISO with a fresh disk (build a template); watch it over noVNC. */
  install(body: { name: string; iso: string; disk: string; disk_gib?: number }) {
    return this.http.post<string>(`${this.base}/vm/install`, body);
  }
  /** Diskless-boot a target that PXE-restores the active template end-to-end. */
  pxeTest(body: { name: string; mac: string; disk: string; disk_gib?: number }) {
    return this.http.post<string>(`${this.base}/vm/pxe-test`, body);
  }
  stopVm(name: string) { return this.http.post<string>(`${this.base}/vm/${name}/stop`, {}); }

  // ── Import an existing disk image (vmdk/qcow2/raw) staged in the lab as a template ───────────────
  importSources() { return this.http.get<string[]>(`${this.base}/images/import/sources`); }
  importImage(body: { name: string; source_file: string; description?: string }) {
    return this.http.post<DiskImage>(`${this.base}/images/import`, body);
  }
}

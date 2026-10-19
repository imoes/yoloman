import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable } from 'rxjs';
import { environment } from '../../../environments/environment';
import { ImageVolume } from './images.service';

/** The deploy wizard's API — the same implementation as the MCP tools vm_hosts / check_ip / suggest_free_ips /
 *  deploy_vm / deployment_status (bossman/api/provision_deploy.py → services/vm_provision.py). */

export interface PlacementNode {
  node: string;
  status?: string;
  storages: { name: string; type?: string; avail_bytes?: number; total_bytes?: number }[];
  bridges: { name: string; comment?: string }[];
}

export interface DeployCatalog {
  vm_hosts: { name: string; kind: string; host: string; placement?: { nodes: PlacementNode[] }; placement_error?: string }[];
  images: { id: string; name: string; status: string; description: string; volumes: ImageVolume[];
            grow_policy: Record<string, number>; grow_mode: 'percent' | 'absolute'; disk_size: number; firmware: string }[];
  installs: { install: string; title: string; family: string; default_packages: string[]; min_memory_mb: number; config: string }[];
  runbooks: { name: string; folder: string; description: string }[];
  roles: { name: string; display_name: string }[];
}

export interface ResolvedInstall {
  distro: string;
  release: string;
  label: string;
  family: string;
  default_packages: string[];
  missing_packages: string[];
  min_memory_mb: number;
}

export interface IpVerdict {
  address: string;
  verdict: 'free' | 'in_use' | 'unknown';
  reason: string;
  sources: Record<string, unknown>;
}

export interface PreflightCheck { check: string; ok: boolean; detail: string; }

export interface DeployResult {
  dry_run: boolean;
  would_deploy?: boolean;
  ok: boolean;
  checks: PreflightCheck[];
  hostname: string;
  vmid?: string;
  mac?: string;
  install?: { label?: string; status?: string; packages?: string[] } | null;
  finalize?: { runbook: string; apply: boolean; status?: string } | null;
  host_id?: string | null;
  roles?: { role: string; ok: boolean; status: string | null; error: string | null }[] | string[];
}

export interface DeploymentRow {
  hostname: string;
  kind: 'install' | 'image';
  os: string;
  status: string;
  error: string | null;
  address: string | null;
  mac: string;
  vmid: string | null;
  created_at: string;
  finished_at: string | null;
  last_seen_at: string | null;
  agent_version: string | null;
  finalize: { runbook: string; status: string; apply: boolean; error: string | null } | null;
}

export interface DeploymentStatus {
  hostname: string;
  install?: { status: string; label?: string | null; error?: string | null; armed_at: string; finished_at: string | null };
  restore?: { status: string; step: string; current: unknown; error: string | null; log_tail: string };
  host?: { enrollment_state: string; address: string | null; agent_version: string; last_seen_at: string | null };
  finalize?: { runbook: string; apply: boolean; status: string; error: string | null; result: unknown };
}

export interface DeployRequest {
  target: 'vm' | 'bare_metal'; mac?: string;
  vm_host: string; node: string; name: string; storage: string; bridge: string;
  address: string; gateway: string; dns: string[];
  image?: string | null; install?: string | null; vlan?: number | null; hostname?: string | null;
  cores: number; memory_mb: number; disk_gib: number;
  packages?: string[] | null;
  finalize_runbook?: string | null; finalize_variables?: Record<string, unknown>; finalize_apply?: boolean;
  roles?: string[]; grow_policy?: Record<string, number> | null; grow_mode?: 'percent' | 'absolute';
  production_vlan?: number | null;
  dry_run: boolean;
}

@Injectable({ providedIn: 'root' })
export class VmDeployService {
  private http = inject(HttpClient);
  private base = `${environment.apiUrl}/provisioning`;

  catalog(): Observable<DeployCatalog> { return this.http.get<DeployCatalog>(`${this.base}/catalog`); }
  resolveInstall(install: string): Observable<ResolvedInstall> {
    return this.http.get<ResolvedInstall>(`${this.base}/installs/${encodeURIComponent(install)}`);
  }
  checkIp(addresses: string[], prefixLen = 24): Observable<IpVerdict[]> {
    return this.http.post<IpVerdict[]>(`${this.base}/check-ip`, { addresses, prefix_len: prefixLen });
  }
  suggestIps(prefix: string, count = 5): Observable<{ free: IpVerdict[]; rejected: { address: string; reason: string }[]; candidates_from: string }> {
    return this.http.get<any>(`${this.base}/suggest-ips`, { params: { prefix, count } });
  }
  deploy(req: DeployRequest): Observable<DeployResult> { return this.http.post<DeployResult>(`${this.base}/deploy`, req); }
  deployments(): Observable<DeploymentRow[]> { return this.http.get<DeploymentRow[]>(`${this.base}/deployments`); }
  status(hostname: string): Observable<DeploymentStatus> {
    return this.http.get<DeploymentStatus>(`${this.base}/deployments/${encodeURIComponent(hostname)}`);
  }
}

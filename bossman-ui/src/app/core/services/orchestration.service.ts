import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';
import {
  CompiledHostState,
  OrchestrationPlan,
  OrchestrationPlanInput,
  OrchestrationPlanLink,
  OrchestrationPlanLinkInput,
  OrchestrationPlanVersionInput,
  PlanLinkPreview,
  PlanLinkPreviewInput,
} from '../models/orchestration.model';

/** REST client for orchestration plans, versions, links + the compiled
 * desired-state read (Blocks L1/L2) — mirrors MonitoringService's shape. */
@Injectable({ providedIn: 'root' })
export class OrchestrationService {
  private http = inject(HttpClient);
  private base = `${environment.apiUrl}/orchestration`;

  listPlans() {
    return this.http.get<OrchestrationPlan[]>(`${this.base}/plans`);
  }

  getPlan(id: string) {
    return this.http.get<OrchestrationPlan>(`${this.base}/plans/${id}`);
  }

  createPlan(body: OrchestrationPlanInput) {
    return this.http.post<OrchestrationPlan>(`${this.base}/plans`, body);
  }

  createPlanVersion(planId: string, body: OrchestrationPlanVersionInput) {
    return this.http.post<OrchestrationPlan>(`${this.base}/plans/${planId}/versions`, body);
  }

  deletePlan(id: string) {
    return this.http.delete<void>(`${this.base}/plans/${id}`);
  }

  listLinks(planId: string) {
    return this.http.get<OrchestrationPlanLink[]>(`${this.base}/plans/${planId}/links`);
  }

  pendingLinks() {
    return this.http.get<OrchestrationPlanLink[]>(`${this.base}/pending-links`);
  }

  previewLink(planId: string, body: PlanLinkPreviewInput) {
    return this.http.post<PlanLinkPreview>(`${this.base}/plans/${planId}/preview-link`, body);
  }

  createLink(planId: string, body: OrchestrationPlanLinkInput) {
    return this.http.post<OrchestrationPlanLink>(`${this.base}/plans/${planId}/links`, body);
  }

  approveLink(planId: string, linkId: string) {
    return this.http.post<OrchestrationPlanLink>(`${this.base}/plans/${planId}/links/${linkId}/approve`, {});
  }

  rejectLink(planId: string, linkId: string) {
    return this.http.post<OrchestrationPlanLink>(`${this.base}/plans/${planId}/links/${linkId}/reject`, {});
  }

  deleteLink(planId: string, linkId: string) {
    return this.http.delete<void>(`${this.base}/plans/${planId}/links/${linkId}`);
  }

  desiredState(agentId: string) {
    return this.http.get<CompiledHostState>(`${environment.apiUrl}/agents/${agentId}/desired-state`);
  }
}

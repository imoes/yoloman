import { Injectable, inject } from '@angular/core';
import { HttpClient, HttpHeaders, HttpParams } from '@angular/common/http';
import { environment } from '../../../environments/environment';
import {
  EventHandler,
  EventHandlerInput,
  HandlerAvailability,
  HandlerMeta,
} from '../models/event-handler.model';

/** REST client for event handlers (/api/v1/event-handlers) — the reusable action an event rule
 * performs. The trigger side lives in the remediation endpoints; this is only the action. */
@Injectable({ providedIn: 'root' })
export class EventHandlerService {
  private http = inject(HttpClient);
  private base = `${environment.apiUrl}/event-handlers`;

  /** The legal bodies/locations/interpreters and the handler directory, served so the form does
   * not repeat what the server validates. */
  meta() {
    return this.http.get<HandlerMeta>(`${this.base}/meta`);
  }

  list() {
    return this.http.get<EventHandler[]>(this.base);
  }

  create(body: EventHandlerInput) {
    return this.http.post<EventHandler>(this.base, body);
  }

  /** `version` travels as If-Match — without it the last writer wins unnoticed (api/etag.py). */
  update(id: string, body: EventHandlerInput, version: string) {
    const headers = version ? new HttpHeaders({ 'If-Match': version }) : undefined;
    return this.http.put<EventHandler>(`${this.base}/${id}`, body, headers ? { headers } : {});
  }

  /** Refused with a count while event rules still use the handler: deleting it would leave a
   * rule that fires and does nothing. */
  delete(id: string) {
    return this.http.delete<void>(`${this.base}/${id}`);
  }

  /** Is the file actually on the hosts? Only meaningful for a local handler — a managed script
   * is deployed by the run itself. Without this, "this handler will run" is a claim nobody has
   * tested until the event fires. */
  availability(id: string, agentIds: string[] = []) {
    let params = new HttpParams();
    for (const id2 of agentIds) params = params.append('agent_ids', id2);
    return this.http.get<HandlerAvailability>(`${this.base}/${id}/availability`, { params });
  }
}

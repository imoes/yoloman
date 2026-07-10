import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';
import { AuthService } from '../auth/auth.service';
import {
  ChatBackendsResponse,
  ChatEvent,
  ChatHistoryMessage,
  ChatPrefs,
  ChatSession,
  ClaudeStartResponse,
  CodexPollResponse,
  CodexStartResponse,
  OAuthStatusResponse,
} from '../models/chat.model';

/** Block K — chat console client. Session CRUD goes over HttpClient (auth via
 * the global interceptor); the streaming message endpoint uses fetch() +
 * ReadableStream because it POSTs a body AND must carry the bearer header —
 * an EventSource can do neither (and the HttpClient interceptor wouldn't apply
 * to an EventSource anyway). Frames are `data: {json}\n\n`, terminated by
 * `data: [DONE]\n\n`. */
@Injectable({ providedIn: 'root' })
export class ChatService {
  private http = inject(HttpClient);
  private auth = inject(AuthService);
  private base = `${environment.apiUrl}/chat`;

  backends() {
    return this.http.get<ChatBackendsResponse>(`${this.base}/backends`);
  }

  // ---- per-user prefs + OAuth login ----
  getPrefs() {
    return this.http.get<ChatPrefs>(`${this.base}/prefs`);
  }
  setPrefs(prefs: Partial<ChatPrefs>) {
    return this.http.patch<ChatPrefs>(`${this.base}/prefs`, prefs);
  }
  oauthStatus() {
    return this.http.get<OAuthStatusResponse>(`${this.base}/oauth/status`);
  }
  codexStart() {
    return this.http.post<CodexStartResponse>(`${this.base}/oauth/codex/start`, {});
  }
  codexPoll(sid: string) {
    return this.http.post<CodexPollResponse>(`${this.base}/oauth/codex/poll/${sid}`, {});
  }
  claudeStart() {
    return this.http.post<ClaudeStartResponse>(`${this.base}/oauth/claude/start`, {});
  }
  claudeComplete(sid: string, code: string) {
    return this.http.post<{ status: string }>(`${this.base}/oauth/claude/complete`, { session_id: sid, code });
  }

  listSessions() {
    return this.http.get<{ sessions: ChatSession[] }>(`${this.base}/sessions`);
  }

  createSession(backend?: string, label?: string) {
    return this.http.post<ChatSession>(`${this.base}/sessions`, { backend, label });
  }

  history(sid: string) {
    return this.http.get<{ messages: ChatHistoryMessage[] }>(`${this.base}/sessions/${sid}/history`);
  }

  rename(sid: string, label: string) {
    return this.http.patch<ChatSession>(`${this.base}/sessions/${sid}`, { label });
  }

  deleteSession(sid: string) {
    return this.http.delete<void>(`${this.base}/sessions/${sid}`);
  }

  /** Stream a message. Calls onEvent for each parsed SSE event until the
   * server sends [DONE] or the AbortSignal fires. Returns when the stream
   * ends. Throws on a transport/HTTP error. */
  async streamMessage(
    sid: string,
    content: string,
    onEvent: (ev: ChatEvent) => void,
    opts: { backend?: string; signal?: AbortSignal } = {},
  ): Promise<void> {
    const token = this.auth.getToken();
    const resp = await fetch(`${environment.apiUrl}/chat/sessions/${sid}/message`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: JSON.stringify({ content, backend: opts.backend }),
      signal: opts.signal,
    });
    if (!resp.ok || !resp.body) {
      const detail = await resp.text().catch(() => '');
      throw new Error(`chat stream failed (${resp.status}): ${detail.slice(0, 500)}`);
    }
    const reader = resp.body.getReader();
    const dec = new TextDecoder();
    let buf = '';
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      const parts = buf.split('\n\n');
      buf = parts.pop() ?? '';
      for (const part of parts) {
        const line = part.trim();
        if (!line.startsWith('data:')) continue;
        const payload = line.slice(5).trim();
        if (payload === '[DONE]') return;
        try {
          onEvent(JSON.parse(payload) as ChatEvent);
        } catch {
          /* ignore a malformed frame */
        }
      }
    }
  }
}

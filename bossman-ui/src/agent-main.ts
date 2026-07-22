import { bootstrapApplication } from '@angular/platform-browser';
import { provideZoneChangeDetection } from '@angular/core';
import { provideHttpClient, withInterceptors } from '@angular/common/http';
import { provideAnimationsAsync } from '@angular/platform-browser/animations/async';
import { provideEchartsCore } from 'ngx-echarts';

import { StandaloneShellComponent } from './app/standalone/standalone-shell.component';
import { agentInterceptor } from './app/standalone/agent-auth';

// Second entry point of the bossman-ui workspace: the standalone-agent console.
// It reuses the fleet host components (Management, …) but talks to the agent's
// own single-host API via agentInterceptor. No router — a single shell.
bootstrapApplication(StandaloneShellComponent, {
  providers: [
    provideZoneChangeDetection({ eventCoalescing: true }),
    provideHttpClient(withInterceptors([agentInterceptor])),
    provideAnimationsAsync(),
    provideEchartsCore({ echarts: () => import('echarts') }),
  ],
}).catch((err) => console.error(err));

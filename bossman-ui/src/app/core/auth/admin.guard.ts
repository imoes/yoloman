import { inject } from '@angular/core';
import { CanActivateFn, Router } from '@angular/router';
import { AuthService } from './auth.service';

/** Block M — gate an admin-only route (e.g. Users & Access). The JWT role
 * claim is used for display/navigation gating only; the backend re-enforces
 * require_admin on every request, so this is never the sole line of defence. */
export const adminGuard: CanActivateFn = () => {
  const auth = inject(AuthService);
  const router = inject(Router);

  if (auth.isLoggedIn() && auth.role() === 'admin') return true;

  return router.createUrlTree([auth.isLoggedIn() ? '/fleet' : '/login']);
};

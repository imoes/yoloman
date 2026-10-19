// Who the suite is, and where the API is. Every value can be overridden from the environment; the defaults match
// the local dev stack (docker compose project agentic-mcp).
export const API_URL = process.env['BOSSMAN_API_URL'] ?? 'http://localhost:8123';
export const BOOTSTRAP = {
  username: process.env['BOSSMAN_ADMIN_USER'] ?? 'admin',
  password: process.env['BOSSMAN_ADMIN_PASSWORD'] ?? 'admin123',
};

/** The three accounts the suite creates: two admins (four-eyes approval needs a SECOND admin) and an operator. */
export const USERS = {
  admin: { username: 'ui-e2e-admin', password: 'sup3rSecret!e2e', role: 'admin' },
  admin2: { username: 'ui-e2e-admin2', password: 'sup3rSecret!e2e', role: 'admin' },
  operator: { username: 'ui-e2e-operator', password: 'sup3rSecret!e2e', role: 'operator' },
} as const;
export type UserKey = keyof typeof USERS;

export const authFile = (u: UserKey) => `e2e/.auth/${u}.json`;

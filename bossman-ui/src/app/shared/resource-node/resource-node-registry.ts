/**
 * Node-descriptor registry (docs/resource-protocol.md) — the extensibility seam
 * for the "one canvas". Each Resource `kind` registers how it presents as a node
 * (label + icon); the canvas is generic and looks the descriptor up. Adding a
 * tier = a Resource impl (backend) + one entry here. The four verbs (schema/
 * observe/plan/apply/rollback) are already uniform, so nothing else changes.
 */
export interface ResourceNodeDescriptor {
  kind: string;      // resource kind on the API (docker | helm | …)
  label: string;     // human label for the node header
  icon: string;      // Material symbol
}

export const RESOURCE_NODES: Record<string, ResourceNodeDescriptor> = {
  docker: { kind: 'docker', label: 'Docker container', icon: 'inventory_2' },
  helm: { kind: 'helm', label: 'Helm release', icon: 'hub' },
  // config delegates its generations to the agent state store (host-scoped).
  config: { kind: 'config', label: 'Config file', icon: 'description' },
  // role = an OrchestrationPlan bound to this host; verbs are the BINDING
  // (bind/unbind), generations are the applied parameter sets.
  role: { kind: 'role', label: 'Role binding', icon: 'assignment_ind' },
  // template folds in as its Resource impl lands.
};

export function descriptorFor(kind: string): ResourceNodeDescriptor {
  return RESOURCE_NODES[kind] ?? { kind, label: kind, icon: 'widgets' };
}

/** Map a System member's target tier → the Resource node kind. */
export function kindForTarget(target: string): string | null {
  if (target === 'docker') return 'docker';
  if (target === 'k8s') return 'helm';
  return null;   // native / unknown: no live Resource node yet
}

// awx-ng: derives the Blockly workspace sidecar path from a playbook path.
// playbooks/site.yml -> playbooks/site.blockly.json
export function sidecarPathFor(path) {
  return path.replace(/\.[^./]+$/, '.blockly.json');
}

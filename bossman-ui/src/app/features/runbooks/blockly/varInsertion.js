// awx-ng: inserts a `{{ variable }}` Jinja reference into a Blockly field's
// current text value — the actual mutation behind dragging a variable from
// the VariablesPanel onto a text field on the canvas.
export function insertVariableReference(field, varName) {
  const current = field.getValue() || '';
  field.setValue(`${current}{{ ${varName} }}`);
}

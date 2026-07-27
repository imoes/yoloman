// awx-ng: builds the Blockly toolbox (palette) for the playbook builder.
//
// Live search runs across ALL categories (modules, roles, conditions, task
// settings, …) via the official @blockly/toolbox-search plugin's `kind:
// 'search'` category — reverted from an earlier category-scoped custom
// callback (which only searched whichever single category was open) per
// user request ("die live suche soll wieder über alle kategorien laufen").
// Importing the plugin registers the `kind: 'search'` toolbox item globally.
import '@blockly/toolbox-search';
import moduleCatalog from './moduleCatalog.generated.json';
import {
  moduleBlockType,
  CONDITION_BLOCK_TYPES,
  TASK_SETTING_BLOCK_TYPES,
  DATA_BLOCK_TYPES,
} from './blocks';

const SORTED_MODULES = [...moduleCatalog].sort((a, b) =>
  a.short_name.localeCompare(b.short_name)
);

function moduleCategory() {
  return {
    kind: 'category',
    name: 'Modules',
    colour: '210',
    contents: SORTED_MODULES.map((mod) => ({ kind: 'block', type: moduleBlockType(mod.short_name) })),
  };
}

// Roles are per-project (unlike the static ansible.builtin catalog), so the
// caller passes the current project's role names; each becomes a `role_use`
// flyout entry pre-filled with that role's name. Since this category's
// contents are static (needed for the search plugin to index them), the
// whole toolbox must be rebuilt via `workspace.updateToolbox(buildToolbox(names))`
// whenever the role list changes — see PlaybookBuilder.js's loadRoles.
function rolesCategory(roleNames) {
  return {
    kind: 'category',
    name: 'Roles',
    colour: '290',
    contents: roleNames.length
      ? [...roleNames].sort().map((name) => ({
          kind: 'block',
          type: 'role_use',
          fields: { ROLE_NAME: name },
        }))
      : [{ kind: 'block', type: 'role_use' }],
  };
}

export function buildToolbox(roleNames = []) {
  return {
    kind: 'categoryToolbox',
    contents: [
      // Live search across every catalogued block (modules, roles,
      // conditions, task settings, …) — rendered by the plugin itself.
      { kind: 'search', name: '🔍 Search', contents: [] },
      {
        kind: 'category',
        name: 'Play',
        colour: '120',
        contents: [{ kind: 'block', type: 'play' }, { kind: 'block', type: 'define_var' }],
      },
      moduleCategory(),
      rolesCategory(roleNames),
      {
        kind: 'category',
        name: 'Conditions',
        colour: '210',
        contents: CONDITION_BLOCK_TYPES.map((type) => ({ kind: 'block', type })),
      },
      {
        kind: 'category',
        name: 'Task Settings',
        colour: '230',
        contents: TASK_SETTING_BLOCK_TYPES.map((type) => ({ kind: 'block', type })),
      },
      {
        kind: 'category',
        name: 'Data',
        colour: '160',
        contents: DATA_BLOCK_TYPES.map((type) => ({ kind: 'block', type })),
      },
      {
        kind: 'category',
        name: 'Raw / Fallback',
        colour: '0',
        contents: [{ kind: 'block', type: 'raw_task' }],
      },
    ],
  };
}

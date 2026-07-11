import { Observable } from 'rxjs';

/** A declarative dialog framework mirroring Cockpit's storaged `dialog_open`
 * (../cockpit/pkg/storaged/dialog.jsx): a dialog is a Title + an array of
 * field descriptors + an Action. Fields carry dynamic visibility/validation
 * and the values map is rebuilt live as the user types, so options and
 * enabled/disabled state can react. This is the single reusable building
 * block the Cockpit-style Network and Storage config screens sit on. */

export type FieldValues = Record<string, unknown>;

export type FieldType =
  | 'text'
  | 'password'
  | 'select'
  | 'radio'
  | 'checkboxes'
  | 'checkboxWithInput'
  | 'sizeSlider'
  | 'selectSpaces'
  | 'stringList'
  | 'message';

export interface Choice {
  value: string;
  title: string;
  disabled?: boolean;
  /** Optional longer explanation shown under a radio choice (Cockpit's LV layout pattern). */
  explanation?: string;
}

/** One selectable "space" (a disk / free region / PV) for selectSpaces. */
export interface Space {
  value: string;
  title: string;
  /** Size in bytes, rendered next to the title. */
  size?: number;
  disabled?: boolean;
}

export interface CheckboxItem {
  tag: string;
  title: string;
  tooltip?: string;
}

export interface ConfigField {
  tag: string;
  title?: string;
  type: FieldType;
  initial?: unknown;
  /** Placeholder / helper text for text & password. */
  placeholder?: string;
  help?: string;

  // select / radio
  choices?: Choice[];

  // checkboxes
  items?: CheckboxItem[];

  // checkboxWithInput
  checkboxLabel?: string;
  inputPlaceholder?: string;

  // selectSpaces
  spaces?: Space[];
  minSelected?: number;
  emptyWarning?: string;

  // sizeSlider (values are bytes)
  min?: number;
  max?: number;
  round?: number;
  allowInfinite?: boolean;

  // message (static text, no value)
  text?: string;

  /** Hide the field unless this returns true (evaluated against the live values). */
  visible?: (values: FieldValues) => boolean;
  /** Return an error string to block submit, or null when valid. */
  validate?: (value: unknown, values: FieldValues) => string | null;
}

export interface DialogVariant {
  /** Footer button label, e.g. "Format and mount". */
  title: string;
  /** Identifier passed to action() so it knows which button was pressed. */
  variant: string;
  primary?: boolean;
}

export interface ConfigDialogDef {
  title: string;
  /** Optional descriptive text rendered above the form. */
  body?: string;
  fields: ConfigField[];
  /** Red danger helper text (destructive dialogs). */
  danger?: string;
  /** Style the primary button red. */
  dangerButton?: boolean;
  /** Extra footer buttons; when present they replace the single OK button. */
  variants?: DialogVariant[];
  /** Label for the single primary button when there are no variants. Default "Apply". */
  submitLabel?: string;
  /** Runs on submit. Return/throw a string for a global error, or an object
   * {tag: message} to attach errors to fields. Resolving closes the dialog. */
  action: (values: FieldValues, variant?: string) => Observable<unknown> | Promise<unknown>;
  /** Live reconfiguration when any field changes — return patched field
   * overrides keyed by tag (e.g. a new sizeSlider max). Optional. */
  update?: (values: FieldValues, trigger: string) => Record<string, Partial<ConfigField>> | void;
}

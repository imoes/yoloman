import { AfterViewInit, Component, ElementRef, OnDestroy, ViewChild, effect, input } from '@angular/core';
import * as monaco from 'monaco-editor';
import { APP_IS_DARK } from '../bm-colors';

(self as unknown as { MonacoEnvironment: unknown }).MonacoEnvironment = {
  getWorker() {
    return new Worker(URL.createObjectURL(new Blob(['self.onmessage=function(){}'], { type: 'text/javascript' })));
  },
};

/**
 * Two versions of one artefact side by side — the ONE diff view of the app (a Monaco diff editor, read-only).
 * The plan library compares stored-plan versions with it; role deployments compare role-artifact versions.
 * A second diff widget would be a second way to read the same kind of change.
 *
 * `original` is the older text (left), `modified` the newer (right); the labels say which version is which,
 * because a diff whose sides are unnamed answers "what changed" without "from what to what".
 */
@Component({
  selector: 'app-version-diff',
  standalone: true,
  template: `
    @if (originalLabel() || modifiedLabel()) {
      <div class="bm-vd-labels"><span>{{ originalLabel() }}</span><span>{{ modifiedLabel() }}</span></div>
    }
    <div #host class="bm-vd" [style.height]="height()"></div>
  `,
  styles: [`
    :host { display: flex; flex-direction: column; flex: 1; min-height: 0; }
    .bm-vd-labels { display: grid; grid-template-columns: 1fr 1fr; font-size: 12px; opacity: .7; padding: 4px 8px; }
    .bm-vd { flex: 1; min-height: 300px; }
  `],
})
export class VersionDiffComponent implements AfterViewInit, OnDestroy {
  original = input.required<string>();
  modified = input.required<string>();
  language = input<string>('json');
  originalLabel = input<string>('');
  modifiedLabel = input<string>('');
  height = input<string>('100%');
  @ViewChild('host') hostEl!: ElementRef<HTMLDivElement>;
  private ed?: monaco.editor.IStandaloneDiffEditor;
  private models: monaco.editor.ITextModel[] = [];

  constructor() {
    effect(() => {
      const [o, m, lang] = [this.original(), this.modified(), this.language()];
      if (this.ed) this.show(o, m, lang);
    });
  }

  ngAfterViewInit(): void {
    this.ed = monaco.editor.createDiffEditor(this.hostEl.nativeElement, {
      readOnly: true, automaticLayout: true, fontSize: 12, renderSideBySide: true,
      theme: APP_IS_DARK ? 'vs-dark' : 'vs',
    });
    this.show(this.original(), this.modified(), this.language());
  }

  private show(original: string, modified: string, language: string): void {
    const next = [monaco.editor.createModel(original, language), monaco.editor.createModel(modified, language)];
    this.ed!.setModel({ original: next[0], modified: next[1] });
    this.models.forEach((m) => m.dispose());
    this.models = next;
    setTimeout(() => this.ed?.layout(), 0);
  }

  ngOnDestroy(): void {
    this.ed?.dispose();
    this.models.forEach((m) => m.dispose());
  }
}

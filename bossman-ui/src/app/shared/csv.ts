/**
 * One place for turning a table into a CSV file and handing it to the browser (CLAUDE.md parsimony: a second copy of
 * this in another component would be two ways to the same result). RFC 4180 quoting — a field that contains a comma,
 * quote or newline is wrapped in quotes and its quotes doubled; rows joined with CRLF so Excel reads them cleanly.
 */

export type CsvCell = string | number | boolean | null | undefined;

/** Serialise headers + rows to a CSV string. */
export function toCsv(headers: string[], rows: CsvCell[][]): string {
  const esc = (v: CsvCell): string => {
    const s = v == null ? '' : String(v);
    return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  return [headers, ...rows].map((r) => r.map(esc).join(',')).join('\r\n');
}

/** Offer `text` to the browser as a download named `filename` (defaults to a text/csv blob). */
export function downloadText(filename: string, text: string, mime = 'text/csv;charset=utf-8'): void {
  const blob = new Blob([text], { type: mime });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}

/** Build the CSV and download it in one call. */
export function downloadCsv(filename: string, headers: string[], rows: CsvCell[][]): void {
  downloadText(filename, toCsv(headers, rows));
}

/** A filesystem-safe slug for a filename fragment. */
export function csvSlug(value: string, max = 40): string {
  return (value || 'all').replace(/[^a-z0-9]+/gi, '-').replace(/^-+|-+$/g, '').slice(0, max) || 'all';
}

import { test, expect } from '@playwright/test';
import { api } from './support/routes';

// Library → Roles (/plan-library) → a runnable plan's "Run…" → the read-before-run page (/plans/:name) →
// Run → host + parameters → server dry run on e2e-deb-1. The suite does NOT apply: the only catalogue plan on
// this instance (img_docker) installs Docker CE, which is not harmless on a shared test host.

test('a library plan is read, then previewed as a dry run on a real host', async ({ page }) => {
  test.setTimeout(180_000);
  const ctx = await api();
  const plans = await (await ctx.get('/api/v1/plans')).json();
  const catalogue: any[] = Array.isArray(plans) ? plans : plans.plans ?? [];
  test.skip(!catalogue.length, 'no runnable plan in the catalogue');
  const name: string = (catalogue.find((p) => p.name === 'img_docker') ?? catalogue[0]).name;

  await page.goto('/plan-library');
  const tree = page.getByRole('complementary');
  await expect(tree.getByText('Roles', { exact: true })).toBeVisible();
  await tree.locator('li.bm-plan', { hasText: name }).first().click();
  await expect(page.locator('.bm-pl-name')).toContainText(name);

  await page.getByRole('link', { name: 'Run…' }).click();
  await expect(page).toHaveURL(new RegExp(`/plans/${name}$`));
  await expect(page.getByRole('heading', { name, level: 1 })).toBeVisible();
  // The read-before-run page: parameters with defaults, steps in order with their modules.
  await expect(page.getByText('Parameters')).toBeVisible();
  await expect(page.locator('.bm-step-list li').first()).toBeVisible();

  await page.getByRole('button', { name: 'Run', exact: true }).click();
  const dialog = page.getByRole('dialog');
  await expect(dialog.getByRole('heading', { name: `Run ${name}` })).toBeVisible();

  // Without a host the preview cannot run.
  const preview = dialog.getByRole('button', { name: 'Preview (dry run)' });
  await expect(preview).toBeDisabled();

  await dialog.getByLabel('Host').click();
  await page.getByRole('option', { name: 'e2e-deb-1', exact: true }).click();
  await expect(preview).toBeEnabled();
  await preview.click();

  await expect(dialog.getByRole('heading', { name: 'Preview result (dry run)' })).toBeVisible({ timeout: 150_000 });
  const steps = dialog.locator('.bm-step-list li');
  expect(await steps.count()).toBeGreaterThan(1);
  await expect(dialog.getByRole('button', { name: 'Apply for real' })).toBeVisible();
  // Leave without applying.
  await dialog.getByRole('button', { name: 'Back' }).click();
  await dialog.getByRole('button', { name: 'Cancel' }).click();
  await expect(dialog).toHaveCount(0);
});

test('the disabled dry-run button says why it is disabled', async ({ page }) => {
  // Regression (fixed): "Preview (dry run)" was [disabled] until a host is picked without saying why (rule 4,
  // "zu jeder Verweigerung der Grund"); it now names the reason (bm-why title).
  const ctx = await api();
  const plans = await (await ctx.get('/api/v1/plans')).json();
  const catalogue: any[] = Array.isArray(plans) ? plans : plans.plans ?? [];
  test.skip(!catalogue.length, 'no runnable plan in the catalogue');
  await page.goto(`/plans/${catalogue[0].name}`);
  await page.getByRole('button', { name: 'Run', exact: true }).click();
  const btn = page.getByRole('dialog').getByRole('button', { name: 'Preview (dry run)' });
  await expect(btn).toBeDisabled();
  const reason = await btn.evaluate((el) => {
    for (let cur: HTMLElement | null = el as HTMLElement, i = 0; cur && i < 3; cur = cur.parentElement, i++) {
      const t = cur.getAttribute('title') || cur.getAttribute('aria-describedby') || cur.getAttribute('data-reason');
      if (t) return t;
    }
    return '';
  });
  expect(reason, 'a disabled button names its reason').not.toBe('');
});

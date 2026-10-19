import { test, expect } from '@playwright/test';

/**
 * The CHANGELOG is reachable from the web UI, not only the README (CLAUDE.md: link it from both). The Help page has a
 * "Changelog" tab that renders CHANGELOG.md (served by GET /api/v1/help/changelog).
 */
test('Help page has a Changelog tab that renders the changelog', async ({ page }) => {
  await page.goto('/help');
  await expect(page.getByRole('heading', { name: 'Help' })).toBeVisible({ timeout: 30_000 });

  await page.getByRole('tab', { name: 'Changelog' }).click();
  const article = page.locator('article.bm-md');
  await expect(article).toBeVisible({ timeout: 30_000 });
  // The changelog's own top heading and a real, recent entry.
  await expect(article.getByRole('heading', { name: 'Changelog', exact: true })).toBeVisible();
  await expect(article).toContainText('recent_incidents');
});

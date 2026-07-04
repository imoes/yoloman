import { test, expect } from '@playwright/test';
import { login } from './helpers';

test('running a real plan against a real host end to end', async ({ page }) => {
  await login(page);

  await page.getByRole('link', { name: 'Plans' }).click();
  await expect(page).toHaveURL(/\/plans$/);
  await expect(page.getByText('ui_demo_plan')).toBeVisible();

  await page.getByRole('button', { name: 'View' }).click();
  await expect(page).toHaveURL(/\/plans\/ui_demo_plan/);
  await expect(page.getByRole('heading', { name: 'ui_demo_plan' })).toBeVisible();

  await page.getByRole('button', { name: 'Run' }).click();
  await expect(page.getByRole('heading', { name: 'Run ui_demo_plan' })).toBeVisible();

  await page.getByLabel('Host').click();
  await page.getByRole('option', { name: 'duppy-ui-e2e' }).click();

  const messageField = page.getByLabel('message', { exact: false });
  await expect(messageField).toHaveValue('hello from bossman-ui');
  await messageField.fill('hello from playwright e2e');

  const dialog = page.getByRole('dialog');
  await page.getByRole('button', { name: 'Preview (dry run)' }).click();
  await expect(dialog.getByText('Preview result (dry run)')).toBeVisible();
  await expect(dialog.getByText('write_message')).toBeVisible();

  await page.getByRole('button', { name: 'Apply for real' }).click();
  await expect(dialog.getByText('Applied')).toBeVisible();

  await page.getByRole('button', { name: 'View run' }).click();
  await expect(page).toHaveURL(/\/runs\//);
  // Scope to the run-detail component: the dialog can still be mid-close
  // in the DOM (Material's exit animation), so an unscoped query can
  // transiently match the same badge text twice.
  const runDetail = page.locator('app-run-detail');
  await expect(runDetail.getByRole('heading', { name: 'ui_demo_plan' })).toBeVisible();
  await expect(runDetail.getByText('succeeded')).toBeVisible();
  await expect(runDetail.locator('.bm-step-list').getByText('write_message')).toBeVisible();
});

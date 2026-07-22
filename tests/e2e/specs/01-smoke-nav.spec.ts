import { test, expect } from "@playwright/test";
import { firstDocHref, getNav, openLibrary } from "../helpers/app";

/**
 * Read-only surface: library, stream, audit, review, nav API.
 * Asserts real product links exist — not just 200 with empty body.
 */
test.describe("smoke navigation (no mutations)", () => {
  test("library has case, docs, stream + audit links", async ({ page }) => {
    const caseId = await openLibrary(page);

    await expect(page.locator("table tbody tr").first()).toBeVisible();
    await expect(
      page.locator(`a[href="/cases/${caseId}/stream"]`)
    ).toBeVisible();
    await expect(
      page.locator(`a[href="/cases/${caseId}/audit"]`)
    ).toBeVisible();
    await expect(page.locator("#export-btn")).toBeVisible();
    await expect(page.locator("#btn-accept-high-case")).toBeVisible();
  });

  test("entity stream lists decide-once controls", async ({ page }) => {
    const caseId = await openLibrary(page);
    await page.goto(`/cases/${caseId}/stream`);
    await expect(page.getByText("Entity stream")).toBeVisible();
    // At least one entity card with accept/reject (corpus has entities)
    const accept = page.locator("[data-entity-decision='accepted']").first();
    await expect(accept).toBeVisible();
    await expect(
      page.locator("[data-entity-decision='rejected']").first()
    ).toBeVisible();
  });

  test("review page has marks or queue from real document", async ({
    page,
  }) => {
    await openLibrary(page);
    const href = await firstDocHref(page);
    await page.goto(href);
    await expect(page.locator("body[data-doc-id]")).toBeVisible();
    await expect(page.locator(".pdf-page img")).toBeVisible();
    // Corpus has AI suggestions — rail or marks present
    const pending = page.locator(".sugg[data-status='pending'], .mark[data-status='pending']");
    await expect(pending.first()).toBeVisible();
  });

  test("nav API is documents + shell paths for the case", async ({
    page,
    request,
  }) => {
    const caseId = await openLibrary(page);
    const rows = (await getNav(request, caseId)) as Array<{
      href: string;
      text: string;
    }>;
    expect(rows.length).toBeGreaterThan(0);
    const hrefs = rows.map((r) => r.href);
    expect(hrefs.some((h) => h.startsWith("/documents/"))).toBeTruthy();
    expect(hrefs).toContain(`/cases/${caseId}/stream`);
    expect(hrefs).toContain(`/cases/${caseId}/audit`);
    expect(hrefs).toContain(`/cases/${caseId}`);
  });

  test("audit page loads for case", async ({ page }) => {
    const caseId = await openLibrary(page);
    await page.goto(`/cases/${caseId}/audit`);
    await expect(page.locator("table")).toBeVisible();
  });
});

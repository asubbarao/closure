import { test, expect } from "@playwright/test";
import {
  firstDocHref,
  openLibrary,
  postDecision,
  suggestionsViaApi,
} from "../helpers/app";

/**
 * Serial FOIA loop against thin SSR + POST + reload.
 * Asserts state change (API fold + UI), not just "click did not throw".
 */
test.describe.configure({ mode: "serial" });

test.describe("FOIA loop (mutate + verify)", () => {
  let caseId: string;
  let suggestionId: string;
  let documentId: string;

  test("pick a pending non-flagged suggestion via API", async ({
    page,
    request,
  }) => {
    caseId = await openLibrary(page);
    const rows = await suggestionsViaApi(request);
    const pending = rows.find(
      (r) => r.status === "pending" && r.band !== "flagged"
    );
    expect(
      pending,
      "fresh DB should have pending non-flagged suggestions"
    ).toBeTruthy();
    suggestionId = pending!.id;
    documentId = pending!.document_id;
  });

  test("accept suggestion → fold to accepted (API + review UI)", async ({
    page,
    request,
  }) => {
    await postDecision(
      request,
      `/api/suggestions/${encodeURIComponent(suggestionId)}/decision?status=accepted&actor=e2e`
    );

    const rows = await suggestionsViaApi(request);
    const row = rows.find((r) => r.id === suggestionId);
    expect(row?.status).toBe("accepted");

    await page.goto(`/documents/${documentId}`);
    // Accepted row should not show A/R pending buttons for that id
    await expect(
      page.locator(
        `.sugg[data-id="${suggestionId}"][data-status="pending"]`
      )
    ).toHaveCount(0);
  });

  test("undo restores prior status for that batch", async ({
    page,
    request,
  }) => {
    await postDecision(
      request,
      `/api/undo?case_id=${encodeURIComponent(caseId)}&actor=e2e`
    );

    const rows = await suggestionsViaApi(request);
    const row = rows.find((r) => r.id === suggestionId);
    expect(row?.status).toBe("pending");

    await page.goto(`/cases/${caseId}/audit`);
    // Audit should mention undo or the decision trail (not empty forever after mutate)
    await expect(page.locator("table tbody tr").first()).toBeVisible();
  });

  test("entity reject excludes flagged path and writes decisions", async ({
    page,
    request,
  }) => {
    await openLibrary(page);
    await page.goto(`/cases/${caseId}/stream`);

    const rejectBtn = page
      .locator("[data-entity-decision='rejected']")
      .first();
    await expect(rejectBtn).toBeVisible();
    const entityId = await rejectBtn.getAttribute("data-entity-id");
    expect(entityId).toBeTruthy();

    await rejectBtn.click();
    // app.js mutate → location.reload
    await page.waitForLoadState("domcontentloaded");
    await expect(page.locator("body[data-case-id]")).toBeVisible();

    const rows = await suggestionsViaApi(request);
    const entityRows = rows.filter(
      (r) => r.entity_id === entityId && r.band !== "flagged"
    );
    // All non-flagged for that entity should no longer be pending
    const stillPending = entityRows.filter((r) => r.status === "pending");
    expect(
      stillPending.length,
      "entity reject should clear pending non-flagged for entity"
    ).toBe(0);
  });

  test("export button reflects blocked vs open", async ({ page }) => {
    await page.goto(`/cases/${caseId}`);
    const exportBtn = page.locator("#export-btn");
    await expect(exportBtn).toBeVisible();
    // When flagged remain, button is disabled — corpus often has flagged
    const disabled = await exportBtn.isDisabled();
    if (disabled) {
      await expect(exportBtn).toHaveAttribute("title", /flagged/i);
    } else {
      // Unblocked: click should POST export (reload); do not require files on disk
      await Promise.all([
        page.waitForLoadState("networkidle"),
        exportBtn.click(),
      ]);
      await expect(page.locator("body[data-case-id]")).toBeVisible();
    }
  });

  test("library still opens first document after mutations", async ({
    page,
  }) => {
    await openLibrary(page);
    const href = await firstDocHref(page);
    await page.goto(href);
    await expect(page.locator("body[data-doc-id]")).toBeVisible();
    await expect(page.locator(".pdf-page")).toBeVisible();
  });
});

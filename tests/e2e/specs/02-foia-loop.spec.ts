import { test, expect } from "@playwright/test";
import {
  api,
  entityWithPendingWork,
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
    const rows = await suggestionsViaApi(request, caseId);
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
    await postDecision(request, api.decide(suggestionId, "accepted"));

    const rows = await suggestionsViaApi(request, caseId);
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
    await postDecision(request, api.undo(caseId));

    const rows = await suggestionsViaApi(request, caseId);
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
    // Grain pick — UI order is kind/text, not "has bulk work".
    const entityId = await entityWithPendingWork(request, caseId);
    expect(entityId, "need entity with pending non-flagged work").toBeTruthy();

    await postDecision(request, api.entity(entityId!, "rejected"));

    await page.goto(`/cases/${caseId}/stream`);
    await expect(
      page.locator(`#e-${entityId}`)
    ).toBeVisible();

    const rows = await suggestionsViaApi(request, caseId);
    const entityRows = rows.filter(
      (r) => r.entity_id === entityId && r.band !== "flagged"
    );
    expect(
      entityRows.length,
      "entity should have non-flagged suggestions to fold"
    ).toBeGreaterThan(0);
    // Product: entity bulk skips band=flagged; non-flagged must not stay pending
    const stillPending = entityRows.filter((r) => r.status === "pending");
    expect(
      stillPending.length,
      "entity reject should clear pending non-flagged for entity"
    ).toBe(0);
  });

  test("export button reflects blocked vs open", async ({ page }) => {
    await page.goto(`/cases/${caseId}`);
    const exportBtn = page.locator("[data-action='export']");
    await expect(exportBtn).toBeVisible();
    const disabled = await exportBtn.isDisabled();
    if (disabled) {
      await expect(exportBtn).toHaveAttribute("title", /flagged/i);
    } else {
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

import { test, expect } from "@playwright/test";
import {
  api,
  caseDocIds,
  docHrefs,
  documentsViaApi,
  nPending,
  openLibrary,
  postDecision,
  suggestionsViaApi,
} from "../helpers/app";

/**
 * Hard proof: multi-doc + bulks + keyboard. Count deltas only — not greenwash.
 */
test.describe.configure({ mode: "serial" });

test.describe("bulk · multi-doc · keyboard", () => {
  let caseId: string;
  let docSet: Set<string>;

  test("multi-doc case (≥2)", async ({ page, request }) => {
    caseId = await openLibrary(page);
    const docs = await documentsViaApi(request);
    docSet = caseDocIds(docs, caseId);
    expect(docSet.size, "need ≥2 docs on open case").toBeGreaterThanOrEqual(2);
    expect((await docHrefs(page)).length).toBeGreaterThanOrEqual(2);
  });

  test("accept-HIGH case-wide: high→0, flagged unchanged", async ({
    request,
  }) => {
    const before = await suggestionsViaApi(request, caseId);
    const inCase = (r: { document_id: string }) => docSet.has(r.document_id);
    const high0 = nPending(before, (r) => inCase(r) && r.band === "high");
    const flag0 = nPending(before, (r) => inCase(r) && r.band === "flagged");
    expect(high0, "need pending HIGH").toBeGreaterThan(0);

    await postDecision(request, api.acceptHigh(caseId));
    const after = await suggestionsViaApi(request, caseId);
    expect(nPending(after, (r) => inCase(r) && r.band === "high")).toBe(0);
    expect(nPending(after, (r) => inCase(r) && r.band === "flagged")).toBe(flag0);
  });

  test("band bulk REVIEW reject on one doc", async ({ request }) => {
    const before = await suggestionsViaApi(request, caseId);
    const docId = [...docSet].find((id) =>
      before.some(
        (r) =>
          r.document_id === id && r.status === "pending" && r.band === "review"
      )
    );
    expect(docId, "need pending REVIEW on a case doc").toBeTruthy();
    const high0 = nPending(
      before,
      (r) => r.document_id === docId && r.band === "high"
    );
    const flag0 = nPending(
      before,
      (r) => r.document_id === docId && r.band === "flagged"
    );

    await postDecision(request, api.band(docId!, "review", "rejected"));
    const after = await suggestionsViaApi(request, caseId);
    expect(
      nPending(after, (r) => r.document_id === docId && r.band === "review")
    ).toBe(0);
    expect(
      nPending(after, (r) => r.document_id === docId && r.band === "high")
    ).toBe(high0);
    expect(
      nPending(after, (r) => r.document_id === docId && r.band === "flagged")
    ).toBe(flag0);
  });

  test("entity work API exposes multi-doc pending lists", async ({
    request,
  }) => {
    const res = await request.get(api.entityWork(caseId));
    expect(res.ok()).toBeTruthy();
    const work = (await res.json()) as Array<{
      entity_id: string;
      n_pending: number;
      n_docs: number;
      pending_doc_ids: string[];
      pending_filenames: string[];
    }>;
    expect(work.length).toBeGreaterThan(0);
    const multi = work.find((e) => e.n_docs >= 2 && e.n_pending > 0);
    // Corpus usually has multi-doc entities; if not, single-doc still valid lists
    const sample = multi ?? work.find((e) => e.n_pending > 0);
    expect(sample).toBeTruthy();
    expect(sample!.pending_doc_ids.length).toBe(sample!.n_docs);
    expect(sample!.pending_filenames.length).toBeGreaterThan(0);
  });

  test("entity bulk clears non-flagged (multi-doc when present)", async ({
    request,
  }) => {
    const before = await suggestionsViaApi(request, caseId);
    const cand = before.filter(
      (r) =>
        r.status === "pending" &&
        r.band !== "flagged" &&
        r.entity_id &&
        docSet.has(r.document_id)
    );
    expect(cand.length, "need entity-linked pending").toBeGreaterThan(0);

    // Prefer entity spanning ≥2 docs
    const byE = new Map<string, Set<string>>();
    for (const r of cand) {
      if (!byE.has(r.entity_id!)) byE.set(r.entity_id!, new Set());
      byE.get(r.entity_id!)!.add(r.document_id);
    }
    let entityId = cand[0].entity_id!;
    for (const [id, docs] of byE) {
      if (docs.size >= 2) {
        entityId = id;
        break;
      }
    }
    const flag0 = nPending(
      before,
      (r) => r.entity_id === entityId && r.band === "flagged" && docSet.has(r.document_id)
    );

    await postDecision(request, api.entity(entityId, "accepted"));
    const after = await suggestionsViaApi(request, caseId);
    expect(
      nPending(
        after,
        (r) =>
          r.entity_id === entityId &&
          r.band !== "flagged" &&
          docSet.has(r.document_id)
      )
    ).toBe(0);
    expect(
      nPending(
        after,
        (r) =>
          r.entity_id === entityId &&
          r.band === "flagged" &&
          docSet.has(r.document_id)
      )
    ).toBe(flag0);
  });

  test("flagged band API cannot bulk-accept", async ({ request }) => {
    const before = await suggestionsViaApi(request, caseId);
    const docId = [...docSet].find((id) =>
      before.some(
        (r) =>
          r.document_id === id && r.status === "pending" && r.band === "flagged"
      )
    );
    if (!docId) {
      test.skip(true, "no flagged pending");
      return;
    }
    const flag0 = nPending(
      before,
      (r) => r.document_id === docId && r.band === "flagged"
    );
    await request.post(api.band(docId, "flagged", "accepted"), {
      headers: { Accept: "application/json", "Content-Type": "application/json" },
      data: {},
    });
    const after = await suggestionsViaApi(request, caseId);
    expect(
      nPending(after, (r) => r.document_id === docId && r.band === "flagged")
    ).toBe(flag0);
  });

  test("keyboard a reduces pending on focused doc", async ({ page, request }) => {
    // After prior bulks, pick remaining grain; undo once if suite exhausted non-flagged.
    let before = await suggestionsViaApi(request, caseId);
    let hit = before.find(
      (r) =>
        r.status === "pending" &&
        r.band !== "flagged" &&
        docSet.has(r.document_id)
    );
    if (!hit) {
      await postDecision(request, api.undo(caseId));
      before = await suggestionsViaApi(request, caseId);
      hit = before.find(
        (r) =>
          r.status === "pending" &&
          r.band !== "flagged" &&
          docSet.has(r.document_id)
      );
    }
    expect(hit, "need a pending mark for keyboard").toBeTruthy();
    const docId = hit!.document_id;
    const pageNo = hit!.page_no ?? 1;
    const id = hit!.id;

    // Open the page that has the mark (marks are page-scoped in SSR)
    const href =
      pageNo <= 1
        ? `/documents/${docId}`
        : `/documents/${docId}/pages/${pageNo}`;
    await page.goto(href);
    await expect(page.locator("body[data-surface='review']")).toBeVisible();
    const mark = page.locator(`.mark[data-status='pending'][data-id='${id}']`);
    await expect(mark).toBeVisible();
    // Click selects focus (same as user); then keyboard a decides
    await mark.click();
    await expect(page.locator(`.mark.current[data-id='${id}']`)).toBeVisible();
    await page.keyboard.press("a");
    await page.waitForLoadState("networkidle");

    const after = await suggestionsViaApi(request, caseId);
    const row = after.find((r) => r.id === id);
    expect(row?.status, "keyboard a must fold that suggestion").not.toBe(
      "pending"
    );
  });

  test("keyboard Shift bulk on doc band", async ({ page, request }) => {
    let before = await suggestionsViaApi(request);
    let docId = [...docSet].find((id) =>
      before.some(
        (r) => r.document_id === id && r.status === "pending" && r.band === "high"
      )
    );
    if (docId) {
      await page.goto(`/documents/${docId}`);
      await page.keyboard.press("Shift+A");
      await page.waitForLoadState("networkidle");
      const after = await suggestionsViaApi(request);
      expect(
        nPending(after, (r) => r.document_id === docId && r.band === "high")
      ).toBe(0);
      return;
    }
    docId = [...docSet].find((id) =>
      before.some(
        (r) =>
          r.document_id === id && r.status === "pending" && r.band === "review"
      )
    );
    expect(docId, "need high or review for Shift bulk").toBeTruthy();
    before = await suggestionsViaApi(request);
    const n0 = nPending(
      before,
      (r) => r.document_id === docId && r.band === "review"
    );
    await page.goto(`/documents/${docId}`);
    await page.keyboard.press("Shift+R");
    await page.waitForLoadState("networkidle");
    const after = await suggestionsViaApi(request);
    expect(
      nPending(after, (r) => r.document_id === docId && r.band === "review")
    ).toBe(0);
    expect(n0).toBeGreaterThan(0);
  });

  test("every case doc still opens", async ({ page }) => {
    await openLibrary(page);
    for (const href of (await docHrefs(page)).slice(0, 4)) {
      await page.goto(href);
      await expect(page.locator("body[data-doc-id]")).toBeVisible();
      await expect(page.locator(".pdf-page")).toBeVisible();
    }
  });

  test("export blocked while flagged; bulk FP batch clears gate", async ({
    page,
    request,
  }) => {
    const rows = await suggestionsViaApi(request, caseId);
    const flagged = rows.filter(
      (r) =>
        r.status === "pending" &&
        r.band === "flagged" &&
        docSet.has(r.document_id)
    );
    await page.goto(`/cases/${caseId}`);
    const btn = page.locator("#export-btn, [data-action='export']");
    await expect(btn).toBeVisible();

    if (flagged.length === 0) return;

    await expect(btn).toBeDisabled();

    // One batch POST — product bulk, not N× decide.
    await postDecision(request, api.flaggedBulk(caseId, "rejected"));

    const after = await suggestionsViaApi(request, caseId);
    expect(
      after.filter(
        (r) =>
          r.band === "flagged" &&
          r.status === "pending" &&
          docSet.has(r.document_id)
      ).length
    ).toBe(0);

    // Audit trail: one batch with many members
    const batRes = await request.get(api.batches(caseId));
    expect(batRes.ok()).toBeTruthy();
    const batches = (await batRes.json()) as Array<{
      label: string;
      n_members: number;
      is_undo: boolean;
    }>;
    const fpBatch = batches.find(
      (b) => b.label && b.label.includes("FP") && !b.is_undo
    );
    expect(fpBatch, "audit has flagged→FP batch").toBeTruthy();
    expect(fpBatch!.n_members).toBeGreaterThanOrEqual(flagged.length);

    await page.goto(`/cases/${caseId}`);
    await expect(page.locator("#export-btn, [data-action='export']")).toBeEnabled({
      timeout: 30_000,
    });
  });

  test("flagged triage page lists judge votes + bulk controls", async ({
    page,
    request,
  }) => {
    await page.goto(`/cases/${caseId}/flagged`);
    await expect(page.locator("body[data-surface='flagged']")).toBeVisible();
    await expect(page.getByText("Flagged triage")).toBeVisible();
    await expect(
      page.locator("[data-action='flagged-bulk'][data-status='rejected']")
    ).toBeVisible();

    const res = await request.get(`/api/cases/${caseId}/flagged`);
    expect(res.ok()).toBeTruthy();
    const flagged = await res.json();
    if (Array.isArray(flagged) && flagged.length > 0) {
      await expect(page.locator(".flagged-row").first()).toBeVisible();
      await expect(page.getByText(/Panel/)).toBeVisible();
      await expect(
        page.locator("[data-action='doc-flagged-bulk']").first()
      ).toBeVisible();
    }
  });

  test("FN remainder page + optional bulk redact", async ({ page, request }) => {
    await page.goto(`/cases/${caseId}/remainder`);
    await expect(page.locator("body[data-surface='remainder']")).toBeVisible();
    await expect(page.getByText("FN remainder")).toBeVisible();
    await expect(
      page.locator("[data-action='remainder-bulk'][data-status='accepted']")
    ).toBeVisible();

    const res = await request.get(`/api/cases/${caseId}/remainder`);
    expect(res.ok()).toBeTruthy();
    const rem = (await res.json()) as Array<{ id: string; status: string }>;
    if (rem.length === 0) return;

    const before = rem.length;
    await postDecision(request, api.remainderBulk(caseId, "accepted"));
    const afterRes = await request.get(`/api/cases/${caseId}/remainder`);
    const after = (await afterRes.json()) as unknown[];
    expect(after.length).toBe(0);

    const batRes = await request.get(api.batches(caseId));
    const batches = (await batRes.json()) as Array<{ label: string; n_members: number }>;
    const remBatch = batches.find((b) => b.label && b.label.includes("remainder"));
    expect(remBatch, "remainder bulk is one audit batch").toBeTruthy();
    expect(remBatch!.n_members).toBeGreaterThanOrEqual(before);
  });
});

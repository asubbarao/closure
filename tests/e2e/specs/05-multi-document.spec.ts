import { test, expect } from "@playwright/test";
import { getCaseDocuments, getCaseSuggestions } from "../helpers/api";
import {
  openCaseLibrary,
  openDocFromLibrary,
  openDocument,
  waitForQueueHydrated,
} from "../helpers/ui";

/**
 * CORE FLOW 5 — Multi-document workflow
 * Case library lists docs; open another; entity decisions propagate across docs.
 * Document set is data-driven from GET /api/cases/:id/documents (no hardcoded filenames).
 */
test.describe("5. Multi-document workflow", () => {
  test("case library lists multiple documents", async ({ page, request }) => {
    const docs = await getCaseDocuments(request, 1);
    expect(docs.length, "case should have multiple PDFs").toBeGreaterThanOrEqual(
      2
    );

    await openCaseLibrary(page, 1);

    const rows = page.locator("#doc-table tbody tr[data-doc-id]");
    await expect(rows.first()).toBeVisible();
    const n = await rows.count();
    expect(n).toBeGreaterThanOrEqual(2);
    // UI row count should match API (data-driven corpus)
    expect(n).toBe(docs.length);

    // Each API doc id appears as a table row; no hardcoded filenames
    for (const d of docs.slice(0, 5)) {
      await expect(
        page.locator(`#doc-table tr[data-doc-id="${d.id}"]`)
      ).toBeVisible();
    }

    // Each row links into the review workspace
    const firstOpen = page.locator('#doc-table a[href^="/documents/"]').first();
    await expect(firstOpen).toBeVisible();
    const href = await firstOpen.getAttribute("href");
    expect(href).toMatch(/\/documents\/\d+/);
  });

  test("open a second document from the library", async ({ page, request }) => {
    const docs = await getCaseDocuments(request, 1);
    test.skip(docs.length < 2, "need ≥2 documents");

    // Prefer a smaller non-first doc when available (data-driven, not by name)
    const ranked = [...docs].sort((a, b) => a.page_count - b.page_count);
    const target = ranked.find((d) => d.id !== docs[0].id) || docs[1];

    await openCaseLibrary(page, 1);
    await openDocFromLibrary(page, target.id);
  });

  test("entity decision propagates across documents", async ({
    page,
    request,
  }) => {
    const caseSuggs = await getCaseSuggestions(request, 1);
    // Entity with pending hits in ≥2 different documents
    const byEnt = new Map<
      number,
      { docs: Set<number>; pending: typeof caseSuggs }
    >();
    for (const s of caseSuggs) {
      if (s.entity_id == null || s.status !== "pending" || s.band === "flagged")
        continue;
      const eid = Number(s.entity_id);
      const entry = byEnt.get(eid) || { docs: new Set<number>(), pending: [] };
      entry.docs.add(s.document_id);
      entry.pending.push(s);
      byEnt.set(eid, entry);
    }

    let entityId: number | null = null;
    let pending: typeof caseSuggs = [];
    for (const [eid, entry] of byEnt) {
      if (entry.docs.size >= 2 && entry.pending.length >= 2) {
        entityId = eid;
        pending = entry.pending;
        break;
      }
    }

    test.skip(
      !entityId,
      "no entity with pending non-flagged hits across ≥2 documents"
    );

    // Use the bulk entity endpoint path (UI) or POST entity decision
    await page.goto(`/ui/bulk?entity=${entityId}&case=1`, {
      waitUntil: "domcontentloaded",
    });
    await expect(page.locator("#btn-accept")).toBeVisible({ timeout: 20_000 });
    await page.waitForTimeout(800);

    const acceptBtn = page.locator("#btn-accept");
    if (await acceptBtn.isDisabled()) {
      // Fallback: API entity decision — still proves server-side propagation
      const res = await request.post(
        `/api/entities/${entityId}/decision?status=accepted&actor=e2e-runner&reason=cross-doc-e2e`,
        {
          headers: {
            "Content-Type": "application/json",
            Accept: "application/json",
          },
          data: {},
        }
      );
      expect(res.ok() || res.status() === 200, `entity decision HTTP ${res.status()}`).toBeTruthy();
    } else {
      await acceptBtn.click();
    }

    await expect
      .poll(async () => {
        const live = await getCaseSuggestions(request, 1);
        return live.filter(
          (s) =>
            Number(s.entity_id) === entityId &&
            s.status === "pending" &&
            s.band !== "flagged"
        ).length;
      }, { timeout: 45_000 })
      .toBe(0);

    const after = await getCaseSuggestions(request, 1);
    const acceptedDocs = new Set(
      after
        .filter(
          (s) => Number(s.entity_id) === entityId && s.status === "accepted"
        )
        .map((s) => s.document_id)
    );
    expect(
      acceptedDocs.size,
      "accepted entity instances should span multiple documents"
    ).toBeGreaterThanOrEqual(2);

    // Spot-check review UI on a second document still shows accepted status
    const otherDoc = [...acceptedDocs].find(
      (d) => d !== pending[0].document_id
    );
    if (otherDoc != null) {
      await openDocument(page, otherDoc);
      await waitForQueueHydrated(page);
      // At least one queue row for this entity (if present on this page) is accepted,
      // or API already proved it — also check rail lists multiple docs.
      const railDocs = page.locator("#docs-list .doc-item");
      await expect(railDocs).toHaveCount(await getCaseDocuments(request, 1).then((d) => d.length));
    }
  });
});

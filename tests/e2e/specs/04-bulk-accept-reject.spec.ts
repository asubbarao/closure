import { test, expect } from "@playwright/test";
import {
  getCaseSuggestions,
  getDocSuggestions,
  pickReviewDoc,
} from "../helpers/api";
import { openDocument, waitForQueueHydrated } from "../helpers/ui";

/**
 * CORE FLOW 4 — Bulk accept / reject
 * Select a confidence band (HIGH) or multi-select and accept many at once.
 */
test.describe("4. Bulk accept / reject", () => {
  test("bulk-accept HIGH band changes many statuses with one action", async ({
    page,
    request,
  }) => {
    const docs = await (await import("../helpers/api")).getCaseDocuments(request, 1);
    // Prefer a doc with multiple pending HIGH (not the huge consolidated file if avoidable)
    const ranked = [...docs]
      .filter((d) => d.pending_count > 0 && d.high_count > 0)
      .sort((a, b) => a.page_count - b.page_count);
    const doc = ranked[0] || (await pickReviewDoc(request));

    const before = await getDocSuggestions(request, doc.id);
    const pendingHigh = before.filter(
      (s) => s.status === "pending" && s.band === "high"
    );
    test.skip(
      pendingHigh.length < 2,
      `need ≥2 pending HIGH on doc ${doc.id} (have ${pendingHigh.length})`
    );

    await openDocument(page, doc.id, pendingHigh[0].page_no);
    await waitForQueueHydrated(page);

    // Select HIGH via toolbar
    const selHigh = page.locator("#btn-sel-high");
    await expect(selHigh).toBeVisible();
    await selHigh.click();

    const bulkBar = page.locator("#bulk-sel");
    await expect(bulkBar).toHaveClass(/on/, { timeout: 10_000 });
    const countTxt = await page.locator("#bulk-count").innerText();
    const selectedN = parseInt(countTxt, 10);
    expect(selectedN, "should select multiple HIGH items").toBeGreaterThanOrEqual(
      2
    );

    const acceptBtn = page.locator("#btn-bulk-accept");
    await expect(acceptBtn).toBeEnabled();
    await acceptBtn.click();

    await expect
      .poll(async () => {
        const live = await getDocSuggestions(request, doc.id);
        const still = live.filter(
          (s) => s.status === "pending" && s.band === "high"
        ).length;
        return still;
      }, { timeout: 45_000 })
      .toBeLessThan(pendingHigh.length);

    const after = await getDocSuggestions(request, doc.id);
    const acceptedHigh = after.filter(
      (s) => s.band === "high" && s.status === "accepted"
    ).length;
    const beforeAcceptedHigh = before.filter(
      (s) => s.band === "high" && s.status === "accepted"
    ).length;
    expect(acceptedHigh).toBeGreaterThan(beforeAcceptedHigh);
    expect(acceptedHigh - beforeAcceptedHigh).toBeGreaterThanOrEqual(
      Math.min(2, selectedN)
    );
  });

  test("entity bulk sheet accepts many instances of one entity", async ({
    page,
    request,
  }) => {
    const caseSuggs = await getCaseSuggestions(request, 1);
    // Find an entity with ≥2 pending non-flagged suggestions
    const byEnt = new Map<number, typeof caseSuggs>();
    for (const s of caseSuggs) {
      if (
        s.status !== "pending" ||
        s.band === "flagged" ||
        s.entity_id == null
      )
        continue;
      const list = byEnt.get(Number(s.entity_id)) || [];
      list.push(s);
      byEnt.set(Number(s.entity_id), list);
    }
    let entityId: number | null = null;
    let group: typeof caseSuggs = [];
    for (const [eid, list] of byEnt) {
      if (list.length >= 2) {
        entityId = eid;
        group = list;
        break;
      }
    }
    test.skip(!entityId, "no entity with ≥2 pending non-flagged instances");

    const beforePending = group.length;

    await page.goto(`/ui/bulk?entity=${entityId}&case=1`, {
      waitUntil: "domcontentloaded",
    });
    await expect(page.locator("#btn-accept")).toBeVisible({ timeout: 20_000 });

    // Wait for rows to load
    await page.waitForTimeout(1000);
    const acceptBtn = page.locator("#btn-accept");
    // If disabled, try selecting all eligible checkboxes
    if (await acceptBtn.isDisabled()) {
      const checks = page.locator(
        'input[type="checkbox"]:not([disabled])'
      );
      const n = await checks.count();
      for (let i = 0; i < Math.min(n, 20); i++) {
        const c = checks.nth(i);
        if (!(await c.isChecked())) await c.check({ force: true });
      }
    }

    if (await acceptBtn.isDisabled()) {
      test.fail(
        true,
        "GAP: bulk accept button stays disabled — cannot bulk-accept entity"
      );
      return;
    }

    await acceptBtn.click();

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
      .toBeLessThan(beforePending);

    const after = await getCaseSuggestions(request, 1);
    const accepted = after.filter(
      (s) => Number(s.entity_id) === entityId && s.status === "accepted"
    ).length;
    expect(accepted).toBeGreaterThan(0);
  });
});

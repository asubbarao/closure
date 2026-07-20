import { test, expect } from "@playwright/test";
import { getDocSuggestions, pickReviewDoc } from "../helpers/api";
import { openDocument, queueRows, waitForQueueHydrated } from "../helpers/ui";

/**
 * CORE FLOW 6 — Confidence display
 * Suggestions show confidence values / bands (high / review / flagged) and are filterable.
 */
test.describe("6. Confidence display & filters", () => {
  test("queue shows confidence numbers and band filters", async ({
    page,
    request,
  }) => {
    const doc = await pickReviewDoc(request);
    const suggs = await getDocSuggestions(request, doc.id);
    expect(suggs.length).toBeGreaterThan(0);

    await openDocument(page, doc.id);
    await waitForQueueHydrated(page);

    // Band filter buttons
    const high = page.locator('#band-filters .band[data-band="high"]');
    const review = page.locator('#band-filters .band[data-band="review"]');
    const flagged = page.locator('#band-filters .band[data-band="flagged"]');
    await expect(high).toBeVisible();
    await expect(review).toBeVisible();
    await expect(flagged).toBeVisible();

    await expect(high).toContainText(/HIGH/i);
    await expect(review).toContainText(/REVIEW/i);
    await expect(flagged).toContainText(/FLAGGED/i);

    // Numeric counts in band headers
    await expect(page.locator("#band-high")).toBeVisible();
    await expect(page.locator("#band-review")).toBeVisible();
    await expect(page.locator("#band-flagged")).toBeVisible();

    // Per-row confidence mono values
    const conf = page.locator("#q-list .sugg .conf").first();
    await expect(conf).toBeVisible();
    const confText = (await conf.innerText()).trim();
    expect(confText).toMatch(/^\d{1,3}$/);
    const confNum = Number(confText);
    expect(confNum).toBeGreaterThanOrEqual(0);
    expect(confNum).toBeLessThanOrEqual(100);
  });

  test("band filters hide and show suggestions", async ({ page, request }) => {
    const doc = await pickReviewDoc(request);
    const suggs = await getDocSuggestions(request, doc.id);
    const bands = new Set(suggs.map((s) => s.band));
    test.skip(
      bands.size < 2,
      "need ≥2 confidence bands on the document to test filtering"
    );

    await openDocument(page, doc.id);
    await waitForQueueHydrated(page);

    const rows = await queueRows(page);
    const initial = await rows.count();
    expect(initial).toBeGreaterThan(0);

    // Turn OFF high band
    const highBtn = page.locator('#band-filters .band[data-band="high"]');
    await highBtn.click();
    await expect(highBtn).not.toHaveClass(/on/);

    // Visible rows should only be non-high (or empty-q message)
    await page.waitForTimeout(200);
    const afterOff = page.locator("#q-list .sugg[data-id]");
    const nOff = await afterOff.count();
    if (nOff > 0) {
      for (let i = 0; i < Math.min(nOff, 10); i++) {
        const band = await afterOff.nth(i).getAttribute("data-band");
        expect(band).not.toBe("high");
      }
    } else {
      await expect(page.locator("#q-list .empty-q")).toBeVisible();
    }

    // Re-enable high
    await highBtn.click();
    await expect(highBtn).toHaveClass(/on/);
    await expect
      .poll(async () => page.locator("#q-list .sugg[data-id]").count())
      .toBeGreaterThanOrEqual(Math.min(initial, 1));

    // Isolate flagged only if any exist
    const flaggedCount = suggs.filter((s) => s.band === "flagged").length;
    if (flaggedCount > 0) {
      // turn off high + review
      if (await highBtn.evaluate((el) => el.classList.contains("on"))) {
        await highBtn.click();
      }
      const reviewBtn = page.locator('#band-filters .band[data-band="review"]');
      if (await reviewBtn.evaluate((el) => el.classList.contains("on"))) {
        await reviewBtn.click();
      }
      const flaggedBtn = page.locator(
        '#band-filters .band[data-band="flagged"]'
      );
      if (!(await flaggedBtn.evaluate((el) => el.classList.contains("on")))) {
        await flaggedBtn.click();
      }
      await page.waitForTimeout(200);
      const only = page.locator("#q-list .sugg[data-id]");
      const n = await only.count();
      for (let i = 0; i < n; i++) {
        expect(await only.nth(i).getAttribute("data-band")).toBe("flagged");
      }
    }
  });
});

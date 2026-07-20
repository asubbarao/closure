import { test, expect } from "@playwright/test";
import {
  getCaseSuggestions,
  getDocSuggestions,
  isStreetFalsePositive,
  waitForSuggestionStatus,
} from "../helpers/api";

/**
 * CORE FLOW 2 — Reject a false positive
 * Find a street-name FP (e.g. "… Street"), reject it, then reject-all-matching.
 * Primary UI: /ui/reject?doc=&sug=
 */
test.describe("2. Reject false positive", () => {
  test("reject one street-name false positive and assert status cleared", async ({
    page,
    request,
  }) => {
    const caseSuggs = await getCaseSuggestions(request, 1);
    const streetPending = caseSuggs.filter(
      (s) => s.status === "pending" && isStreetFalsePositive(s)
    );
    // Assignment example is "Nienow Street"; live seed uses case surname + Street
    // (e.g. Cronin Street). Prefer that text if present.
    const target =
      streetPending.find((s) => /Nienow Street/i.test(s.text)) ||
      streetPending.find((s) => /\bStreet\b/i.test(s.text)) ||
      streetPending[0];

    test.skip(
      !target,
      "no pending street-name false positives — seed/decisions left none for case 1"
    );

    await page.goto(
      `/ui/reject?doc=${target.document_id}&sug=${target.id}`,
      { waitUntil: "domcontentloaded" }
    );

    // Shell should load and resolve current suggestion
    await expect(page.locator("#btn-reject")).toBeVisible({ timeout: 20_000 });
    // Why-card / queue should mention the street text
    await expect(page.locator("body")).toContainText(target.text, {
      timeout: 15_000,
    });

    await page.locator("#btn-reject").click();

    // Toast or local status flip
    await expect
      .poll(async () => {
        const rows = await getDocSuggestions(request, target.document_id);
        return rows.find((r) => r.id === target.id)?.status;
      })
      .toBe("rejected");

    const live = await waitForSuggestionStatus(
      request,
      target.document_id,
      target.id,
      "rejected"
    );
    expect(live?.status).toBe("rejected");
  });

  test("reject-all-matching clears every instance of the same text", async ({
    page,
    request,
  }) => {
    const caseSuggs = await getCaseSuggestions(request, 1);
    // Group pending street FPs by exact text; need ≥2 pending matches
    const byText = new Map<string, typeof caseSuggs>();
    for (const s of caseSuggs) {
      if (s.status !== "pending" || !isStreetFalsePositive(s)) continue;
      const list = byText.get(s.text) || [];
      list.push(s);
      byText.set(s.text, list);
    }
    let text = "";
    let group: typeof caseSuggs = [];
    for (const [t, list] of byText) {
      if (list.length >= 2) {
        text = t;
        group = list;
        break;
      }
    }
    // Fall back: any text with ≥2 pending matches (not only street)
    if (!group.length) {
      const allByText = new Map<string, typeof caseSuggs>();
      for (const s of caseSuggs) {
        if (s.status !== "pending") continue;
        const list = allByText.get(s.text) || [];
        list.push(s);
        allByText.set(s.text, list);
      }
      for (const [t, list] of allByText) {
        if (list.length >= 2 && /Street|v\. Ohio|Det\./i.test(t)) {
          text = t;
          group = list;
          break;
        }
      }
    }

    test.skip(
      group.length < 2,
      "need ≥2 pending matching false-positive instances for reject-all"
    );

    const seed = group[0];
    await page.goto(`/ui/reject?doc=${seed.document_id}&sug=${seed.id}`, {
      waitUntil: "domcontentloaded",
    });
    await expect(page.locator("#btn-reject-all")).toBeVisible({ timeout: 20_000 });

    // Button should advertise bulk clear
    const btnText = await page.locator("#btn-reject-all").innerText();
    expect(btnText.toLowerCase()).toMatch(/reject all/);

    await page.locator("#btn-reject-all").click();

    // All previously-pending matching instances should clear from pending
    await expect
      .poll(async () => {
        const live = await getCaseSuggestions(request, 1);
        const stillPending = live.filter(
          (s) => s.text === text && s.status === "pending"
        );
        return stillPending.length;
      }, { timeout: 30_000 })
      .toBe(0);

    const after = (await getCaseSuggestions(request, 1)).filter(
      (s) => s.text === text
    );
    // Instances we targeted should be rejected (others may already have been
    // accepted/rejected by earlier bulk/entity tests in the suite).
    const touched = after.filter((s) =>
      group.some((g) => Number(g.id) === Number(s.id))
    );
    expect(touched.length).toBeGreaterThan(0);
    expect(
      touched.every((s) => s.status === "rejected"),
      `expected reject-all to reject the pending cohort for "${text}"`
    ).toBeTruthy();
    expect(after.filter((s) => s.status === "pending").length).toBe(0);
  });
});

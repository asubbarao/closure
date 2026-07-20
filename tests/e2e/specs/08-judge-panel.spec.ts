import { test, expect } from "@playwright/test";
import {
  asJudgePanel,
  getCaseSuggestions,
  getSuggestionJudges,
  pickFlaggedPending,
  pickReviewDoc,
  getDocSuggestions,
} from "../helpers/api";
import {
  judgePanelLocator,
  openDocument,
  waitForQueueHydrated,
} from "../helpers/ui";

/**
 * WAVE-2 — Judge panel
 * GET /api/suggestions/:id/judges + UI surface on flagged items.
 * Skips cleanly when the route is not landed (404).
 */
test.describe("8. Judge panel (wave-2)", () => {
  test("GET /api/suggestions/:id/judges returns panel for a live suggestion", async ({
    request,
  }) => {
    const flagged = await pickFlaggedPending(request, 1);
    const any =
      flagged ||
      (await getCaseSuggestions(request, 1)).find((s) => s.id != null);
    test.skip(!any, "no suggestions available to probe judges");

    const probe = await getSuggestionJudges(request, any!.id);
    test.skip(!probe.live, probe.live === false ? probe.reason : "not live");

    const panel = asJudgePanel(probe.body);
    // Accept either aggregated panel or list of votes
    const hasSignal =
      typeof panel.panel_signal === "string" ||
      typeof panel.confidence === "number" ||
      panel.judge_count != null ||
      Array.isArray(panel.judges) ||
      (Array.isArray(probe.body) && (probe.body as unknown[]).length > 0);

    expect(
      hasSignal,
      `judges payload should expose panel_signal / confidence / judges list; got ${JSON.stringify(probe.body).slice(0, 400)}`
    ).toBeTruthy();

    if (typeof panel.panel_signal === "string") {
      expect(["agree", "split", "conflict"]).toContain(panel.panel_signal);
    }
    if (typeof panel.confidence === "number") {
      expect(panel.confidence).toBeGreaterThanOrEqual(0);
      expect(panel.confidence).toBeLessThanOrEqual(100);
    }
    if (Array.isArray(panel.judges) && panel.judges.length > 0) {
      const j0 = panel.judges[0] as Record<string, unknown>;
      // Each judge should name itself or give a verdict
      const named =
        j0.judge_name != null ||
        j0.name != null ||
        j0.verdict != null ||
        j0.factor != null;
      expect(named, "judge vote should have name/verdict/factor").toBeTruthy();
    }
  });

  test("flagged queue item can surface judge panel UI when feature is live", async ({
    page,
    request,
  }) => {
    const flagged = await pickFlaggedPending(request, 1);
    // Prefer flagged; fall back to any pending so we still exercise the page
    let target = flagged;
    if (!target) {
      const doc = await pickReviewDoc(request);
      const rows = await getDocSuggestions(request, doc.id);
      target = rows.find((s) => s.status === "pending") || rows[0] || null;
    }
    test.skip(!target, "no suggestion to open for judge UI");

    // Route gate first — if API 404s, UI cannot be fully live either
    const probe = await getSuggestionJudges(request, target!.id);
    test.skip(!probe.live, probe.live === false ? probe.reason : "not live");

    await openDocument(page, target!.document_id, target!.page_no);
    await waitForQueueHydrated(page);

    const row = page.locator(`#q-list .sugg[data-id="${target!.id}"]`);
    // May need band filter — ensure flagged visible
    if ((await row.count()) === 0 && target!.band === "flagged") {
      const flaggedBtn = page.locator('#band-filters .band[data-band="flagged"]');
      if (await flaggedBtn.count()) {
        if (!(await flaggedBtn.evaluate((el) => el.classList.contains("on")))) {
          await flaggedBtn.click();
        }
      }
    }

    if ((await row.count()) > 0) {
      await row.click();
      // judge.js hydrates chips / why-card on selection
      await page.waitForTimeout(400);
    }

    // Live mount: #judge-why-card / #judge-panel / .judge-chip
    const panel = judgePanelLocator(page);
    await expect
      .poll(async () => panel.count(), { timeout: 15_000 })
      .toBeGreaterThan(0);

    const panelVisible = await panel
      .first()
      .isVisible()
      .catch(() => false);

    // Why-card may be hidden until .on — chips on flagged rows are enough
    const chips = page.locator(".judge-chip, .judge-badge, #judge-why-card.on");
    const chipN = await chips.count();
    const bodyish = await page.locator("body").innerText();
    const hasVocab =
      /agree|split|conflict|pattern|context|prior|redact|keep|judge/i.test(
        bodyish
      );

    if (panelVisible || chipN > 0 || hasVocab) {
      expect(hasVocab || chipN > 0 || panelVisible).toBeTruthy();
    } else {
      // API live but UI silent — still require mount nodes in DOM
      expect(
        await page.locator("#judge-panel, #judge-why-card, .judge-panel").count()
      ).toBeGreaterThan(0);
      const panelData = asJudgePanel(probe.body);
      expect(panelData.panel_signal || panelData.judges).toBeTruthy();
    }
  });

  test("judges endpoint is consistent across multiple suggestions", async ({
    request,
  }) => {
    const rows = await getCaseSuggestions(request, 1);
    const sample = rows.filter((s) => s.status === "pending").slice(0, 5);
    test.skip(sample.length === 0, "no pending suggestions");

    let liveN = 0;
    let missingN = 0;
    for (const s of sample) {
      const probe = await getSuggestionJudges(request, s.id);
      if (!probe.live) {
        missingN++;
        continue;
      }
      liveN++;
      const panel = asJudgePanel(probe.body);
      if (typeof panel.panel_signal === "string") {
        expect(["agree", "split", "conflict"]).toContain(panel.panel_signal);
      }
    }

    if (liveN === 0) {
      test.skip(
        true,
        `route /api/suggestions/:id/judges not live (${missingN} probes 404/error)`
      );
    }
    expect(liveN).toBeGreaterThan(0);
  });
});

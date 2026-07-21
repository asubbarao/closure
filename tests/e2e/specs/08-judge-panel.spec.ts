import { test, expect } from "@playwright/test";
import {
  asJudgePanel,
  getCaseSuggestions,
  getSuggestionJudges,
  pickFlaggedPending,
} from "../helpers/api";

/**
 * Judge panel — one API probe (UI path was redundant with API + skip-heavy).
 */
test.describe("8. Judge panel", () => {
  test("GET /api/suggestions/:id/judges returns panel for a live suggestion", async ({
    request,
  }) => {
    const flagged = await pickFlaggedPending(request);
    const any =
      flagged ||
      (await getCaseSuggestions(request)).find((s) => s.id != null);
    test.skip(!any, "no suggestions available to probe judges");

    const probe = await getSuggestionJudges(request, any!.id);
    test.skip(!probe.live, probe.live === false ? probe.reason : "not live");

    const panel = asJudgePanel(probe.body);
    const hasSignal =
      typeof panel.panel_signal === "string" ||
      typeof panel.confidence === "number" ||
      panel.judge_count != null ||
      Array.isArray(panel.judges) ||
      (Array.isArray(probe.body) && (probe.body as unknown[]).length > 0);

    expect(
      hasSignal,
      `judges payload should expose panel_signal / confidence / judges; got ${JSON.stringify(probe.body).slice(0, 400)}`
    ).toBeTruthy();

    if (typeof panel.panel_signal === "string") {
      expect(["agree", "split", "conflict"]).toContain(panel.panel_signal);
    }
  });
});

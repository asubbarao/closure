import { test, expect } from "@playwright/test";
import {
  getCaseAudit,
  getCaseSuggestions,
  getExportPlan,
  postDecision,
} from "../helpers/api";
import { openCaseLibrary } from "../helpers/ui";

/**
 * CORE FLOW 7 — Export + audit
 * Export is blocked while flagged items are pending; audit log records decisions.
 */
test.describe("7. Export + audit", () => {
  test("export is blocked while flagged items are pending", async ({
    page,
    request,
  }) => {
    const plan = await getExportPlan(request, 1);
    const caseSuggs = await getCaseSuggestions(request, 1);
    const flaggedPending = caseSuggs.filter(
      (s) => s.band === "flagged" && s.status === "pending"
    );

    // API contract
    if (flaggedPending.length > 0) {
      expect(
        plan.blocked,
        "export_plan.blocked must be true when flagged pending remain"
      ).toBeTruthy();
      expect(plan.flagged_remaining).toBeGreaterThan(0);
    } else {
      // If nothing flagged pending, record that the gate is open
      expect(plan.flagged_remaining ?? 0).toBe(0);
    }

    await openCaseLibrary(page, 1);

    const exportBtn = page.locator("#export-btn");
    await expect(exportBtn).toBeVisible();

    if (flaggedPending.length > 0) {
      await expect(
        exportBtn,
        "Export button must be disabled while flagged pending"
      ).toBeDisabled();

      // Banner callout
      const banner = page.locator("#export-banner");
      // may be hidden attr toggled by JS — check either SSR disabled title or banner
      const disabled = await exportBtn.isDisabled();
      expect(disabled).toBeTruthy();

      // Banner text when present
      if (await banner.isVisible().catch(() => false)) {
        await expect(banner).toContainText(/flagged|blocked|export/i);
      }
    } else {
      // No flagged pending: button should be enabled (or banner hidden)
      // This is still a valid state after a full triage.
      test.info().annotations.push({
        type: "note",
        description:
          "No flagged pending at runtime — export gate is open; blocking assertion skipped",
      });
    }

    // If blocked, attempting export via API still reports blocked
    if (plan.blocked) {
      const res = await request.post(
        `/api/cases/1/export?actor=e2e-runner`,
        {
          headers: {
            "Content-Type": "application/json",
            Accept: "application/json",
          },
          data: {},
        }
      );
      // May return 200 with blocked:true or non-OK — accept either signal
      const body = await res.json().catch(() => null);
      const row = Array.isArray(body) ? body[0] : body;
      if (row && typeof row === "object" && "blocked" in row) {
        expect(row.blocked).toBeTruthy();
      } else {
        // UI gate is the primary assertion above
        expect(await exportBtn.isDisabled()).toBeTruthy();
      }
    }
  });

  test("audit log records decisions", async ({ page, request }) => {
    const caseSuggs = await getCaseSuggestions(request, 1);
    const target =
      caseSuggs.find(
        (s) => s.status === "pending" && s.band !== "flagged"
      ) || caseSuggs.find((s) => s.status === "pending");

    test.skip(!target, "no pending suggestion left to decide for audit proof");

    const marker = `e2e-audit-${Date.now()}`;
    const res = await postDecision(
      request,
      target.id,
      "accepted",
      marker
    );
    expect(res.ok() || res.status() === 200, `decision HTTP ${res.status()}`).toBeTruthy();

    // API audit
    await expect
      .poll(async () => {
        const events = await getCaseAudit(request, 1);
        return events.some(
          (e) =>
            (e.reason || "").includes(marker) ||
            (e.target || "").includes(target.text) ||
            Number(e.suggestion_id) === Number(target.id)
        );
      }, { timeout: 20_000 })
      .toBeTruthy();

    // HTML audit page
    await page.goto(`/cases/1/audit`, { waitUntil: "domcontentloaded" });
    await expect(page.locator(".audit-card, .au").first()).toBeVisible({
      timeout: 15_000,
    });
    // Should show at least one decision-ish row
    const bodyText = await page.locator("body").innerText();
    expect(bodyText.length).toBeGreaterThan(50);
    // Prefer seeing our marker or the accepted action
    const hasMarker =
      bodyText.includes(marker) ||
      /accepted|rejected|decision|added/i.test(bodyText);
    expect(
      hasMarker,
      "audit HTML should list decision events"
    ).toBeTruthy();

    // Case library recent audit strip
    await openCaseLibrary(page, 1);
    const auditList = page.locator("#audit-list");
    await expect(auditList).toBeVisible();
  });
});

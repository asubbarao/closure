import { test, expect } from "@playwright/test";
import {
  asMissedCandidates,
  getDocMissed,
  getDocSuggestions,
  getCaseDocuments,
  pickDocWithMissed,
} from "../helpers/api";
import {
  missedQueueLocator,
  openDocument,
  waitForQueueHydrated,
} from "../helpers/ui";

/**
 * WAVE-2 — Possible missed redactions queue
 * GET /api/documents/:id/missed + one-tap add into accepted manual suggestions.
 * Skips cleanly when the route is not landed (404).
 */
test.describe("9. Possible missed redactions queue (wave-2)", () => {
  test("GET /api/documents/:id/missed lists residual candidates (or empty array)", async ({
    request,
  }) => {
    const docs = await getCaseDocuments(request);
    test.skip(docs.length === 0, "no documents in case");

    // Probe every case doc (data-driven); at least one route must be live
    let liveProbes = 0;
    let totalCandidates = 0;
    let sample: ReturnType<typeof asMissedCandidates>[0] | null = null;

    for (const doc of docs) {
      const probe = await getDocMissed(request, doc.id);
      if (!probe.live) continue;
      liveProbes++;
      const candidates = asMissedCandidates(probe.body);
      expect(Array.isArray(candidates)).toBeTruthy();
      totalCandidates += candidates.length;
      if (!sample && candidates.length > 0) sample = candidates[0];
    }

    if (liveProbes === 0) {
      test.skip(true, "route /api/documents/:id/missed not live (404)");
    }

    if (sample) {
      const hasLoc =
        sample.page != null ||
        sample.page_no != null ||
        sample.box != null ||
        (sample.x0 != null && sample.y0 != null);
      const hasText = typeof sample.text === "string" && sample.text.length > 0;
      expect(
        hasLoc || hasText || sample.kind != null || sample.why != null,
        `candidate should have location/text/kind; got ${JSON.stringify(sample).slice(0, 300)}`
      ).toBeTruthy();
    } else {
      test.info().annotations.push({
        type: "note",
        description: `missed queue empty across ${liveProbes} docs (totalCandidates=${totalCandidates}) — valid when remainder scan finds nothing`,
      });
    }
  });

  test("one-tap add promotes a missed candidate into an accepted suggestion", async ({
    request,
  }) => {
    const hit = await pickDocWithMissed(request);
    if (!hit) {
      // Distinguish "route missing" vs "empty residual set"
      const docs = await getCaseDocuments(request);
      const probe = docs[0]
        ? await getDocMissed(request, docs[0].id)
        : { live: false as const, status: 0, reason: "no docs" };
      test.skip(
        !probe.live,
        probe.live === false ? probe.reason : "not live"
      );
      test.skip(true, "no residual candidates in case to one-tap add");
    }

    const { doc, candidates } = hit!;
    const c = candidates[0];
    const before = await getDocSuggestions(request, doc.id);
    const beforeN = before.length;
    const marker = String(c.text || `missed-${c.id ?? "0"}`);

    // Integer-floored coords (known quackapi query type constraint)
    const pageNo = Math.floor(Number(c.page_no ?? c.page ?? 1));
    const x0 = Math.floor(Number(c.x0 ?? 100));
    const y0 = Math.floor(Number(c.y0 ?? 100));
    const x1 = Math.floor(Number(c.x1 ?? x0 + 80));
    const y1 = Math.floor(Number(c.y1 ?? y0 + 14));

    const qs = new URLSearchParams({
      page: String(pageNo),
      x0: String(x0),
      y0: String(y0),
      x1: String(x1),
      y1: String(y1),
      text: marker,
      kind: String(c.kind || "MANUAL"),
      scope: "one",
      actor: "e2e-runner",
      reason: "one-tap missed residual",
    });
    const res = await request.post(`/api/documents/${doc.id}/add?${qs}`, {
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      data: {},
    });
    expect(
      res.ok(),
      `POST add from missed candidate HTTP ${res.status()}`
    ).toBeTruthy();

    await expect
      .poll(async () => {
        const live = await getDocSuggestions(request, doc.id);
        const row = live.find(
          (s) =>
            s.text === marker ||
            (s.source === "manual" && live.length > beforeN)
        );
        return row ? `${row.status}:${row.source || ""}` : "";
      }, { timeout: 15_000 })
      .toMatch(/accepted/);
  });

  test("review UI shows remainder / missed queue and one-tap when live", async ({
    page,
    request,
  }) => {
    const hit = await pickDocWithMissed(request);
    const docs = await getCaseDocuments(request);
    const doc = hit?.doc || docs.sort((a, b) => a.page_count - b.page_count)[0];
    test.skip(!doc, "no documents");

    const probe = await getDocMissed(request, doc.id);
    test.skip(!probe.live, probe.live === false ? probe.reason : "not live");

    await openDocument(page, doc.id, hit?.candidates[0]?.page
      ? Number(hit.candidates[0].page)
      : 1);
    await waitForQueueHydrated(page);

    // remainder.js mounts #remainder-panel / #rm-list
    const queue = missedQueueLocator(page);
    await expect
      .poll(async () => queue.count(), { timeout: 15_000 })
      .toBeGreaterThan(0);

    const visible = await queue.first().isVisible().catch(() => false);
    if (!visible) {
      // Panel may be in DOM but collapsed — still count as landed if #rm-list exists
      const rmList = page.locator("#rm-list, #remainder-panel");
      expect(await rmList.count()).toBeGreaterThan(0);
    }

    if (hit && hit.candidates.length > 0) {
      // Wait for rows or empty state to finish loading
      await page
        .waitForSelector("#rm-list .rm-row, #rm-list .rm-empty, .rm-row", {
          timeout: 15_000,
        })
        .catch(() => {});

      const addBtn = page.locator(
        "#rm-list .rm-add:not(.rm-done), .rm-add:not(.rm-done)"
      );
      if ((await addBtn.count()) > 0) {
        const marker = String(hit.candidates[0].text || "");
        const before = await getDocSuggestions(request, doc.id);
        await addBtn.first().click();

        // UI success: row marks added OR API gains accepted manual
        await expect
          .poll(async () => {
            const live = await getDocSuggestions(request, doc.id);
            const found = live.find(
              (s) =>
                s.text === marker &&
                (s.status === "accepted" || s.source === "manual")
            );
            if (found) return "api-ok";
            const done = page.locator(".rm-row.rm-added, .rm-add.rm-done");
            if ((await done.count()) > 0) return "ui-ok";
            // Float-coord 422 is a known app footgun — surface clearly
            const toast = await page
              .locator("#rm-toast, .rm-toast, #toast")
              .innerText()
              .catch(() => "");
            if (/422|type_error|failed/i.test(toast)) return `fail:${toast.slice(0, 120)}`;
            return live.length > before.length ? "grew" : "pending";
          }, { timeout: 20_000 })
          .toMatch(/api-ok|ui-ok|grew/);
      }
    }
  });
});

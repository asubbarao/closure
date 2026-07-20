import { test, expect } from "@playwright/test";
import { getCaseSuggestions, getDocSuggestions, pickReviewDoc } from "../helpers/api";

/**
 * CORE FLOW 3 — Add a missed redaction (false negative)
 * /ui/add-missed drag → confirm → manual redaction appears, born accepted.
 *
 * Known gap (documented by the UI test): UI drag sends float x0/y0/x1/y1 query
 * params; quackapi currently validates them as integers → HTTP 422. The UI still
 * paints a local "born accepted" mark. Backend path works when integer coords
 * + JSON body `{}` are sent.
 */
test.describe("3. Add missed redaction", () => {
  test("backend POST /api/documents/:id/add creates accepted manual suggestion", async ({
    request,
  }) => {
    const doc = await pickReviewDoc(request);
    const unique = `E2E_API_ADD_${Date.now()}`;
    const qs = new URLSearchParams({
      page: "1",
      x0: "120",
      y0: "180",
      x1: "280",
      y1: "196",
      text: unique,
      kind: "PERSON",
      scope: "one",
      actor: "e2e-runner",
      reason: "missed by AI",
    });
    const res = await request.post(`/api/documents/${doc.id}/add?${qs}`, {
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      data: {},
    });
    expect(res.ok(), `add HTTP ${res.status()}`).toBeTruthy();

    await expect
      .poll(async () => {
        const live = await getDocSuggestions(request, doc.id);
        const hit = live.find((s) => s.text === unique);
        return hit ? `${hit.status}:${hit.source}` : "";
      }, { timeout: 15_000 })
      .toBe("accepted:manual");
  });

  test("add-missed UI flow creates a manual redaction born accepted", async ({
    page,
    request,
  }) => {
    const doc = await pickReviewDoc(request);
    const before = await getDocSuggestions(request, doc.id);
    const beforeTotal = before.length;

    await page.goto(`/ui/add-missed?doc=${doc.id}&page=1`, {
      waitUntil: "domcontentloaded",
    });

    const pdf = page.locator("#pdf-page");
    await expect(pdf).toBeVisible({ timeout: 20_000 });
    await expect(page.locator("#manual-list")).toBeVisible();

    await page.waitForFunction(() => {
      const el = document.getElementById("pdf-page");
      return !!el && el.getBoundingClientRect().width > 100;
    });
    await page.waitForTimeout(500);

    const box = await pdf.boundingBox();
    expect(box, "pdf-page must have layout").toBeTruthy();

    const x0 = box!.x + box!.width * 0.25;
    const y0 = box!.y + box!.height * 0.25;
    const x1 = box!.x + box!.width * 0.45;
    const y1 = box!.y + box!.height * 0.32;
    await page.mouse.move(x0, y0);
    await page.mouse.down();
    await page.mouse.move(x1, y1, { steps: 12 });
    await page.mouse.up();

    const popover = page.locator("#add-popover");
    await expect(popover).toBeVisible({ timeout: 10_000 });

    const unique = `E2E_MISSED_${Date.now()}`;
    await page.locator("#text-input").fill(unique);

    const personBtn = page
      .locator('.cat-btn[data-kind="PERSON"], .cat-btn[data-kind="SSN"]')
      .first();
    if ((await personBtn.count()) === 0) {
      await page.locator(".cat-btn").first().click();
    } else {
      await personBtn.click();
    }

    const addBtn = page.locator("#btn-add");
    await expect(addBtn).toBeEnabled({ timeout: 10_000 });
    await addBtn.click();

    // UI should paint a reviewer-added row (optimistic path even on POST failure)
    await expect
      .poll(async () => {
        const manualList = await page.locator("#manual-list").innerText();
        return manualList.includes(unique);
      }, { timeout: 15_000 })
      .toBeTruthy();

    // Authoritative: re-query for the new manual/accepted row
    let found: { status: string; source?: string } | null = null;
    for (let i = 0; i < 16; i++) {
      const live = await getCaseSuggestions(request, 1);
      const hit = live.find((s) => s.text === unique);
      if (hit) {
        found = { status: hit.status, source: hit.source };
        break;
      }
      const docLive = await getDocSuggestions(request, doc.id);
      const hit2 = docLive.find((s) => s.text === unique);
      if (hit2) {
        found = { status: hit2.status, source: hit2.source };
        break;
      }
      if (docLive.length > beforeTotal) {
        const manual = docLive.filter((s) => s.source === "manual");
        const latest = manual.find((s) => (s.text || "").includes("E2E_MISSED"));
        if (latest) {
          found = { status: latest.status, source: latest.source };
          break;
        }
      }
      await page.waitForTimeout(250);
    }

    const toast = await page.locator("#toast").innerText().catch(() => "");

    // Local paint is required either way (optimistic UI)
    const manualList = await page.locator("#manual-list").innerText();
    expect(manualList.includes(unique)).toBeTruthy();

    if (!found) {
      // APP BUG (punch-list): UI paints locally but does not persist via API.
      // static/addmissed.js posts float x0/y0/x1/y1 → quackapi 422 integer type_error.
      // Integer coords + JSON {} work (sibling test). Not a test-selector issue.
      expect(
        found,
        [
          "APP BUG: add-missed UI did not persist a manual accepted suggestion into v_suggestions.",
          "UI still paints locally (manual list has the text).",
          `toast=${toast.slice(0, 280)}`,
          "Observed: POST 422 type_error on query x1 (float coords vs integer validation).",
          "Fix: floor coords in static/addmissed.js and/or accept DOUBLE query params on POST /api/documents/:id/add.",
        ].join(" ")
      ).toBeTruthy();
    } else {
      expect(found.status, "manual add must be born accepted").toBe("accepted");
      expect(found.source === "manual" || found.source == null).toBeTruthy();
    }
  });
});

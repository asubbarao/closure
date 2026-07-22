import { test, expect } from "@playwright/test";
import { getDocSuggestions, pickReviewDoc } from "../helpers/api";
import { openDocument, waitForQueueHydrated } from "../helpers/ui";

/**
 * Document lines spine — visual-line rail + PDF snap highlight.
 * Complements entity queue: addressable lines for orientation / FP judgment.
 */
test.describe("13. Document lines rail", () => {
  test("API returns line_no + text for a document page", async ({
    request,
  }) => {
    const doc = await pickReviewDoc(request);
    const suggs = await getDocSuggestions(request, doc.id);
    expect(suggs.length).toBeGreaterThan(0);
    const pageNo = suggs[0].page_no || 1;

    const res = await request.get(
      `/api/documents/${doc.id}/lines?page=${pageNo}`
    );
    expect(res.ok(), "lines API should 200").toBeTruthy();
    const body = await res.json();
    const rows = Array.isArray(body) ? body : body.rows || body.data || [];
    // quackapi multi-row: array of objects
    const lines = Array.isArray(rows) ? rows : [body];
    const list = Array.isArray(body) ? body : lines;
    expect(list.length, "page should have visual lines").toBeGreaterThan(0);
    const first = list[0];
    expect(first.line_no).toBeGreaterThan(0);
    expect(String(first.text || "")).toBeTruthy();
    expect(first.y0).toBeDefined();
    expect(first.y1).toBeDefined();
  });

  test("suggestions expose line_no when geometry joins", async ({
    request,
  }) => {
    const doc = await pickReviewDoc(request);
    const suggs = await getDocSuggestions(request, doc.id);
    const withLine = suggs.filter(
      (s: { line_no?: number | null }) => s.line_no != null && s.line_no > 0
    );
    expect(
      withLine.length,
      "most AI suggestions should map to a visual line"
    ).toBeGreaterThan(0);
  });

  test("Lines tab lists page text and click paints line-hl", async ({
    page,
    request,
  }) => {
    const doc = await pickReviewDoc(request);
    const suggs = await getDocSuggestions(request, doc.id);
    const pageNo = (suggs.find((s) => s.page_no)?.page_no as number) || 1;

    await openDocument(page, doc.id, pageNo);
    await waitForQueueHydrated(page);

    await page.locator("#rail-tab-lines").click();
    const rows = page.locator("#lines-list .line-row");
    await expect(rows.first(), "lines list should populate").toBeVisible({
      timeout: 15_000,
    });
    const count = await rows.count();
    expect(count).toBeGreaterThan(0);

    // Prefer a row with pending hits if any
    const withHit = page.locator("#lines-list .line-row.has-hit").first();
    if (await withHit.count()) {
      await withHit.click();
    } else {
      await rows.nth(Math.min(2, count - 1)).click();
    }

    await expect(page.locator("#line-hl")).toBeVisible({ timeout: 5_000 });
    await expect(page.locator("#lines-list .line-row.on")).toHaveCount(1);
  });
});

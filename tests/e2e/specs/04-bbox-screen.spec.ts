import { test, expect } from "@playwright/test";
import {
  api,
  assertScreenMatchesBbox,
  assertValidBbox,
  assertValidScreen,
  firstDocHref,
  openLibrary,
  postDecision,
  suggestionsViaApi,
  type Bbox,
  type ScreenBox,
  type Suggestion,
} from "../helpers/app";

/**
 * First-class geometry: suggestions.bbox (PDF) + suggestions.screen (canvas).
 * Prove grain API + SSR mark styles agree — not flat left_px laundry.
 */
test.describe.configure({ mode: "serial" });

test.describe("bbox · screen (first-class mark geometry)", () => {
  let caseId: string;
  let sample: Suggestion;

  test("grain API exposes typed bbox + screen on suggestions", async ({
    page,
    request,
  }) => {
    caseId = await openLibrary(page);
    const rows = await suggestionsViaApi(request, caseId);
    expect(rows.length, "corpus has suggestions").toBeGreaterThan(0);

    const withGeom = rows.filter((r) => r.bbox && r.screen);
    expect(
      withGeom.length,
      "suggestions carry bbox + screen STRUCTs"
    ).toBeGreaterThan(0);

    // Spot-check a handful — every geometry-bearing row must be valid.
    for (const r of withGeom.slice(0, 25)) {
      assertValidBbox(r.bbox as Bbox, `sug ${r.id} bbox`);
      assertValidScreen(r.screen as ScreenBox, `sug ${r.id} screen`);
    }
    sample = withGeom.find((r) => r.status === "pending") ?? withGeom[0];
    expect(sample.id).toBeTruthy();
  });

  test("screen is bbox × page scale (PDF top-left, no flip)", async ({
    page,
    request,
  }) => {
    const href =
      (sample.page_no ?? 1) <= 1
        ? `/documents/${sample.document_id}`
        : `/documents/${sample.document_id}/pages/${sample.page_no}`;
    await page.goto(href);
    await expect(page.locator("body[data-surface='review']")).toBeVisible();
    const scaleAttr = await page.locator("body").getAttribute("data-scale");
    expect(scaleAttr).toBeTruthy();
    const scale = Number(scaleAttr);
    expect(scale).toBeGreaterThan(0);

    // Re-fetch so we use the same scale pin the page uses.
    const rows = await suggestionsViaApi(request, caseId);
    const row = rows.find((r) => r.id === sample.id);
    expect(row?.bbox && row?.screen).toBeTruthy();
    assertScreenMatchesBbox(
      row!.bbox as Bbox,
      row!.screen as ScreenBox,
      scale
    );
  });

  test("canvas mark DOM styles match screen_box (x,y,w,h)", async ({
    page,
    request,
  }) => {
    const rows = await suggestionsViaApi(request, caseId);
    // Prefer a pending mark on page 1 of any doc for a simple open.
    const hit =
      rows.find(
        (r) =>
          r.bbox &&
          r.screen &&
          r.status === "pending" &&
          (r.page_no ?? 1) === 1
      ) ?? rows.find((r) => r.bbox && r.screen);
    expect(hit, "need a mark with geometry").toBeTruthy();

    const href =
      (hit!.page_no ?? 1) <= 1
        ? `/documents/${hit!.document_id}`
        : `/documents/${hit!.document_id}/pages/${hit!.page_no}`;
    await page.goto(href);
    await expect(page.locator("body[data-surface='review']")).toBeVisible();

    const mark = page.locator(`.mark[data-id='${hit!.id}']`);
    await expect(mark).toBeVisible();
    const style = await mark.getAttribute("style");
    expect(style).toBeTruthy();

    const scr = hit!.screen as ScreenBox;
    // Template: left:{{ m.screen.x }}px; top:…; width:…; height:…
    expect(style!).toMatch(new RegExp(`left:\\s*${escapeRe(numCss(scr.x))}px`));
    expect(style!).toMatch(new RegExp(`top:\\s*${escapeRe(numCss(scr.y))}px`));
    expect(style!).toMatch(
      new RegExp(`width:\\s*${escapeRe(numCss(scr.w))}px`)
    );
    expect(style!).toMatch(
      new RegExp(`height:\\s*${escapeRe(numCss(scr.h))}px`)
    );
  });

  test("POST manual mark packs bbox; fold exposes screen pin", async ({
    page,
    request,
  }) => {
    await openLibrary(page);
    const href = await firstDocHref(page);
    await page.goto(href);
    const docId = await page.locator("body").getAttribute("data-doc-id");
    expect(docId).toBeTruthy();

    const pageNo = 1;
    const box: Bbox = { x0: 40, y0: 50, x1: 140, y1: 70 };
    const label = `e2e-manual-bbox-${Date.now()}`;

    await postDecision(
      request,
      api.mark(docId!, {
        page: pageNo,
        ...box,
        text: label,
      })
    );

    const rows = await suggestionsViaApi(request, caseId);
    const man = rows.find((r) => r.text === label);
    expect(man, "manual mark appears in case suggestions").toBeTruthy();
    expect(man!.document_id).toBe(docId);
    assertValidBbox(man!.bbox as Bbox, "manual bbox");
    assertValidScreen(man!.screen as ScreenBox, "manual screen");

    // PDF coords round-trip (allow float noise)
    const b = man!.bbox as Bbox;
    expect(Math.abs(b.x0 - box.x0)).toBeLessThan(0.01);
    expect(Math.abs(b.y0 - box.y0)).toBeLessThan(0.01);
    expect(Math.abs(b.x1 - box.x1)).toBeLessThan(0.01);
    expect(Math.abs(b.y1 - box.y1)).toBeLessThan(0.01);

    await page.goto(`/documents/${docId}`);
    const scale = Number(
      await page.locator("body").getAttribute("data-scale")
    );
    assertScreenMatchesBbox(b, man!.screen as ScreenBox, scale);

    const mark = page.locator(`.mark[data-id='${man!.id}']`);
    await expect(mark).toBeVisible();
    await expect(mark).toHaveAttribute("data-status", "accepted");
  });
});

function numCss(n: number): string {
  // Duck may emit 10.28 or 10.280000; template uses round(..., 2).
  return String(Number(n.toFixed(2)));
}

function escapeRe(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

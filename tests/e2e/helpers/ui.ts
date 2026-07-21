import { Page, expect } from "@playwright/test";

/**
 * SSR seeds live under #ssr-seed[hidden], so `#q-list .sugg` matches hidden
 * nodes first. Playwright waitForSelector(visible) then waits forever on that
 * first match. Hydration is attach-based: residual render finishes
 * (window.__review) and #triage-loading is gone.
 */
export async function waitForQueueHydrated(page: Page, timeout = 30_000) {
  await page.waitForFunction(
    () => {
      const w = window as Window & { __review?: unknown };
      if (!w.__review) return false;
      const list = document.querySelector("#q-list");
      if (!list) return false;
      if (list.querySelector("#triage-loading")) return false;
      const live = Array.from(list.querySelectorAll(".sugg[data-id]")).filter(
        (el) => !el.closest("#ssr-seed")
      );
      if (live.length > 0) return true;
      if (list.querySelector(".rg")) return true;
      const empty = list.querySelector(".empty-q");
      return !!empty && empty.id !== "triage-loading";
    },
    { timeout }
  );
}

export async function openDocument(
  page: Page,
  docId: string | number,
  pageNo = 1
) {
  const path =
    pageNo <= 1 ? `/documents/${docId}` : `/documents/${docId}/pages/${pageNo}`;
  await page.goto(path, { waitUntil: "domcontentloaded" });
  await expect(page.locator("body")).toHaveAttribute("data-doc-id", String(docId), {
    timeout: 20_000,
  });
  await waitForQueueHydrated(page);
  await page
    .evaluate(() => {
      const h = (window as Window & { __history?: { close?: () => void } })
        .__history;
      if (h && typeof h.close === "function") h.close();
    })
    .catch(() => {});
}

/** Open case library; caseId is required (resolve via firstCaseId in the spec). */
export async function openCaseLibrary(page: Page, caseId: string | number) {
  await page.goto(`/cases/${caseId}`, { waitUntil: "domcontentloaded" });
  await expect(page.locator("#doc-table")).toBeVisible({ timeout: 20_000 });
}

/** Live residual/queue rows only (exclude hidden SSR seed). */
export function queueRows(page: Page) {
  return page.locator("#q-list .rg .sugg[data-id], #q-list > .sugg[data-id]");
}

/** Raw data-id string (uuids or numeric ids); do not Number()-coerce. */
export async function currentSuggestionId(page: Page): Promise<string | null> {
  const cur = page
    .locator("#q-list .rg .sugg.current, #q-list > .sugg.current")
    .first();
  if ((await cur.count()) === 0) return null;
  const id = await cur.getAttribute("data-id");
  return id || null;
}

/** Press a review-workspace key (j/k/a/r/…) with focus outside inputs. */
export async function pressReviewKey(page: Page, key: string) {
  const focusTarget = page.locator("#stage, #kbd-legend, main").first();
  await focusTarget
    .click({ position: { x: 4, y: 4 }, force: true })
    .catch(async () => {
      await page.locator("body").click({ position: { x: 8, y: 8 }, force: true });
    });
  await page.keyboard.press(key);
}

/**
 * Open a document from the case library by data-doc-id.
 * Tolerates `a.btn` / `a.btn.small` / filename link markup drift.
 */
export async function openDocFromLibrary(page: Page, docId: string | number) {
  const row = page.locator(`#doc-table tr[data-doc-id="${docId}"]`);
  await expect(row).toBeVisible({ timeout: 15_000 });
  const openBtn = row
    .locator(`a.btn[href="/documents/${docId}"], a[href="/documents/${docId}"]`)
    .first();
  await expect(openBtn).toBeVisible();
  await openBtn.click();
  await expect(page).toHaveURL(new RegExp(`/documents/${docId}`));
  await expect(page.locator("body")).toHaveAttribute("data-doc-id", String(docId), {
    timeout: 20_000,
  });
  await waitForQueueHydrated(page);
}

/** Flexible locator for a judge panel surface (wave-2 UI). */
export function judgePanelLocator(page: Page) {
  return page.locator(
    [
      "#judge-panel",
      "#judge-why-card",
      ".judge-why-card",
      ".judge-panel",
      ".judge-chip",
      ".judge-badge",
      "[data-role='judge-panel']",
      "[data-panel-signal]",
    ].join(", ")
  );
}

/** Flexible locator for residual / possible-missed queue (wave-2 UI). */
export function missedQueueLocator(page: Page) {
  return page.locator(
    [
      "#remainder-panel",
      "#rm-list",
      ".rm-panel",
      ".rm-list",
      "#missed-list",
      "#missed-queue",
      "[data-role='missed-queue']",
      "[data-role='residual']",
    ].join(", ")
  );
}

/** Flexible locator for provenance / chain-of-custody panel (wave-2 UI). */
export function provenancePanelLocator(page: Page) {
  return page.locator(
    [
      "#chain-of-custody",
      "#provenance-panel",
      "#custody-panel",
      ".coc-card",
      "[data-role='provenance']",
      "[data-role='custody']",
    ].join(", ")
  );
}

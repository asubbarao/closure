import { Page, expect } from "@playwright/test";

export async function openDocument(page: Page, docId: number, pageNo = 1) {
  const path =
    pageNo <= 1 ? `/documents/${docId}` : `/documents/${docId}/pages/${pageNo}`;
  await page.goto(path, { waitUntil: "domcontentloaded" });
  await expect(page.locator("body")).toHaveAttribute("data-doc-id", String(docId), {
    timeout: 20_000,
  });
  // review.js hydrates queue from DOM then /api — wait for either real rows or empty state
  await page.waitForSelector("#q-list .sugg, #q-list .empty-q", { timeout: 20_000 });
}

export async function openCaseLibrary(page: Page, caseId = 1) {
  await page.goto(`/cases/${caseId}`, { waitUntil: "domcontentloaded" });
  await expect(page.locator("#doc-table")).toBeVisible({ timeout: 20_000 });
}

export async function queueRows(page: Page) {
  return page.locator("#q-list .sugg[data-id]");
}

export async function currentSuggestionId(page: Page): Promise<number | null> {
  const cur = page.locator("#q-list .sugg.current").first();
  if ((await cur.count()) === 0) return null;
  const id = await cur.getAttribute("data-id");
  return id ? Number(id) : null;
}

export async function waitForQueueHydrated(page: Page) {
  // After live fetch, window.__review may be exposed
  await page.waitForFunction(() => {
    const list = document.querySelectorAll("#q-list .sugg[data-id]");
    const empty = document.querySelector("#q-list .empty-q");
    return list.length > 0 || !!empty;
  });
}

/** Press a review-workspace key (j/k/a/r/…) with focus outside inputs. */
export async function pressReviewKey(page: Page, key: string) {
  await page.locator("body").click({ position: { x: 8, y: 8 }, force: true }).catch(() => {});
  await page.keyboard.press(key);
}

/**
 * Open a document from the case library by data-doc-id.
 * Tolerates `a.btn` / `a.btn.small` / filename link markup drift.
 */
export async function openDocFromLibrary(page: Page, docId: number) {
  const row = page.locator(`#doc-table tr[data-doc-id="${docId}"]`);
  await expect(row).toBeVisible({ timeout: 15_000 });
  const openBtn = row.locator(`a.btn[href="/documents/${docId}"], a[href="/documents/${docId}"]`).first();
  await expect(openBtn).toBeVisible();
  await openBtn.click();
  await expect(page).toHaveURL(new RegExp(`/documents/${docId}`));
  await waitForQueueHydrated(page);
  await expect(page.locator("body")).toHaveAttribute("data-doc-id", String(docId));
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

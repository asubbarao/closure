import { expect, type APIRequestContext, type Page } from "@playwright/test";

/** Paths match server/routes.sql product + catalog surface. */

/** PDF page space — first-class bbox type on the mark grain. */
export type Bbox = {
  x0: number;
  y0: number;
  x1: number;
  y1: number;
};

/** Canvas screen_box (x,y,w,h) → CSS left/top/width/height. */
export type ScreenBox = {
  x: number;
  y: number;
  w: number;
  h: number;
};

export type Suggestion = {
  id: string;
  status: string;
  band: string;
  document_id: string;
  page_no?: number;
  text: string;
  entity_id: string | null;
  bbox?: Bbox;
  screen?: ScreenBox;
  confidence?: number;
};

export function assertValidBbox(b: Bbox, label = "bbox") {
  for (const k of ["x0", "y0", "x1", "y1"] as const) {
    expect(typeof b[k], `${label}.${k} number`).toBe("number");
    expect(Number.isFinite(b[k]), `${label}.${k} finite`).toBeTruthy();
  }
  expect(b.x1, `${label} x1 >= x0`).toBeGreaterThanOrEqual(b.x0);
  expect(b.y1, `${label} y1 >= y0`).toBeGreaterThanOrEqual(b.y0);
}

export function assertValidScreen(s: ScreenBox, label = "screen") {
  for (const k of ["x", "y", "w", "h"] as const) {
    expect(typeof s[k], `${label}.${k} number`).toBe("number");
    expect(Number.isFinite(s[k]), `${label}.${k} finite`).toBeTruthy();
  }
  expect(s.w, `${label}.w > 0`).toBeGreaterThan(0);
  expect(s.h, `${label}.h > 0`).toBeGreaterThan(0);
  expect(s.x, `${label}.x >= 0`).toBeGreaterThanOrEqual(0);
  expect(s.y, `${label}.y >= 0`).toBeGreaterThanOrEqual(0);
}

/** screen should be bbox × scale (top-left, no y-flip). */
export function assertScreenMatchesBbox(
  b: Bbox,
  s: ScreenBox,
  scale: number,
  tol = 1.5
) {
  expect(Math.abs(s.x - b.x0 * scale)).toBeLessThanOrEqual(tol);
  expect(Math.abs(s.y - b.y0 * scale)).toBeLessThanOrEqual(tol);
  expect(Math.abs(s.w - (b.x1 - b.x0) * scale)).toBeLessThanOrEqual(tol);
  expect(Math.abs(s.h - (b.y1 - b.y0) * scale)).toBeLessThanOrEqual(tol);
}

export async function openLibrary(page: Page) {
  await page.goto("/");
  await expect(page.locator("body[data-case-id]")).toBeVisible();
  const caseId = await page.locator("body").getAttribute("data-case-id");
  expect(caseId).toBeTruthy();
  return caseId as string;
}

export async function docHrefs(page: Page) {
  const links = page.locator('table a.btn[href^="/documents/"]');
  await expect(links.first()).toBeVisible();
  const n = await links.count();
  const hrefs: string[] = [];
  for (let i = 0; i < n; i++) {
    const h = await links.nth(i).getAttribute("href");
    if (h) hrefs.push(h);
  }
  return hrefs;
}

export async function firstDocHref(page: Page) {
  const hrefs = await docHrefs(page);
  expect(hrefs.length).toBeGreaterThan(0);
  return hrefs[0];
}

export async function postDecision(request: APIRequestContext, path: string) {
  const res = await request.post(path, {
    headers: {
      Accept: "application/json",
      "Content-Type": "application/json",
    },
    data: {},
  });
  expect(res.ok(), `POST ${path} → ${res.status()}`).toBeTruthy();
  return res;
}

export async function getNav(request: APIRequestContext, caseId: string) {
  const res = await request.get(`/api/cases/${caseId}/nav`);
  expect(res.ok()).toBeTruthy();
  return res.json();
}

/** Catalog rows — allowlisted relation open. */
export async function catalogRows(request: APIRequestContext, relation: string) {
  const res = await request.get(
    `/api/catalog/${encodeURIComponent(relation)}/rows`
  );
  expect(res.ok(), `catalog rows ${relation} → ${res.status()}`).toBeTruthy();
  return res.json();
}

export async function suggestionsViaApi(
  request: APIRequestContext,
  caseId?: string
) {
  if (caseId) {
    const res = await request.get(`/api/cases/${caseId}/suggestions`);
    expect(res.ok(), `case suggestions → ${res.status()}`).toBeTruthy();
    return res.json() as Promise<Suggestion[]>;
  }
  return catalogRows(request, "v_suggestions") as Promise<Suggestion[]>;
}

/** First entity with pending non-flagged suggestions (grain, not UI order). */
export async function entityWithPendingWork(
  request: APIRequestContext,
  caseId: string
) {
  const rows = await suggestionsViaApi(request, caseId);
  const hit = rows.find(
    (r) =>
      r.status === "pending" &&
      r.band !== "flagged" &&
      r.entity_id
  );
  return hit?.entity_id ?? null;
}

export async function documentsViaApi(request: APIRequestContext) {
  return catalogRows(request, "documents") as Promise<
    Array<{ id: string; case_id: string; filename: string }>
  >;
}

export function caseDocIds(
  docs: Array<{ id: string; case_id: string }>,
  caseId: string
) {
  return new Set(docs.filter((d) => d.case_id === caseId).map((d) => d.id));
}

export function pending(
  rows: Suggestion[],
  pred: (r: Suggestion) => boolean = () => true
) {
  return rows.filter((r) => r.status === "pending" && pred(r));
}

export function nPending(
  rows: Suggestion[],
  pred: (r: Suggestion) => boolean = () => true
) {
  return pending(rows, pred).length;
}

/** Product write URLs (mirror app.js). */
export const api = {
  decide: (id: string, status: string, actor = "e2e") =>
    `/api/suggestions/${encodeURIComponent(id)}/decision?status=${status}&actor=${actor}`,
  entity: (id: string, status: string, actor = "e2e") =>
    `/api/entities/${encodeURIComponent(id)}/decision?status=${status}&actor=${actor}`,
  band: (docId: string, band: string, status: string, actor = "e2e") =>
    `/api/documents/${encodeURIComponent(docId)}/bands/${encodeURIComponent(band)}/decision?status=${status}&actor=${actor}`,
  acceptHigh: (caseId: string, actor = "e2e") =>
    `/api/cases/${encodeURIComponent(caseId)}/accept-high?threshold=90&actor=${actor}`,
  undo: (caseId: string, actor = "e2e") =>
    `/api/cases/${encodeURIComponent(caseId)}/undo?actor=${actor}`,
  export: (caseId: string) =>
    `/api/cases/${encodeURIComponent(caseId)}/export`,
  flaggedBulk: (caseId: string, status: string, actor = "e2e") =>
    `/api/cases/${encodeURIComponent(caseId)}/flagged/decision?status=${status}&actor=${actor}`,
  docFlaggedBulk: (docId: string, status: string, actor = "e2e") =>
    `/api/documents/${encodeURIComponent(docId)}/flagged/decision?status=${status}&actor=${actor}`,
  remainderBulk: (caseId: string, status: string, actor = "e2e") =>
    `/api/cases/${encodeURIComponent(caseId)}/remainder/decision?status=${status}&actor=${actor}`,
  entityWork: (caseId: string) =>
    `/api/cases/${encodeURIComponent(caseId)}/entity-work`,
  batches: (caseId: string) =>
    `/api/cases/${encodeURIComponent(caseId)}/batches`,
  mark: (
    docId: string,
    q: {
      page: number;
      x0: number;
      y0: number;
      x1: number;
      y1: number;
      text: string;
      actor?: string;
    }
  ) => {
    const p = new URLSearchParams({
      page: String(q.page),
      x0: String(q.x0),
      y0: String(q.y0),
      x1: String(q.x1),
      y1: String(q.y1),
      text: q.text,
      actor: q.actor ?? "e2e",
    });
    return `/api/documents/${encodeURIComponent(docId)}/marks?${p}`;
  },
};

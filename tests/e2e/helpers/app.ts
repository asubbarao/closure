import { expect, type APIRequestContext, type Page } from "@playwright/test";

/** Thin-stack helpers: SSR pages + POST mutations. No SPA locators. */

export async function openLibrary(page: Page) {
  await page.goto("/");
  await expect(page.locator("body[data-case-id]")).toBeVisible();
  const caseId = await page.locator("body").getAttribute("data-case-id");
  expect(caseId).toBeTruthy();
  return caseId as string;
}

export async function openStream(page: Page, caseId: string) {
  await page.goto(`/cases/${caseId}/stream`);
  await expect(page.locator("body[data-case-id]")).toHaveAttribute(
    "data-case-id",
    caseId
  );
}

export async function openAudit(page: Page, caseId: string) {
  await page.goto(`/cases/${caseId}/audit`);
  await expect(page.locator("strong").filter({ hasText: /Audit/ })).toBeVisible();
}

/** First document id from library table Open link. */
export async function firstDocHref(page: Page) {
  const open = page.locator('table a.btn[href^="/documents/"]').first();
  await expect(open).toBeVisible();
  const href = await open.getAttribute("href");
  expect(href).toMatch(/^\/documents\//);
  return href as string;
}

/** POST decision APIs the way app.js does (query params + empty JSON body). */
export async function postDecision(
  request: APIRequestContext,
  path: string
) {
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

/** Pull suggestion rows via allowlisted relation open (DB-as-server). */
export async function suggestionsViaApi(request: APIRequestContext) {
  const res = await request.get("/api/rel/v_suggestions");
  expect(res.ok(), `api/rel/v_suggestions → ${res.status()}`).toBeTruthy();
  return res.json() as Promise<
    Array<{
      id: string;
      status: string;
      band: string;
      document_id: string;
      text: string;
      entity_id: string | null;
    }>
  >;
}

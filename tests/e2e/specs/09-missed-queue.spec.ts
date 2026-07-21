import { test, expect } from "@playwright/test";
import {
  getCaseDocuments,
  getDocMissed,
  getDocSuggestions,
  pickReviewDoc,
} from "../helpers/api";

/**
 * Residual / missed queue — API only (UI one-tap overlaps add-missed specs).
 */
test.describe("9. Possible missed redactions queue", () => {
  test("GET /api/documents/:id/missed lists residual candidates (or empty array)", async ({
    request,
  }) => {
    const docs = await getCaseDocuments(request);
    test.skip(docs.length === 0, "no documents in case");

    const probe = await getDocMissed(request, docs[0].id);
    if (!probe.live) {
      test.skip(true, "route /api/documents/:id/missed not live (404)");
    }

    const body = probe.body;
    const rows = Array.isArray(body)
      ? body
      : body && typeof body === "object" && Array.isArray((body as { rows?: unknown }).rows)
        ? (body as { rows: unknown[] }).rows
        : body && typeof body === "object" && Array.isArray((body as { missed?: unknown }).missed)
          ? (body as { missed: unknown[] }).missed
          : null;

    expect(rows, "missed payload should be an array (possibly empty)").not.toBeNull();
    expect(Array.isArray(rows)).toBeTruthy();
  });

  test("one-tap style POST add promotes missed candidate when any exist", async ({
    request,
  }) => {
    const docs = await getCaseDocuments(request);
    test.skip(docs.length === 0, "no documents");

    let candidate: Record<string, unknown> | null = null;
    let docId: string | number | null = null;
    for (const d of docs.slice(0, 5)) {
      const probe = await getDocMissed(request, d.id);
      if (!probe.live) continue;
      const body = probe.body;
      const rows = Array.isArray(body)
        ? body
        : body && typeof body === "object"
          ? ((body as { rows?: unknown[]; missed?: unknown[] }).rows ||
              (body as { missed?: unknown[] }).missed ||
              [])
          : [];
      if (Array.isArray(rows) && rows.length > 0) {
        candidate = rows[0] as Record<string, unknown>;
        docId = d.id;
        break;
      }
    }
    test.skip(!candidate || docId == null, "no residual candidates to promote");

    const before = await getDocSuggestions(request, docId!);
    const beforeN = before.length;

    // Integer coords + query-string params (quackapi rejects float form bodies → 422)
    const x0 = Math.floor(Number(candidate!.x0 ?? 10));
    const y0 = Math.floor(Number(candidate!.y0 ?? 10));
    const x1 = Math.floor(Number(candidate!.x1 ?? x0 + 40));
    const y1 = Math.floor(Number(candidate!.y1 ?? y0 + 12));
    const page = Math.floor(Number(candidate!.page_no ?? candidate!.page ?? 1));
    const text = String(candidate!.text ?? `missed-e2e-${Date.now()}`);

    const qs = new URLSearchParams({
      page: String(page),
      x0: String(x0),
      y0: String(y0),
      x1: String(x1),
      y1: String(y1),
      text,
      kind: "PERSON",
      scope: "one",
      actor: "e2e",
      reason: "missed-queue-promote",
    });
    const res = await request.post(`/api/documents/${docId}/add?${qs}`, {
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      data: {},
    });
    expect(res.ok(), `POST add → ${res.status()}`).toBeTruthy();

    await expect
      .poll(async () => {
        const after = await getDocSuggestions(request, docId!);
        return after.some((s) => s.text === text && s.status === "accepted")
          ? "ok"
          : `n=${after.length}/before=${beforeN}`;
      }, { timeout: 15_000 })
      .toBe("ok");
  });
});


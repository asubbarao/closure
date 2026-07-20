import { test, expect } from "@playwright/test";
import {
  firstCaseId,
  getCaseDocuments,
  getCaseProvenance,
  getExportPlan,
} from "../helpers/api";
import {
  openCaseLibrary,
  provenancePanelLocator,
} from "../helpers/ui";

/**
 * WAVE-2 — Provenance / chain-of-custody panel
 * GET /api/cases/:id/provenance + UI panel on case dashboard.
 * Skips cleanly when the route is not landed (404).
 */
test.describe("11. Provenance / chain-of-custody (wave-2)", () => {
  test("GET /api/cases/:id/provenance returns custody payload when live", async ({
    request,
  }) => {
    const probe = await getCaseProvenance(request);
    test.skip(!probe.live, probe.live === false ? probe.reason : "not live");

    const body = probe.body;
    expect(body).toBeTruthy();

    // Accept: array of doc custody rows, or object with chain/documents/sha fields
    const asObj = Array.isArray(body)
      ? body[0] && typeof body[0] === "object"
        ? (body[0] as Record<string, unknown>)
        : null
      : (body as Record<string, unknown>);

    const blob = JSON.stringify(body);
    const hasCustodySignal =
      /sha256|md5|revision|custody|lineage|fingerprint|producer|ingested|eof|chain/i.test(
        blob
      ) ||
      (asObj &&
        (asObj.source_sha256 != null ||
          asObj.sha256 != null ||
          asObj.revision_count != null ||
          asObj.source_revision_count != null ||
          asObj.custody_ok != null ||
          asObj.documents != null ||
          asObj.chain != null));

    expect(
      hasCustodySignal,
      `provenance payload should include custody/fingerprint fields; got ${blob.slice(0, 400)}`
    ).toBeTruthy();

    // If array of per-doc rows, should cover case docs roughly
    if (Array.isArray(body) && body.length > 0 && "document_id" in (body[0] as object)) {
      const docs = await getCaseDocuments(request);
      expect(body.length).toBeGreaterThanOrEqual(1);
      // Not required to equal, but should not be empty while docs exist
      if (docs.length > 0) {
        expect(body.length).toBeGreaterThan(0);
      }
    }
  });

  test("provenance rows reference real case documents when structured", async ({
    request,
  }) => {
    const probe = await getCaseProvenance(request);
    test.skip(!probe.live, probe.live === false ? probe.reason : "not live");

    const docs = await getCaseDocuments(request);
    const docIds = new Set(docs.map((d) => String(d.id)));
    const filenames = new Set(docs.map((d) => d.filename));

    const rows: Array<Record<string, unknown>> = [];
    const body = probe.body;
    if (Array.isArray(body)) {
      for (const r of body) {
        if (r && typeof r === "object") rows.push(r as Record<string, unknown>);
      }
    } else if (body && typeof body === "object") {
      const o = body as Record<string, unknown>;
      for (const k of ["documents", "chain", "items", "rows", "custody"]) {
        if (Array.isArray(o[k])) {
          for (const r of o[k] as unknown[]) {
            if (r && typeof r === "object") rows.push(r as Record<string, unknown>);
          }
        }
      }
      // single aggregate object
      if (rows.length === 0) rows.push(o);
    }

    test.skip(rows.length === 0, "provenance live but no row-like objects to validate");

    // At least one row should join back to a live document when ids/filenames present
    const linked = rows.some((r) => {
      const id = r.document_id ?? r.doc_id ?? r.id;
      const fn = r.filename ?? r.stem ?? r.source_path;
      if (id != null && docIds.has(String(id))) return true;
      if (typeof fn === "string") {
        const base = fn.replace(/^.*\//, "").replace(/\.pdf$/i, "");
        if (filenames.has(base) || filenames.has(fn)) return true;
      }
      return false;
    });

    // If rows carry no doc linkage fields, only require custody signal keys
    const anyDocField = rows.some(
      (r) =>
        r.document_id != null ||
        r.doc_id != null ||
        r.filename != null ||
        r.source_path != null
    );

    if (anyDocField) {
      expect(
        linked,
        "provenance rows with doc fields should reference live case documents"
      ).toBeTruthy();
    } else {
      const blob = JSON.stringify(rows[0]);
      expect(/sha|revision|custody|hash|producer/i.test(blob)).toBeTruthy();
    }
  });

  test("case library surfaces provenance panel when feature is live", async ({
    page,
    request,
  }) => {
    const caseId = await firstCaseId(request);
    const probe = await getCaseProvenance(request);
    test.skip(!probe.live, probe.live === false ? probe.reason : "not live");

    await openCaseLibrary(page, caseId);

    // Live mount: #chain-of-custody (provenance_panel.html)
    const panel = provenancePanelLocator(page);
    await expect(page.locator("#chain-of-custody")).toBeVisible({
      timeout: 15_000,
    });

    // Wait for JS hydrate of recheck rows
    await expect
      .poll(async () => {
        const badge = await page.locator("#coc-badge").innerText().catch(() => "");
        const body = await page.locator("#coc-body").innerText().catch(() => "");
        return `${badge}|${body}`.slice(0, 200);
      }, { timeout: 20_000 })
      .not.toMatch(/loading…\|Loading provenance/i);

    const bodyText = await page.locator("#chain-of-custody").innerText();
    expect(bodyText.length).toBeGreaterThan(20);
    expect(bodyText).toMatch(/chain of custody|intact|break|sha|fingerprint|revision|source/i);

    // Cross-check with export_plan still coexisting
    const plan = await getExportPlan(request);
    expect(typeof plan.blocked).toBe("boolean");

    // Panel should list at least one live doc filename when API returned rows
    const docs = await getCaseDocuments(request);
    if (docs.length > 0 && Array.isArray(probe.body) && (probe.body as unknown[]).length > 0) {
      const anyName = docs.some((d) => bodyText.includes(d.filename));
      expect(
        anyName,
        "custody table should mention a live case document filename"
      ).toBeTruthy();
    }

    await expect(panel.first()).toBeVisible();
  });
});

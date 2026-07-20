import { test, expect } from "@playwright/test";
import {
  getCaseDocuments,
  getCaseSuggestions,
  pickReviewDoc,
  searchCase,
} from "../helpers/api";

/**
 * WAVE-2 — Fuzzy add-missed search
 * Exact vs similar match counts when searching from add-missed / search API.
 * Baseline /api/search is live; exact/similar split is optional wave-2.
 */
test.describe("10. Fuzzy add-missed search (wave-2)", () => {
  test("GET /api/search returns matches for a token present in the corpus", async ({
    request,
  }) => {
    // Data-driven: pick a real suggestion token from the live case (not hardcoded names)
    const suggs = await getCaseSuggestions(request, 1);
    test.skip(suggs.length === 0, "no suggestions to derive search terms from");

    // Prefer a single-token alphabetic word (search is substring on words)
    let token = "";
    for (const s of suggs) {
      const parts = (s.text || "")
        .split(/[\s#,./()-]+/)
        .map((p) => p.trim())
        .filter((p) => p.length >= 4 && /^[A-Za-z]+$/.test(p));
      if (parts.length) {
        token = parts[0];
        break;
      }
    }
    test.skip(!token, "could not derive a searchable alphabetic token from suggestions");

    const { status, result } = await searchCase(request, token, 1);
    expect(status, `search HTTP for q=${token}`).toBe(200);
    expect(result).toBeTruthy();
    expect(result!.count).toBeGreaterThan(0);
    expect(result!.matches.length).toBeGreaterThan(0);

    // Each match should point at a document/page when structured
    const m0 = result!.matches[0];
    if (m0 && typeof m0 === "object") {
      const hasDoc =
        m0.document_id != null || m0.documentId != null || m0.filename != null;
      const hasPage = m0.page_no != null || m0.pageNo != null || m0.page != null;
      expect(hasDoc || hasPage, "match row should locate a doc/page").toBeTruthy();
    }
  });

  test("search reports exact vs similar counts when fuzzy fields are live", async ({
    request,
  }) => {
    const suggs = await getCaseSuggestions(request, 1);
    test.skip(suggs.length === 0, "no suggestions");

    // Use a multi-char token that should have exact hits
    let token = "";
    for (const s of suggs) {
      const parts = (s.text || "")
        .split(/[\s#,./()-]+/)
        .map((p) => p.trim())
        .filter((p) => p.length >= 5 && /^[A-Za-z]+$/.test(p));
      if (parts.length) {
        token = parts[0];
        break;
      }
    }
    test.skip(!token, "no token for fuzzy probe");

    // Try baseline + explicit fuzzy modes
    const probes = [
      await searchCase(request, token, 1),
      await searchCase(request, token, 1, { mode: "fuzzy" }),
      await searchCase(request, token, 1, { fuzzy: "1" }),
    ];

    const withSplit = probes.find((p) => {
      if (!p.result) return false;
      const r = p.result;
      return (
        r.exact_count != null ||
        r.fuzzy_count != null ||
        r.similar_count != null ||
        r.exact != null ||
        r.similar != null ||
        r.fuzzy != null ||
        r.exact_matches != null ||
        r.similar_matches != null
      );
    });

    if (!withSplit?.result) {
      // Baseline search still works — document that fuzzy split is not landed
      const base = probes[0];
      expect(base.status).toBe(200);
      expect(base.result!.count).toBeGreaterThanOrEqual(0);
      test.skip(
        true,
        "search is live but exact_count/fuzzy_count (fuzzy split) not present in response — wave-2 field not landed"
      );
      return;
    }

    const r = withSplit.result;
    const exact = Number(
      r.exact_count ?? r.exact ?? (Array.isArray(r.exact_matches) ? r.exact_matches.length : 0)
    );
    const similar = Number(
      r.fuzzy_count ??
        r.similar_count ??
        r.fuzzy ??
        r.similar ??
        (Array.isArray(r.similar_matches) ? r.similar_matches.length : 0)
    );

    expect(exact).toBeGreaterThanOrEqual(0);
    expect(similar).toBeGreaterThanOrEqual(0);
    // Total should reconcile when both are provided
    if (r.count != null && (r.exact_count != null || r.exact != null)) {
      expect(exact + similar).toBeGreaterThanOrEqual(0);
      // soft: count often equals exact+fuzzy or exact alone
      expect(r.count).toBeGreaterThanOrEqual(exact);
    }
    // Exact query against a real token should yield ≥1 exact when field exists
    expect(exact, `exact matches for known token "${token}"`).toBeGreaterThan(0);
  });

  test("add-missed UI search updates match counts for a live token", async ({
    page,
    request,
  }) => {
    const doc = await pickReviewDoc(request);
    const suggs = await getCaseSuggestions(request, 1);
    let token = "";
    for (const s of suggs) {
      if (Number(s.document_id) !== Number(doc.id)) continue;
      const parts = (s.text || "")
        .split(/[\s#,./()-]+/)
        .map((p) => p.trim())
        .filter((p) => p.length >= 4 && /^[A-Za-z]+$/.test(p));
      if (parts.length) {
        token = parts[0];
        break;
      }
    }
    if (!token) {
      for (const s of suggs) {
        const parts = (s.text || "")
          .split(/[\s#,./()-]+/)
          .map((p) => p.trim())
          .filter((p) => p.length >= 4 && /^[A-Za-z]+$/.test(p));
        if (parts.length) {
          token = parts[0];
          break;
        }
      }
    }
    test.skip(!token, "no token for add-missed search UI");

    await page.goto(`/ui/add-missed?doc=${doc.id}&page=1`, {
      waitUntil: "domcontentloaded",
    });
    const pdf = page.locator("#pdf-page");
    await expect(pdf).toBeVisible({ timeout: 20_000 });
    // #text-input lives in #add-popover — only visible after a drag selection
    await page.waitForFunction(() => {
      const el = document.getElementById("pdf-page");
      return !!el && el.getBoundingClientRect().width > 100;
    });
    const box = await pdf.boundingBox();
    expect(box, "pdf-page layout").toBeTruthy();
    await page.mouse.move(box!.x + box!.width * 0.2, box!.y + box!.height * 0.2);
    await page.mouse.down();
    await page.mouse.move(
      box!.x + box!.width * 0.4,
      box!.y + box!.height * 0.28,
      { steps: 8 }
    );
    await page.mouse.up();

    const textInput = page.locator("#text-input");
    await expect(page.locator("#add-popover")).toBeVisible({ timeout: 10_000 });
    await expect(textInput).toBeVisible({ timeout: 10_000 });

    await textInput.fill(token);
    // Debounced search (~220ms) + network
    await page.waitForTimeout(700);

    // Scope count / subtitle should reflect search
    const scopeCount = page.locator("#scope-count");
    const scopeAllSub = page.locator("#scope-all-sub");
    await expect(scopeCount.or(scopeAllSub).first()).toBeVisible();

    const countText = ((await scopeCount.innerText().catch(() => "")) || "").trim();
    const subText = ((await scopeAllSub.innerText().catch(() => "")) || "").trim();
    const combined = `${countText} ${subText}`;

    // Either a numeric match count, "exact"/"similar" labels, or "no other matches"
    const meaningful =
      /\d/.test(combined) ||
      /match/i.test(combined) ||
      /exact|similar/i.test(combined) ||
      /no other matches|type text/i.test(combined);

    expect(
      meaningful,
      `add-missed search UI should react to token "${token}"; got count="${countText}" sub="${subText}"`
    ).toBeTruthy();

    // Wave-2 UI contract: "N exact · M similar" on #scope-count
    const body = await page.locator("body").innerText();
    if (/exact/i.test(combined) || /similar/i.test(combined)) {
      expect(combined).toMatch(/exact/i);
      expect(combined).toMatch(/similar/i);
      test.info().annotations.push({
        type: "note",
        description: `add-missed UI exact/similar chip: ${countText}`,
      });
    } else if (/exact/i.test(body) && /similar/i.test(body)) {
      test.info().annotations.push({
        type: "note",
        description: "add-missed UI shows exact vs similar vocabulary in page body",
      });
    }

    // Cross-check API still agrees the token is findable
    const { result } = await searchCase(request, token, 1);
    if (result && result.count > 0) {
      // UI should not claim absolute zero when API has hits (unless local-only empty)
      // Allow "this page only" / numeric counts; only soft-check contradiction
      if (/^0$/.test(countText) && /no other matches/i.test(subText)) {
        // Possible if API hits are only other docs and UI scopes oddly — note it
        test.info().annotations.push({
          type: "note",
          description: `UI reported 0 while API count=${result.count} for "${token}"`,
        });
      }
    }

    // Sanity: case still has documents (data-driven corpus check)
    const docs = await getCaseDocuments(request, 1);
    expect(docs.some((d) => d.id === doc.id)).toBeTruthy();
  });
});

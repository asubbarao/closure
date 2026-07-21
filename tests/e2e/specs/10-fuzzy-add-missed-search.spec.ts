import { test, expect } from "@playwright/test";
import { getCaseSuggestions, searchCase } from "../helpers/api";

/**
 * Search API — one probe (UI search UI path was redundant).
 */
test.describe("10. Corpus search", () => {
  test("GET /api/search returns matches for a token present in the corpus", async ({
    request,
  }) => {
    const suggs = await getCaseSuggestions(request);
    test.skip(suggs.length === 0, "no suggestions to derive search terms from");

    const token =
      suggs
        .map((s) => (s.text || "").split(/\s+/))
        .flat()
        .map((p) => p.replace(/[^A-Za-z]/g, ""))
        .filter((p) => p.length >= 4)[0] || null;

    test.skip(!token, "could not derive a searchable alphabetic token");

    const { status, result } = await searchCase(request, token!);
    expect(status, `search HTTP ${status}`).toBe(200);
    expect(result).toBeTruthy();
    expect(
      (result!.count ?? 0) > 0 ||
        (result!.matches && result!.matches.length > 0),
      `expected matches for token ${token}`
    ).toBeTruthy();
  });
});

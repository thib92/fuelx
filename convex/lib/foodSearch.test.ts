import { describe, expect, test } from "vitest";
import { normalizeTerms, rankFoods, searchTextFor } from "./foodSearch";

describe("normalizeTerms", () => {
  test.each([
    ["Pâtes", ["pate"]],
    ["YAOURTS nature", ["yaourt", "nature"]],
    ["choux", ["chou"]],
    ["riz", ["riz"]],
  ])("normalises %s", (input, want) => {
    expect(normalizeTerms(input)).toEqual(want);
  });

  test("both spellings of a ligature give the same term", () => {
    expect(normalizeTerms("bœuf")).toEqual(normalizeTerms("boeuf"));
  });

  test("returns nothing for punctuation", () => {
    expect(normalizeTerms("!!! ...")).toEqual([]);
  });

  test("keeps 16 terms at most", () => {
    const query = Array.from({ length: 30 }, (_, i) => `mot${i}`).join(" ");
    expect(normalizeTerms(query)).toHaveLength(16);
  });
});

describe("searchTextFor", () => {
  test("joins name, English name and brand", () => {
    expect(
      searchTextFor({ name: "Filets de poulet", nameEn: "Chicken breast", brand: "Herta" }),
    ).toBe("filet de poulet chicken breast herta");
  });

  test("the 16-term cap applies to queries, not stored text", () => {
    const name = Array.from({ length: 30 }, (_, i) => `mot${i}`).join(" ");
    expect(searchTextFor({ name }).split(" ")).toHaveLength(30);
  });
});

describe("rankFoods", () => {
  const food = (id: string, searchText: string, offScans?: number) => ({
    _id: id,
    searchText,
    offScans,
  });

  test("ranks recents, then all-terms matches, then the rest", () => {
    const out = rankFoods(
      [food("tea", "nat form tisane"), food("yog", "yaourt nature cora"), food("rec", "yaourt fraise")],
      ["yaourt", "nat"],
      new Set(["rec"]),
    );
    expect(out.map((x) => x._id)).toEqual(["rec", "yog", "tea"]);
  });

  test("popular products rise within their group; blank counts keep their order", () => {
    const out = rankFoods(
      [food("a", "skyr"), food("b", "skyr", 5), food("c", "skyr", 20), food("d", "skyr", 1000)],
      ["skyr"],
      new Set(),
    );
    expect(out.map((x) => x._id)).toEqual(["d", "c", "a", "b"]);
  });

  test("only the last query term matches as a prefix", () => {
    const out = rankFoods(
      [food("partial", "yaourtine nature"), food("full", "yaourt nature")],
      ["yaourt", "nat"],
      new Set(),
    );
    expect(out.map((x) => x._id)).toEqual(["full", "partial"]);
  });

  test("does not change the input array", () => {
    const foods = [food("a", "skyr"), food("b", "skyr", 50)];
    rankFoods(foods, ["skyr"], new Set());
    expect(foods.map((x) => x._id)).toEqual(["a", "b"]);
  });
});

import { cleanText } from "./foodQuality";

/** Products with at least this many OFF scans rise to the top of their ranking group. */
export const POPULAR_SCANS = 20;

/** Convex search queries accept at most this many terms. */
const MAX_QUERY_TERMS = 16;
const MIN_STEMMED_LENGTH = 4;

function stems(text: string): string[] {
  return cleanText(text)
    .split(" ")
    .filter(Boolean)
    .map((token) =>
      token.length >= MIN_STEMMED_LENGTH ? token.replace(/[sx]$/, "") : token,
    );
}

/** Search terms for a user's query. Convex has no stemming or accent folding, so we do both. */
export function normalizeTerms(text: string): string[] {
  return stems(text).slice(0, MAX_QUERY_TERMS);
}

/** The text stored for search, normalised the same way as queries. */
export function searchTextFor(food: { name: string; nameEn?: string; brand?: string }): string {
  return stems([food.name, food.nameEn, food.brand].filter(Boolean).join(" ")).join(" ");
}

/** Whether every term appears, with the last one as a prefix, as in Convex search. */
function containsAllTerms(searchText: string, terms: string[]): boolean {
  const tokens = searchText.split(" ");
  const lastIndex = terms.length - 1;
  return terms.every((term, index) =>
    index === lastIndex
      ? tokens.some((token) => token.startsWith(term))
      : tokens.includes(term),
  );
}

function popularFirst<T extends { offScans?: number }>(foods: T[]): T[] {
  const isPopular = (food: T) => (food.offScans ?? 0) >= POPULAR_SCANS;
  return [
    ...foods.filter(isPopular).sort((a, b) => (b.offScans ?? 0) - (a.offScans ?? 0)),
    ...foods.filter((food) => !isPopular(food)),
  ];
}

/**
 * Orders search results: the user's recent foods, then foods containing every query term, then
 * the rest. Within a group, Convex's relevance order is kept apart from popular products.
 */
export function rankFoods<T extends { _id: string; searchText: string; offScans?: number }>(
  foods: T[],
  queryTerms: string[],
  recentIds: Set<string>,
): T[] {
  const recents: T[] = [];
  const allTerms: T[] = [];
  const rest: T[] = [];
  for (const food of foods) {
    if (recentIds.has(food._id)) recents.push(food);
    else if (containsAllTerms(food.searchText, queryTerms)) allTerms.push(food);
    else rest.push(food);
  }
  return [...popularFirst(recents), ...popularFirst(allTerms), ...popularFirst(rest)];
}

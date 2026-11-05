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

/** Whether every term appears as a whole word. */
function containsExactTerms(searchText: string, terms: string[]): boolean {
  const tokens = searchText.split(" ");
  return terms.every((term) => tokens.includes(term));
}

/** Generic foods, then popular products, then Convex's relevance order. */
function orderGroup<T extends { source?: string; offScans?: number }>(foods: T[]): T[] {
  const isGeneric = (food: T) => food.source === "ciqual";
  const isPopular = (food: T) => !isGeneric(food) && (food.offScans ?? 0) >= POPULAR_SCANS;
  return [
    ...foods.filter(isGeneric),
    ...foods.filter(isPopular).sort((a, b) => (b.offScans ?? 0) - (a.offScans ?? 0)),
    ...foods.filter((food) => !isGeneric(food) && !isPopular(food)),
  ];
}

const STARTS_WITH_TYPED = 2;
const CONTAINS_TYPED = 1;
const NO_TYPED_MATCH = 0;

/**
 * How well a name matches the words as typed, before plural stripping. Stemming merges "pâtes"
 * and "pâté", but "pates" is only a word in one of those names.
 */
function typedMatch(name: string | undefined, typedWords: string[]): number {
  if (!name || typedWords.length === 0) return NO_TYPED_MATCH;
  const words = cleanText(name).split(" ");
  if (!typedWords.every((word) => words.includes(word))) return NO_TYPED_MATCH;
  return words[0] === typedWords[0] ? STARTS_WITH_TYPED : CONTAINS_TYPED;
}

/**
 * Orders search results: the user's recent foods, then foods with every query term as a whole
 * word, then foods matching by prefix, then the rest. Inside each group, names matching the words
 * as typed come first, and `orderGroup` breaks ties.
 */
export function rankFoods<
  T extends { _id: string; searchText: string; name?: string; source?: string; offScans?: number },
>(foods: T[], queryTerms: string[], recentIds: Set<string>, query = ""): T[] {
  const typedWords = cleanText(query).split(" ").filter(Boolean);
  const orderByTypedMatch = (group: T[]) =>
    [STARTS_WITH_TYPED, CONTAINS_TYPED, NO_TYPED_MATCH].flatMap((strength) =>
      orderGroup(group.filter((food) => typedMatch(food.name, typedWords) === strength)),
    );

  const recents: T[] = [];
  const exact: T[] = [];
  const prefix: T[] = [];
  const rest: T[] = [];
  for (const food of foods) {
    if (recentIds.has(food._id)) recents.push(food);
    else if (containsExactTerms(food.searchText, queryTerms)) exact.push(food);
    else if (containsAllTerms(food.searchText, queryTerms)) prefix.push(food);
    else rest.push(food);
  }
  return [recents, exact, prefix, rest].flatMap(orderByTypedMatch);
}

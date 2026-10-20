// List prices in US dollars, per million tokens and per search call, as of
// October 2026. Google's are the full prices its launch discounts run out
// into (Argon on 1 December, Flash on 1 January), and its first 5,000
// searches a month are free.

const SEARCH = { anthropic: 10 / 1000, openai: 10 / 1000, google: 14 / 1000 };

const PRICES: Record<string, { input: number; output: number; search: number }> = {
  "claude-opus-5-5": { input: 4, output: 20, search: SEARCH.anthropic },
  "claude-sonnet-5-5": { input: 2, output: 10, search: SEARCH.anthropic },
  "claude-sonnet-5": { input: 2, output: 10, search: SEARCH.anthropic },
  "claude-haiku-5-5": { input: 0.1, output: 0.5, search: SEARCH.anthropic },
  "gpt-6-astra": { input: 10, output: 50, search: SEARCH.openai },
  "gpt-6.1-sol": { input: 2, output: 10, search: SEARCH.openai },
  "gpt-6-sol": { input: 2, output: 10, search: SEARCH.openai },
  "gpt-6-luna": { input: 0.1, output: 0.5, search: SEARCH.openai },
  "gpt-5.6-sol": { input: 4, output: 20, search: SEARCH.openai },
  "gpt-5.6-terra": { input: 2, output: 12, search: SEARCH.openai },
  "gpt-5.6-luna": { input: 0.2, output: 1.2, search: SEARCH.openai },
  "gemini-4-argon": { input: 4, output: 20, search: SEARCH.google },
  "gemini-3.8-flash": { input: 1.5, output: 7.5, search: SEARCH.google },
  "gemini-3.5-flash-lite": { input: 0.3, output: 2.5, search: SEARCH.google },
};

/// What one call cost, or null for a model missing from the table.
export function cost(
  model: string,
  usage: { input_tokens?: number; output_tokens?: number; searches?: number },
): number | null {
  const price = PRICES[model.split("@")[0]];
  if (!price) return null;
  return ((usage.input_tokens ?? 0) * price.input + (usage.output_tokens ?? 0) * price.output) / 1e6 +
    (usage.searches ?? 0) * price.search;
}

export type BudgetProfile = "quick" | "standard" | "deep" | "overnight";
export type BudgetProfileInput = BudgetProfile | "auto";
export type BudgetSource = "none" | "tokens" | "profile" | "auto";

export interface BudgetProfileConfig {
  token_budget: number;
  continuations_remaining: number;
  max_wall_clock_seconds: number;
}

export const BUDGET_PROFILES: Record<BudgetProfile, BudgetProfileConfig> = {
  quick: {
    token_budget: 500_000,
    continuations_remaining: 25,
    max_wall_clock_seconds: 3_600,
  },
  standard: {
    token_budget: 2_000_000,
    continuations_remaining: 75,
    max_wall_clock_seconds: 14_400,
  },
  deep: {
    token_budget: 5_000_000,
    continuations_remaining: 150,
    max_wall_clock_seconds: 28_800,
  },
  overnight: {
    token_budget: 20_000_000,
    continuations_remaining: 500,
    max_wall_clock_seconds: 43_200,
  },
};

export function isBudgetProfileInput(value: unknown): value is BudgetProfileInput {
  return value === "quick" || value === "standard" || value === "deep" || value === "overnight" || value === "auto";
}

export function resolveBudgetProfile(input: BudgetProfileInput, objective: string): BudgetProfile {
  if (input !== "auto") return input;

  const normalized = objective.toLowerCase();
  if (/\b(overnight|weekend|over\s+the\s+weekend|all\s+night|tomorrow\s+morning)\b/.test(normalized)) {
    return "overnight";
  }
  if (/\b(migrations?|migrate|repo\s*-?\s*wide|repository\s*-?\s*wide|redesigns?|integrations?|multi\s*-?\s*module|multi\s*-?\s*file|many files|many named files|broad|cross-cutting|large refactor|major refactor)\b/.test(normalized)) {
    return "deep";
  }
  if (/\b(feature|bug fix|bugfix|tests?|bounded|medium refactor|refactor|implement|add)\b/.test(normalized)) {
    return "standard";
  }
  return "quick";
}

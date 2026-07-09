export const PRACTICAL_UNBOUNDED_CONTINUATIONS = 1_000_000;
export const PRACTICAL_UNBOUNDED_WALL_CLOCK_SECONDS = 315_360_000; // 10 years
export const BUDGET_PROFILES = {
    quick: {
        token_budget: 2_000_000,
        continuations_remaining: 50,
        max_wall_clock_seconds: 7_200,
    },
    standard: {
        token_budget: 10_000_000,
        continuations_remaining: 200,
        max_wall_clock_seconds: 28_800,
    },
    deep: {
        token_budget: 100_000_000,
        continuations_remaining: 1_000,
        max_wall_clock_seconds: 86_400,
    },
    overnight: {
        token_budget: 1_000_000_000,
        continuations_remaining: 5_000,
        max_wall_clock_seconds: 259_200,
    },
};
export function isBudgetProfileInput(value) {
    return value === "quick" || value === "standard" || value === "deep" || value === "overnight" || value === "auto";
}
export function resolveBudgetProfile(input, objective) {
    if (input !== "auto")
        return input;
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

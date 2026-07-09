const VERDICTS = ["complete", "incomplete", "unverifiable", "impossible"];
const REASON_MAX = 1000;
const EVIDENCE_MAX_ITEMS = 20;
const EVIDENCE_ITEM_MAX = 500;
export function handleRecordVerdict(repo, args) {
    if (typeof args.session_id !== "string" || args.session_id.length === 0) {
        return { error: "session_id is required" };
    }
    if (!VERDICTS.includes(args.verdict)) {
        return { error: `verdict must be one of ${VERDICTS.join(", ")}; got '${args.verdict}'` };
    }
    if (args.reason != null && (typeof args.reason !== "string" || args.reason.length > REASON_MAX)) {
        return { error: `reason must be a string of at most ${REASON_MAX} characters` };
    }
    let evidence = null;
    if (args.evidence != null) {
        if (!Array.isArray(args.evidence) || args.evidence.some((e) => typeof e !== "string")) {
            return { error: "evidence must be an array of strings" };
        }
        if (args.evidence.length > EVIDENCE_MAX_ITEMS) {
            return { error: `evidence is limited to ${EVIDENCE_MAX_ITEMS} items (got ${args.evidence.length})` };
        }
        evidence = args.evidence.map((e) => (e.length > EVIDENCE_ITEM_MAX ? e.slice(0, EVIDENCE_ITEM_MAX) : e));
    }
    try {
        repo.recordVerdict(args.session_id, args.goal_id ?? undefined, args.verdict, args.reason ?? null, evidence);
        return { ok: true };
    }
    catch (e) {
        return { error: e.message };
    }
}

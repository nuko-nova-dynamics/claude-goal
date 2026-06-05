import { randomUUID } from "node:crypto";
import { BUDGET_PROFILES, isBudgetProfileInput, resolveBudgetProfile } from "./budget-profiles.js";
export class GoalsRepo {
    db;
    constructor(db) {
        this.db = db;
    }
    getBySession(session_id) {
        const row = this.db.prepare("SELECT * FROM goals WHERE session_id = ?").get(session_id);
        return row ?? null;
    }
    listEvents(session_id) {
        return this.db.prepare("SELECT event_type, created_at_ms FROM goal_events WHERE session_id = ? ORDER BY id").all(session_id);
    }
    create(input) {
        if (typeof input.session_id !== "string" || input.session_id.length === 0) {
            throw new Error("session_id is required");
        }
        if (typeof input.objective !== "string" || input.objective.trim().length < 1 || input.objective.length > 4000) {
            throw new Error("objective must be 1-4000 characters");
        }
        if (input.token_budget !== null && (!Number.isInteger(input.token_budget) || input.token_budget <= 0)) {
            throw new Error("token_budget must be a positive integer");
        }
        if (input.token_budget !== null && input.budget_profile !== null) {
            throw new Error("token_budget and budget_profile are mutually exclusive");
        }
        if (input.budget_profile !== null && !isBudgetProfileInput(input.budget_profile)) {
            throw new Error("budget_profile must be one of quick, standard, deep, overnight, auto");
        }
        const resolvedProfile = input.budget_profile ? resolveBudgetProfile(input.budget_profile, input.objective) : null;
        const profileConfig = resolvedProfile ? BUDGET_PROFILES[resolvedProfile] : null;
        const tokenBudget = profileConfig?.token_budget ?? input.token_budget;
        const continuationsRemaining = profileConfig?.continuations_remaining ?? 50;
        const maxWallClockSeconds = profileConfig?.max_wall_clock_seconds ?? 14400;
        const budgetSource = input.budget_profile === "auto" ? "auto" :
            input.budget_profile ? "profile" :
                input.token_budget !== null ? "tokens" :
                    "none";
        const txn = this.db.transaction(() => {
            const existing = this.getBySession(input.session_id);
            if (existing && (existing.status === "active" || existing.status === "paused" || existing.status === "blocked" || existing.status === "budget_limited")) {
                throw new Error(`a goal already exists in status '${existing.status}'; complete or abandon first`);
            }
            const now = Date.now();
            const goal_id = randomUUID();
            if (existing) {
                // Replacement path
                this.db.prepare(`
          UPDATE goals SET
            goal_id = ?, objective = ?, status = 'active', paused_reason = NULL,
            token_budget = ?, budget_profile = ?, budget_source = ?,
            tokens_used = 0, subagent_tokens = 0, time_used_seconds = 0,
            resume_at_ms = ?, last_accounted_byte_offset = 0, last_accounted_uuid = NULL,
            accounting_uncertain = 0, last_continuation_at_ms = NULL,
            continuations_remaining = ?, max_wall_clock_seconds = ?,
            budget_limit_reported = 0,
            version = version + 1, created_at_ms = ?, updated_at_ms = ?
          WHERE session_id = ?
        `).run(goal_id, input.objective, tokenBudget, resolvedProfile, budgetSource, now, continuationsRemaining, maxWallClockSeconds, now, now, input.session_id);
                this.db.prepare("DELETE FROM subagent_token_cursors WHERE session_id = ?").run(input.session_id);
                this.recordEvent(input.session_id, goal_id, "goal_replaced", null, "active", { prev_status: existing.status, prev_goal_id: existing.goal_id });
            }
            else {
                this.db.prepare(`
          INSERT INTO goals (
            session_id, goal_id, objective, status, token_budget, budget_profile,
            budget_source, continuations_remaining, max_wall_clock_seconds,
            resume_at_ms, created_at_ms, updated_at_ms
          ) VALUES (?, ?, ?, 'active', ?, ?, ?, ?, ?, ?, ?, ?)
        `).run(input.session_id, goal_id, input.objective, tokenBudget, resolvedProfile, budgetSource, continuationsRemaining, maxWallClockSeconds, now, now, now);
                this.recordEvent(input.session_id, goal_id, "goal_created", null, "active", null);
            }
            return this.getBySession(input.session_id);
        });
        return txn();
    }
    markComplete(session_id, goal_id, completedBy = "self_update") {
        const txn = this.db.transaction(() => {
            const g = this.getBySession(session_id);
            if (!g)
                throw new Error("no goal exists");
            if (goal_id && g.goal_id !== goal_id)
                throw new Error("goal_id mismatch");
            if (g.status !== "active") {
                throw new Error(`cannot mark complete from status '${g.status}'`);
            }
            const now = Date.now();
            const elapsedSec = g.resume_at_ms ? Math.floor((now - g.resume_at_ms) / 1000) : 0;
            this.db.prepare(`
        UPDATE goals SET
          status = 'complete',
          time_used_seconds = time_used_seconds + ?,
          resume_at_ms = NULL,
          version = version + 1,
          updated_at_ms = ?
        WHERE session_id = ? AND goal_id = ?
      `).run(elapsedSec, now, session_id, g.goal_id);
            // Distinct event types per completion path for audit-trail clarity.
            const eventType = completedBy === "evaluator" ? "goal_completed_by_evaluator" : "goal_completed_by_self_update";
            this.recordEvent(session_id, g.goal_id, eventType, g.status, "complete", { completed_by: completedBy });
        });
        txn();
    }
    markBlocked(session_id, goal_id, reason = null) {
        const txn = this.db.transaction(() => {
            const g = this.getBySession(session_id);
            if (!g)
                throw new Error("no goal exists");
            if (goal_id && g.goal_id !== goal_id)
                throw new Error("goal_id mismatch");
            if (g.status !== "active") {
                throw new Error(`cannot mark blocked from status '${g.status}'`);
            }
            const now = Date.now();
            const elapsedSec = g.resume_at_ms ? Math.floor((now - g.resume_at_ms) / 1000) : 0;
            this.db.prepare(`
        UPDATE goals SET
          status = 'blocked',
          paused_reason = NULL,
          time_used_seconds = time_used_seconds + ?,
          resume_at_ms = NULL,
          version = version + 1,
          updated_at_ms = ?
        WHERE session_id = ? AND goal_id = ?
      `).run(elapsedSec, now, session_id, g.goal_id);
            this.recordEvent(session_id, g.goal_id, "goal_blocked", g.status, "blocked", { reason: reason?.trim() || null });
        });
        txn();
    }
    pause(session_id, goal_id, reason) {
        const txn = this.db.transaction(() => {
            const g = this.getBySession(session_id);
            if (!g)
                throw new Error("no goal exists");
            if (g.goal_id !== goal_id)
                throw new Error("goal_id mismatch");
            if (g.status !== "active" && g.status !== "budget_limited") {
                throw new Error(`cannot pause from status '${g.status}'`);
            }
            const now = Date.now();
            const elapsedSec = g.resume_at_ms ? Math.floor((now - g.resume_at_ms) / 1000) : 0;
            this.db.prepare(`
        UPDATE goals SET
          status = 'paused', paused_reason = ?,
          time_used_seconds = time_used_seconds + ?,
          resume_at_ms = NULL,
          version = version + 1,
          updated_at_ms = ?
        WHERE session_id = ? AND goal_id = ?
      `).run(reason, elapsedSec, now, session_id, goal_id);
            this.recordEvent(session_id, goal_id, "goal_paused", g.status, "paused", { reason });
        });
        txn();
    }
    resume(session_id, goal_id) {
        const txn = this.db.transaction(() => {
            const g = this.getBySession(session_id);
            if (!g)
                throw new Error("no goal exists");
            if (g.goal_id !== goal_id)
                throw new Error("goal_id mismatch");
            if (g.status !== "paused" && g.status !== "blocked")
                throw new Error(`cannot resume from status '${g.status}'`);
            if (g.status === "paused" && g.paused_reason !== "user" && g.paused_reason !== "degraded") {
                throw new Error(`cannot resume goal paused by '${g.paused_reason}'; use /goal-extend or /goal-reconcile`);
            }
            const now = Date.now();
            this.db.prepare(`
        UPDATE goals SET
          status = 'active', paused_reason = NULL,
          resume_at_ms = ?, version = version + 1, updated_at_ms = ?
        WHERE session_id = ? AND goal_id = ?
      `).run(now, now, session_id, goal_id);
            this.recordEvent(session_id, goal_id, "goal_resumed", g.status, "active", null);
        });
        txn();
    }
    abandon(session_id, goal_id) {
        const txn = this.db.transaction(() => {
            const g = this.getBySession(session_id);
            if (!g)
                throw new Error("no goal exists");
            if (g.goal_id !== goal_id)
                throw new Error("goal_id mismatch");
            if (g.status === "complete" || g.status === "abandoned")
                return;
            const now = Date.now();
            const elapsedSec = g.resume_at_ms ? Math.floor((now - g.resume_at_ms) / 1000) : 0;
            this.db.prepare(`
        UPDATE goals SET
          status = 'abandoned',
          paused_reason = NULL,
          time_used_seconds = time_used_seconds + ?,
          resume_at_ms = NULL, version = version + 1, updated_at_ms = ?
        WHERE session_id = ? AND goal_id = ?
      `).run(elapsedSec, now, session_id, goal_id);
            this.recordEvent(session_id, goal_id, "goal_abandoned", g.status, "abandoned", null);
        });
        txn();
    }
    testHelper_setResumeAt(session_id, ms) {
        this.db.prepare("UPDATE goals SET resume_at_ms = ? WHERE session_id = ?").run(ms, session_id);
    }
    testHelper_setStatus(session_id, status) {
        this.db.prepare("UPDATE goals SET status = ? WHERE session_id = ?").run(status, session_id);
    }
    recordEvent(session_id, goal_id, event_type, status_before, status_after, payload) {
        this.db.prepare(`
      INSERT INTO goal_events (session_id, goal_id, event_type, status_before, status_after, payload_json, pid, created_at_ms)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    `).run(session_id, goal_id, event_type, status_before, status_after, payload ? JSON.stringify(payload) : null, process.pid, Date.now());
    }
}

import { describe, it, expect } from "vitest";
import { sumTranscript } from "../src/token-math.js";
import { readFileSync, readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURES_DIR = join(__dirname, "../../../tests/fixtures/transcripts");

describe("transcript fixtures", () => {
  const files = readdirSync(FIXTURES_DIR).filter(f => f.endsWith(".jsonl")).sort();
  for (const file of files) {
    const base = file.replace(".jsonl", "");
    const expectedPath = join(FIXTURES_DIR, `${base}.expected.json`);
    const expected = JSON.parse(readFileSync(expectedPath, "utf8"));
    it(`fixture: ${file}`, () => {
      const text = readFileSync(join(FIXTURES_DIR, file), "utf8");
      const r = sumTranscript(text, 0, null);
      expect(r.tokens_delta).toBe(expected.tokens_used);
      if (expected.last_uuid !== undefined) {
        expect(r.last_uuid).toBe(expected.last_uuid);
      }
      if (expected.cap_exceeded !== undefined) {
        expect(r.cap_exceeded).toBe(expected.cap_exceeded);
      }
      // Note: accounting_uncertain isn't a sumTranscript field; that's set by the
      // caller (account_advance_inline) on cursor reset. The test asserts what
      // sumTranscript returns about the cursor (cursor_reset) instead.
      if (expected.cursor_reset !== undefined) {
        expect(r.cursor_reset).toBe(expected.cursor_reset);
      }
    });
  }
});

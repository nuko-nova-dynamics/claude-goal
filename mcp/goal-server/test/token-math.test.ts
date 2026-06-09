import { describe, it, expect } from "vitest";
import { tokensFromUsage, sumTranscript } from "../src/token-math.js";

describe("tokensFromUsage", () => {
  it("returns 0 for missing usage", () => {
    expect(tokensFromUsage(undefined)).toBe(0);
  });

  it("excludes cache_read_input_tokens", () => {
    expect(tokensFromUsage({
      input_tokens: 100,
      cache_creation_input_tokens: 0,
      cache_read_input_tokens: 500,
      output_tokens: 50,
    })).toBe(150);
  });

  it("includes cache_creation", () => {
    expect(tokensFromUsage({
      input_tokens: 100,
      cache_creation_input_tokens: 200,
      cache_read_input_tokens: 0,
      output_tokens: 50,
    })).toBe(350);
  });

  it("treats missing cache fields as 0", () => {
    expect(tokensFromUsage({ input_tokens: 100, output_tokens: 50 })).toBe(150);
  });

  it("rejects malformed token fields", () => {
    expect(() => tokensFromUsage({ input_tokens: -1, output_tokens: 0 })).toThrow(/non-negative integers/);
    expect(() => tokensFromUsage({ input_tokens: 1.5, output_tokens: 0 })).toThrow(/non-negative integers/);
    expect(() => tokensFromUsage({ input_tokens: Number.POSITIVE_INFINITY, output_tokens: 0 })).toThrow(/non-negative integers/);
    expect(() => tokensFromUsage({ input_tokens: Number.MAX_SAFE_INTEGER + 1, output_tokens: 0 })).toThrow(/non-negative integers/);
    expect(() => tokensFromUsage({ input_tokens: "100" as never, output_tokens: 0 })).toThrow(/non-negative integers/);
  });
});

describe("sumTranscript", () => {
  it("sums assistant messages from byte offset 0", () => {
    const lines = [
      JSON.stringify({ type: "user", uuid: "u1", message: { content: [] } }),
      JSON.stringify({ type: "assistant", uuid: "u2", message: { usage: { input_tokens: 10, output_tokens: 20 } } }),
      JSON.stringify({ type: "assistant", uuid: "u3", message: { usage: { input_tokens: 30, output_tokens: 40 } } }),
    ];
    const text = lines.join("\n") + "\n";
    const r = sumTranscript(text, 0, null);
    expect(r.tokens_delta).toBe(10 + 20 + 30 + 40);
    expect(r.last_uuid).toBe("u3");
    expect(r.cursor_reset).toBe(false);
  });

  it("does not flag cursor_reset on normal append after expected previous uuid", () => {
    const prefix = JSON.stringify({ type: "assistant", uuid: "previous", message: { usage: { input_tokens: 1, output_tokens: 1 } } }) + "\n";
    const append = JSON.stringify({ type: "assistant", uuid: "next", message: { usage: { input_tokens: 2, output_tokens: 3 } } }) + "\n";
    const r = sumTranscript(prefix + append, prefix.length, "previous");
    expect(r.cursor_reset).toBe(false);
    expect(r.tokens_delta).toBe(5);
    expect(r.last_uuid).toBe("next");
  });

  it("flags cursor_reset when the previous uuid before the byte cursor changed", () => {
    const original = JSON.stringify({ type: "assistant", uuid: "previous", message: { usage: { input_tokens: 1, output_tokens: 1 } } }) + "\n";
    const rewritten = JSON.stringify({ type: "assistant", uuid: "rewritten", message: { usage: { input_tokens: 1, output_tokens: 1 } } }) + "\n";
    const append = JSON.stringify({ type: "assistant", uuid: "next", message: { usage: { input_tokens: 2, output_tokens: 3 } } }) + "\n";
    const r = sumTranscript(rewritten + append, original.length, "previous");
    expect(r.cursor_reset).toBe(true);
  });

  it("skips messages without usage field", () => {
    const text = JSON.stringify({ type: "assistant", uuid: "u1", message: {} }) + "\n";
    const r = sumTranscript(text, 0, null);
    expect(r.tokens_delta).toBe(0);
  });

  it("accounts large valid usage fields instead of treating them as accounting errors", () => {
    const text = JSON.stringify({ type: "assistant", uuid: "u1", message: { usage: { input_tokens: 2_000_000_000, output_tokens: 0 } } }) + "\n";
    const r = sumTranscript(text, 0, null);
    expect(r.cap_exceeded).toBe(false);
    expect(r.tokens_delta).toBe(2_000_000_000);
    expect(r.last_uuid).toBe("u1");
  });

  it("flags malformed usage fields as accounting errors", () => {
    const text = JSON.stringify({ type: "assistant", uuid: "u1", message: { usage: { input_tokens: -1, output_tokens: 0 } } }) + "\n";
    const r = sumTranscript(text, 0, null);
    expect(r.cap_exceeded).toBe(true);
    expect(r.cap_field).toBe("input_tokens");
  });

  it("end_byte_offset matches UTF-8 byte length for non-ASCII content", () => {
    // 🚀 is 4 bytes in UTF-8 but .length === 2 in JS (surrogate pair).
    // end_byte_offset must match what `wc -c` would report on the same content.
    const text = JSON.stringify({ type: "assistant", uuid: "u1", message: { usage: { input_tokens: 10, output_tokens: 5 } }, note: "🚀" }) + "\n";
    const byteLen = Buffer.from(text, "utf8").byteLength;
    const r = sumTranscript(text, 0, null);
    expect(r.end_byte_offset).toBe(byteLen);
    // Sanity: byteLen > text.length because the emoji is multi-byte
    expect(byteLen).toBeGreaterThan(text.length);
  });

  it("sumTranscript handles multi-cache-breakpoint", () => {
    const text = JSON.stringify({
      type: "assistant", uuid: "u1",
      message: { usage: {
        input_tokens: 100,
        cache_creation_input_tokens: 300,
        cache_read_input_tokens: 200,  // excluded
        output_tokens: 50
      } }
    }) + "\n";
    const r = sumTranscript(text, 0, null);
    expect(r.tokens_delta).toBe(100 + 300 + 50);
    expect(r.cursor_reset).toBe(false);
  });

  it("sumTranscript treats reasoning tokens as part of output_tokens (no double-count)", () => {
    // Anthropic API folds reasoning into output_tokens already; we just trust the field.
    // Verify a usage block with a reasoning_output_tokens field is ignored.
    const text = JSON.stringify({
      type: "assistant", uuid: "u1",
      message: { usage: {
        input_tokens: 100,
        output_tokens: 50,
        reasoning_output_tokens: 30  // should NOT be added separately
      } }
    }) + "\n";
    const r = sumTranscript(text, 0, null);
    expect(r.tokens_delta).toBe(100 + 50);  // not 180
  });
});

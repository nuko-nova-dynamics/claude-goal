import { Buffer } from "node:buffer";

export interface Usage {
  input_tokens?: number;
  cache_creation_input_tokens?: number;
  cache_read_input_tokens?: number;
  output_tokens?: number;
}

type AccountedUsageField = "input_tokens" | "cache_creation_input_tokens" | "output_tokens";

function normalizeUsageField(u: Usage, field: AccountedUsageField): number | null {
  const value = u[field];
  if (value === undefined || value === null) return 0;
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    return null;
  }
  return value;
}

export function tokensFromUsage(u: Usage | undefined): number {
  if (!u) return 0;
  const input = normalizeUsageField(u, "input_tokens");
  const cacheCreate = normalizeUsageField(u, "cache_creation_input_tokens");
  const output = normalizeUsageField(u, "output_tokens");
  if (input === null || cacheCreate === null || output === null) {
    throw new Error("usage token fields must be non-negative integers");
  }
  return input + cacheCreate + output;
}

export interface SumResult {
  tokens_delta: number;
  last_uuid: string | null;
  end_byte_offset: number;
  cursor_reset: boolean;
  // Historical name retained for fixture compatibility. This now means an
  // invalid token field was seen, not that a valid large token count is too big.
  cap_exceeded: boolean;
  cap_field: string | null;
}

function lastUuidBeforeByteOffset(buf: Buffer, endByteOffset: number): string | null {
  if (endByteOffset <= 0) return null;
  const prefix = buf.subarray(0, endByteOffset).toString("utf8");
  let lastUuid: string | null = null;

  for (const line of prefix.split("\n")) {
    if (line.length === 0) continue;
    let rec: any;
    try { rec = JSON.parse(line); }
    catch { continue; }
    if (rec.uuid) lastUuid = rec.uuid;
  }

  return lastUuid;
}

export function sumTranscript(text: string, startOffset: number, expectedPreviousUuid: string | null): SumResult {
  // Convert to UTF-8 byte buffer so all offsets match bash's byte-level wc -c / tail -c.
  const buf = Buffer.from(text, "utf8");

  const result: SumResult = {
    tokens_delta: 0,
    last_uuid: null,
    end_byte_offset: buf.byteLength,
    cursor_reset: false,
    cap_exceeded: false,
    cap_field: null,
  };

  if (startOffset > buf.byteLength) {
    result.cursor_reset = true;
    return result;
  }

  if (startOffset > 0 && expectedPreviousUuid !== null) {
    const previousUuid = lastUuidBeforeByteOffset(buf, startOffset);
    if (previousUuid !== expectedPreviousUuid) {
      result.cursor_reset = true;
      return result;
    }
  }

  // Slice from byte offset and decode to string for line iteration.
  const window = buf.subarray(startOffset).toString("utf8");
  const lines = window.split("\n").filter(l => l.length > 0);

  for (const line of lines) {
    let rec: any;
    try { rec = JSON.parse(line); }
    catch { continue; }

    if (rec.type === "assistant" && rec.message?.usage) {
      const u: Usage = rec.message.usage;
      for (const field of ["input_tokens", "output_tokens", "cache_creation_input_tokens"] as const) {
        if (normalizeUsageField(u, field) === null) {
          result.cap_exceeded = true; result.cap_field = field; return result;
        }
      }
      result.tokens_delta += tokensFromUsage(u);
    }
    if (rec.uuid) result.last_uuid = rec.uuid;
  }

  return result;
}

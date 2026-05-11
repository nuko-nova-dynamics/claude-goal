import { Buffer } from "node:buffer";

export interface Usage {
  input_tokens?: number;
  cache_creation_input_tokens?: number;
  cache_read_input_tokens?: number;
  output_tokens?: number;
}

export function tokensFromUsage(u: Usage | undefined): number {
  if (!u) return 0;
  return (u.input_tokens ?? 0) + (u.cache_creation_input_tokens ?? 0) + (u.output_tokens ?? 0);
}

export interface SumResult {
  tokens_delta: number;
  last_uuid: string | null;
  end_byte_offset: number;
  cursor_reset: boolean;
  cap_exceeded: boolean;
  cap_field: string | null;
}

const CAP_INPUT = 200_000;
const CAP_OUTPUT = 100_000;
const CAP_CACHE_CREATE = 200_000;

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
      if ((u.input_tokens ?? 0) > CAP_INPUT) {
        result.cap_exceeded = true; result.cap_field = "input_tokens"; return result;
      }
      if ((u.output_tokens ?? 0) > CAP_OUTPUT) {
        result.cap_exceeded = true; result.cap_field = "output_tokens"; return result;
      }
      if ((u.cache_creation_input_tokens ?? 0) > CAP_CACHE_CREATE) {
        result.cap_exceeded = true; result.cap_field = "cache_creation_input_tokens"; return result;
      }
      result.tokens_delta += tokensFromUsage(u);
    }
    if (rec.uuid) result.last_uuid = rec.uuid;
  }

  return result;
}

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

export function sumTranscript(text: string, startOffset: number, expectedFirstUuid: string | null): SumResult {
  const result: SumResult = {
    tokens_delta: 0,
    last_uuid: null,
    end_byte_offset: text.length,
    cursor_reset: false,
    cap_exceeded: false,
    cap_field: null,
  };

  const window = text.slice(startOffset);
  const lines = window.split("\n").filter(l => l.length > 0);

  let firstUuidChecked = false;
  for (const line of lines) {
    let rec: any;
    try { rec = JSON.parse(line); }
    catch { continue; }

    if (!firstUuidChecked && expectedFirstUuid !== null && rec.uuid && rec.uuid !== expectedFirstUuid) {
      // Cursor invalidated — caller should restart from offset 0
      result.cursor_reset = true;
      return result;
    }
    firstUuidChecked = true;

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

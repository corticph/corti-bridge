// Bounded retry policy for upstream failures a fresh attempt can plausibly fix.
//
// Corti's edge intermittently answers with an empty-bodied 5xx for tens of seconds
// while a fraction of requests still succeed — on 2026-08-18 two requests 154ms
// apart came back 503 and 200. Claude Code's own ladder is ~5 attempts inside ~8s,
// too fast to outlast such a window, so absorbing the blip here is what keeps a
// session alive instead of ending it.
//
// Deliberately small: the client is still retrying on top of this, so the two
// ladders multiply. Worst case here is ~6s of added latency before the client
// ever sees an error.

export const RETRY_MAX_ATTEMPTS = 3; // initial attempt + 2 retries

const BASE_DELAY_MS = 500;
const MAX_DELAY_MS = 4_000;
const JITTER_MS = 250;

// 401/403 are deliberately absent. A bad CORTI_BEARER must fail fast and loudly
// rather than being retried on every single request.
const RETRYABLE_STATUS = new Set([408, 429, 500, 502, 503, 504, 529]);

const RETRYABLE_CODES = new Set([
  "ECONNRESET",
  "ECONNREFUSED",
  "ETIMEDOUT",
  "ESOCKETTIMEDOUT",
  "EPIPE",
  "EAI_AGAIN",
  "EHOSTUNREACH",
  "ENETUNREACH",
  "ENETDOWN",
]);

export function isRetryableStatus(status) {
  return RETRYABLE_STATUS.has(status);
}

export function isRetryableNetworkError(err) {
  return RETRYABLE_CODES.has(err?.cause?.code ?? err?.code);
}

// `attempt` is 1-based: the wait after attempt 1 fails is the first back-off.
// A numeric Retry-After wins, clamped — upstream may name a wait far longer than
// the client's own timeout, and stalling that long just fails slower.
export function retryDelayMs(attempt, retryAfter, jitter = Math.random()) {
  const seconds = Number(retryAfter);
  if (retryAfter != null && retryAfter !== "" && Number.isFinite(seconds) && seconds >= 0)
    return Math.min(seconds * 1000, MAX_DELAY_MS);
  const backoff = Math.min(BASE_DELAY_MS * 3 ** (attempt - 1), MAX_DELAY_MS);
  return backoff + Math.round(jitter * JITTER_MS);
}

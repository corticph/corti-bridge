// Calibration for the char/4 prompt estimate, as pure functions over one small bounded store.
//
// The estimate is what message_start reports as input_tokens. It is normally overwritten by the
// real split from message_delta, but a turn that dies first — client abort, upstream error
// mid-response, a failed advisor continuation — leaves it standing as that message's final
// recorded usage. Raw char/4 lands a few percent under the truth, so the harness then records less
// context than the previous turn held and the statusline steps backwards before recovering.
//
// Scaling by the last real/estimate ratio rather than pinning to the last real total: after an
// auto-compact the estimate legitimately collapses, and a pinned floor would keep reporting the
// pre-compact size until real usage arrived to correct it.

export const MAX_TRACKED_SESSIONS = 256;
// Below this the ratio is dominated by fixed overhead (system prompt, tool schemas) rather than by
// the transcript, and generalizes badly to a full-sized turn.
export const MIN_SAMPLE_ESTIMATE = 4096;
// Observed ratios sit between 0.98 and 1.07; the ceiling only bounds a pathological upstream.
export const MAX_CALIBRATION_RATIO = 1.15;

const samples = new Map(); // key -> { est, real }

/**
 * Model is part of the key: a session's haiku-tier side requests (topic detection and the like)
 * carry the same session id under a prompt two orders of magnitude smaller. Returns null when
 * there is no session to key on, which disables calibration for that request.
 */
export function calibrationKey(sessionId, model) {
  if (!sessionId || typeof sessionId !== "string") return null;
  return `${sessionId} ${model ?? ""}`;
}

export function recordPromptTokens(key, est, promptTokens) {
  if (!key) return;
  if (!Number.isFinite(est) || est < MIN_SAMPLE_ESTIMATE) return;
  if (!Number.isFinite(promptTokens) || promptTokens <= 0) return;
  // Re-insert so insertion order stays least-recently-seen first and the eviction below drops a
  // session nobody is talking to rather than the one in front of the user.
  samples.delete(key);
  samples.set(key, { est, real: promptTokens });
  if (samples.size > MAX_TRACKED_SESSIONS) samples.delete(samples.keys().next().value);
}

/**
 * Never returns less than the raw estimate: an over-report is corrected by the next real
 * message_delta, while an under-report is exactly what makes the statusline wobble.
 */
export function calibratedEstimate(key, est) {
  if (!Number.isFinite(est) || est <= 0) return est;
  const sample = key ? samples.get(key) : null;
  if (!sample) return est;
  const ratio = Math.min(Math.max(sample.real / sample.est, 1), MAX_CALIBRATION_RATIO);
  return Math.round(est * ratio);
}

// Tests only: the store is process-global by design (one gateway, many sessions).
export function _resetCalibration() {
  samples.clear();
}

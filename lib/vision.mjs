/** Vision-model resolution for the image-describe sidecall.
 *
 *  The describe sidecall needs a sighted (image_input) model. A blind primary tier pin (e.g. haiku
 *  on corti-s1-instant-beta, which is non-reasoning AND image_input:false) used to make the sidecall
 *  400 at upstream and degrade to a placeholder — even when the sonnet tier right beside it was
 *  sighted. This resolver walks the configured tier ladder and returns the first model the live
 *  sighted catalog confirms is multimodal, so a blind tier steps down instead of bottoming out.
 *
 *  Pure by design: no I/O, no process.env access, no gateway imports — the gateway injects the env
 *  and the sighted Set it already fetched. Mirrors lib/retry.mjs and lib/prompt-estimate.mjs so the
 *  step-down logic is hermetic and unit-testable in test/translate.sh. */

// The non-reasoning instant sonnet: multimodal, no thinking cap, low latency. Describing is
// perception, not reasoning — cheapest-first is the whole point of the tier ladder order below.
export const VISION_DEFAULT = "corti-s1-mini-instant";

// Cheapest first: the haiku tier is where the wrapper points CORTI_VISION_MODEL by default, so it
// is tried first; sonnet/opus/fable are the step-down rungs.
export const VISION_TIERS = [
  "ANTHROPIC_DEFAULT_HAIKU_MODEL",
  "ANTHROPIC_DEFAULT_SONNET_MODEL",
  "ANTHROPIC_DEFAULT_OPUS_MODEL",
  "ANTHROPIC_DEFAULT_FABLE_MODEL",
];

const isSighted = (id, imageModels) =>
  imageModels instanceof Set && id ? imageModels.has(id) : false;

/** Resolves the vision model for the describe sidecall.
 *
 *  Order: an explicit CORTI_VISION_MODEL (if sighted) → the first sighted tier in VISION_TIERS →
 *  VISION_DEFAULT (if sighted) → "". The empty string is the true bottom, reached only when no
 *  configured tier is sighted; the gateway short-circuits the sidecall then so it degrades to the
 *  placeholder without burning an upstream 400.
 *
 *  An explicit CORTI_VISION_MODEL that is blind is bypassed, not forced: the caller logs a
 *  one-line, deduped warning and steps down. `{ warned, fallbackFrom }` carry the bypassed id so
 *  the warning can name it. */
export function resolveVisionModel({ env, imageModels, tiers = VISION_TIERS } = {}) {
  const override = env?.CORTI_VISION_MODEL?.trim();
  if (isSighted(override, imageModels)) return { model: override, warned: false, fallbackFrom: null };

  let fallbackFrom = null;
  if (override) fallbackFrom = override;

  for (const name of tiers) {
    const id = env?.[name]?.trim();
    if (isSighted(id, imageModels)) return { model: id, warned: fallbackFrom != null, fallbackFrom };
  }

  if (isSighted(VISION_DEFAULT, imageModels))
    return { model: VISION_DEFAULT, warned: fallbackFrom != null, fallbackFrom };

  /** Non-Set imageModels means /models failed or hasn't loaded — sightedness unknown, not
   *  confirmed blind. Fall back to VISION_DEFAULT (OLD behavior) so a transient outage describes
   *  images rather than pinning placeholders for the session (the image-hash cache never
   *  re-describes). The true bottom "" is reached only when the catalog loaded (a Set, even empty)
   *  and nothing is sighted. */
  if (!(imageModels instanceof Set)) return { model: VISION_DEFAULT, warned: false, fallbackFrom: null };

  return { model: "", warned: fallbackFrom != null, fallbackFrom };
}

/** Vision-model resolution for the image-describe sidecall: walks the configured tier ladder
 *  and returns the first sighted model the live catalog confirms — a blind preference steps
 *  down instead of 400-ing. Pure by design (no I/O, no env access, no gateway imports — the
 *  gateway injects env and the sighted set) so the logic stays hermetic for test/translate.sh. */

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

/** Resolve order: explicit CORTI_VISION_MODEL (if sighted) → first sighted VISION_TIERS entry →
 *  VISION_DEFAULT (if sighted) → "" — nothing sighted; the gateway then short-circuits the
 *  sidecall to the placeholder. A blind override is bypassed, not forced — `warned` /
 *  `fallbackFrom` carry the bypassed id so the caller's deduped warning can name it. */
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

  // Non-Set imageModels means the /models fetch failed or hasn't loaded — sightedness unknown,
  // not blind: fall back to the default rather than pinning placeholders for the whole session.
  if (!(imageModels instanceof Set)) return { model: VISION_DEFAULT, warned: false, fallbackFrom: null };

  return { model: "", warned: fallbackFrom != null, fallbackFrom };
}

// Ranks Corti's catalog into Claude Code tiers, printing models.env on stdout.
// Usage: node lib/models.mjs '<catalog JSON>'

const DEFAULT_CONTEXT = 262144;
const SIZES = new Set(["ultra", "mini", "tiny"]);
const CHANNELS = new Set(["beta", "alpha", "rc", "preview", "canary"]);

// A tier takes the first [size, speed] shape it can fill, and a beta beats the GA of that same
// shape. Matching on shape rather than on "corti-s1" lets a later generation slot in unchanged.
const SHAPES = {
  fable: [["ultra", ""]],
  opus: [["", ""]],
  sonnet: [["", "instant"]],
  haiku: [["mini", "instant"], ["mini", ""], ["tiny", "instant"], ["tiny", ""]],
};

const catalog = JSON.parse(process.argv[2]);
const models = [];
for (const m of Array.isArray(catalog.data) ? catalog.data : []) {
  if (!m || typeof m.id !== "string") continue;
  const tokens = m.id.toLowerCase().split("-");
  if (tokens.some((t) => /^embeddings?$/.test(t))) continue;
  const sized = typeof m.max_input_tokens === "number";
  // A window under 100k breaks a coding session before it gets going; exclude from every tier.
  if (sized && m.max_input_tokens < 100_000) continue;
  if (!sized) console.error(`    ! ${m.id} has no max_input_tokens; assuming ${DEFAULT_CONTEXT}`);
  models.push({
    id: m.id,
    size: tokens.find((t) => SIZES.has(t)) || "",
    speed: tokens.includes("instant") ? "instant" : "",
    beta: tokens.some((t) => CHANNELS.has(t)),
    context: sized ? m.max_input_tokens : DEFAULT_CONTEXT,
    caps: m.capabilities || {},
    effort: m.effort?.supported === true,
  });
}

if (models.length === 0) {
  console.error("no usable chat models in the catalog");
  process.exit(1);
}

// Sorting rather than scanning keeps every pick independent of the order the API returned.
const rank = (a, b) => b.beta - a.beta || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
const fill = (tier) =>
  SHAPES[tier]
    .map(([size, speed]) =>
      models
        .filter((m) => m.size === size && m.speed === speed && (tier === "fable" || !m.beta))
        .sort(rank)[0],
    )
    .find(Boolean);

const tiers = { fable: fill("fable"), opus: fill("opus"), sonnet: fill("sonnet"), haiku: fill("haiku") };
// An unfilled tier borrows the one above it; nothing sits above opus, so it takes the roomiest.
tiers.opus ||= models.slice().sort((a, b) => b.context - a.context || rank(a, b))[0];
tiers.sonnet ||= tiers.opus;
tiers.haiku ||= tiers.sonnet;
// A fable that only repeats opus is not a tier. Aliases hiding behind a different name are
// caught later, by the fingerprint probe in models.sh.
if (tiers.fable?.id === tiers.opus.id) tiers.fable = null;

const distinct = new Set([tiers.opus.id, tiers.sonnet.id, tiers.haiku.id]).size;
if (distinct < 3) console.error(`warning: only ${distinct} distinct model(s); some tiers share one`);

// Unset, Claude Code guesses from the model name; set, the list is authoritative and anything
// absent is disabled. Silence in the catalog keeps a cap - only an explicit false drops it.
// xhigh is never offered, and interleaved_thinking is omitted: history thinking blocks are stripped.
const caps = (m) =>
  [
    m.caps.reasoning !== false && "thinking,adaptive_thinking",
    m.effort && "effort,max_effort",
    m.caps.temperature !== false && "temperature",
    "mid_conversation_system",
  ]
    .filter(Boolean)
    .join(",");

const out = ["# Written by setup.sh. Do not edit by hand - run ./setup.sh --fresh to refresh."];
for (const tier of ["fable", "opus", "sonnet", "haiku"]) {
  if (!tiers[tier]) continue;
  const key = `ANTHROPIC_DEFAULT_${tier.toUpperCase()}_MODEL`;
  out.push(`${key}="${tiers[tier].id}"`);
  if (tier === "fable") out.push(`${key}_NAME="${tiers[tier].id}"`);
  out.push(`${key}_SUPPORTED_CAPABILITIES="${caps(tiers[tier])}"`);
}
out.push(`CLAUDE_CODE_MAX_CONTEXT_TOKENS="${tiers.opus.context}"`);
process.stdout.write(out.join("\n") + "\n");

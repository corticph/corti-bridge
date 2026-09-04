// Ranks Corti's catalog into Claude Code tiers, printing models.env on stdout.
//
// Usage:
//   node lib/models.mjs '<catalog JSON>'                 # rank + emit models.env (default)
//   node lib/models.mjs --candidates '<catalog JSON>'    # per-tier candidate lists for the picker
//   node lib/models.mjs --emit '<catalog JSON>' '<picks>' # models.env from user tier->id picks
//
// The default mode is unchanged: rank the catalog into fable/opus/sonnet/haiku and emit
// models.env. The two flagged modes back the interactive `corti-bridge models` picker:
// --candidates lists, per tier, the models that could plausibly fill it (shape-filtered, the
// same rules `fill()` uses), so the picker's menus and the ranker can't drift; --emit takes the
// user's tier->id assignments and derives caps+context from each chosen id's catalog entry,
// keeping all capability/shape logic in this one file (no shell re-implementation).

const DEFAULT_CONTEXT = 262144;
const SIZES = new Set(["ultra", "mini", "tiny"]);
const CHANNELS = new Set(["beta", "alpha", "rc", "preview", "canary"]);

// A tier takes the first [size, speed] shape it can fill, and a beta beats the GA of that same
// shape. Matching on shape rather than on "corti-s1" lets a later generation slot in unchanged.
const SHAPES = {
  fable: [["ultra", ""]],
  opus: [["", ""]],
  sonnet: [["mini", ""], ["", "instant"]],
  haiku: [["mini", "instant"], ["mini", ""], ["tiny", "instant"], ["tiny", ""]],
};

// Sorting rather than scanning keeps every pick independent of the order the API returned.
const rank = (a, b) => b.beta - a.beta || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);

const parseCatalog = (raw) => {
  const catalog = JSON.parse(raw);
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
  return models;
};

// The candidate set for a tier: models whose [size, speed] matches one of the tier's shapes.
// Non-fable tiers exclude betas, matching `fill()` below, so the picker only offers a model
// the ranker would actually consider for that tier.
const candidatesFor = (tier, models) => {
  const out = [];
  for (const [size, speed] of SHAPES[tier]) {
    for (const m of models) {
      if (m.size !== size || m.speed !== speed) continue;
      if (tier !== "fable" && m.beta) continue;
      out.push(m);
    }
  }
  // The sort keeps the list independent of the order the API returned.
  return out.sort(rank);
};

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

// The first model a tier can fill from one of its shapes; betas kept out of GA tiers.
const fill = (tier, models) =>
  SHAPES[tier]
    .map(([size, speed]) =>
      models
        .filter((m) => m.size === size && m.speed === speed && (tier === "fable" || !m.beta))
        .sort(rank)[0],
    )
    .find(Boolean);

// Runs the auto-rank and resolves the borrow/fallback chain. Shared by the default mode and
// --emit, so a tier the user didn't pick falls through to exactly what the ranker would choose.
const autoRank = (models) => {
  const tiers = { fable: fill("fable", models), opus: fill("opus", models), sonnet: fill("sonnet", models), haiku: fill("haiku", models) };
  // An unfilled tier borrows the one above it; nothing sits above opus, so it takes the roomiest.
  tiers.opus ||= models.slice().sort((a, b) => b.context - a.context || rank(a, b))[0];
  tiers.sonnet ||= tiers.opus;
  tiers.haiku ||= tiers.sonnet;
  // A fable that only repeats opus is not a tier. Aliases hiding behind a different name are
  // caught later, by the fingerprint probe in models.sh.
  if (tiers.fable?.id === tiers.opus.id) tiers.fable = null;
  return tiers;
};

// Emits the models.env body for resolved tiers (tier -> model object, or null to skip). fable's
// _NAME and the per-tier _SUPPORTED_CAPABILITIES come from the model object, and
// CLAUDE_CODE_MAX_CONTEXT_TOKENS from the opus model's context window. The _PIN lines the picker
// appends are not emitted here — this is the ranker's output shape, unchanged.
const emitModelsEnv = (tiers, context) => {
  const out = ["# Written by setup.sh. Do not edit by hand - run ./setup.sh --fresh to refresh."];
  for (const tier of ["fable", "opus", "sonnet", "haiku"]) {
    const m = tiers[tier];
    if (!m) continue;
    const key = `ANTHROPIC_DEFAULT_${tier.toUpperCase()}_MODEL`;
    out.push(`${key}="${m.id}"`);
    if (tier === "fable") out.push(`${key}_NAME="${m.id}"`);
    out.push(`${key}_SUPPORTED_CAPABILITIES="${caps(m)}"`);
  }
  out.push(`CLAUDE_CODE_MAX_CONTEXT_TOKENS="${context}"`);
  process.stdout.write(out.join("\n") + "\n");
};

// --candidates: one line per tier, tab-delimited, grep/awk-friendly for the POSIX-sh picker.
// Fields: tier \t id \t context \t flags(,comma-sep). Flags: instant, tiny, mini, ultra, beta.
const emitCandidates = (models) => {
  const flags = (m) =>
    [
      m.size === "ultra" && "ultra",
      m.size === "mini" && "mini",
      m.size === "tiny" && "tiny",
      m.speed === "instant" && "instant",
      m.beta && "beta",
    ].filter(Boolean).join(",");
  for (const tier of ["fable", "opus", "sonnet", "haiku"]) {
    const cands = candidatesFor(tier, models);
    for (const m of cands) {
      process.stdout.write(`${tier}\t${m.id}\t${m.context}\t${flags(m)}\n`);
    }
  }
};

// --emit: argv = ['node', script, '--emit', '<catalog>', '<picks>'] where picks is
// "tier=id,tier=id,..." for only the tiers the user overrode. Tiers absent from picks fall through
// to auto-rank (and the same borrow chain), so the output is always a full models.env. An unknown
// id is a hard error: the picker must only offer ids that came from this catalog, so a miss is a
// bug to surface, not silently drop.
const emitFromPicks = (catalogRaw, picksRaw) => {
  const models = parseCatalog(catalogRaw);
  if (models.length === 0) {
    console.error("no usable chat models in the catalog");
    process.exit(1);
  }
  const byId = new Map(models.map((m) => [m.id, m]));
  const tiers = autoRank(models);
  for (const pair of picksRaw.split(",")) {
    if (!pair) continue;
    const eq = pair.indexOf("=");
    if (eq < 0) continue;
    const tier = pair.slice(0, eq);
    const id = pair.slice(eq + 1);
    if (!SHAPES[tier]) continue;
    const model = byId.get(id);
    if (!model) {
      console.error(`no model '${id}' in the catalog for tier ${tier}`);
      process.exit(1);
    }
    tiers[tier] = model;
  }
  // Context comes from the resolved opus model, matching the ranker.
  emitModelsEnv(tiers, tiers.opus.context);
};

const args = process.argv.slice(2);
if (args[0] === "--candidates") {
  const models = parseCatalog(args[1] ?? "");
  if (models.length === 0) {
    console.error("no usable chat models in the catalog");
    process.exit(1);
  }
  emitCandidates(models);
} else if (args[0] === "--emit") {
  emitFromPicks(args[1] ?? "", args[2] ?? "");
} else {
  // Default: rank the catalog and emit models.env (unchanged behavior).
  const models = parseCatalog(args[0] ?? "");

  if (models.length === 0) {
    console.error("no usable chat models in the catalog");
    process.exit(1);
  }

  const tiers = autoRank(models);

  const distinct = new Set([tiers.opus.id, tiers.sonnet.id, tiers.haiku.id]).size;
  if (distinct < 3) console.error(`warning: only ${distinct} distinct model(s); some tiers share one`);

  emitModelsEnv(tiers, tiers.opus.context);
}

#!/bin/sh
# Pure-function tests for lib/retry.mjs. Zero dependencies, hermetic, offline.
#
# The end-to-end behaviour these back — a transient upstream 5xx being absorbed
# before Claude Code ever sees it — needs a stub upstream and lives outside this
# suite; what's checked here is the policy that decides it.
#
# Run: sh test/retry.sh
set -eu

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

node --input-type=module -e '
import {
  RETRY_MAX_ATTEMPTS,
  isRetryableNetworkError,
  isRetryableStatus,
  retryDelayMs,
} from "'"$REPO"'/lib/retry.mjs";

let failed = 0;
const check = (name, got, want) => {
  if (got === want) console.log(`ok   ${name}`);
  else { console.log(`FAIL ${name} (expected ${want}, got ${got})`); failed++; }
};

// A blip worth outlasting. 429 is deliberately absent: it is "slow down", not a transient
// fault a fresh attempt fixes — retrying multiplies load into the very throttle that caused it
// (a live incident saw 6,558 retried 429s cascade into 503/500s). The client backs off on its
// own and Retry-After is preserved by translateError, so it still gets the signal.
for (const s of [408, 500, 502, 503, 504, 529])
  check(`retries HTTP ${s}`, isRetryableStatus(s), true);
check("does not retry HTTP 429", isRetryableStatus(429), false);

// A bad CORTI_BEARER or a rejected request must fail on the first attempt: retrying
// tripled the cost of every request during a real credential problem.
for (const s of [200, 400, 401, 403, 404, 413])
  check(`does not retry HTTP ${s}`, isRetryableStatus(s), false);

check("retries ECONNRESET", isRetryableNetworkError({ code: "ECONNRESET" }), true);
check("retries a wrapped cause code", isRetryableNetworkError({ cause: { code: "ETIMEDOUT" } }), true);
check("does not retry an unknown error", isRetryableNetworkError(new Error("boom")), false);
check("does not retry a missing error", isRetryableNetworkError(undefined), false);

// Back-off, jitter pinned to 0 so the ladder is exact.
check("first back-off", retryDelayMs(1, null, 0), 500);
check("second back-off", retryDelayMs(2, null, 0), 1500);
check("back-off is clamped", retryDelayMs(3, null, 0), 4000);
check("jitter is added on top", retryDelayMs(1, null, 1), 750);

// The whole ladder has to stay short: Claude Code retries on top of this, and the
// two multiply. Worst case must not approach the clients timeout.
const worst = [1, 2].reduce((sum, n) => sum + retryDelayMs(n, null, 1), 0);
check("total added latency stays under 3s", worst < 3000, true);
check("attempts stay bounded", RETRY_MAX_ATTEMPTS, 3);

// Retry-After wins when numeric, but clamped — upstream may name a wait longer
// than the clients own timeout, and stalling that long just fails slower.
check("honours numeric Retry-After", retryDelayMs(1, "2", 0), 2000);
check("clamps an outsized Retry-After", retryDelayMs(1, "600", 0), 4000);
check("ignores an HTTP-date Retry-After", retryDelayMs(1, "Wed, 21 Oct 2026 07:28:00 GMT", 0), 500);
check("ignores an empty Retry-After", retryDelayMs(1, "", 0), 500);
check("ignores a missing Retry-After", retryDelayMs(1, undefined, 0), 500);

if (failed) { console.log(`\n${failed} check(s) failed`); process.exit(1); }
console.log("\nall checks passed");
'

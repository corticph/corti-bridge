#!/bin/sh
# Pure-function tests for lib/prompt-estimate.mjs. Zero dependencies, hermetic, offline.
#
# What this backs end-to-end: a turn that dies before upstream reports usage leaves
# message_start-s estimate standing as its final recorded usage, and the harness then holds less
# context than the previous turn did. The replay block at the bottom uses real estimate/prompt_token
# pairs from a captured session, where raw char/4 steps backwards every time.
#
# Run: sh test/prompt-estimate.sh
set -eu

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

node --input-type=module -e '
import {
  MAX_CALIBRATION_RATIO,
  MAX_TRACKED_SESSIONS,
  MIN_SAMPLE_ESTIMATE,
  _resetCalibration,
  calibratedEstimate,
  calibrationKey,
  recordPromptTokens,
} from "'"$REPO"'/lib/prompt-estimate.mjs";

let failed = 0;
const check = (name, got, want) => {
  if (got === want) console.log(`ok   ${name}`);
  else { console.log(`FAIL ${name} (expected ${want}, got ${got})`); failed++; }
};

const KEY = calibrationKey("sess-1", "corti-s1");

// Nothing observed yet: the raw estimate is all there is.
_resetCalibration();
check("no sample leaves the estimate untouched", calibratedEstimate(KEY, 100000), 100000);
check("a null key disables calibration", calibratedEstimate(null, 100000), 100000);

// One real turn is enough to correct the next.
_resetCalibration();
recordPromptTokens(KEY, 100000, 105000);
check("scales by the observed ratio", calibratedEstimate(KEY, 200000), 210000);

// An estimate that ran high must not drag the next one down: over-reporting is corrected by the
// next real message_delta, under-reporting is the whole bug.
_resetCalibration();
recordPromptTokens(KEY, 100000, 90000);
check("never returns below the raw estimate", calibratedEstimate(KEY, 100000), 100000);

// A pathological upstream cannot inflate the number without bound.
_resetCalibration();
recordPromptTokens(KEY, 100000, 400000);
check("clamps a runaway ratio", calibratedEstimate(KEY, 100000), Math.round(100000 * MAX_CALIBRATION_RATIO));

// Below the floor the ratio is mostly fixed overhead (system prompt, tool schemas) and does not
// generalize to a full-sized turn.
_resetCalibration();
recordPromptTokens(KEY, MIN_SAMPLE_ESTIMATE - 1, 3000);
check("ignores a sample under the size floor", calibratedEstimate(KEY, 100000), 100000);
recordPromptTokens(KEY, MIN_SAMPLE_ESTIMATE, 5000);
check("accepts a sample at the size floor", calibratedEstimate(KEY, 100000) > 100000, true);

// Garbage in never becomes a stored sample.
_resetCalibration();
for (const bad of [0, -1, NaN, Infinity, undefined, null, "9000"])
  recordPromptTokens(KEY, 100000, bad);
check("ignores a non-numeric prompt_tokens", calibratedEstimate(KEY, 100000), 100000);
check("passes a zero estimate straight through", calibratedEstimate(KEY, 0), 0);

// Side requests ride the same session id under a far smaller prompt, so the model is part of the
// key or the haiku tier would calibrate the opus tier.
_resetCalibration();
recordPromptTokens(calibrationKey("sess-1", "corti-s1-mini-instant"), 5000, 9000);
check("a different model does not calibrate this one", calibratedEstimate(KEY, 100000), 100000);
check("a different session does not either",
  calibratedEstimate(calibrationKey("sess-2", "corti-s1"), 100000), 100000);

// The store is process-global and lives as long as the gateway, so it has to be bounded — and the
// eviction has to drop a session nobody is talking to, not the one in front of the user.
_resetCalibration();
recordPromptTokens(KEY, 100000, 105000);
for (let i = 0; i < MAX_TRACKED_SESSIONS; i++) {
  recordPromptTokens(calibrationKey(`filler-${i}`, "corti-s1"), 100000, 110000);
  // Keep the first session current, the way an active conversation would.
  calibratedEstimate(KEY, 100000);
  recordPromptTokens(KEY, 100000, 105000);
}
check("an active session survives eviction", calibratedEstimate(KEY, 100000), 105000);
check("the oldest filler was evicted",
  calibratedEstimate(calibrationKey("filler-0", "corti-s1"), 100000), 100000);

// Replay: consecutive (estimate, real prompt_tokens) pairs from one captured session. For each,
// the previous turn is what the statusline is already showing, and this turn dies before upstream
// reports anything — so what it records is whatever the estimate said.
_resetCalibration();
const replay = [[108682, 114738], [109042, 114125], [112227, 119971], [112673, 120408]];
for (let i = 1; i < replay.length; i++) {
  const [prevEst, prevReal] = replay[i - 1];
  const [est] = replay[i];
  check(`raw char/4 would step backwards after ${prevReal}`, est < prevReal, true);
  recordPromptTokens(KEY, prevEst, prevReal);
  check(`calibrated holds the line after ${prevReal}`, calibratedEstimate(KEY, est) >= prevReal, true);
}

if (failed) { console.log(`\n${failed} check(s) failed`); process.exit(1); }
console.log("\nall checks passed");
'

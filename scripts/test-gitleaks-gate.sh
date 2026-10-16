#!/usr/bin/env bash
# Prove that the pinned Gitleaks binary rejects a plausible, disposable GitHub token.
set -euo pipefail

tmp="$(mktemp -d "${TMPDIR:-/tmp}/dx03v2-gitleaks-gate.XXXXXX")"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

mkdir -p "$tmp/input"
node - "$tmp/input/credentials.env" <<'NODE'
const { randomBytes } = require("node:crypto");
const fs = require("node:fs");

const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
const bytes = randomBytes(36);
let token = "ghp_";
for (const byte of bytes) token += alphabet[byte % alphabet.length];
fs.writeFileSync(process.argv[2], `GITHUB_TOKEN=${token}\n`, { mode: 0o600 });
NODE

status=0
if gitleaks dir --no-banner --redact --log-level warn --report-format json \
  --report-path "$tmp/report.json" "$tmp/input" >"$tmp/scanner.log" 2>&1; then
  status=0
else
  status=$?
fi

if ((status != 1)); then
  echo "FAIL: Gitleaks did not reject the disposable secret (exit $status)" >&2
  exit 1
fi

if ! node - "$tmp/report.json" <<'NODE'
const fs = require("node:fs");

let findings;
try {
  findings = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
} catch {
  console.error("FAIL: Gitleaks produced no valid JSON report for the negative fixture");
  process.exit(1);
}

const finding = Array.isArray(findings) && findings.find((item) => item.RuleID === "github-pat");
if (!finding) {
  console.error("FAIL: Gitleaks rejected input without reporting the expected github-pat rule");
  process.exit(1);
}
if (typeof finding.Secret === "string" && /^ghp_[A-Za-z0-9]{36}$/.test(finding.Secret)) {
  console.error("FAIL: Gitleaks report did not redact the disposable secret");
  process.exit(1);
}
NODE
then
  exit 1
fi

echo "PASS: Gitleaks rejects and redacts a disposable GitHub token"

import assert from 'node:assert/strict';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import path from 'node:path';

const SECURITY_TAG = /(?:^|[/:_-])security(?:$|[/:_-])|\bcwe[-/]\d+/i;
const SECURITY_THRESHOLD = 7;

function sarifFiles(inputPath) {
  const resolved = path.resolve(inputPath);
  const stat = statSync(resolved);
  if (stat.isFile()) return [resolved];
  if (!stat.isDirectory()) throw new Error(`SARIF path is neither a file nor directory: ${resolved}`);
  return readdirSync(resolved)
    .filter((name) => name.endsWith('.sarif'))
    .map((name) => path.join(resolved, name))
    .sort();
}

function parseSarifDocument(document, file) {
  if (!document || !Array.isArray(document.runs) || document.version !== '2.1.0') {
    throw new Error(`Unsupported or malformed SARIF 2.1.0 document: ${file}`);
  }
  return document.runs.map((run) => ({ file, run }));
}

function readSarif(inputPath) {
  const files = sarifFiles(inputPath);
  if (files.length === 0) throw new Error(`CodeQL produced no SARIF report in ${inputPath}`);
  return files.flatMap((file) => parseSarifDocument(JSON.parse(readFileSync(file, 'utf8')), file));
}

function numericSeverity(...values) {
  for (const value of values) {
    if (value === undefined || value === null || value === '') continue;
    const severity = Number(value);
    if (Number.isFinite(severity)) return severity;
  }
  return undefined;
}

function evaluate(documents) {
  const failures = [];
  let findingCount = 0;
  for (const { file, run } of documents) {
    const rules = run.tool?.driver?.rules ?? [];
    const byId = new Map(rules.map((rule) => [rule.id, rule]));
    const results = run.results ?? [];
    if (!Array.isArray(results)) throw new Error(`SARIF results is not an array: ${file}`);

    for (const result of results) {
      findingCount++;
      const rule = byId.get(result.ruleId) ?? rules[result.ruleIndex] ?? {};
      const properties = rule.properties ?? {};
      const resultProperties = result.properties ?? {};
      const tags = [...(properties.tags ?? []), ...(resultProperties.tags ?? [])].map(String);
      const ruleId = result.ruleId ?? rule.id ?? '<missing-rule-id>';
      const severity = numericSeverity(
        resultProperties['security-severity'],
        properties['security-severity'],
        rule.defaultConfiguration?.properties?.['security-severity'],
      );
      const securityFinding = tags.some((tag) => SECURITY_TAG.test(tag));

      if (severity === undefined && securityFinding) {
        failures.push(`${file}: security finding ${ruleId} has no numeric security-severity metadata`);
      } else if (severity !== undefined && severity >= SECURITY_THRESHOLD) {
        failures.push(
          `${file}: ${ruleId} security-severity=${severity} meets the blocking threshold >= ${SECURITY_THRESHOLD}`,
        );
      }
    }
  }
  return { failures, findingCount };
}

function selfTest() {
  const sample = (severity, tags = ['security']) => ({
    version: '2.1.0',
    runs: [
      {
        tool: {
          driver: {
            rules: [{ id: 'js/example', properties: { tags, 'security-severity': severity } }],
          },
        },
        results: [
          { ruleId: 'js/example', locations: [{ physicalLocation: { artifactLocation: { uri: 'src/app.ts' } } }] },
        ],
      },
    ],
  });

  assert.equal(evaluate([{ file: 'low.sarif', run: sample('6.9').runs[0] }]).failures.length, 0);
  assert.equal(evaluate([{ file: 'high.sarif', run: sample('7.0').runs[0] }]).failures.length, 1);
  assert.equal(evaluate([{ file: 'unknown.sarif', run: sample(undefined).runs[0] }]).failures.length, 1);
  assert.equal(
    evaluate([{ file: 'quality.sarif', run: sample(undefined, ['maintainability']).runs[0] }]).failures.length,
    0,
  );
  assert.throws(() => parseSarifDocument({ version: '1.1.0', runs: [] }, 'invalid.sarif'), /invalid.sarif/);
  console.log(
    'PASS: CodeQL SARIF gate self-test (below-threshold, blocking, unscored security, non-security, invalid version)',
  );
}

if (process.argv[2] === '--self-test') {
  selfTest();
} else if (process.argv.length === 3) {
  try {
    const { failures, findingCount } = evaluate(readSarif(process.argv[2]));
    console.log(`CodeQL SARIF results checked: ${findingCount}`);
    if (failures.length > 0) {
      for (const failure of failures) console.error(`BLOCKED: ${failure}`);
      process.exitCode = 1;
    } else {
      console.log(`PASS: no security findings at or above severity ${SECURITY_THRESHOLD}`);
    }
  } catch (error) {
    console.error(`error: ${error.message}`);
    process.exitCode = 1;
  }
} else {
  console.error(`usage: ${path.basename(process.argv[1])} <SARIF file or directory> | --self-test`);
  process.exitCode = 2;
}

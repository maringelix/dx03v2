#!/usr/bin/env node
// Check the runtime Argo CD Kustomize overrides against an offline render of the selected overlay.
import { readFileSync } from 'node:fs';
import { parseAllDocuments } from 'yaml';

const [patchFile, manifestsFile] = process.argv.slice(2);
if (!patchFile || !manifestsFile) {
  console.error('usage: node scripts/check-gitops-renderer.mjs <application-patch.json> <overlay.yaml>');
  process.exit(2);
}
const fail = (message) => {
  console.error(message);
  process.exitCode = 1;
};
const document = JSON.parse(readFileSync(patchFile, 'utf8'));
const manifests = parseAllDocuments(readFileSync(manifestsFile, 'utf8'))
  .map((doc) => doc.toJS())
  .filter(Boolean);
const source = document.spec?.source;
if (typeof source?.path !== 'string' || !/^deploy\/k8s\/overlays\/(gcp|gcp-waf)(-full)?$/.test(source.path))
  fail(`unexpected source path: ${source?.path}`);
const workloads = manifests.flatMap((resource) => {
  const pod = resource.spec?.template?.spec;
  return pod ? [...(pod.initContainers ?? []), ...(pod.containers ?? [])] : [];
});
const images = source?.kustomize?.images ?? [];
if (images.length !== 2) fail(`expected two immutable application images, got ${images.length}`);
for (const override of images) {
  if (typeof override !== 'string') {
    fail(`image override must use Argo CD's string format: ${JSON.stringify(override)}`);
    continue;
  }
  const separator = override.indexOf('=');
  if (separator <= 0 || separator !== override.lastIndexOf('=')) {
    fail(`invalid image override: ${JSON.stringify(override)}`);
    continue;
  }
  const sourceName = override.slice(0, separator);
  const targetImage = override.slice(separator + 1);
  const immutableTag = targetImage.match(/^(.+):([0-9a-f]{40})$/);
  const immutableDigest = targetImage.match(/^(.+)@sha256:([0-9a-f]{64})$/);
  const expectedSuffix = sourceName.endsWith('/api') ? '/dx03v2/api' : sourceName.endsWith('/web') ? '/dx03v2/web' : '';
  const targetName = immutableTag?.[1] ?? immutableDigest?.[1];
  if (!expectedSuffix || !sourceName.endsWith(expectedSuffix) || !targetName?.endsWith(expectedSuffix)) {
    fail('image override must use the dx03v2/api or dx03v2/web repository: ' + override);
    continue;
  }
  if (!immutableTag && !immutableDigest) {
    fail(`image override must target an image tagged with the full source commit SHA: ${override}`);
    continue;
  }
  if (!workloads.some((container) => container.image?.startsWith(`${sourceName}:`)))
    fail(`image source ${sourceName} is absent from the rendered overlay`);
}
const patches = source?.kustomize?.patches ?? [];
if (patches.length === 0) fail('the Application has no cloud-specific Kustomize patches');
for (const entry of patches) {
  const { kind, name } = entry.target ?? {};
  const targets = manifests.filter((resource) => resource.kind === kind && resource.metadata?.name === name);
  if (targets.length !== 1) {
    fail(`patch target ${kind}/${name} matched ${targets.length} rendered resources`);
    continue;
  }
  let operations;
  try {
    operations = JSON.parse(entry.patch);
  } catch {
    fail(`patch for ${kind}/${name} is not JSON`);
    continue;
  }
  for (const operation of operations) {
    if (operation.op !== 'replace' || typeof operation.path !== 'string' || !operation.path.startsWith('/')) {
      fail(`unsupported patch operation for ${kind}/${name}: ${JSON.stringify(operation)}`);
      continue;
    }
    const segments = operation.path
      .slice(1)
      .split('/')
      .map((part) => part.replaceAll('~1', '/').replaceAll('~0', '~'));
    let current = targets[0];
    for (const segment of segments.slice(0, -1))
      current = current?.[Array.isArray(current) ? Number(segment) : segment];
    const last = segments.at(-1);
    if (current === null || typeof current !== 'object' || !(last in current))
      fail(`replace path ${operation.path} does not exist on ${kind}/${name}`);
  }
}
if (process.exitCode) process.exit(process.exitCode);
console.log(`GitOps renderer: ${source.path}, ${images.length} image overrides, ${patches.length} valid patches`);

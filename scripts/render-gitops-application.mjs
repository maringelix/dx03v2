#!/usr/bin/env node
// Keep live GCP resource names and CIDRs in the in-cluster Argo CD Application, never in public Git.
import fs from 'node:fs';

function fail(message) {
  console.error(message);
  process.exit(2);
}

function readEnv(file) {
  const result = Object.create(null);
  for (const [index, raw] of fs.readFileSync(file, 'utf8').split(/\r?\n/).entries()) {
    const line = raw.trim();
    if (line === '' || line.startsWith('#')) continue;
    const split = line.indexOf('=');
    if (split < 1) fail(`${file}:${index + 1}: expected KEY=VALUE`);
    const key = line.slice(0, split);
    const value = line.slice(split + 1);
    if (!/^[A-Z][A-Z0-9_]*$/.test(key) || Object.hasOwn(result, key)) {
      fail(`${file}:${index + 1}: invalid or duplicate key ${key}`);
    }
    if (/[\r\n\t]/.test(value)) fail(`${file}:${index + 1}: ${key} must be a single line`);
    result[key] = value;
  }
  return result;
}

function required(params, key) {
  if (typeof params[key] !== 'string' || params[key] === '') fail(`missing ${key}`);
  return params[key];
}

function image(value, key) {
  if (/^.+@sha256:[0-9a-f]{64}$/.test(value)) return { name: value.slice(0, value.indexOf('@')), reference: value };
  const colon = value.lastIndexOf(':');
  if (colon <= value.lastIndexOf('/') || !/^[0-9a-f]{40}$/.test(value.slice(colon + 1))) {
    fail(`${key} must end in a full source commit SHA tag`);
  }
  return { name: value.slice(0, colon), reference: value };
}

const [cloud, overlay, actualFile, exampleFile] = process.argv.slice(2);
if (
  cloud !== 'gcp' ||
  !['gcp', 'gcp-waf', 'gcp-full', 'gcp-waf-full'].includes(overlay) ||
  !actualFile ||
  !exampleFile
) {
  fail(
    'usage: render-gitops-application.mjs gcp <gcp|gcp-waf|gcp-full|gcp-waf-full> <actual params.env> <params.example.env>',
  );
}

const actual = readEnv(actualFile);
const example = readEnv(exampleFile);
const api = image(required(actual, 'API_IMAGE'), 'API_IMAGE');
const web = image(required(actual, 'WEB_IMAGE'), 'WEB_IMAGE');
const apiExample = image(required(example, 'API_IMAGE'), 'example API_IMAGE');
const webExample = image(required(example, 'WEB_IMAGE'), 'example WEB_IMAGE');
if (
  ![api.name, apiExample.name].every((name) => name.endsWith('/dx03v2/api')) ||
  ![web.name, webExample.name].every((name) => name.endsWith('/dx03v2/web'))
) {
  fail('runtime and example images must use the dx03v2/api and dx03v2/web repositories');
}
const ranges = required(actual, 'LB_SOURCE_RANGES').split(',');
if (ranges.length !== 2 || ranges.some((cidr) => !/^\d{1,3}(?:\.\d{1,3}){3}\/(?:\d|[12]\d|3[0-2])$/.test(cidr))) {
  fail('LB_SOURCE_RANGES must contain the two IPv4 CIDRs from the tx03v2 contract');
}
const endpoint = required(actual, 'DB_ENDPOINT_IP');
if (!/^\d{1,3}(?:\.\d{1,3}){3}$/.test(endpoint)) fail('DB_ENDPOINT_IP must be an IPv4 address');

const patches = [];
const addPatch = (kind, name, path, value) => {
  patches.push({ target: { kind, name }, patch: JSON.stringify([{ op: 'replace', path, value }]) });
};

addPatch('Gateway', 'dx03v2', '/spec/addresses/0/value', required(actual, 'GATEWAY_ADDRESS_NAME'));
for (const name of ['web-ingress-from-lb', 'api-ingress-from-lb']) {
  addPatch('NetworkPolicy', name, '/spec/ingress/0/from/0/ipBlock/cidr', ranges[0]);
  addPatch('NetworkPolicy', name, '/spec/ingress/0/from/1/ipBlock/cidr', ranges[1]);
}
addPatch('NetworkPolicy', 'api-egress-to-cloudsql', '/spec/egress/0/to/0/ipBlock/cidr', `${endpoint}/32`);
if (overlay.endsWith('-full')) {
  // The public hostname and the certificate map of the fork owner, and the Cloud SQL address that bypasses the sidecar.
  const hostname = required(actual, 'DNS_HOSTNAME');
  const certificateMap = required(actual, 'CERT_MAP');
  if (hostname === 'disabled' || certificateMap === 'disabled') {
    fail(`${overlay} requires DNS_HOSTNAME and CERT_MAP other than disabled`);
  }
  addPatch('Gateway', 'dx03v2', '/metadata/annotations/networking.gke.io~1certmap', certificateMap);
  addPatch('Gateway', 'dx03v2', '/spec/listeners/0/hostname', hostname);
  addPatch('Gateway', 'dx03v2', '/spec/listeners/1/hostname', hostname);
  addPatch('HTTPRoute', 'dx03v2', '/spec/hostnames/0', hostname);
  addPatch('HTTPRoute', 'dx03v2-http-redirect', '/spec/hostnames/0', hostname);
  addPatch(
    'Deployment',
    'api',
    '/spec/template/metadata/annotations/traffic.sidecar.istio.io~1excludeOutboundIPRanges',
    `${endpoint}/32`,
  );
}
if (overlay === 'gcp-waf' || overlay === 'gcp-waf-full') {
  const policy = required(actual, 'WAF_SECURITY_POLICY');
  if (policy === 'none') fail('gcp-waf requires WAF_SECURITY_POLICY other than none');
  addPatch('GCPBackendPolicy', 'api', '/spec/default/securityPolicy', policy);
  addPatch('GCPBackendPolicy', 'web', '/spec/default/securityPolicy', policy);
}

const document = {
  spec: {
    source: {
      path: `deploy/k8s/overlays/${overlay}`,
      kustomize: {
        images: [apiExample.name + '=' + api.reference, webExample.name + '=' + web.reference],
        patches,
      },
    },
  },
};
process.stdout.write(`${JSON.stringify(document, null, 2)}\n`);

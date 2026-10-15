// Structural checks of the rendered Kubernetes manifests against contract v2 (docs/CONTRATO.md)
// and the hardening rules of docs/GUARDRAILS.md. Used by the harness check `contract-app`.
//   node scripts/check-manifests.mjs --params <params.env> --local-params <params.env> local=<file> gcp=<file>
//     gcp-waf=<file> local-platform=<file>
import { readFileSync } from 'node:fs';
import { parseAllDocuments } from 'yaml';

const NAMESPACE = 'dx03v2';
// Kinds the deployer Role of tx03v2 may write (docs/CONTRATO.md). Secrets are written by ESO only.
const DEPLOYER_KINDS = new Set([
  'ConfigMap',
  'Deployment',
  'ExternalSecret',
  'GCPBackendPolicy',
  'Gateway',
  'HTTPRoute',
  'HealthCheckPolicy',
  'HorizontalPodAutoscaler',
  'NetworkPolicy',
  'PodDisruptionBudget',
  'Service',
  'ServiceAccount',
]);
// Kinds that exist only on Google Cloud: the local overlay (kind) never renders them.
const GCP_ONLY_KINDS = [
  'ExternalSecret',
  'GCPBackendPolicy',
  'Gateway',
  'HTTPRoute',
  'HealthCheckPolicy',
  'HorizontalPodAutoscaler',
];
// dx03v2 started as a copy of the Azure app dx02v2, itself a copy of the AWS app dx01v2: nothing of
// those paths may come back.
const OTHER_CLOUD =
  /(^|[^a-z0-9])(aws|eks|ecr|rds|elbv2|wafv2|tx01v2|azure|aks|agc|acr|tx02v2)([^a-z0-9]|$)|amazonaws|alb\.ingress\.kubernetes\.io|alb\.networking\.azure\.io|azurecr|keyvault|vault\.azure/i;
// Contract: sources of the traffic and health checks of the global external Application Load
// Balancer (Parameter Manager key lb-source-ranges, a fixed value), and the name server of the
// NodeLocal DNSCache of GKE Autopilot.
const LB_SOURCE_RANGES = ['35.191.0.0/16', '130.211.0.0/22'];
const NODE_DNS_CACHE = '169.254.20.10/32';
const BASE_NETWORK_POLICIES = [
  'allow-dns-egress',
  'api-ingress-from-web',
  'api-metrics-from-monitoring',
  'default-deny-all',
  'web-egress-to-api',
];
const GCP_NETWORK_POLICIES = [
  'allow-node-dns-cache-egress',
  'api-egress-to-cloudsql',
  'api-egress-to-collector',
  'api-ingress-from-lb',
  'web-ingress-from-lb',
];
// Autopilot, general-purpose compute class on clusters with bursting (GKE doc "Resource requests in
// Autopilot", checked 2026-10-12): at least 50m CPU and 52 MiB of memory per Pod, and between 1 and
// 6.5 GiB of memory per vCPU. Autopilot silently changes requests outside these rules.
const AUTOPILOT = { minCpu: 0.05, minMemory: 52 * 2 ** 20, minGiBPerCpu: 1, maxGiBPerCpu: 6.5 };

const failures = [];
let assertions = 0;
const check = (ok, message) => {
  assertions++;
  if (!ok) {
    failures.push(message);
  }
};
// Deep equality that ignores object key order (kustomize prints keys alphabetically); array order
// still matters.
const canonical = (value) => {
  if (Array.isArray(value)) {
    return value.map(canonical);
  }
  if (value !== null && typeof value === 'object') {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, canonical(value[key])]),
    );
  }
  return value;
};
const eq = (actual, expected, message) =>
  check(
    JSON.stringify(canonical(actual)) === JSON.stringify(canonical(expected)),
    `${message}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
  );

function parseArgs(argv) {
  const files = {};
  let params;
  let localParams;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--params') {
      params = argv[++i];
    } else if (argv[i] === '--local-params') {
      localParams = argv[++i];
    } else {
      const [name, file] = argv[i].split('=');
      files[name] = file;
    }
  }
  if (params === undefined || Object.keys(files).length === 0) {
    console.error(
      'usage: node scripts/check-manifests.mjs --params <params.env> [--local-params <params.env>] <overlay>=<rendered.yaml>...',
    );
    process.exit(2);
  }
  return {
    params: readParams(params),
    files,
    localParams: localParams === undefined ? undefined : readParams(localParams),
  };
}

function readParams(file) {
  const out = {};
  for (const line of readFileSync(file, 'utf8').split('\n')) {
    const match = /^([A-Z_]+)=(.*)$/.exec(line);
    if (match) {
      out[match[1]] = match[2];
    }
  }
  return out;
}

function load(file) {
  const text = readFileSync(file, 'utf8');
  const docs = parseAllDocuments(text);
  for (const doc of docs) {
    if (doc.errors.length > 0) {
      throw new Error(`${file}: ${doc.errors[0].message}`);
    }
  }
  return { text, objs: docs.map((doc) => doc.toJS()).filter((obj) => obj !== null) };
}

const find = (objs, kind, name) => objs.find((o) => o.kind === kind && o.metadata?.name === name);
const all = (objs, kind) => objs.filter((o) => o.kind === kind);
const names = (objs, kind) =>
  all(objs, kind)
    .map((o) => o.metadata?.name)
    .sort();

// Kubernetes quantities: CPU in cores ('50m', '1') and memory in bytes ('64Mi', '1Gi').
const MEMORY_UNITS = { '': 1, k: 1e3, M: 1e6, G: 1e9, Ki: 2 ** 10, Mi: 2 ** 20, Gi: 2 ** 30 };
function cpuCores(quantity) {
  const match = /^([0-9]+(?:\.[0-9]+)?)(m?)$/.exec(String(quantity ?? ''));
  return match === null ? NaN : Number(match[1]) / (match[2] === 'm' ? 1000 : 1);
}
function memoryBytes(quantity) {
  const match = /^([0-9]+(?:\.[0-9]+)?)(k|M|G|Ki|Mi|Gi)?$/.exec(String(quantity ?? ''));
  return match === null ? NaN : Number(match[1]) * MEMORY_UNITS[match[2] ?? ''];
}

function podChecks(where, workload) {
  const spec = workload.spec?.template?.spec ?? {};
  const pod = spec.securityContext ?? {};
  check(pod.runAsNonRoot === true, `${where}: pod securityContext.runAsNonRoot must be true`);
  check(
    Number.isInteger(pod.runAsUser) && pod.runAsUser > 0,
    `${where}: pod securityContext.runAsUser must be a non-root uid`,
  );
  eq(pod.seccompProfile?.type, 'RuntimeDefault', `${where}: seccompProfile`);
  check(spec.automountServiceAccountToken === false, `${where}: automountServiceAccountToken must be false`);
  for (const key of ['hostNetwork', 'hostPID', 'hostIPC']) {
    check(spec[key] !== true, `${where}: ${key} is forbidden`);
  }
  for (const volume of spec.volumes ?? []) {
    check(volume.hostPath === undefined, `${where}: hostPath volume ${volume.name} is forbidden`);
  }
  for (const c of [...(spec.initContainers ?? []), ...(spec.containers ?? [])]) {
    const sc = c.securityContext ?? {};
    const name = `${where}/${c.name}`;
    check(sc.allowPrivilegeEscalation === false, `${name}: allowPrivilegeEscalation must be false`);
    check(sc.readOnlyRootFilesystem === true, `${name}: readOnlyRootFilesystem must be true`);
    check(sc.privileged !== true, `${name}: privileged is forbidden`);
    check((sc.capabilities?.drop ?? []).includes('ALL'), `${name}: capabilities.drop must include ALL`);
    check((sc.capabilities?.add ?? []).length === 0, `${name}: no capabilities may be added`);
    check(
      c.resources?.requests?.cpu !== undefined && c.resources?.requests?.memory !== undefined,
      `${name}: cpu/memory requests`,
    );
    check(c.resources?.limits?.memory !== undefined, `${name}: memory limit`);
  }
  return spec;
}

// The requests Autopilot sees for a Pod: the larger of the sum over the app containers and the
// largest init container (Kubernetes effective requests).
function autopilotChecks(where, workload) {
  const spec = workload.spec?.template?.spec ?? {};
  const effective = (read, key) => {
    const value = (c) => read(c.resources?.requests?.[key]);
    const app = (spec.containers ?? []).reduce((sum, c) => sum + value(c), 0);
    return Math.max(app, ...(spec.initContainers ?? []).map(value));
  };
  const cpu = effective(cpuCores, 'cpu');
  const memory = effective(memoryBytes, 'memory');
  const gibPerCpu = memory / 2 ** 30 / cpu;
  check(cpu >= AUTOPILOT.minCpu, `${where}: requests ${cpu} vCPU per Pod, below the Autopilot minimum (50m)`);
  check(
    memory >= AUTOPILOT.minMemory,
    `${where}: requests ${memory / 2 ** 20} MiB per Pod, below the Autopilot minimum (52 MiB)`,
  );
  check(
    gibPerCpu >= AUTOPILOT.minGiBPerCpu && gibPerCpu <= AUTOPILOT.maxGiBPerCpu,
    `${where}: ${gibPerCpu.toFixed(2)} GiB of memory per vCPU, outside the Autopilot range (1 to 6.5)`,
  );
}

function probePath(container, probe) {
  return container?.[probe]?.httpGet?.path;
}

function commonChecks(overlay, { text, objs }) {
  check(
    !OTHER_CLOUD.test(text),
    `${overlay}: rendered manifests mention another cloud (${OTHER_CLOUD.exec(text)?.[0]})`,
  );
  for (const o of objs) {
    if (o.kind !== 'Namespace') {
      eq(o.metadata?.namespace, NAMESPACE, `${overlay}: ${o.kind}/${o.metadata?.name} namespace`);
    }
    check(
      o.kind !== 'Secret',
      `${overlay}: Secret ${o.metadata?.name} must not be in git (created at runtime or by ESO)`,
    );
  }

  const api = find(objs, 'Deployment', 'api');
  const web = find(objs, 'Deployment', 'web');
  check(api !== undefined && web !== undefined, `${overlay}: Deployments api and web`);
  if (api === undefined || web === undefined) {
    return;
  }
  const apiSpec = podChecks(`${overlay}: Deployment/api`, api);
  const webSpec = podChecks(`${overlay}: Deployment/web`, web);
  const apiContainer = apiSpec.containers?.find((c) => c.name === 'api');
  const migrate = apiSpec.initContainers?.find((c) => c.name === 'migrate');
  const webContainer = webSpec.containers?.find((c) => c.name === 'web');

  eq(apiSpec.serviceAccountName, 'api', `${overlay}: api serviceAccountName`);
  eq(webSpec.serviceAccountName, 'web', `${overlay}: web serviceAccountName`);
  eq(migrate?.args, ['dist/migrate.js'], `${overlay}: initContainer migrate args`);
  eq(migrate?.image, apiContainer?.image, `${overlay}: migrate uses the api image`);
  eq(apiContainer?.args, ['dist/server.js'], `${overlay}: api args`);
  eq(
    (apiContainer?.ports ?? []).map((p) => [p.name, p.containerPort]),
    [
      ['http', 3000],
      ['metrics', 9464],
    ],
    `${overlay}: api container ports`,
  );
  eq(probePath(apiContainer, 'startupProbe'), '/healthz', `${overlay}: api startupProbe`);
  eq(probePath(apiContainer, 'livenessProbe'), '/healthz', `${overlay}: api livenessProbe`);
  eq(probePath(apiContainer, 'readinessProbe'), '/readyz', `${overlay}: api readinessProbe`);
  eq(probePath(webContainer, 'readinessProbe'), '/healthz', `${overlay}: web readinessProbe`);
  eq(apiContainer?.lifecycle?.preStop?.sleep?.seconds, 5, `${overlay}: api preStop sleep`);
  for (const c of [migrate, apiContainer]) {
    const refs = (c?.envFrom ?? []).map((e) => e.configMapRef?.name ?? `secret:${e.secretRef?.name}`);
    eq(refs, ['app-config', 'secret:db-credentials'], `${overlay}: ${c?.name} envFrom`);
  }
  const adminToken = apiContainer?.env?.find((e) => e.name === 'ADMIN_TOKEN')?.valueFrom?.secretKeyRef;
  eq(
    adminToken && { name: adminToken.name, key: adminToken.key },
    { name: 'app-secrets', key: 'ADMIN_TOKEN' },
    `${overlay}: ADMIN_TOKEN source`,
  );
  eq(webContainer?.ports?.[0]?.containerPort, 8080, `${overlay}: web container port`);

  const apiService = find(objs, 'Service', 'api');
  const webService = find(objs, 'Service', 'web');
  eq(
    (apiService?.spec?.ports ?? []).map((p) => [p.name, p.port]),
    [
      ['http', 3000],
      ['metrics', 9464],
    ],
    `${overlay}: Service api ports`,
  );
  eq(
    (webService?.spec?.ports ?? []).map((p) => [p.name, p.port]),
    [['http', 8080]],
    `${overlay}: Service web ports`,
  );
  for (const name of ['api', 'web']) {
    eq(
      find(objs, 'ServiceAccount', name)?.automountServiceAccountToken,
      false,
      `${overlay}: ServiceAccount ${name} token`,
    );
    eq(find(objs, 'PodDisruptionBudget', name)?.spec?.minAvailable, 1, `${overlay}: PDB ${name} minAvailable`);
  }

  const deny = find(objs, 'NetworkPolicy', 'default-deny-all');
  eq(deny?.spec?.podSelector, {}, `${overlay}: default-deny-all selects every pod`);
  eq(deny?.spec?.policyTypes, ['Ingress', 'Egress'], `${overlay}: default-deny-all policyTypes`);
  check(
    deny?.spec?.ingress === undefined && deny?.spec?.egress === undefined,
    `${overlay}: default-deny-all has no rules`,
  );
  const dns = find(objs, 'NetworkPolicy', 'allow-dns-egress');
  eq(
    dns?.spec?.egress?.[0]?.to?.[0]?.podSelector?.matchLabels,
    { 'k8s-app': 'kube-dns' },
    `${overlay}: DNS egress target`,
  );
  eq(
    find(objs, 'NetworkPolicy', 'web-egress-to-api')?.spec?.egress?.[0]?.ports,
    [{ protocol: 'TCP', port: 3000 }],
    `${overlay}: web -> api:3000`,
  );
  eq(
    find(objs, 'NetworkPolicy', 'api-ingress-from-web')?.spec?.ingress?.[0]?.from?.[0]?.podSelector?.matchLabels,
    { 'app.kubernetes.io/name': 'web' },
    `${overlay}: api accepts web`,
  );
  const metrics = find(objs, 'NetworkPolicy', 'api-metrics-from-monitoring')?.spec?.ingress?.[0];
  eq(
    metrics?.from?.[0]?.namespaceSelector?.matchLabels,
    { 'kubernetes.io/metadata.name': 'monitoring' },
    `${overlay}: metrics source`,
  );
  eq(metrics?.ports, [{ protocol: 'TCP', port: 9464 }], `${overlay}: metrics port`);
  return { apiSpec, apiContainer, migrate, webContainer };
}

function localChecks({ objs }) {
  const ns = find(objs, 'Namespace', NAMESPACE);
  eq(ns?.metadata?.labels?.['pod-security.kubernetes.io/enforce'], 'restricted', 'local: PSA enforce');
  eq(ns?.metadata?.labels?.['pod-security.kubernetes.io/enforce-version'], 'latest', 'local: PSA enforce-version');
  const config = find(objs, 'ConfigMap', 'app-config')?.data ?? {};
  eq([config.APP_ENV, config.DB_SSL_MODE, config.TRUST_PROXY_HOPS], ['kind', 'disable', '1'], 'local: app-config');
  eq(config.OTEL_EXPORTER_OTLP_ENDPOINT, undefined, 'local: no trace exporter on kind (no Collector there)');
  const pg = find(objs, 'StatefulSet', 'postgres');
  const spec = pg === undefined ? {} : podChecks('local: StatefulSet/postgres', pg);
  eq(spec.securityContext?.runAsUser, 70, 'local: postgres uid');
  check(
    /^postgres:17-alpine@sha256:[0-9a-f]{64}$/.test(spec.containers?.[0]?.image ?? ''),
    'local: postgres image pinned by digest',
  );
  check(
    (spec.volumes ?? []).every((v) => v.emptyDir !== undefined),
    'local: postgres uses emptyDir volumes only',
  );
  for (const d of ['api', 'web']) {
    const pod = find(objs, 'Deployment', d)?.spec?.template?.spec;
    for (const c of [...(pod?.initContainers ?? []), ...(pod?.containers ?? [])]) {
      eq([c.image, c.imagePullPolicy], [`dx03v2-${d}:e2e`, 'Never'], `local: ${d}/${c.name} image`);
    }
  }
  eq(
    find(objs, 'NetworkPolicy', 'api-egress-to-postgres')?.spec?.egress?.[0]?.ports,
    [{ protocol: 'TCP', port: 5432 }],
    'local: api -> postgres:5432',
  );
  eq(
    find(objs, 'NetworkPolicy', 'postgres-ingress-from-api')?.spec?.ingress?.[0]?.from?.[0]?.podSelector?.matchLabels,
    { 'app.kubernetes.io/name': 'api' },
    'local: postgres accepts api only',
  );
  for (const kind of GCP_ONLY_KINDS) {
    eq(names(objs, kind), [], `local: no ${kind} (Google Cloud only)`);
  }
}

function gcpChecks(overlay, { objs }, params, waf) {
  for (const o of objs) {
    check(DEPLOYER_KINDS.has(o.kind), `${overlay}: ${o.kind} is outside what the dx03v2-deployer Role may write`);
    eq(
      o.metadata?.labels?.['app.kubernetes.io/part-of'],
      'dx03v2',
      `${overlay}: ${o.kind}/${o.metadata?.name} part-of label`,
    );
    // deploy-params is dropped by kustomize; the GKE Gateway and its policies need no annotation.
    eq(
      Object.keys(o.metadata?.annotations ?? {}),
      [],
      `${overlay}: ${o.kind}/${o.metadata?.name} carries no annotations`,
    );
  }
  const config = find(objs, 'ConfigMap', 'app-config')?.data ?? {};
  eq(
    [config.APP_ENV, config.DB_SSL_MODE, config.DB_SSL_CA_FILE, config.TRUST_PROXY_HOPS],
    ['lab', 'verify-full', '/etc/cloudsql-ca/ca.pem', '2'],
    `${overlay}: app-config (TRUST_PROXY_HOPS=2: Google Front End + load balancer address)`,
  );
  const api = find(objs, 'Deployment', 'api');
  const web = find(objs, 'Deployment', 'web');
  const pod = api?.spec?.template?.spec ?? {};
  check(api?.spec?.replicas === undefined, `${overlay}: api replicas must be left to the HPA`);
  eq(pod.volumes, [{ name: 'cloudsql-ca', configMap: { name: 'cloudsql-ca' } }], `${overlay}: cloudsql-ca volume`);
  for (const c of [...(pod.initContainers ?? []), ...(pod.containers ?? [])]) {
    eq(
      c.volumeMounts,
      [{ name: 'cloudsql-ca', mountPath: '/etc/cloudsql-ca', readOnly: true }],
      `${overlay}: ${c.name} mounts cloudsql-ca`,
    );
    eq(c.image, params.API_IMAGE, `${overlay}: ${c.name} image from params`);
  }
  const webContainer = web?.spec?.template?.spec?.containers?.[0];
  eq(webContainer?.image, params.WEB_IMAGE, `${overlay}: web image from params`);
  eq(webContainer?.resources?.requests?.memory, '64Mi', `${overlay}: web memory request (Autopilot minimum 52 MiB)`);
  for (const workload of [api, web]) {
    if (workload !== undefined) {
      autopilotChecks(`${overlay}: Deployment/${workload.metadata?.name}`, workload);
    }
  }

  // Gateway API on the GKE Gateway controller: a global external Application Load Balancer on the
  // reserved address of tx03v2 (docs/CONTRATO.md).
  eq(names(objs, 'Gateway'), ['dx03v2'], `${overlay}: exactly one Gateway`);
  const gateway = find(objs, 'Gateway', 'dx03v2');
  eq(
    gateway?.spec?.gatewayClassName,
    'gke-l7-global-external-managed',
    `${overlay}: GatewayClass (global external Application Load Balancer)`,
  );
  eq(
    gateway?.spec?.addresses,
    [{ type: 'NamedAddress', value: params.GATEWAY_ADDRESS_NAME }],
    `${overlay}: reserved address name from params`,
  );
  eq(
    gateway?.spec?.listeners,
    [{ name: 'http', protocol: 'HTTP', port: 80, allowedRoutes: { namespaces: { from: 'Same' } } }],
    `${overlay}: one HTTP listener on 80 (HTTPS planned)`,
  );
  eq(names(objs, 'HTTPRoute'), ['dx03v2'], `${overlay}: exactly one HTTPRoute`);
  const route = find(objs, 'HTTPRoute', 'dx03v2')?.spec;
  eq(route?.parentRefs, [{ name: 'dx03v2', sectionName: 'http' }], `${overlay}: HTTPRoute parent`);
  check(route?.hostnames === undefined, `${overlay}: HTTPRoute without hostnames (reached by the Gateway address)`);
  eq(
    (route?.rules ?? []).map((r) => [
      r.matches?.length,
      r.matches?.[0]?.path?.type,
      r.matches?.[0]?.path?.value,
      r.filters,
      r.backendRefs?.map((b) => [b.name, b.port, b.kind ?? 'Service', b.weight]),
    ]),
    [
      [1, 'PathPrefix', '/api', undefined, [['api', 3000, 'Service', undefined]]],
      [1, 'PathPrefix', '/', undefined, [['web', 8080, 'Service', undefined]]],
    ],
    `${overlay}: HTTPRoute rules (/api -> api:3000, / -> web:8080)`,
  );
  // One HealthCheckPolicy per Service of the HTTPRoute (contract: web /healthz on 8080, api
  // /readyz on 3000, the container ports the network endpoint groups point at).
  eq(names(objs, 'HealthCheckPolicy'), ['api', 'web'], `${overlay}: HealthCheckPolicies`);
  for (const [name, port, path] of [
    ['web', 8080, '/healthz'],
    ['api', 3000, '/readyz'],
  ]) {
    const policy = find(objs, 'HealthCheckPolicy', name)?.spec;
    eq(policy?.targetRef, { group: '', kind: 'Service', name }, `${overlay}: HealthCheckPolicy ${name} target`);
    eq(
      policy?.default?.config,
      { type: 'HTTP', httpHealthCheck: { port, requestPath: path } },
      `${overlay}: HealthCheckPolicy ${name} (HTTP ${port} ${path})`,
    );
  }
  const backendPolicies = names(objs, 'GCPBackendPolicy');
  if (waf) {
    check(
      params.WAF_SECURITY_POLICY !== undefined && params.WAF_SECURITY_POLICY !== 'none',
      `${overlay}: rendered with a Cloud Armor security policy name`,
    );
    eq(backendPolicies, ['api', 'web'], `${overlay}: one GCPBackendPolicy per Service of the HTTPRoute`);
    for (const name of ['api', 'web']) {
      const policy = find(objs, 'GCPBackendPolicy', name)?.spec;
      eq(policy?.targetRef, { group: '', kind: 'Service', name }, `${overlay}: GCPBackendPolicy ${name} target`);
      eq(
        policy?.default,
        { securityPolicy: params.WAF_SECURITY_POLICY },
        `${overlay}: GCPBackendPolicy ${name} attaches only the Cloud Armor policy from params`,
      );
    }
  } else {
    eq(backendPolicies, [], `${overlay}: no GCPBackendPolicy without Cloud Armor`);
  }

  const store = { kind: 'ClusterSecretStore', name: 'gcp-secret-manager' };
  const db = find(objs, 'ExternalSecret', 'db-credentials')?.spec;
  eq(db?.secretStoreRef, store, `${overlay}: db-credentials store`);
  eq(db?.target, { name: 'db-credentials', creationPolicy: 'Owner' }, `${overlay}: db-credentials target`);
  eq(
    (db?.data ?? []).map((d) => [d.secretKey, d.remoteRef?.key, d.remoteRef?.property]),
    [
      ['DB_HOST', 'tx03v2-lab-db-app', 'host'],
      ['DB_PORT', 'tx03v2-lab-db-app', 'port'],
      ['DB_NAME', 'tx03v2-lab-db-app', 'dbname'],
      ['DB_USER', 'tx03v2-lab-db-app', 'username'],
      ['DB_PASSWORD', 'tx03v2-lab-db-app', 'password'],
    ],
    `${overlay}: db-credentials mapping`,
  );
  const app = find(objs, 'ExternalSecret', 'app-secrets')?.spec;
  eq(app?.secretStoreRef, store, `${overlay}: app-secrets store`);
  eq(app?.target, { name: 'app-secrets', creationPolicy: 'Owner' }, `${overlay}: app-secrets target`);
  eq(
    (app?.data ?? []).map((d) => [d.secretKey, d.remoteRef?.key, d.remoteRef?.property]),
    [['ADMIN_TOKEN', 'tx03v2-lab-app-admin-token', undefined]],
    `${overlay}: app-secrets mapping`,
  );

  const hpa = find(objs, 'HorizontalPodAutoscaler', 'api')?.spec;
  eq(
    [
      hpa?.scaleTargetRef?.name,
      hpa?.minReplicas,
      hpa?.maxReplicas,
      hpa?.metrics?.[0]?.resource?.target?.averageUtilization,
    ],
    ['api', 2, 4, 70],
    `${overlay}: HPA`,
  );

  // Exactly the base policies plus the four Google Cloud edges: nothing else widens the namespace.
  eq(
    names(objs, 'NetworkPolicy'),
    [...BASE_NETWORK_POLICIES, ...GCP_NETWORK_POLICIES].sort(),
    `${overlay}: NetworkPolicies`,
  );
  eq(
    (params.LB_SOURCE_RANGES ?? '').split(','),
    LB_SOURCE_RANGES,
    `${overlay}: params LB_SOURCE_RANGES (docs/CONTRATO.md)`,
  );
  check(
    /^(?:[0-9]{1,3}\.){3}[0-9]{1,3}$/.test(params.DB_ENDPOINT_IP ?? ''),
    `${overlay}: params DB_ENDPOINT_IP is one IPv4 address`,
  );
  const lbPeers = LB_SOURCE_RANGES.map((cidr) => ({ ipBlock: { cidr } }));
  for (const [name, selected, direction, peers, ports] of [
    ['web-ingress-from-lb', 'web', 'Ingress', lbPeers, [{ protocol: 'TCP', port: 8080 }]],
    ['api-ingress-from-lb', 'api', 'Ingress', lbPeers, [{ protocol: 'TCP', port: 3000 }]],
    [
      'api-egress-to-cloudsql',
      'api',
      'Egress',
      [{ ipBlock: { cidr: `${params.DB_ENDPOINT_IP}/32` } }],
      [{ protocol: 'TCP', port: 5432 }],
    ],
    [
      'allow-node-dns-cache-egress',
      undefined,
      'Egress',
      [{ ipBlock: { cidr: NODE_DNS_CACHE } }],
      [
        { protocol: 'UDP', port: 53 },
        { protocol: 'TCP', port: 53 },
      ],
    ],
  ]) {
    const spec = find(objs, 'NetworkPolicy', name)?.spec;
    eq(
      spec?.podSelector,
      selected === undefined ? {} : { matchLabels: { 'app.kubernetes.io/name': selected } },
      `${overlay}: NetworkPolicy ${name} selects ${selected ?? 'every pod'}`,
    );
    eq(spec?.policyTypes, [direction], `${overlay}: NetworkPolicy ${name} type`);
    eq(
      spec?.[direction.toLowerCase()],
      [{ [direction === 'Ingress' ? 'from' : 'to']: peers, ports }],
      `${overlay}: NetworkPolicy ${name} (exact peers and ports, no except)`,
    );
  }
  // Contract v2: traces to the OpenTelemetry Collector of the platform layer, and nowhere else.
  eq(
    config.OTEL_EXPORTER_OTLP_ENDPOINT,
    'http://opentelemetry-collector.observability.svc:4318',
    `${overlay}: OTLP endpoint of the contract`,
  );
  eq(
    find(objs, 'NetworkPolicy', 'api-egress-to-collector')?.spec?.egress,
    [
      {
        to: [
          {
            namespaceSelector: { matchLabels: { 'kubernetes.io/metadata.name': 'observability' } },
            podSelector: { matchLabels: { 'app.kubernetes.io/name': 'opentelemetry-collector' } },
          },
        ],
        ports: [{ protocol: 'TCP', port: 4318 }],
      },
    ],
    `${overlay}: api -> OpenTelemetry Collector (4318) only`,
  );
}

// Kinds the AppProject dx03v2 of the tx03v2 local lab lets Argo CD sync (local contract,
// platform/local/manifests/argocd-project-dx03v2.yaml of tx03v2).
const APPPROJECT_KINDS = new Set([
  'AuthorizationPolicy',
  'ConfigMap',
  'Deployment',
  'ExternalSecret',
  'Gateway',
  'HTTPRoute',
  'HorizontalPodAutoscaler',
  'NetworkPolicy',
  'PeerAuthentication',
  'PodDisruptionBudget',
  'PrometheusRule',
  'Service',
  'ServiceAccount',
  'ServiceMonitor',
]);

function localPlatformChecks({ objs }, params) {
  const overlay = 'local-platform';
  for (const o of objs) {
    check(APPPROJECT_KINDS.has(o.kind), `${overlay}: ${o.kind} is outside what the AppProject dx03v2 may sync`);
  }
  const config = find(objs, 'ConfigMap', 'app-config')?.data ?? {};
  // One proxy hop in front of the API: the Envoy of the Istio Gateway (the load balancer emulator
  // in front of it is a TCP proxy and adds no X-Forwarded-For entry).
  eq(
    [config.APP_ENV, config.DB_SSL_MODE, config.DB_SSL_CA_FILE, config.TRUST_PROXY_HOPS],
    ['lab', 'verify-full', '/etc/lab-ca/ca.crt', '1'],
    `${overlay}: app-config`,
  );
  const api = find(objs, 'Deployment', 'api');
  const pod = api?.spec?.template?.spec ?? {};
  check(api?.spec?.replicas === undefined, `${overlay}: api replicas must be left to the HPA`);
  eq(pod.volumes, [{ name: 'lab-ca', configMap: { name: 'lab-ca' } }], `${overlay}: lab-ca volume`);
  for (const c of [...(pod.initContainers ?? []), ...(pod.containers ?? [])]) {
    eq(
      c.volumeMounts,
      [{ name: 'lab-ca', mountPath: '/etc/lab-ca', readOnly: true }],
      `${overlay}: ${c.name} mounts lab-ca`,
    );
    eq(c.image, params.API_IMAGE, `${overlay}: ${c.name} image from params`);
  }
  eq(
    find(objs, 'Deployment', 'web')?.spec?.template?.spec?.containers?.[0]?.image,
    params.WEB_IMAGE,
    `${overlay}: web image from params`,
  );

  eq(
    all(objs, 'Gateway').map((g) => g.metadata?.name),
    ['dx03v2'],
    `${overlay}: exactly one Gateway`,
  );
  const gw = find(objs, 'Gateway', 'dx03v2');
  eq(gw?.spec?.gatewayClassName, 'istio', `${overlay}: Gateway class`);
  eq(gw?.metadata?.annotations?.['cert-manager.io/cluster-issuer'], 'lab-ca', `${overlay}: Gateway issuer`);
  eq(
    (gw?.spec?.listeners ?? []).map((l) => [l.name, l.protocol, l.port, l.hostname, l.tls?.certificateRefs?.[0]?.name]),
    [
      ['http', 'HTTP', 80, 'dx03v2.tx03v2.local', undefined],
      ['https', 'HTTPS', 443, 'dx03v2.tx03v2.local', 'dx03v2-tls'],
    ],
    `${overlay}: Gateway listeners`,
  );
  const redirect = find(objs, 'HTTPRoute', 'dx03v2-redirect')?.spec;
  eq(redirect?.parentRefs?.[0]?.sectionName, 'http', `${overlay}: redirect on the http listener`);
  eq(
    redirect?.rules?.[0]?.filters?.[0]?.requestRedirect,
    { scheme: 'https', statusCode: 301 },
    `${overlay}: HTTP -> HTTPS redirect`,
  );
  const route = find(objs, 'HTTPRoute', 'dx03v2')?.spec;
  eq(route?.parentRefs?.[0]?.sectionName, 'https', `${overlay}: app routes on the https listener only`);
  eq(
    (route?.rules ?? []).map((r) => [r.matches?.[0]?.path?.value, r.backendRefs?.[0]?.name, r.backendRefs?.[0]?.port]),
    [
      ['/api', 'api', 3000],
      ['/', 'web', 8080],
    ],
    `${overlay}: HTTPRoute rules (the same as on the GKE Gateway)`,
  );

  const db = find(objs, 'ExternalSecret', 'db-credentials')?.spec;
  eq(db?.secretStoreRef, { kind: 'ClusterSecretStore', name: 'local-secrets' }, `${overlay}: db-credentials store`);
  eq(
    (db?.data ?? []).map((d) => [d.secretKey, d.remoteRef?.key, d.remoteRef?.property]),
    [
      ['DB_HOST', 'tx03v2-lab-db-app', 'host'],
      ['DB_PORT', 'tx03v2-lab-db-app', 'port'],
      ['DB_NAME', 'tx03v2-lab-db-app', 'dbname'],
      ['DB_USER', 'tx03v2-lab-db-app', 'username'],
      ['DB_PASSWORD', 'tx03v2-lab-db-app', 'password'],
    ],
    `${overlay}: db-credentials mapping`,
  );
  const app = find(objs, 'ExternalSecret', 'app-secrets')?.spec;
  eq(app?.secretStoreRef, { kind: 'ClusterSecretStore', name: 'local-secrets' }, `${overlay}: app-secrets store`);
  // Secret Manager holds the admin token as a plain string; the local twin keeps it under the key token.
  eq(
    (app?.data ?? []).map((d) => [d.secretKey, d.remoteRef?.key, d.remoteRef?.property]),
    [['ADMIN_TOKEN', 'tx03v2-lab-app-admin-token', 'token']],
    `${overlay}: app-secrets mapping`,
  );

  eq(find(objs, 'PeerAuthentication', 'default')?.spec?.mtls?.mode, 'STRICT', `${overlay}: mTLS STRICT`);
  const principals = (name) =>
    (find(objs, 'AuthorizationPolicy', name)?.spec?.rules ?? []).map((r) => [
      r.from?.[0]?.source?.principals,
      r.to?.[0]?.operation?.ports,
    ]);
  eq(
    principals('api'),
    [
      [['cluster.local/ns/dx03v2/sa/web', 'cluster.local/ns/dx03v2/sa/dx03v2-istio'], ['3000']],
      [['cluster.local/ns/monitoring/sa/kube-prometheus-stack-prometheus'], ['9464']],
    ],
    `${overlay}: AuthorizationPolicy api`,
  );
  eq(
    principals('web'),
    [[['cluster.local/ns/dx03v2/sa/dx03v2-istio'], ['8080']]],
    `${overlay}: AuthorizationPolicy web`,
  );

  eq(
    find(objs, 'NetworkPolicy', 'gateway-ingress-from-load-balancer')?.spec?.ingress?.[0]?.from?.[0]?.ipBlock?.cidr,
    params.NETWORK_CIDR,
    `${overlay}: Gateway ingress only from the lab network`,
  );
  eq(
    find(objs, 'NetworkPolicy', 'api-egress-to-db')?.spec?.egress?.[0],
    { to: [{ ipBlock: { cidr: params.DB_ENDPOINT_CIDR } }], ports: [{ protocol: 'TCP', port: 5432 }] },
    `${overlay}: api -> database only`,
  );
  // Local contract v2: the OTLP endpoint and the paths of the spans (API and Gateway, both over the mesh).
  eq(
    config.OTEL_EXPORTER_OTLP_ENDPOINT,
    'http://opentelemetry-collector.monitoring.svc:4318',
    `${overlay}: OTLP endpoint of the local contract`,
  );
  const collector = {
    namespaceSelector: { matchLabels: { 'kubernetes.io/metadata.name': 'monitoring' } },
    podSelector: { matchLabels: { 'app.kubernetes.io/name': 'opentelemetry-collector' } },
  };
  eq(
    find(objs, 'NetworkPolicy', 'api-egress-to-collector')?.spec?.egress,
    [
      {
        to: [collector],
        ports: [
          { protocol: 'TCP', port: 4318 },
          { protocol: 'TCP', port: 15008 },
        ],
      },
    ],
    `${overlay}: api -> OpenTelemetry Collector (OTLP/HTTP over HBONE) only`,
  );
  // Every Gateway egress rule that names the Collector: exactly one, OTLP/gRPC (4317) over HBONE (15008).
  eq(
    (find(objs, 'NetworkPolicy', 'gateway-egress')?.spec?.egress ?? []).filter((r) =>
      (r.to ?? []).some((peer) => JSON.stringify(canonical(peer)) === JSON.stringify(canonical(collector))),
    ),
    [
      {
        to: [collector],
        ports: [
          { protocol: 'TCP', port: 4317 },
          { protocol: 'TCP', port: 15008 },
        ],
      },
    ],
    `${overlay}: the Gateway must reach the OpenTelemetry Collector on 4317 over HBONE (its spans) and only there`,
  );
  for (const name of ['api-ingress-mesh', 'web-ingress-mesh']) {
    const rules = find(objs, 'NetworkPolicy', name)?.spec?.ingress ?? [];
    check(
      rules.some((r) => (r.ports ?? []).some((p) => p.port === 15008)),
      `${overlay}: ${name} must allow HBONE (15008)`,
    );
    check(
      rules.some((r) => r.from?.[0]?.ipBlock?.cidr === '169.254.7.127/32'),
      `${overlay}: ${name} must allow the ambient kubelet probes (169.254.7.127/32)`,
    );
  }
  eq(
    find(objs, 'ServiceMonitor', 'api')?.spec?.endpoints?.[0]?.port,
    'metrics',
    `${overlay}: ServiceMonitor scrapes the metrics port`,
  );
  eq(
    (find(objs, 'PrometheusRule', 'dx03v2')?.spec?.groups?.[0]?.rules ?? []).map((r) => r.alert),
    ['Dx03v2ApiDown', 'Dx03v2HighErrorRate', 'Dx03v2HighLatencyP95', 'Dx03v2PodRestarting', 'Dx03v2PodNotReady'],
    `${overlay}: alert rules`,
  );
  eq(
    find(objs, 'ConfigMap', 'dx03v2-dashboard')?.metadata?.labels?.grafana_dashboard,
    '1',
    `${overlay}: dashboard ConfigMap for the Grafana sidecar`,
  );
  const hpa = find(objs, 'HorizontalPodAutoscaler', 'api')?.spec;
  eq([hpa?.minReplicas, hpa?.maxReplicas], [2, 4], `${overlay}: HPA`);
}

const { params, files, localParams } = parseArgs(process.argv.slice(2));
const rendered = {};
for (const [overlay, file] of Object.entries(files)) {
  rendered[overlay] = load(file);
  commonChecks(overlay, rendered[overlay]);
  if (overlay === 'local') {
    localChecks(rendered[overlay]);
  } else if (overlay === 'gcp' || overlay === 'gcp-waf') {
    gcpChecks(overlay, rendered[overlay], params, overlay === 'gcp-waf');
  } else if (overlay === 'local-platform') {
    check(localParams !== undefined, 'local-platform needs --local-params');
    if (localParams !== undefined) {
      localPlatformChecks(rendered[overlay], localParams);
    }
  } else {
    failures.push(`unknown overlay ${overlay}`);
  }
}
// The WAF variant differs from the plain one only by the GCPBackendPolicies.
if (rendered.gcp !== undefined && rendered['gcp-waf'] !== undefined) {
  const withoutWaf = ({ objs }) =>
    JSON.stringify(objs.filter((o) => o.kind !== 'GCPBackendPolicy').map((o) => canonical(o)));
  check(
    withoutWaf(rendered.gcp) === withoutWaf(rendered['gcp-waf']),
    'gcp-waf: renders the same objects as gcp apart from the GCPBackendPolicies',
  );
}

if (failures.length > 0) {
  console.log(failures.map((f) => `FAIL ${f}`).join('\n'));
  console.log(`${failures.length} of ${assertions} assertions failed`);
  process.exit(1);
}
console.log(
  `SUMMARY: contract and hardening checks: ${assertions} assertions passed (${Object.keys(files).join(', ')})`,
);

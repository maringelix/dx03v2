// Read-only bounded HTTPS workload through the real Gateway; no credentials or request bodies logged.
import https from 'node:https';
import { performance } from 'node:perf_hooks';
import { pathToFileURL } from 'node:url';

export function summarize(samples) {
  if (!samples.length) throw new Error('no load samples');
  const sorted = samples.map((s) => s.ms).sort((a, b) => a - b);
  return {
    requests: samples.length,
    failed: samples.filter((s) => s.status !== 200).length,
    p99Ms: sorted[Math.ceil(sorted.length * 0.99) - 1],
  };
}

export function meetsSlo(report) {
  return report.requests >= 20 && report.failed / report.requests <= 0.01 && report.p99Ms <= 1500;
}

export async function workload(url, seconds, concurrency) {
  const target = new URL(url);
  if (target.protocol !== 'https:' || target.pathname !== '/api/messages')
    throw new Error('only HTTPS message reads are allowed');
  if (!Number.isInteger(seconds) || seconds < 1 || seconds > 180) throw new Error('duration must be 1-180 seconds');
  if (!Number.isInteger(concurrency) || concurrency < 1 || concurrency > 32)
    throw new Error('concurrency must be 1-32');
  const samples = [];
  const until = Date.now() + seconds * 1000;
  const read = () =>
    new Promise((resolve) => {
      const start = performance.now();
      let finished = false;
      const done = (status) => {
        if (finished) return;
        finished = true;
        samples.push({ status, ms: performance.now() - start });
        resolve();
      };
      const req = https.get(target, { timeout: 2500, agent: false }, (res) => {
        res.resume();
        res.on('end', () => done(res.statusCode));
        res.on('error', () => done(0));
      });
      req.on('timeout', () => req.destroy());
      req.on('error', () => done(0));
    });
  await Promise.all(
    Array.from({ length: concurrency }, async () => {
      while (Date.now() < until) {
        await read();
        await new Promise((resolve) => setTimeout(resolve, 100));
      }
    }),
  );
  return summarize(samples);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const report = await workload(
      process.env.CAPACITY_URL,
      Number(process.env.DURATION_SECONDS ?? 30),
      Number(process.env.CONCURRENCY ?? 4),
    );
    console.log(JSON.stringify(report));
    const ok = process.env.EXPECT_FAILURE === '1' ? report.failed > 0 : meetsSlo(report);
    if (!ok) process.exitCode = 1;
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}

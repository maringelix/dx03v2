// JSON logging with pino. Credentials never reach the output: the Authorization and Cookie
// headers and any `password`/`token` field (top level or one level deep) are redacted. A line written
// inside a traced request carries `trace_id` and `span_id` (W3C, hex), which Grafana turns into a link
// to the trace in Tempo.
import { isSpanContextValid, trace } from '@opentelemetry/api';
import { pino, type DestinationStream, type Logger, type LoggerOptions as PinoOptions } from 'pino';

export const REDACT_PATHS = [
  'req.headers.authorization',
  'req.headers.cookie',
  'res.headers["set-cookie"]',
  'password',
  'token',
  '*.password',
  '*.token',
  'DB_PASSWORD',
  'ADMIN_TOKEN',
];

export interface LoggerOptions {
  level: string;
  appEnv: string;
  version: string;
  gitSha: string;
}

/** trace_id and span_id of the active span, or nothing outside a traced request. */
export function traceFields(): { trace_id?: string; span_id?: string } {
  const spanContext = trace.getActiveSpan()?.spanContext();
  if (spanContext === undefined || !isSpanContextValid(spanContext)) {
    return {};
  }
  return { trace_id: spanContext.traceId, span_id: spanContext.spanId };
}

export function createLogger(options: LoggerOptions, destination?: DestinationStream): Logger {
  const pinoOptions: PinoOptions = {
    level: options.level,
    base: { service: 'dx03v2-api', env: options.appEnv, version: options.version, commit: options.gitSha },
    timestamp: pino.stdTimeFunctions.isoTime,
    redact: { paths: REDACT_PATHS, censor: '[Redacted]' },
    formatters: {
      level: (label) => ({ level: label }),
    },
    mixin: traceFields,
  };
  return destination ? pino(pinoOptions, destination) : pino(pinoOptions);
}

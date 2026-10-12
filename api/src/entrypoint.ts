// Helpers shared by the two entrypoints (server.ts, migrate.ts).
import { readFileSync, realpathSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

/** true when the module at `moduleUrl` is the script Node was started with (not an import). */
export function isMain(moduleUrl: string, argv1: string | undefined = process.argv[1]): boolean {
  if (argv1 === undefined) {
    return false;
  }
  try {
    return moduleUrl === pathToFileURL(realpathSync(argv1)).href;
  } catch {
    return false;
  }
}

/** Version of the API package (api/package.json, one level above src/ and dist/). */
export function readVersion(packageJsonUrl: URL = new URL('../package.json', import.meta.url)): string {
  const parsed: unknown = JSON.parse(readFileSync(packageJsonUrl, 'utf8'));
  if (typeof parsed === 'object' && parsed !== null && 'version' in parsed && typeof parsed.version === 'string') {
    return parsed.version;
  }
  return '0.0.0';
}

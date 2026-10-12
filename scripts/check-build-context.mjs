// Proves that paths stay out of a Docker build context, given its ignore file (.dockerignore or a
// Dockerfile-specific <Dockerfile>.dockerignore), with the matching rules of BuildKit
// (moby/patternmatcher): lines starting with `#` are comments, each pattern is cleaned and made
// relative to the context root, the last matching line wins, `!` re-includes, `*` and `?` never
// cross `/`, `**` spans any number of directories, and a pattern that matches a parent directory
// covers everything under it. Used by the harness check `policy-images`:
//   node scripts/check-build-context.mjs <ignore-file> <path>...
// Exits 1 listing every path the build context would still contain.
import { readFileSync } from 'node:fs';
import { posix } from 'node:path';

const REGEX_SPECIAL = '.+()|{}$^';

function clean(pattern) {
  let p = posix.normalize(pattern);
  if (p.length > 1 && p.endsWith('/')) {
    p = p.slice(0, -1);
  }
  return p.length > 1 && p.startsWith('/') ? p.slice(1) : p;
}

function compile(pattern) {
  let re = '^';
  for (let i = 0; i < pattern.length; i++) {
    const ch = pattern[i];
    if (ch === '*' && pattern[i + 1] === '*') {
      i++;
      if (pattern[i + 1] === '/') {
        i++;
      }
      re += i + 1 >= pattern.length ? '.*' : '(.*/)?';
    } else if (ch === '*') {
      re += '[^/]*';
    } else if (ch === '?') {
      re += '[^/]';
    } else if (ch === '\\') {
      re += i + 1 < pattern.length ? `\\${pattern[++i]}` : '\\\\';
    } else if (REGEX_SPECIAL.includes(ch)) {
      re += `\\${ch}`;
    } else {
      re += ch;
    }
  }
  return new RegExp(`${re}$`);
}

function readRules(file) {
  return readFileSync(file, 'utf8')
    .replace(/^\uFEFF/, '')
    .split('\n')
    .filter((line) => !line.startsWith('#'))
    .map((line) => line.trim())
    .filter((line) => line !== '')
    .map((line) => {
      const negate = line.startsWith('!');
      const pattern = clean(negate ? line.slice(1).trim() : line);
      return { negate, re: compile(pattern) };
    });
}

function excluded(rules, path) {
  const dirs = path.split('/').slice(0, -1);
  let matched = false;
  for (const { negate, re } of rules) {
    // A re-include only matters once the path is excluded, an exclusion only while it is not.
    if (negate !== matched) {
      continue;
    }
    let hit = re.test(path);
    for (let i = 1; !hit && i <= dirs.length; i++) {
      hit = re.test(dirs.slice(0, i).join('/'));
    }
    if (hit) {
      matched = !negate;
    }
  }
  return matched;
}

const [file, ...paths] = process.argv.slice(2);
if (file === undefined || paths.length === 0) {
  console.error('usage: node scripts/check-build-context.mjs <ignore-file> <path>...');
  process.exit(2);
}
const rules = readRules(file);
const sent = paths.filter((path) => !excluded(rules, path));
for (const path of sent) {
  console.log(`${file}: ${path} would be sent to the build context`);
}
process.exitCode = sent.length === 0 ? 0 : 1;

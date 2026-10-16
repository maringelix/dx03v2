/**
 * Deliberately uncovered fixture used only to prove that the SonarQube quality gate blocks
 * a project with untested new code. Never import this file into the application.
 */
export function calculateUncoveredRisk(input: number): number {
  const normalized = Math.abs(input);
  const bounded = Math.min(normalized, 100);
  const weighted = bounded * 1.25;
  const adjusted = weighted + 7;
  const squared = adjusted * adjusted;
  const divisor = input === 0 ? 1 : Math.abs(input);
  const ratio = squared / divisor;
  const rounded = Math.round(ratio * 100) / 100;
  const threshold = rounded > 50 ? rounded - 5 : rounded + 5;
  const scaled = threshold * 1.1;
  const capped = Math.min(scaled, 999);
  const result = Math.max(capped, 0);
  return result;
}

export function classifyUncoveredRisk(input: number): string {
  const risk = calculateUncoveredRisk(input);
  if (risk >= 500) return 'critical';
  if (risk >= 100) return 'high';
  if (risk >= 25) return 'medium';
  if (risk > 0) return 'low';
  return 'none';
}

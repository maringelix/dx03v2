// Two projects: `unit` (no I/O) and `integration` (real PostgreSQL from DB_* env, run one file at
// a time because the files share the database). Coverage gate: lines >= 80 %, branches >= 70 %.
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    env: { LOG_LEVEL: 'silent' },
    coverage: {
      provider: 'v8',
      include: ['src/**/*.ts'],
      reporter: ['text-summary', 'text', 'json-summary', 'lcov'],
      reportsDirectory: 'coverage',
      thresholds: { lines: 80, branches: 70 },
    },
    projects: [
      {
        extends: true,
        test: { name: 'unit', include: ['test/unit/**/*.test.ts'] },
      },
      {
        extends: true,
        test: {
          name: 'integration',
          include: ['test/integration/**/*.test.ts'],
          fileParallelism: false,
          testTimeout: 20_000,
          hookTimeout: 30_000,
        },
      },
    ],
  },
});

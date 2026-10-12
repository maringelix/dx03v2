/// <reference types="vitest/config" />
// Vite build of the single page + its tests (jsdom). `npm run dev` proxies /api to a local API on
// port 3000 so the browser keeps talking to a single origin, like nginx and Application Gateway
// for Containers do.
import react from '@vitejs/plugin-react';
import { defineConfig } from 'vite';

export default defineConfig({
  plugins: [react()],
  build: {
    outDir: 'dist',
    sourcemap: false,
    // No inline <script>/<style>: the CSP (script-src 'self'; style-src 'self') forbids them.
    assetsInlineLimit: 0,
  },
  server: {
    host: '127.0.0.1',
    port: 5173,
    proxy: { '/api': 'http://127.0.0.1:3000' },
  },
  test: {
    environment: 'jsdom',
    setupFiles: ['src/test/setup.ts'],
    include: ['src/**/*.test.{ts,tsx}'],
    restoreMocks: true,
    coverage: {
      provider: 'v8',
      include: ['src/**/*.{ts,tsx}'],
      // main.tsx only mounts <App /> into #root; everything it renders is covered through App.
      exclude: ['src/test/**', 'src/main.tsx'],
      reporter: ['text-summary', 'text', 'json-summary'],
      reportsDirectory: 'coverage',
      thresholds: { lines: 70 },
    },
  },
});

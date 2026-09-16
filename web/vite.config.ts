import tailwindcss from '@tailwindcss/postcss';
import vinext from 'vinext';
import { defineConfig } from 'vite';
export default defineConfig({
  css: { postcss: { plugins: [tailwindcss()] } },
  server: {
    host: '127.0.0.1',
    port: 4181,
    strictPort: true,
    allowedHosts: ['leekt-macmini.tail45c85e.ts.net'],
    fs: {
      strict: true,
      deny: ['.env', '.env.*', '**/.git/**', '**/*.pem', '**/*.key'],
    },
  },
  plugins: [vinext()],
});

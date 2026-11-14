import preact from '@preact/preset-vite';
import tailwindcss from '@tailwindcss/vite';
import { resolve } from 'node:path';
import { defineConfig } from 'vite';

export default defineConfig({
  define: { 'process.env.NODE_ENV': JSON.stringify('production') },
  plugins: [preact(), tailwindcss(), {
    name: 'desktop-html',
    generateBundle(_options, bundle) {
      const entry = Object.values(bundle).find((item) => item.type === 'chunk' && item.isEntry);
      if (!entry || entry.type !== 'chunk') throw new Error('Missing desktop entry');
      const script = entry.code.replaceAll('</script', '<\\/script');
      this.emitFile({ type: 'asset', fileName: 'index.html', source: `<!doctype html><html><head><meta charset="utf-8"><style>html,body{margin:0;width:100%;height:100%;background:transparent}</style></head><body><script>window.addEventListener('error',e=>window.chrome?.webview?.postMessage({type:'page:error',message:e.message,line:e.lineno}));</script><script>${script}</script></body></html>` });
    },
  }],
  build: {
    outDir: resolve(__dirname, '../../../packages/desktop-uia/web'),
    emptyOutDir: true,
    lib: { entry: resolve(__dirname, 'main.tsx'), name: 'MarkLayerDesktop', formats: ['iife'], fileName: () => 'app.js' },
  },
});

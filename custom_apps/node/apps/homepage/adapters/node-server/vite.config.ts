import { nodeServerAdapter } from '@builder.io/qwik-city/adapters/node-server/vite';
import { extendConfig } from '@builder.io/qwik-city/vite';
import baseConfig from '../../vite.config';

export default extendConfig(baseConfig, () => ({
  build: {
    outDir: 'dist/server',
    emptyOutDir: true,
    ssr: true,
    rollupOptions: {
      input: ['src/entry.node-server.tsx', '@qwik-city-plan'],
    },
  },
  plugins: [
    nodeServerAdapter({
      name: 'node-server',
    }),
  ],
}));

import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// The bridge owns the serial port and, in production, serves dist/ itself so
// the app and the WebSocket share an origin. In dev, Vite serves the app and
// proxies /ws to the bridge instead.
const BRIDGE = process.env.BRIDGE_URL ?? 'ws://127.0.0.1:8781'

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5273,
    proxy: {
      '/ws': { target: BRIDGE, ws: true },
      '/api': { target: BRIDGE.replace(/^ws/, 'http') },
    },
  },
  build: { outDir: 'dist', sourcemap: true },
})

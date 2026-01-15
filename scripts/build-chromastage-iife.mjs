import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { rollup } from 'rollup';
import { nodeResolve } from '@rollup/plugin-node-resolve';
import commonjs from '@rollup/plugin-commonjs';
import terser from '@rollup/plugin-terser';
import assemblyscriptPlugin from '../config/rollup-plugin-assemblyscript.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, '..');

const input = path.join(repoRoot, 'src/index.js');
const outputFile = path.join(
  repoRoot,
  'Chromastage/Resources/Visualizer/butterchurn.iife.js'
);

const bundle = await rollup({
  input,
  plugins: [
    assemblyscriptPlugin({ include: /\.ts$/ }),
    commonjs(),
    nodeResolve({ browser: true, preferBuiltins: false }),
    terser(),
  ],
});

await bundle.write({
  file: outputFile,
  format: 'iife',
  name: 'butterchurn',
  sourcemap: false,
});

await bundle.close();

console.log(`Wrote ${outputFile}`);

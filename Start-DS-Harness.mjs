// Taskbar runtime: use built modules and persist their compile cache after boot.
import { enableCompileCache, flushCompileCache } from 'node:module';
import { existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const started = performance.now();
const [installPath, ...args] = process.argv.slice(2);
if (!installPath) throw new Error('DS Harness installation path is required.');
const entry = resolve(installPath, 'node_modules/@deepseek-ai/dsh/lib/bin.js');
if (!existsSync(entry)) throw new Error(`Built CLI missing: ${entry}. Build DS Harness before launching.`);
const cacheDirectory = join(dirname(fileURLToPath(import.meta.url)), 'node-compile-cache');
enableCompileCache(cacheDirectory);
process.argv = [process.execPath, entry, ...args];
console.log('dsh startup: loading compiled runtime');
const { runCli } = await import(pathToFileURL(entry).href);
await runCli();
// Windows may terminate a background server without a normal Node exit.
flushCompileCache();
console.log(`dsh startup: initialized in ${Math.round(performance.now() - started)} ms; compile cache saved`);

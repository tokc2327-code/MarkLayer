import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const script = fileURLToPath(new URL('./adapter.ps1', import.meta.url));
const [command, ...args] = process.argv.slice(2);
if (!command || !['list-windows', 'snapshot', 'resolve'].includes(command)) {
  console.error('Usage: node cli.mjs list-windows | snapshot -Hwnd <handle> | resolve -Target <json>');
  process.exit(1);
}
const result = spawnSync(
  'powershell.exe',
  ['-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', script, '-Command', command, ...args],
  { stdio: 'inherit' },
);
if (result.error) throw result.error;
process.exit(result.status ?? 1);

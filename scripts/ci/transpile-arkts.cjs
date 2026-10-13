// Host-only execution of ArkTS-shaped fixtures through the supported TypeScript 7 CLI.
// The official HarmonyOS compiler remains the authority for application builds.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const compiler = path.join(__dirname, 'node_modules/typescript/bin/tsc');
const ModuleKind = { CommonJS: 'commonjs' };
const ScriptTarget = { ES2020: 'es2020' };

function transpileModule(source, options = {}) {
  const module = options.compilerOptions?.module ?? ModuleKind.CommonJS;
  const target = options.compilerOptions?.target ?? ScriptTarget.ES2020;
  if (module !== ModuleKind.CommonJS || target !== ScriptTarget.ES2020) {
    throw new Error('Host fixture requests an unsupported TypeScript mode');
  }
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'cexing-ts7-'));
  try {
    const input = path.join(temp, 'fixture.ts');
    fs.writeFileSync(input, source);
    const result = spawnSync(process.execPath, [compiler, input, '--module', module,
      '--target', target, '--noCheck', '--noResolve', '--skipLibCheck',
      '--outDir', temp, '--pretty', 'false'], { encoding: 'utf8' });
    if (result.error || result.status !== 0) {
      throw new Error(`TypeScript 7 fixture compilation failed: ${result.error || result.stderr || result.stdout}`);
    }
    return { outputText: fs.readFileSync(path.join(temp, 'fixture.js'), 'utf8') };
  } finally {
    fs.rmSync(temp, { recursive: true, force: true });
  }
}

module.exports = { ModuleKind, ScriptTarget, transpileModule };

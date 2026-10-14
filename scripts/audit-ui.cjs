#!/usr/bin/env node
// Advisory inventory. Read only tracked production source; no device or user data.
const fs = require('node:fs');
const { execFileSync } = require('node:child_process');
const git = (...args) => execFileSync('git', args, { encoding: 'utf8' }).trim();
const files = git('ls-files', '--', 'cexing/entry/src/main/ets/**/*.ets').split('\n').filter(Boolean);
const base = new Set(), chinese = new Set();
for (const scope of ['cexing/entry', 'cexing/AppScope']) {
  for (const [locale, names] of [['base', base], ['zh_CN', chinese]]) {
    const file = `${scope}/src/main/resources/${locale}/element/string.json`;
    const actual = scope.endsWith('AppScope') ? `${scope}/resources/${locale}/element/string.json` : file;
    if (fs.existsSync(actual)) for (const item of JSON.parse(fs.readFileSync(actual, 'utf8')).string) names.add(item.name);
  }
}
const inventory = [], missingReferences = [];
for (const file of files) {
  const source = fs.readFileSync(file, 'utf8'), literals = [], clicks = [], references = [];
  const line = index => source.slice(0, index).split('\n').length;
  // Comment alternatives precede string tokens; strings containing URLs remain one token.
  const tokens = /\/\*[\s\S]*?\*\/|\/\/[^\n]*|(['"`])(?:\\[\s\S]|(?!\1)[^\\])*?\1/g;
  for (const match of source.matchAll(tokens)) {
    if (match[0].startsWith('/')) continue;
    if (/\p{Script=Han}/u.test(match[0])) literals.push({ line: line(match.index), candidate: match[0] });
  }
  for (const match of source.matchAll(/\.onClick\s*\(/g)) clicks.push(line(match.index));
  for (const match of source.matchAll(/\$r\(['"]app\.string\.([^'"]+)['"]/g)) {
    references.push(match[1]);
    if (!base.has(match[1])) missingReferences.push({ file, line: line(match.index), name: match[1] });
  }
  if (literals.length || clicks.length || references.length) inventory.push({ file, chineseLiteralCandidates: literals, clickLines: clicks, resourceReferences: [...new Set(references)] });
}
console.log(JSON.stringify({ advisory: true, commit: git('rev-parse', 'HEAD'),
  trackedTreeDirty: git('status', '--porcelain', '--untracked-files=no').length > 0,
  scope: 'Tracked production ArkTS; candidates require human display/role review',
  totals: { files: files.length, chineseLiteralCandidates: inventory.reduce((n, f) => n + f.chineseLiteralCandidates.length, 0),
    clickHandlers: inventory.reduce((n, f) => n + f.clickLines.length, 0), baseResources: base.size, chineseResources: chinese.size },
  missingBaseResources: [...chinese].filter(name => !base.has(name)),
  missingChineseResources: [...base].filter(name => !chinese.has(name)), missingReferences,
  notVerified: ['screen reader semantics', 'selected/disabled reasons', 'font scale and focus', 'physical device layouts'], inventory
}, null, 2));

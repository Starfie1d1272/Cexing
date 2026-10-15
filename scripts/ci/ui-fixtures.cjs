// Platform resource mock backed by the shipped locale files, not duplicated copy.
const fs = require('node:fs'), path = require('node:path');
const values = new Map(JSON.parse(fs.readFileSync(path.join(__dirname,
  '../../cexing/entry/src/main/resources/zh_CN/element/string.json'), 'utf8')).string.map(x => [x.name, x.value]));
const get = (resource, ...args) => {
  const key = resource.id.replace(/^app\.string\./, '');
  if (!values.has(key)) throw Error('Missing UI resource ' + key);
  let index = 0; return values.get(key).replace(/%[sd]/g, () => String(args[index++]));
};
module.exports = { globals: { $r: id => ({ id }) }, module: { UiText: { get } } };

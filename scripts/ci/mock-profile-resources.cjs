// Host-test resource adapter; production uses HarmonyOS ResourceManager.
const fs = require('node:fs'), path = require('node:path');
const root = path.join(__dirname, '../../cexing/entry/src/main/resources');
function resourceContext(locale = 'zh_CN') {
  const values = new Map();
  for (const name of locale === 'base' ? ['base'] : ['base', locale]) {
    for (const item of JSON.parse(fs.readFileSync(path.join(root, name, 'element/string.json'))).string) values.set(item.name, item.value);
  }
  return { resourceManager: { getStringByNameSync(name, ...args) {
    if (!values.has(name)) throw Error('Missing test resource: ' + name);
    let index = 0;
    return values.get(name).replace(/%[sd]/g, () => String(args[index++]));
  } } };
}
module.exports = { resourceContext };

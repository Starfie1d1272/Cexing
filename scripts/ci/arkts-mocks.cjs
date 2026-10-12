// Existing regressions load the SDK TypeScript path. Substitute only that import.
// This does not validate ArkTS syntax, SDK APIs, or physical-device behavior.
const Module = require('node:module');
const path = require('node:path');
const original = Module._resolveFilename;
const sdk = process.env.OHOS_SDK_HOME;
if (!sdk) throw new Error('Set OHOS_SDK_HOME to the host mock placeholder');
const compiler = path.join(sdk, 'ets/build-tools/ets-loader/node_modules/typescript');
Module._resolveFilename = function(request, ...args) {
  return original.call(this, request === compiler ? require.resolve('typescript') : request, ...args);
};

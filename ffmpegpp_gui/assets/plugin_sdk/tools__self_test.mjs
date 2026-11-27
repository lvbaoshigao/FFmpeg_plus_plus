#!/usr/bin/env node
// A real WASM ABI smoke test, not a replacement for the application's WAMR tests.
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
const [wasmPath, manifestPath, ...options] = process.argv.slice(2);
if (!wasmPath || !manifestPath) throw new Error('Usage: node self_test.mjs plugin.wasm manifest.json [--fixtures output.json]');
const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
const module = await WebAssembly.compile(readFileSync(wasmPath));
const imports = WebAssembly.Module.imports(module).map(({ module, name, kind }) => ({ module, name, kind }));
assert.deepEqual(imports.sort((a, b) => a.name.localeCompare(b.name)), [
  { module: 'ffmpegpp', name: 'request_read', kind: 'function' },
  { module: 'ffmpegpp', name: 'response_write', kind: 'function' },
]);
const exports = WebAssembly.Module.exports(module);
assert.deepEqual(exports.map(x => x.name).sort(), ['Basic_info', 'Node_info', 'Node_editor_add', 'Node_execute', 'memory'].sort());
const decoder = new TextDecoder('utf-8', { fatal: true });
const encoder = new TextEncoder();
async function invoke(entry, request) {
  let instance;
  let result;
  const data = encoder.encode(JSON.stringify(request));
  instance = await WebAssembly.instantiate(module, { ffmpegpp: {
    request_read(pointer, capacity) {
      if (data.length > capacity) return -data.length;
      new Uint8Array(instance.exports.memory.buffer, pointer >>> 0, data.length).set(data);
      return data.length;
    },
    response_write(pointer, length) {
      assert.ok(length > 0 && length <= 262144, 'bounded response length');
      assert.equal(result, undefined, 'one response per invocation');
      result = JSON.parse(decoder.decode(new Uint8Array(instance.exports.memory.buffer, pointer >>> 0, length >>> 0)));
      return length;
    },
  } });
  assert.equal(instance.exports[entry].length, 0, entry + ' takes zero arguments');
  instance.exports[entry]();
  assert.notEqual(result, undefined, entry + ' must emit JSON');
  return result;
}
const base = { api_version: 1, plugin_id: manifest.id, node_id: 'audio_gain', media_type: 'audio' };
const error = { error: 'Invalid audio_gain request or gain outside [-60,12]' };
const cases = [
  { name: 'metadata', entry: 'Basic_info', request: {}, response: manifest.Basic_info },
  { name: 'nodes', entry: 'Node_info', request: {}, response: { nodes: manifest.Node_info } },
  { name: 'host-ui-fields', entry: 'Node_editor_add', request: { node_id: 'audio_gain' }, response: { fields: manifest.Node_info[0].fields } },
  ...[-60, -6, 0, 3.5, 12].map(decibels => ({ name: 'gain-' + decibels, entry: 'Node_execute', request: { ...base, params: { decibels } }, response: { operation: 'audio.volume', decibels } })),
  ...[-61, 13, '2', null].map((decibels, i) => ({ name: 'reject-gain-' + i, entry: 'Node_execute', request: { ...base, params: { decibels } }, response: error })),
  { name: 'reject-wrong-media', entry: 'Node_execute', request: { ...base, media_type: 'video', params: { decibels: -6 } }, response: error },
  { name: 'reject-unknown-node', entry: 'Node_execute', request: { ...base, node_id: 'not_audio_gain', params: { decibels: -6 } }, response: error },
  { name: 'skip-nested-decibels', entry: 'Node_execute', request: { ...base, params: { nested: { decibels: 99 }, decibels: -4 } }, response: { operation: 'audio.volume', decibels: -4 } },
  { name: 'reject-oversized-request', entry: 'Node_execute', request: { ...base, params: { decibels: -6 }, padding: 'x'.repeat(17000) }, response: error },
];
for (const test of cases) assert.deepEqual(await invoke(test.entry, test.request), test.response, test.name);
const fixtureIndex = options.indexOf('--fixtures');
if (fixtureIndex >= 0) {
  const destination = options[fixtureIndex + 1];
  if (!destination) throw new Error('Missing --fixtures destination');
  mkdirSync(dirname(destination), { recursive: true });
  writeFileSync(destination, JSON.stringify({ api_version: 1, plugin_id: manifest.id, cases }, null, 2) + '\n');
}
console.log('PASS: ' + cases.length + ' real WASM invocations; two imports; four void exports; fresh instance per invocation.');

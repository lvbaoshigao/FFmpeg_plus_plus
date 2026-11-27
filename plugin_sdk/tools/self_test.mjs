#!/usr/bin/env node
// Execute JSON-driven ABI tests against a real WASM module.
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync, statSync } from 'node:fs';
import { dirname } from 'node:path';

const [wasmPath, manifestPath, ...options] = process.argv.slice(2);
if (!wasmPath || !manifestPath) {
  throw new Error('Usage: node self_test.mjs plugin.wasm manifest.json [--test-cases cases.json] [--fixtures output.json]');
}
let casesPath;
let fixturesPath;
for (let i = 0; i < options.length; i += 1) {
  const option = options[i];
  if (option === '--test-cases' || option === '--fixtures') {
    const value = options[i + 1];
    if (!value || value.startsWith('--')) throw new Error('Missing path after ' + option);
    if (option === '--test-cases') {
      if (casesPath) throw new Error('--test-cases may be specified only once');
      casesPath = value;
    } else {
      if (fixturesPath) throw new Error('--fixtures may be specified only once');
      fixturesPath = value;
    }
    i += 1;
  } else {
    throw new Error('Unknown option: ' + option);
  }
}
const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
const module = await WebAssembly.compile(readFileSync(wasmPath));
const imports = WebAssembly.Module.imports(module);
const allowedImports = new Set(['ffmpegpp.request_read:function', 'ffmpegpp.response_write:function']);
for (const entry of imports) {
  const identity = entry.module + '.' + entry.name + ':' + entry.kind;
  assert.ok(allowedImports.has(identity), 'unsupported WASM import: ' + identity);
}
const exports = WebAssembly.Module.exports(module);
const exportByName = new Map(exports.map(entry => [entry.name, entry]));
const allowedExports = new Set(['memory', 'Basic_info', 'Node_info', 'Node_editor_add', 'Node_execute']);
for (const entry of exports) {
  assert.ok(allowedExports.has(entry.name), 'unsupported WASM export: ' + entry.name);
}
assert.equal(exportByName.get('memory')?.kind, 'memory', 'module must export memory');
const nodes = Array.isArray(manifest.Node_info) ? manifest.Node_info : [];
const required = ['Basic_info'];
if (nodes.length > 0) required.push('Node_info', 'Node_execute');
for (const name of required) {
  assert.equal(exportByName.get(name)?.kind, 'function', 'required function export: ' + name);
}
for (const name of ['Basic_info', 'Node_info', 'Node_editor_add', 'Node_execute']) {
  const entry = exportByName.get(name);
  if (entry) assert.equal(entry.kind, 'function', name + ' must be a function export');
}

function metadataCases() {
  const result = [{ name: 'metadata', entry: 'Basic_info', request: {}, response: manifest.Basic_info }];
  if (nodes.length > 0) {
    result.push({ name: 'nodes', entry: 'Node_info', request: {}, response: { nodes } });
  }
  return result;
}

function legacyCases() {
  const first = nodes[0];
  if (!first || !Array.isArray(first.input_types) || first.input_types.length === 0) return metadataCases();
  const base = { api_version: 1, plugin_id: manifest.id, node_id: first.id, media_type: first.input_types[0] };
  const common = metadataCases();
  if (exportByName.has('Node_editor_add')) {
    common.push({ name: 'host-ui-fields', entry: 'Node_editor_add', request: { node_id: first.id },
      response: { fields: Array.isArray(first.fields) ? first.fields : [] } });
  }
  if (first.id === 'audio_gain' && base.media_type === 'audio') {
    const error = { error: 'Invalid audio_gain request or gain outside [-60,12]' };
    return [
      ...common,
      ...[-60, -6, 0, 3.5, 12].map(decibels => ({ name: 'gain-' + decibels, entry: 'Node_execute', request: { ...base, params: { decibels } }, response: { operation: 'audio.volume', decibels } })),
      ...[-61, 13, '2', null].map((decibels, i) => ({ name: 'reject-gain-' + i, entry: 'Node_execute', request: { ...base, params: { decibels } }, response: error })),
      { name: 'reject-wrong-media', entry: 'Node_execute', request: { ...base, media_type: 'video', params: { decibels: -6 } }, response: error },
      { name: 'reject-unknown-node', entry: 'Node_execute', request: { ...base, node_id: 'not_audio_gain', params: { decibels: -6 } }, response: error },
      { name: 'skip-nested-decibels', entry: 'Node_execute', request: { ...base, params: { nested: { decibels: 99 }, decibels: -4 } }, response: { operation: 'audio.volume', decibels: -4 } },
      { name: 'reject-oversized-request', entry: 'Node_execute', request: { ...base, params: { decibels: -6 }, padding: 'x'.repeat(17000) }, response: error },
    ];
  }
  if (first.id === 'video_flip' && base.media_type === 'video') {
    const error = { error: 'Invalid video_flip request or axis' };
    return [
      ...common,
      ...['horizontal', 'vertical'].map(axis => ({ name: 'flip-' + axis, entry: 'Node_execute', request: { ...base, params: { axis } }, response: { operation: 'video.flip', axis } })),
      ...['diagonal', null, 3].map((axis, i) => ({ name: 'reject-axis-' + i, entry: 'Node_execute', request: { ...base, params: { axis } }, response: error })),
      { name: 'reject-wrong-media', entry: 'Node_execute', request: { ...base, media_type: 'audio', params: { axis: 'horizontal' } }, response: error },
      { name: 'reject-unknown-node', entry: 'Node_execute', request: { ...base, node_id: 'not_video_flip', params: { axis: 'horizontal' } }, response: error },
      { name: 'skip-nested-axis', entry: 'Node_execute', request: { ...base, params: { nested: { axis: 'vertical' }, axis: 'horizontal' } }, response: { operation: 'video.flip', axis: 'horizontal' } },
      { name: 'reject-oversized-request', entry: 'Node_execute', request: { ...base, params: { axis: 'horizontal' }, padding: 'x'.repeat(17000) }, response: error },
    ];
  }
  return metadataCases();
}

let testCases;
if (casesPath) {
  if (statSync(casesPath).size > 1024 * 1024) throw new Error('test case file exceeds 1 MiB');
  const parsed = JSON.parse(readFileSync(casesPath, 'utf8'));
  testCases = Array.isArray(parsed) ? parsed : parsed?.cases;
  if (!Array.isArray(testCases)) throw new Error('test case JSON must be an array or an object with a cases array');
} else {
  testCases = legacyCases();
}
if (testCases.length === 0 || testCases.length > 1024) {
  throw new Error('test case count must be between 1 and 1024');
}

const decoder = new TextDecoder('utf-8', { fatal: true });
const encoder = new TextEncoder();
async function createInstance() {
  let instance;
  let data = new Uint8Array(0);
  let response;
  let wroteResponse = false;
  instance = await WebAssembly.instantiate(module, { ffmpegpp: {
    request_read(pointer, capacity) {
      if (data.length > (capacity >>> 0)) return -data.length;
      new Uint8Array(instance.exports.memory.buffer, pointer >>> 0, data.length).set(data);
      return data.length;
    },
    response_write(pointer, length) {
      assert.ok(length > 0 && length <= 262144, 'bounded response length');
      assert.equal(wroteResponse, false, 'one response per invocation');
      response = JSON.parse(decoder.decode(new Uint8Array(instance.exports.memory.buffer, pointer >>> 0, length >>> 0)));
      wroteResponse = true;
      return length;
    },
  } });
  return {
    async invoke(step, label) {
      assert.ok(step && typeof step === 'object' && !Array.isArray(step), label + ' must be an object');
      assert.ok(Object.hasOwn(step, 'request'), label + ' needs request');
      const entry = step.entry;
      assert.equal(typeof entry, 'string', label + ' needs an entry export');
      const exported = instance.exports[entry];
      assert.equal(typeof exported, 'function', label + ' references a function export');
      assert.equal(exported.length, 0, entry + ' takes zero arguments');
      if (Object.hasOwn(step, 'expected_request')) {
        assert.deepEqual(step.request, step.expected_request, label + ' request');
      }
      data = encoder.encode(JSON.stringify(step.request));
      assert.ok(data.length <= 262144, label + ' bounded request length');
      response = undefined;
      wroteResponse = false;
      const returned = exported();
      assert.equal(returned, undefined, entry + ' must have void return type');
      assert.equal(wroteResponse, true, label + ' must emit exactly one JSON response');
      const expected = Object.hasOwn(step, 'response') ? step.response : step.expected_response;
      assert.ok(Object.hasOwn(step, 'response') || Object.hasOwn(step, 'expected_response'), label + ' needs expected response');
      assert.deepEqual(response, expected, label + ' response');
      return entry;
    },
  };
}

const calls = new Set();
// Always compare metadata against the manifest, independent of user-supplied expectations.
for (const test of metadataCases()) {
  const instance = await createInstance();
  const entry = await instance.invoke(test, 'manifest-' + test.name);
  calls.add(entry);
}
for (const test of testCases) {
  assert.ok(test && typeof test === 'object' && !Array.isArray(test), 'each test case must be an object');
  const caseName = typeof test.name === 'string' && test.name ? test.name : 'case-' + (calls.size + 1);
  if (Array.isArray(test.steps)) {
    assert.ok(test.steps.length > 0 && test.steps.length <= 128, caseName + ' needs 1..128 steps');
    for (let index = 0; index < test.steps.length; index += 1) {
      const step = { ...test.steps[index], entry: test.steps[index]?.entry ?? test.entry };
      // Host continuation rounds are separate WASM calls; each step gets a fresh instance.
      const instance = await createInstance();
      const entry = await instance.invoke(step, caseName + '/step-' + (index + 1));
      calls.add(entry);
    }
  } else {
    const instance = await createInstance();
    const entry = await instance.invoke(test, caseName);
    calls.add(entry);
  }
}
for (const name of required) {
  assert.ok(calls.has(name), 'test cases must exercise required export ' + name);
}
if (fixturesPath) {
  mkdirSync(dirname(fixturesPath), { recursive: true });
  writeFileSync(fixturesPath, JSON.stringify({ api_version: 1, plugin_id: manifest.id, cases: testCases }, null, 2) + '\n');
}
console.log('PASS: ' + testCases.length + ' test cases; imports are within the allowed ABI; required exports use zero-argument void signatures.');

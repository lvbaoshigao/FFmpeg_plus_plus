import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const wasmPath = process.argv[2];
assert.ok(wasmPath, 'expected helper test WASM path');
let instance;
let rejectResponse = false;
let responseText = '';
const imports = {
  ffmpegpp: {
    response_write(pointer, length) {
      if (rejectResponse) return -1;
      const bytes = new Uint8Array(instance.exports.memory.buffer, pointer, length);
      responseText = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
      return length;
    },
  },
};
const result = await WebAssembly.instantiate(readFileSync(wasmPath), imports);
instance = result.instance;
instance.exports.run_sdk_helpers();
const report = JSON.parse(responseText);
assert.equal(report.failure, 0, 'C helper test assertion failed: ' + responseText);
assert.ok(instance.exports.test_sdk_writer_text() > 0, 'writer must return a complete response');
assert.deepEqual(JSON.parse(responseText), {
  ['quote"\n\\']: Array.from({ length: 127 }, (_, index) => String.fromCharCode(index + 1)).join('') + '中😀',
}, 'object keys and values must preserve ASCII controls, quotes, backslashes and UTF-8');
rejectResponse = true;
assert.equal(instance.exports.test_sdk_helper_response_failure(), -8,
  'response_write failure must be returned by plan_respond');
console.log('PASS: bounded C JSON helpers, capabilities, FFmpeg plan, and response failures');

'use strict';
// Sandbox shim: node libuv spawn with pipe stdio fails EPERM on this host.
// Redirect child stdout/stderr to temp files (fd stdio) and re-expose as streams/results.
const cp = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { EventEmitter } = require('events');
const { PassThrough } = require('stream');

// 2026-11-08：默认落到工作区 _tmp（用户 Temp 目录在本机沙箱下会 EPERM，且便于一次性清理）。
const TMP = process.env.HVIGOR_SPAWN_TMP
  || path.join(__dirname, '..', '_tmp', 'hvigor-spawn');
fs.mkdirSync(TMP, { recursive: true });
let seq = 0;

function openPair() {
  const base = path.join(TMP, 's' + process.pid + '-' + Date.now() + '-' + (seq++));
  const op = base + '.out';
  const ep = base + '.err';
  return { op, ep, fo: fs.openSync(op, 'w'), fe: fs.openSync(ep, 'w') };
}
function closeQuiet(fd) { try { fs.closeSync(fd); } catch (e) {} }
function readQuiet(p) { try { return fs.readFileSync(p); } catch (e) { return Buffer.alloc(0); } }
function unlinkQuiet(p) { try { fs.unlinkSync(p); } catch (e) {} }

function stdioIsPipe(spec) {
  if (spec === undefined || spec === null) return true;
  if (typeof spec === 'string') return spec === 'pipe';
  if (Array.isArray(spec)) return spec.some((s) => s === 'pipe' || s === undefined || s === null);
  return false;
}
function hasIpc(spec) { return Array.isArray(spec) && spec.indexOf('ipc') >= 0; }

// --- command logging (HVIGOR_SPAWN_LOG=<file>) ---
function logCmd(file, args) {
  const lp = process.env.HVIGOR_SPAWN_LOG;
  if (!lp) return;
  try {
    fs.appendFileSync(lp, JSON.stringify({ t: Date.now(), cwd: process.cwd(), file: file, args: args }) + '\n');
  } catch (e) {}
}

const origSpawn = cp.spawn;
const origSpawnSync = cp.spawnSync;

cp.spawnSync = function (file, args, options) {
  logCmd(file, args);
  const opts = options ? Object.assign({}, options) : {};
  if (!stdioIsPipe(opts.stdio) || hasIpc(opts.stdio)) return origSpawnSync.call(cp, file, args, opts);
  const f = openPair();
  opts.stdio = ['ignore', f.fo, f.fe];
  const res = origSpawnSync.call(cp, file, args, opts);
  closeQuiet(f.fo); closeQuiet(f.fe);
  const out = readQuiet(f.op);
  const err = readQuiet(f.ep);
  unlinkQuiet(f.op); unlinkQuiet(f.ep);
  if (res && !res.error) {
    const enc = opts.encoding;
    res.stdout = enc ? out.toString(enc) : out;
    res.stderr = enc ? err.toString(enc) : err;
  } else if (res) {
    res.stdout = res.stdout || Buffer.alloc(0);
    res.stderr = res.stderr || Buffer.alloc(0);
  }
  return res;
};

cp.spawn = function (file, args, options) {
  logCmd(file, args);
  const opts = options ? Object.assign({}, options) : {};
  if (!stdioIsPipe(opts.stdio) || hasIpc(opts.stdio)) return origSpawn.call(cp, file, args, opts);
  const f = openPair();
  opts.stdio = ['ignore', f.fo, f.fe];
  let child;
  try {
    child = origSpawn.call(cp, file, args, opts);
  } catch (e) {
    closeQuiet(f.fo); closeQuiet(f.fe); unlinkQuiet(f.op); unlinkQuiet(f.ep);
    throw e;
  }
  const wrapper = new EventEmitter();
  const outStream = new PassThrough();
  const errStream = new PassThrough();
  wrapper.stdout = outStream;
  wrapper.stderr = errStream;
  wrapper.stdin = child.stdin || null;
  wrapper.pid = child.pid;
  wrapper.killed = false;
  wrapper.exitCode = null;
  wrapper.signalCode = null;
  wrapper.kill = function () { wrapper.killed = true; return child.kill.apply(child, arguments); };
  wrapper.ref = function () { try { child.ref(); } catch (e) {} return wrapper; };
  wrapper.unref = function () { try { child.unref(); } catch (e) {} return wrapper; };
  let done = false;
  child.on('error', function (e) {
    if (done) return;
    done = true;
    closeQuiet(f.fo); closeQuiet(f.fe); unlinkQuiet(f.op); unlinkQuiet(f.ep);
    wrapper.emit('error', e);
  });
  child.on('exit', function (code, signal) {
    if (done) return;
    done = true;
    wrapper.exitCode = code;
    wrapper.signalCode = signal;
    setTimeout(function () {
      closeQuiet(f.fo); closeQuiet(f.fe);
      const out = readQuiet(f.op);
      const err = readQuiet(f.ep);
      unlinkQuiet(f.op); unlinkQuiet(f.ep);
      if (out.length) outStream.write(out);
      if (err.length) errStream.write(err);
      outStream.end();
      errStream.end();
      wrapper.emit('exit', code, signal);
      wrapper.emit('close', code, signal);
    }, 20);
  });
  return wrapper;
};

// execFile / exec go through the patched spawn so pipe capture works.
cp.execFile = function (file, args, options, callback) {
  if (typeof args === 'function') { callback = args; args = []; options = {}; }
  else if (typeof options === 'function') { callback = options; options = {}; }
  const opts = Object.assign({}, options || {});
  const child = cp.spawn(file, args || [], opts);
  const enc = opts.encoding && opts.encoding !== 'buffer' ? opts.encoding : null;
  let so = [], se = [];
  if (child.stdout) child.stdout.on('data', (d) => so.push(d));
  if (child.stderr) child.stderr.on('data', (d) => se.push(d));
  const finish = (err, code, signal) => {
    if (!callback) return;
    let out = Buffer.concat(so.map((b) => Buffer.isBuffer(b) ? b : Buffer.from(String(b))));
    let errOut = Buffer.concat(se.map((b) => Buffer.isBuffer(b) ? b : Buffer.from(String(b))));
    if (enc) { out = out.toString(enc); errOut = errOut.toString(enc); }
    if (err) { err.code = err.code; err.stdout = out; err.stderr = errOut; return callback(err, out, errOut); }
    if (code !== 0) {
      const e = new Error('Command failed: ' + file + ' ' + (args || []).join(' '));
      e.code = code; e.killed = false; e.signal = signal; e.cmd = file;
      return callback(e, out, errOut);
    }
    callback(null, out, errOut);
  };
  child.on('error', (e) => finish(e));
  child.on('close', (code, signal) => finish(null, code, signal));
  return child;
};

cp.exec = function (command, options, callback) {
  if (typeof options === 'function') { callback = options; options = {}; }
  const opts = Object.assign({}, options || {});
  opts.windowsVerbatimArguments = true;
  const shell = process.env.ComSpec || 'C:\\Windows\\system32\\cmd.exe';
  return cp.execFile(shell, ['/d', '/s', '/c', '"' + command + '"'], opts, callback);
};

cp.execFileSync = function (file, args, options) {
  if (args && !Array.isArray(args)) { options = args; args = []; }
  const opts = Object.assign({}, options || {});
  const res = cp.spawnSync(file, args || [], opts);
  if (res.error) throw res.error;
  if (res.status !== 0) {
    const e = new Error('Command failed: ' + file + ' ' + (args || []).join(' '));
    e.status = res.status; e.stdout = res.stdout; e.stderr = res.stderr;
    throw e;
  }
  const out = res.stdout || Buffer.alloc(0);
  return (opts.encoding && opts.encoding !== 'buffer') ? out.toString(opts.encoding) : out;
};
cp.execSync = function (command, options) {
  const opts = Object.assign({}, options || {});
  const shell = process.env.ComSpec || 'C:\\Windows\\system32\\cmd.exe';
  return cp.execFileSync(shell, ['/d', '/s', '/c', '"' + command + '"'], opts);
};

// --- worker_threads: inject this preload into every Worker ---
try {
  const wt = require('worker_threads');
  const OrigWorker = wt.Worker;
  if (OrigWorker && !OrigWorker.__spawnShimPatched) {
    const SelfPreload = process.env.HVIGOR_SPAWN_SHIM || __filename;
    function ShimWorker(filename, options) {
      const opts = Object.assign({}, options || {});
      const argv = (opts.execArgv || []).slice();
      const has = argv.some(function (a) { return String(a).indexOf('spawn-shim') >= 0; });
      if (!has) { argv.push('--require', SelfPreload); }
      opts.execArgv = argv;
      return new OrigWorker(filename, opts);
    }
    ShimWorker.prototype = OrigWorker.prototype;
    Object.setPrototypeOf(ShimWorker, OrigWorker);
    ShimWorker.__spawnShimPatched = true;
    try {
      Object.defineProperty(wt, 'Worker', { value: ShimWorker, writable: true, configurable: true, enumerable: true });
    } catch (e) { console.log('[spawn-shim] cannot patch Worker:', e.message); }
  }
} catch (e) { console.log('[spawn-shim] worker patch failed', e.message); }

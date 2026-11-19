#!/usr/bin/env node
// === TELEMETRY_MOD_CLI_STATUSLINE ===
'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');
const { fileURLToPath } = require('url');

const FIXED_MAX_TOKENS = 1000000; // 统一固定 1M 上下文窗口
const SPEED_CACHE_PATH = path.join(os.tmpdir(), 'agy-cli-telemetry-cache.json');

function stripBom(text) {
  return String(text == null ? '' : text).replace(/^\uFEFF/, '');
}

function getCliHomeDir() {
  const envCliHome = typeof process.env.ANTIGRAVITY_CLI_HOME === 'string'
    ? process.env.ANTIGRAVITY_CLI_HOME.trim()
    : '';
  if (envCliHome) {
    return path.resolve(envCliHome);
  }
  return path.join(os.homedir(), '.gemini', 'antigravity-cli');
}

function getActivityCachePath() {
  return path.join(os.homedir(), '.gemini', 'telemetry-activity-cache.json');
}

function readSettingsModel() {
  try {
    const settingsPath = path.join(getCliHomeDir(), 'settings.json');
    if (fs.existsSync(settingsPath)) {
      const raw = stripBom(fs.readFileSync(settingsPath, 'utf8')).trim();
      if (raw) {
        const s = JSON.parse(raw);
        if (s && typeof s.model === 'string') {
          return s.model.trim();
        }
      }
    }
  } catch {
    // ignore malformed or unreadable settings
  }
  return '';
}

function sleepSyncMs(ms) {
  const delay = Math.max(1, Number(ms) || 1);
  try {
    const sab = new SharedArrayBuffer(4);
    const ia = new Int32Array(sab);
    Atomics.wait(ia, 0, 0, delay);
  } catch {
    const end = Date.now() + delay;
    while (Date.now() < end) {
      // fallback wait
    }
  }
}

function acquireFileLockSync(lockPath, timeoutMs = 1000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const fd = fs.openSync(lockPath, 'wx');
      try {
        fs.writeSync(fd, `${process.pid}`);
      } finally {
        fs.closeSync(fd);
      }
      return true;
    } catch (err) {
      const code = err && err.code;
      if (code === 'EEXIST') {
        try {
          const st = fs.statSync(lockPath);
          if (Date.now() - st.mtimeMs > 5000) {
            fs.unlinkSync(lockPath);
            continue;
          }
        } catch {
          // ignore race
        }
      } else if (code !== 'EPERM' && code !== 'EBUSY' && code !== 'EACCES') {
        return false;
      }
      sleepSyncMs(12 + Math.floor(Math.random() * 14));
    }
  }
  return false;
}

function releaseFileLockSync(lockPath) {
  try {
    if (fs.existsSync(lockPath)) {
      fs.unlinkSync(lockPath);
    }
  } catch {
    // ignore
  }
}

function atomicWriteFileSync(targetPath, payload) {
  const dir = path.dirname(targetPath);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
  const rand = Math.random().toString(36).slice(2, 8);
  const tmpPath = `${targetPath}.${process.pid}.${Date.now()}.${rand}.tmp`;
  try {
    fs.writeFileSync(tmpPath, payload, 'utf8');
    const retryDelays = [15, 30, 50, 80];
    let renamed = false;
    for (let attempt = 0; attempt <= retryDelays.length; attempt++) {
      try {
        fs.renameSync(tmpPath, targetPath);
        renamed = true;
        break;
      } catch (err) {
        const code = err && err.code;
        const retryable = code === 'EPERM' || code === 'EBUSY' || code === 'EACCES';
        if (retryable && attempt < retryDelays.length) {
          sleepSyncMs(retryDelays[attempt]);
          continue;
        }
        break;
      }
    }
    if (!renamed) {
      fs.writeFileSync(targetPath, payload, 'utf8');
    }
  } finally {
    try {
      if (fs.existsSync(tmpPath)) {
        fs.unlinkSync(tmpPath);
      }
    } catch {
      // ignore cleanup error
    }
  }
}

function formatCompactTokens(num) {
  if (num == null || !Number.isFinite(Number(num)) || Number(num) <= 0) {
    return '0';
  }
  const n = Number(num);
  if (n >= 1000000) {
    return (n / 1000000).toFixed(1).replace(/\.0$/, '') + 'M';
  }
  if (n >= 1000) {
    return Math.round(n / 1000) + 'k';
  }
  return String(Math.round(n));
}

function getRingChar(pct) {
  if (pct <= 0) return '○';
  if (pct < 30) return '◔';
  if (pct < 60) return '◑';
  if (pct < 90) return '◕';
  return '●';
}

function normalizePath(p) {
  if (!p || typeof p !== 'string') return '';
  const trimmed = p.trim();
  if (trimmed.startsWith('file://')) {
    try {
      return fileURLToPath(trimmed);
    } catch {
      return trimmed.replace(/^file:\/\/\/?/, '');
    }
  }
  return trimmed;
}

function isHexOrUuid(s) {
  return /^[0-9a-f]{16,64}$/i.test(s) || /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s);
}

const MODEL_PAREN_SUFFIX_RE = /\s*\((?:Extra\s+Low|Very\s+High|XHigh|High|Medium|Low|Max|Thinking|Fast|Slow|Standard|Preview|Experimental|MaaS|\d+(?:\.\d+)?\s*[KM](?:\s*context)?)\)\s*$/i;
const MODEL_SLUG_SUFFIX_RE = /-(?:maas|extra[-_]low|very[-_]high|xhigh|high|medium|low|max|thinking|tiered|trial|preview|exp|latest|control|worker-agy|orchestrator-g1-pro|1m|2m|128k|200k|256k|512k|1000k|\d{4}-\d{2}-\d{2}|\d{8}|[nhabc])$/i;

function stripModelParenSuffixes(raw) {
  let name = String(raw || '').trim();
  let prev;
  do {
    prev = name;
    name = name.replace(MODEL_PAREN_SUFFIX_RE, '').trim();
  } while (name !== prev);
  return name;
}

function normalizeModelSlug(raw) {
  let s = stripModelParenSuffixes(raw);
  if (!s || isHexOrUuid(s)) return '';
  s = s.replace(/^(?:[a-z0-9._-]+\/)+/i, '');
  s = s.replace(/@.*$/, '').trim();
  if (!s || isHexOrUuid(s)) return '';
  if (/^gemini-pro-orchestrator-g1-pro$/i.test(s)) return 'Gemini 4 Argon';
  let prev;
  do {
    prev = s;
    s = s.replace(MODEL_SLUG_SUFFIX_RE, '');
  } while (s !== prev);
  s = s.replace(/(\d)[-_](\d)/g, '$1.$2').replace(/(\d)[-_](\d)/g, '$1.$2');
  const parts = s.split(/[-_]+/).filter(Boolean).map((w) => {
    if (/^gpt$/i.test(w)) return 'GPT';
    if (/^oss$/i.test(w)) return 'OSS';
    if (/^\d+(?:\.\d+)?[bk]$/i.test(w)) return w.toUpperCase();
    if (/^\d/.test(w)) return w;
    return w.charAt(0).toUpperCase() + w.slice(1);
  });
  return parts.join(' ').trim();
}

function normalizeModelName(rawDisplay, rawInternal) {
  const d = String(rawDisplay || '').trim();
  if (d && !isHexOrUuid(d)) {
    let name = stripModelParenSuffixes(d);
    const looksLikeSlug = name && !/\s/.test(name) && (
      name.includes('/') ||
      name.includes('@') ||
      /-(?:maas|extra[-_]low|very[-_]high|xhigh|high|medium|low|max|thinking|tiered|trial|preview|exp|latest|control|worker-agy|orchestrator-g1-pro)$/i.test(name) ||
      (/^[a-z0-9._-]+$/.test(name) && name.includes('-'))
    );
    if (looksLikeSlug) {
      const slugRes = normalizeModelSlug(name);
      if (slugRes) return slugRes;
    }
    name = name.replace(/^(?:[a-z0-9._-]+\/)+/i, '').replace(/@[^\s()]*$/, '').trim();
    if (/^Orchestrator\s*\(([^)]+)\)$/i.test(name)) {
      name = 'Gemini 4 ' + name.match(/^Orchestrator\s*\(([^)]+)\)$/i)[1].trim();
    }
    if (name && !isHexOrUuid(name)) return name;
  }
  const intern = String(rawInternal || '').trim();
  if (intern && !isHexOrUuid(intern)) {
    const res = normalizeModelSlug(intern);
    if (res) return res;
  }
  return '';
}

const needleLsi = Buffer.from('\x0flast_step_index\x12', 'latin1');

function extractConvModelMap(convDbPath) {
  const stepMap = {};
  let defaultModel = '';
  let dbSize = 0;
  if (!convDbPath || typeof convDbPath !== 'string') {
    return { stepMap, sortedSteps: [], defaultModel, dbSize };
  }

  const filesToCheck = [convDbPath, `${convDbPath}-wal`];
  for (const filePath of filesToCheck) {
    let stat;
    try {
      if (!fs.existsSync(filePath)) continue;
      stat = fs.statSync(filePath);
    } catch {
      continue;
    }
    if (!stat || !stat.isFile()) continue;
    dbSize += stat.size;
    if (stat.size > 512 * 1024 * 1024 || stat.size === 0) {
      continue;
    }
    const CHUNK_SIZE = 8 * 1024 * 1024;
    const MARGIN = 700;
    const KEEP = MARGIN * 2;
    let fd = null;
    try {
      fd = fs.openSync(filePath, 'r');
      const chunkBuf = Buffer.allocUnsafe(stat.size <= CHUNK_SIZE ? stat.size : (CHUNK_SIZE + KEEP));
      let filePos = 0;
      let carryLen = 0;
      while (filePos < stat.size) {
        const maxRead = Math.min(CHUNK_SIZE, stat.size - filePos, chunkBuf.length - carryLen);
        if (maxRead <= 0) break;
        const bytesRead = fs.readSync(fd, chunkBuf, carryLen, maxRead, filePos);
        if (bytesRead <= 0) break;
        filePos += bytesRead;
        const totalLen = carryLen + bytesRead;
        const isLast = filePos >= stat.size;
        const scanEnd = isLast ? totalLen : totalLen - MARGIN;
        let offset = carryLen > 0 ? Math.max(0, carryLen - MARGIN) : 0;
        let prevLsiEnd = offset;
        while (offset < scanEnd) {
          const idx = chunkBuf.indexOf(needleLsi, offset);
          if (idx === -1 || idx >= scanEnd) break;
          const pos = idx + needleLsi.length;
          if (pos < totalLen) {
            const vlen = chunkBuf[pos];
            if (vlen >= 1 && vlen <= 8 && pos + 1 + vlen <= totalLen) {
              const stepStr = chunkBuf.slice(pos + 1, pos + 1 + vlen).toString('latin1');
              if (/^\d+$/.test(stepStr)) {
                let rawInternal = '';
                const intStart = Math.max(prevLsiEnd, idx - 650);
                for (let k = intStart; k <= idx - 3; k++) {
                  if (chunkBuf[k] === 0x9a && chunkBuf[k + 1] === 0x01) {
                    const mlen = chunkBuf[k + 2];
                    if (mlen >= 4 && mlen <= 120 && k + 3 + mlen <= idx) {
                      const s = chunkBuf.slice(k + 3, k + 3 + mlen).toString('utf8');
                      if (/^[a-z][a-z0-9._/@-]+$/i.test(s) && !isHexOrUuid(s)) {
                        rawInternal = s;
                      }
                    }
                  }
                }
                let rawDisplay = '';
                const nextIdx = chunkBuf.indexOf(needleLsi, pos);
                const winEnd = Math.min(totalLen, idx + 650, nextIdx !== -1 ? nextIdx : totalLen);
                for (let k = pos; k <= winEnd - 3; k++) {
                  if (chunkBuf[k] === 0xaa && chunkBuf[k + 1] === 0x01) {
                    const dlen = chunkBuf[k + 2];
                    if (dlen >= 4 && dlen <= 120 && k + 3 + dlen <= winEnd) {
                      const s = chunkBuf.slice(k + 3, k + 3 + dlen).toString('utf8');
                      if (/^[A-Za-z][A-Za-z0-9 ._()\-+/]+$/.test(s) && !isHexOrUuid(s)) {
                        rawDisplay = s;
                        break;
                      }
                    }
                  }
                }
                const norm = normalizeModelName(rawDisplay, rawInternal);
                if (norm) {
                  stepMap[Number(stepStr)] = norm;
                  defaultModel = norm;
                }
              }
            }
          }
          prevLsiEnd = pos;
          offset = pos;
        }
        if (isLast) break;
        carryLen = Math.min(KEEP, totalLen);
        chunkBuf.copy(chunkBuf, 0, totalLen - carryLen, totalLen);
      }
    } catch {
      continue;
    } finally {
      if (fd !== null) {
        try { fs.closeSync(fd); } catch {}
      }
    }
  }

  const sortedSteps = Object.keys(stepMap).map(Number).sort((a, b) => a - b);
  return { stepMap, sortedSteps, defaultModel, dbSize };
}

function resolveStepModel(stepIdx, modelInfo, fallbackModel) {
  if (modelInfo && modelInfo.stepMap && modelInfo.stepMap[stepIdx]) {
    return modelInfo.stepMap[stepIdx];
  }
  if (modelInfo && modelInfo.sortedSteps && modelInfo.sortedSteps.length > 0) {
    const steps = modelInfo.sortedSteps;
    if (stepIdx < steps[0]) {
      return modelInfo.stepMap[steps[0]];
    }
    let chosen = steps[0];
    for (let i = steps.length - 1; i >= 0; i--) {
      if (steps[i] <= stepIdx) {
        chosen = steps[i];
        break;
      }
    }
    return modelInfo.stepMap[chosen];
  }
  const fb = fallbackModel ? (normalizeModelName(fallbackModel, '') || String(fallbackModel).trim()) : '';
  return (modelInfo && modelInfo.defaultModel) || fb || '其他模型';
}

function isConvEntryNewer(candidate, current) {
  if (!candidate || typeof candidate !== 'object' || typeof candidate.mtimeMs !== 'number') {
    return false;
  }
  if (!current || typeof current !== 'object' || typeof current.mtimeMs !== 'number') {
    return true;
  }
  if (candidate.mtimeMs !== current.mtimeMs) {
    return candidate.mtimeMs > current.mtimeMs;
  }
  const candSize = Number(candidate.size) || 0;
  const curSize = Number(current.size) || 0;
  if (candSize !== curSize) {
    return candSize > curSize;
  }
  return (Number(candidate.dbSize) || 0) > (Number(current.dbSize) || 0);
}

function resolveTranscriptPath(rawPath, convId) {
  const normalized = normalizePath(rawPath);
  if (normalized && fs.existsSync(normalized)) {
    return normalized;
  }
  if (!convId || !/^[a-zA-Z0-9_-]+$/.test(convId)) return '';
  const cliHome = getCliHomeDir();
  const candidates = [
    path.join(cliHome, 'brain', convId, '.system_generated', 'logs', 'transcript.jsonl'),
    path.join(os.homedir(), '.gemini', 'antigravity', 'brain', convId, '.system_generated', 'logs', 'transcript.jsonl'),
  ];
  for (const c of candidates) {
    if (fs.existsSync(c)) return c;
  }
  return '';
}

function toLocalDayKey(dt) {
  return new Date(dt.getTime() - dt.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
}

function addDailyBucket(dailyBuckets, row, inTok, cacheTok, outTok, fallbackMs, modelName) {
  const rowTotal = inTok + cacheTok + outTok;
  if (rowTotal <= 0) return;
  let dt = row.created_at ? new Date(row.created_at) : new Date(fallbackMs);
  if (Number.isNaN(dt.getTime())) {
    dt = new Date(fallbackMs);
  }
  const dayKey = toLocalDayKey(dt);
  if (!dailyBuckets[dayKey]) {
    dailyBuckets[dayKey] = { in: 0, cache: 0, out: 0, total: 0, steps: 0, models: {} };
  }
  dailyBuckets[dayKey].in += inTok;
  dailyBuckets[dayKey].cache += cacheTok;
  dailyBuckets[dayKey].out += outTok;
  dailyBuckets[dayKey].total += rowTotal;
  dailyBuckets[dayKey].steps += 1;

  const mName = modelName || '其他模型';
  if (!dailyBuckets[dayKey].models) {
    dailyBuckets[dayKey].models = {};
  }
  if (!dailyBuckets[dayKey].models[mName]) {
    dailyBuckets[dayKey].models[mName] = { in: 0, cache: 0, out: 0, total: 0, steps: 0 };
  }
  dailyBuckets[dayKey].models[mName].in += inTok;
  dailyBuckets[dayKey].models[mName].cache += cacheTok;
  dailyBuckets[dayKey].models[mName].out += outTok;
  dailyBuckets[dayKey].models[mName].total += rowTotal;
  dailyBuckets[dayKey].models[mName].steps += 1;
}

function parseTranscriptStats(transcriptPath, convId, fallbackModel) {
  try {
    if (!transcriptPath || !fs.existsSync(transcriptPath)) {
      return null;
    }
    const stat = fs.statSync(transcriptPath);
    const raw = stripBom(fs.readFileSync(transcriptPath, 'utf8'));
    const lines = raw.split(/\r?\n/);
    const rows = [];
    for (let i = 0; i < lines.length; i++) {
      const line = stripBom(lines[i]).trim();
      if (!line) continue;
      try {
        rows.push(JSON.parse(line));
      } catch {
        // ignore malformed line
      }
    }

    let modelInfo = null;
    const resolvedConvId = typeof convId === 'string' && /^[a-zA-Z0-9_-]+$/.test(convId) ? convId : null;
    if (resolvedConvId) {
      const cliHome = getCliHomeDir();
      const cliConvDbPath = path.join(cliHome, 'conversations', `${resolvedConvId}.db`);
      const desktopConvDbPath = path.join(os.homedir(), '.gemini', 'antigravity', 'conversations', `${resolvedConvId}.db`);
      const hasCliDb = fs.existsSync(cliConvDbPath) || fs.existsSync(`${cliConvDbPath}-wal`);
      const hasDesktopDb = fs.existsSync(desktopConvDbPath) || fs.existsSync(`${desktopConvDbPath}-wal`);
      const convDbPath = hasCliDb ? cliConvDbPath : (hasDesktopDb ? desktopConvDbPath : cliConvDbPath);
      modelInfo = extractConvModelMap(convDbPath);
    }

    let sumInputTokens = 0;
    let sumCacheTokens = 0;
    let sumOutputTokens = 0;
    let latestStepTps = 0;
    let baseInstructionTokens = 16000;
    let firstPlannerSeen = false;
    let latestPlanner = null;
    let compactedContextUsed = null;
    const dailyBuckets = {};

    for (let i = 0; i < rows.length; i++) {
      const row = rows[i];
      if (row.type === 'PLANNER_RESPONSE') {
        const inTok = Number(row.input_tokens) || 0;
        const cacheTok = Number(row.cache_read_tokens) || 0;
        const outTok = Number(row.output_tokens) || 0;
        if (!firstPlannerSeen && (inTok + cacheTok > 0)) {
          firstPlannerSeen = true;
          baseInstructionTokens = Math.min(25000, inTok + cacheTok);
        }
        sumInputTokens += inTok;
        sumCacheTokens += cacheTok;
        sumOutputTokens += outTok;
        const stepIdx = Number(row.step_index) || 0;
        const modelName = resolveStepModel(stepIdx, modelInfo, fallbackModel);
        addDailyBucket(dailyBuckets, row, inTok, cacheTok, outTok, stat.mtimeMs, modelName);

        if (row.created_at && outTok > 0) {
          const t0 = new Date(row.created_at).getTime();
          const nextRow = rows[i + 1];
          const t1 = (nextRow && nextRow.created_at && nextRow.type !== 'USER_INPUT')
            ? new Date(nextRow.created_at).getTime()
            : (i === rows.length - 1 ? stat.mtimeMs : 0);
          if (t1 > t0) {
            const elapsed = (t1 - t0) / 1000;
            if (elapsed >= 0.4 && elapsed <= 180) {
              const stepTps = outTok / elapsed;
              if (stepTps >= 5 && stepTps <= 350) {
                latestStepTps = Math.max(1, Math.min(350, Math.round(stepTps)));
              }
            }
          }
        }

        latestPlanner = {
          inputTokens: inTok,
          cacheReadTokens: cacheTok,
          outputTokens: outTok,
        };
        compactedContextUsed = null;
      } else if (row.type === 'CHECKPOINT') {
        const cpIn = Number(row.input_tokens) || 0;
        const cpCache = Number(row.cache_read_tokens) || 0;
        const cpOut = Number(row.output_tokens) || 0;
        sumInputTokens += cpIn;
        sumCacheTokens += cpCache;
        sumOutputTokens += cpOut;
        const stepIdx = Number(row.step_index) || 0;
        const modelName = resolveStepModel(stepIdx, modelInfo, fallbackModel);
        addDailyBucket(dailyBuckets, row, cpIn, cpCache, cpOut, stat.mtimeMs, modelName);
        const summaryTokens = cpOut > 0
          ? cpOut
          : Math.round(String(row.content || '').length / 3.6);
        compactedContextUsed = baseInstructionTokens + summaryTokens;
      }
    }

    const tokensPerSecond = latestStepTps;
    const cumulativePromptTokens = sumInputTokens + sumCacheTokens;
    const cacheHitRate = cumulativePromptTokens > 0
      ? Math.round((sumCacheTokens / cumulativePromptTokens) * 100)
      : 0;

    let latestContextUsed = 0;
    if (latestPlanner) {
      const promptSum = latestPlanner.inputTokens + latestPlanner.cacheReadTokens;
      latestContextUsed = compactedContextUsed !== null
        ? compactedContextUsed
        : (promptSum + latestPlanner.outputTokens);
    } else if (compactedContextUsed !== null) {
      latestContextUsed = compactedContextUsed;
    }

    return {
      tokensPerSecond,
      cacheHitRate,
      cumulativePromptTokens,
      cumulativeTokens: sumInputTokens + sumCacheTokens + sumOutputTokens,
      latestContextUsed,
      compactedJustNow: compactedContextUsed !== null,
      dailyBuckets,
      statMtimeMs: stat.mtimeMs,
      statSize: stat.size,
      dbSize: modelInfo ? modelInfo.dbSize : 0,
    };
  } catch {
    return null;
  }
}

function readJsonObjectSync(filePath) {
  try {
    if (!fs.existsSync(filePath)) return null;
    const raw = stripBom(fs.readFileSync(filePath, 'utf8')).trim();
    if (!raw) return {};
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === 'object' ? parsed : {};
  } catch {
    return null;
  }
}

function updateAndReadSpeedCache(convId, totalOutTokens, transcriptSpeed) {
  if (!convId) return transcriptSpeed || 0;
  const lockPath = `${SPEED_CACHE_PATH}.lock`;
  let hasLock = false;
  try {
    const cacheDir = path.dirname(SPEED_CACHE_PATH);
    if (!fs.existsSync(cacheDir)) {
      fs.mkdirSync(cacheDir, { recursive: true });
    }
    hasLock = acquireFileLockSync(lockPath, 400);
    const cache = readJsonObjectSync(SPEED_CACHE_PATH) || {};
    const now = Date.now();
    const prev = cache[convId] && typeof cache[convId] === 'object' ? cache[convId] : {};
    let speed = transcriptSpeed > 0 ? transcriptSpeed : (prev.speed || 0);

    if (totalOutTokens > 0 && prev.outTokens > 0 && totalOutTokens > prev.outTokens && prev.ts > 0) {
      const dt = (now - prev.ts) / 1000;
      const dOut = totalOutTokens - prev.outTokens;
      if (dt >= 0.3 && dt <= 60) {
        const liveTps = Math.round(dOut / dt);
        if (liveTps >= 5 && liveTps <= 350 && !(transcriptSpeed > 0)) {
          speed = liveTps;
        }
      }
    }

    if (transcriptSpeed > 0) {
      speed = transcriptSpeed;
    }

    cache[convId] = {
      outTokens: totalOutTokens || prev.outTokens || 0,
      ts: totalOutTokens !== prev.outTokens ? now : (prev.ts || now),
      speed,
    };
    atomicWriteFileSync(SPEED_CACHE_PATH, JSON.stringify(cache));
    return speed;
  } catch {
    return transcriptSpeed || 0;
  } finally {
    if (hasLock) {
      releaseFileLockSync(lockPath);
    }
  }
}

function readActivityCacheSync(activityCachePath) {
  if (!fs.existsSync(activityCachePath)) {
    return { status: 'missing', cache: { version: 4, conversations: {} } };
  }
  const raw = stripBom(fs.readFileSync(activityCachePath, 'utf8')).trim();
  if (!raw) {
    return { status: 'empty', cache: { version: 4, conversations: {} } };
  }
  try {
    const parsed = JSON.parse(raw);
    if (parsed && typeof parsed === 'object' && parsed.version === 4 && parsed.conversations && typeof parsed.conversations === 'object') {
      return { status: 'ok', cache: { version: 4, conversations: { ...parsed.conversations } } };
    }
    return { status: 'reset', cache: { version: 4, conversations: {} } };
  } catch {
    return { status: 'corrupt', cache: null };
  }
}

function syncActivityLedgerCache(convId, tStats) {
  if (!convId || typeof convId !== 'string' || !tStats || !tStats.dailyBuckets) {
    return;
  }
  try {
    const activityCachePath = getActivityCachePath();
    const key = `cli:${convId}`;
    const targetDbSize = Number(tStats.dbSize) || 0;
    const initialRead = readActivityCacheSync(activityCachePath);
    if (initialRead.status === 'ok') {
      const prev = initialRead.cache.conversations[key];
      if (
        prev &&
        prev.mtimeMs === tStats.statMtimeMs &&
        prev.size === tStats.statSize &&
        (Number(prev.dbSize) || 0) === targetDbSize &&
        prev.daily &&
        typeof prev.daily === 'object'
      ) {
        return;
      }
    }

    const newEntry = {
      mtimeMs: tStats.statMtimeMs,
      size: tStats.statSize,
      dbSize: targetDbSize,
      source: 'cli',
      daily: tStats.dailyBuckets,
    };

    const cacheDir = path.dirname(activityCachePath);
    if (!fs.existsSync(cacheDir)) {
      fs.mkdirSync(cacheDir, { recursive: true });
    }
    const lockPath = `${activityCachePath}.lock`;
    const hasLock = acquireFileLockSync(lockPath, 1000);
    try {
      let latestRead = readActivityCacheSync(activityCachePath);
      if (latestRead.status === 'corrupt') {
        sleepSyncMs(20);
        latestRead = readActivityCacheSync(activityCachePath);
      }
      if (latestRead.status === 'corrupt' || !latestRead.cache) {
        return;
      }
      const cache = latestRead.cache;
      const latestSelf = cache.conversations[key];
      if (isConvEntryNewer(latestSelf, newEntry)) {
        return;
      }
      if (
        latestSelf &&
        latestSelf.mtimeMs === newEntry.mtimeMs &&
        Number(latestSelf.size) === Number(newEntry.size) &&
        (Number(latestSelf.dbSize) || 0) === targetDbSize &&
        latestSelf.daily &&
        typeof latestSelf.daily === 'object'
      ) {
        return;
      }
      cache.conversations[key] = newEntry;
      atomicWriteFileSync(activityCachePath, JSON.stringify(cache));
    } finally {
      if (hasLock) {
        releaseFileLockSync(lockPath);
      }
    }
  } catch {
    // non-blocking
  }
}

function extractEffortFromLabel(label) {
  const str = String(label || '').trim();
  const m = str.match(/\(\s*(Extra\s+Low|Very\s+High|XHigh|High|Medium|Low|Max)\s*\)(?:\s*\([^)]+\))*\s*$/i);
  return m ? m[1].replace(/\s+/g, ' ').toLowerCase() : '';
}

function extractEffortFromSlug(slug) {
  let s = String(slug || '').trim().replace(/@.*$/, '');
  s = s.replace(/-(?:maas|1m|2m|128k|200k|256k|512k|1000k)$/i, '');
  const m = s.match(/-(extra[-_]low|very[-_]high|xhigh|high|medium|low|max)$/i);
  return m ? m[1].replace(/[-_]+/g, ' ').toLowerCase() : '';
}

function resolveModelLabel(data) {
  const modelObj = data && data.model && typeof data.model === 'object' ? data.model : null;
  const rawDisplay = modelObj && typeof modelObj.display_name === 'string'
    ? modelObj.display_name.trim()
    : (typeof (data && data.model) === 'string' ? data.model.trim() : '');
  const rawId = modelObj && typeof modelObj.id === 'string' ? modelObj.id.trim() : '';
  let effort = modelObj && typeof modelObj.effort === 'string' ? modelObj.effort.trim() : '';

  let displayName = '';
  if (rawDisplay) {
    if (!effort) {
      effort = extractEffortFromLabel(rawDisplay) || extractEffortFromSlug(rawDisplay);
    }
    displayName = normalizeModelName(rawDisplay, '');
  }

  if (!displayName && rawId) {
    if (!effort) {
      effort = extractEffortFromSlug(rawId);
    }
    displayName = normalizeModelName('', rawId);
  } else if (displayName && !effort && rawId) {
    effort = extractEffortFromSlug(rawId);
  }

  if (!displayName) {
    const settingsModel = readSettingsModel();
    if (settingsModel) {
      if (!effort) {
        effort = extractEffortFromLabel(settingsModel) || extractEffortFromSlug(settingsModel);
      }
      displayName = normalizeModelName(settingsModel, '');
    }
  }

  if (!displayName) {
    return '';
  }

  const cleanEffort = String(effort || '').trim().replace(/_/g, ' ').replace(/\s+/g, ' ').toLowerCase();
  return cleanEffort ? `${displayName} · ${cleanEffort}` : displayName;
}

function resolveLeftHint(data) {
  const state = String(data.agent_state || 'idle').toLowerCase();
  if (state && state !== 'idle') {
    return 'esc to cancel';
  }
  return '? for shortcuts';
}

function renderSingleLine(data, speed, usedTokens, pct, cacheHit, totalTokens) {
  const FG = '\x1b[38;2;145;145;156m';       // #91919C 指标文字与单色图标
  const DOT = '\x1b[38;2;118;120;134m';      // #767886 分隔圆点
  const NATIVE = '\x1b[38;2;118;118;118m';   // #767676 原生快捷键提示与模型名
  const RST = '\x1b[0m';

  const leftText = resolveLeftHint(data);
  const modelText = resolveModelLabel(data);

  const speedStr = speed > 0 ? `${speed} t/s` : '-- t/s';
  const ringChar = getRingChar(pct);
  const ctxStr = `${formatCompactTokens(usedTokens)} / 1M ${pct}%`;
  const cacheStr = `${cacheHit}%`;
  const totalStr = modelText
    ? formatCompactTokens(totalTokens).padEnd(5, ' ')
    : formatCompactTokens(totalTokens);

  const telemetryPlain =
    `↯ ${speedStr}  ·  ` +
    `${ringChar} ${ctxStr}  ·  ` +
    `◈ ${cacheStr}  ·  ` +
    `∑ ${totalStr}`;

  const telemetryAnsi =
    `${FG}↯ ${speedStr}${DOT}  ·  ` +
    `${FG}${ringChar} ${ctxStr}${DOT}  ·  ` +
    `${FG}◈ ${cacheStr}${DOT}  ·  ` +
    `${FG}∑ ${totalStr}${RST}`;

  const gapBeforeModel = modelText ? '   ' : '';
  const rightVisibleCols = telemetryPlain.length + gapBeforeModel.length + modelText.length;

  const termWidth = Number(data.terminal_width) || Number(process.stdout.columns) || 120;
  const centerSpaces = Math.max(2, termWidth - leftText.length - rightVisibleCols);

  return (
    `${NATIVE}${leftText}${RST}` +
    ' '.repeat(centerSpaces) +
    telemetryAnsi +
    (modelText ? `${gapBeforeModel}${NATIVE}${modelText}${RST}` : '')
  );
}

function runWithInput(rawInput) {
  const input = stripBom(rawInput || '').trim();
  let data = {};
  if (input) {
    try {
      data = JSON.parse(input);
    } catch {
      data = {};
    }
  }

  const convId = data.conversation_id || data.session_id || '';
  const rawDisplayName = (data.model && data.model.display_name) || '';
  const rawModelId = (data.model && data.model.id) || '';
  let mainModelFallback = normalizeModelName(rawDisplayName, rawModelId);
  if (!mainModelFallback) {
    const settingsModel = readSettingsModel();
    if (settingsModel) {
      mainModelFallback = normalizeModelName(settingsModel, '');
    }
  }

  const transcriptPath = resolveTranscriptPath(data.transcript_path, convId);
  const tStats = parseTranscriptStats(transcriptPath, convId, mainModelFallback);

  const cw = data.context_window || {};
  const cu = cw.current_usage || {};

  const cuIn = Number(cu.input_tokens) || 0;
  const cuCacheRead = Number(cu.cache_read_input_tokens) || 0;
  const cuCacheCreate = Number(cu.cache_creation_input_tokens) || 0;
  const cuOut = Number(cu.output_tokens) || 0;
  const cuUsed = cuIn + cuCacheRead + cuCacheCreate + cuOut;

  const totalOutTokens = Math.max(Number(cw.total_output_tokens) || 0, cuOut);

  // 1. Speed (t/s)
  const rawSpeed = tStats && tStats.tokensPerSecond > 0 ? tStats.tokensPerSecond : 0;
  const speed = updateAndReadSpeedCache(convId, totalOutTokens, rawSpeed);

  // 2. Context Window (used / 1M & pct%): prefer unified API token count from transcript.jsonl, fallback to stdin current_usage
  const usedTokens = (tStats && tStats.latestContextUsed > 0)
    ? tStats.latestContextUsed
    : cuUsed > 0
      ? cuUsed
      : 0;
  const pct = Math.max(0, Math.min(100, Math.round((usedTokens / FIXED_MAX_TOKENS) * 100)));

  // 3. Cumulative Cache Hit Rate (%)
  let cacheHit = 0;
  if (tStats && tStats.cumulativePromptTokens > 0) {
    cacheHit = tStats.cacheHitRate;
  } else if (cuIn + cuCacheRead > 0) {
    cacheHit = Math.round((cuCacheRead / (cuIn + cuCacheRead)) * 100);
  }

  // 4. Cumulative Total Tokens (∑)
  const cwTotal = (Number(cw.total_input_tokens) || 0) + (Number(cw.total_output_tokens) || 0);
  const totalTokens = Math.max(
    tStats ? tStats.cumulativeTokens : 0,
    cwTotal,
    cuUsed
  );

  process.stdout.write(renderSingleLine(data, speed, usedTokens, pct, cacheHit, totalTokens) + '\n');
  syncActivityLedgerCache(convId, tStats);
}

if (process.stdin.isTTY) {
  runWithInput('');
} else {
  let chunks = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk) => {
    chunks += chunk;
  });
  process.stdin.on('end', () => {
    runWithInput(chunks);
  });
  process.stdin.on('error', () => {
    runWithInput(chunks);
  });
}

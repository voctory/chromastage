const FFT_SIZE = 2048;
const canvas = document.getElementById('output');
const AUTO_SWITCH_INTERVAL_MS = 15000;
const WATCHDOG_INTERVAL_MS = 5000;
const STALL_THRESHOLD_MS = 4000;

const status = document.createElement('div');
status.style.position = 'absolute';
status.style.left = '12px';
status.style.top = '12px';
status.style.color = '#fff';
status.style.font = '13px -apple-system, BlinkMacSystemFont, sans-serif';
status.style.background = 'rgba(0,0,0,0.6)';
status.style.padding = '6px 10px';
status.style.borderRadius = '6px';
status.style.zIndex = '10';
status.style.display = 'none';
document.body.appendChild(status);

function setStatus(message) {
  if (message) {
    status.textContent = message;
    status.style.display = 'block';
    log('status', message);
  } else {
    status.textContent = '';
    status.style.display = 'none';
  }
}

function hasWebGL2() {
  const test = document.createElement('canvas');
  return !!test.getContext('webgl2');
}

if (!hasWebGL2()) {
  setStatus('WebGL2 is not available in this view.');
}

// Avoid OffscreenCanvas issues in WKWebView.
try {
  window.OffscreenCanvas = undefined;
} catch {}

let visualizer = null;
let presets = {};
let basePresets = {};
let presetKeys = [];
let blockedPresetNames = new Set();
let playlistPresetSet = null;
let presetIndex = 0;
let autoSwitchTimer = null;
let autoSwitchEnabled = true;
let autoSwitchRandomized = false;
let autoSwitchIntervalMs = AUTO_SWITCH_INTERVAL_MS;
let currentPresetName = null;
let paletteColors = [];
let lastRenderTime = 0;
let renderLoopActive = false;
let watchdogTimer = null;
let isContextLost = false;
let isRebuilding = false;
let audioLevels = {
  timeByteArray: new Uint8Array(FFT_SIZE),
  timeByteArrayL: new Uint8Array(FFT_SIZE),
  timeByteArrayR: new Uint8Array(FFT_SIZE),
};
let audioCtx = null;
let analysisGain = null;
let muteGain = null;
let nextPlayTime = 0;

function nowMs() {
  if (typeof performance !== 'undefined' && typeof performance.now === 'function') {
    return performance.now();
  }
  return Date.now();
}

function decodeBase64Into(b64, target) {
  const binary = atob(b64);
  const len = binary.length;
  if (target.length !== len) {
    target = new Uint8Array(len);
  }
  for (let i = 0; i < len; i += 1) {
    target[i] = binary.charCodeAt(i);
  }
  return target;
}

function log(level, message) {
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nativeLog) {
    window.webkit.messageHandlers.nativeLog.postMessage({ level, message });
  }
}

canvas.addEventListener('webglcontextlost', (event) => {
  event.preventDefault();
  isContextLost = true;
  if (autoSwitchTimer) {
    clearTimeout(autoSwitchTimer);
    autoSwitchTimer = null;
  }
  setStatus('Visualizer paused (WebGL context lost).');
  log('warn', 'webglcontextlost');
});

canvas.addEventListener('webglcontextrestored', () => {
  isContextLost = false;
  setStatus('');
  log('info', 'webglcontextrestored');
  rebuildVisualizer('context-restored');
});

async function loadPresetMap() {
  const presetUrl = '../Presets/presets.json';
  try {
    const response = await fetch(presetUrl);
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }
    const payload = await response.json();
    if (payload && Array.isArray(payload.presets)) {
      const map = {};
      for (const preset of payload.presets) {
        if (preset && preset.name) {
          map[preset.name] = preset;
        }
      }
      log('info', `presets.json loaded: ${payload.presets.length}`);
      return map;
    }
  } catch (error) {
    log('warn', `presets.json load failed: ${error?.message || error}`);
  }

  if (window.butterchurnPresets && window.butterchurnPresets.getPresets) {
    return window.butterchurnPresets.getPresets();
  }
  return {};
}

function applyCuratedList(keys) {
  const curated = window.curatedPresetNames;
  if (!Array.isArray(curated) || curated.length === 0) {
    return keys;
  }
  const available = new Set(keys);
  const filtered = curated.filter((name) => available.has(name));
  if (filtered.length === 0) {
    log('warn', 'curated preset list empty after filtering');
    return keys;
  }
  const missingCount = curated.length - filtered.length;
  if (missingCount > 0) {
    log('warn', `curated presets missing: ${missingCount}`);
  }
  return filtered;
}

function hexToRgb(hex) {
  if (!hex || typeof hex !== 'string') {
    return null;
  }
  const normalized = hex.trim().replace('#', '');
  if (normalized.length !== 6) {
    return null;
  }
  const value = Number.parseInt(normalized, 16);
  if (Number.isNaN(value)) {
    return null;
  }
  const r = (value >> 16) & 0xff;
  const g = (value >> 8) & 0xff;
  const b = value & 0xff;
  return [r / 255, g / 255, b / 255];
}

function parsePalette(input) {
  if (!Array.isArray(input)) {
    return [];
  }
  return input.map(hexToRgb).filter(Boolean);
}

function applyPaletteToPreset(preset, palette) {
  if (!palette || palette.length === 0 || !preset) {
    return preset;
  }
  const clone = { ...preset };
  if (preset.baseVals) {
    clone.baseVals = { ...preset.baseVals };
    const primary = palette[0];
    const secondary = palette[1] || primary;
    if (primary) {
      if ('wave_r' in clone.baseVals) clone.baseVals.wave_r = primary[0];
      if ('wave_g' in clone.baseVals) clone.baseVals.wave_g = primary[1];
      if ('wave_b' in clone.baseVals) clone.baseVals.wave_b = primary[2];
    }
    if (secondary) {
      if ('ib_r' in clone.baseVals) clone.baseVals.ib_r = secondary[0];
      if ('ib_g' in clone.baseVals) clone.baseVals.ib_g = secondary[1];
      if ('ib_b' in clone.baseVals) clone.baseVals.ib_b = secondary[2];
    }
  }

  if (Array.isArray(preset.waves)) {
    clone.waves = preset.waves.map((wave, index) => {
      if (!wave || !wave.baseVals) {
        return wave;
      }
      const next = { ...wave, baseVals: { ...wave.baseVals } };
      const color = palette[index % palette.length];
      if (color) {
        if ('r' in next.baseVals) next.baseVals.r = color[0];
        if ('g' in next.baseVals) next.baseVals.g = color[1];
        if ('b' in next.baseVals) next.baseVals.b = color[2];
      }
      return next;
    });
  }

  if (Array.isArray(preset.shapes)) {
    clone.shapes = preset.shapes.map((shape, index) => {
      if (!shape || !shape.baseVals) {
        return shape;
      }
      const next = { ...shape, baseVals: { ...shape.baseVals } };
      const color = palette[(index + 1) % palette.length];
      if (color) {
        if ('r' in next.baseVals) next.baseVals.r = color[0];
        if ('g' in next.baseVals) next.baseVals.g = color[1];
        if ('b' in next.baseVals) next.baseVals.b = color[2];
        if ('border_r' in next.baseVals) next.baseVals.border_r = color[0];
        if ('border_g' in next.baseVals) next.baseVals.border_g = color[1];
        if ('border_b' in next.baseVals) next.baseVals.border_b = color[2];
      }
      return next;
    });
  }

  return clone;
}

function applyPaletteToMap(map) {
  if (!paletteColors || paletteColors.length === 0) {
    return map;
  }
  const next = {};
  for (const [name, preset] of Object.entries(map)) {
    next[name] = applyPaletteToPreset(preset, paletteColors);
  }
  return next;
}

function rebuildPresets() {
  if (!basePresets || Object.keys(basePresets).length === 0) {
    return;
  }
  presets = applyPaletteToMap(basePresets);
  presetKeys = applyCuratedList(Object.keys(presets));
  if (presetKeys.length === 0) {
    return;
  }
  const activeKeys = activePresetKeys();
  const candidateKeys = activeKeys.length > 0 ? activeKeys : presetKeys;
  const currentName = currentPresetName && candidateKeys.includes(currentPresetName)
    ? currentPresetName
    : candidateKeys[0];
  if (currentName) {
    loadPresetByName(currentName, 0.5);
  }
  resetAutoSwitchTimer();
}

function notifyPresetChanged(name, source) {
  currentPresetName = name;
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nativePresetChanged) {
    window.webkit.messageHandlers.nativePresetChanged.postMessage({ name, source });
  }
}

function ensureAudioGraph() {
  if (audioCtx) {
    return;
  }
  const Ctor = window.AudioContext || window.webkitAudioContext;
  if (!Ctor) {
    log('warn', 'AudioContext not available; Chromastage will not react to audio.');
    return;
  }
  try {
    audioCtx = new Ctor({ sampleRate: 44100 });
  } catch {
    audioCtx = new Ctor();
  }
  analysisGain = audioCtx.createGain();
  muteGain = audioCtx.createGain();
  muteGain.gain.value = 0.0;
  analysisGain.connect(muteGain);
  muteGain.connect(audioCtx.destination);
  nextPlayTime = audioCtx.currentTime;
  log('info', `AudioContext created: sampleRate=${audioCtx.sampleRate}, state=${audioCtx.state}`);

  document.addEventListener('click', () => {
    if (audioCtx && audioCtx.state !== 'running') {
      audioCtx.resume().catch(() => {});
    }
  }, { once: true });
}

async function ensureAudioRunning() {
  if (!audioCtx || audioCtx.state === 'running') {
    return;
  }
  try {
    await audioCtx.resume();
    log('info', `AudioContext resumed: state=${audioCtx.state}`);
  } catch (error) {
    log('warn', `AudioContext resume blocked: ${error?.message || error}`);
  }
}

function byteToFloat(value) {
  return (value - 128) / 128;
}

function scheduleStereoFromBytes(leftBytes, rightBytes) {
  if (!audioCtx || !analysisGain) {
    return;
  }
  const frames = Math.min(leftBytes.length, rightBytes.length);
  if (frames <= 0) {
    return;
  }
  const now = audioCtx.currentTime;
  const maxAhead = 0.25;
  if (nextPlayTime < now || (nextPlayTime - now) > maxAhead) {
    nextPlayTime = now;
  }

  const buffer = audioCtx.createBuffer(2, frames, audioCtx.sampleRate);
  const l = buffer.getChannelData(0);
  const r = buffer.getChannelData(1);
  for (let i = 0; i < frames; i += 1) {
    l[i] = byteToFloat(leftBytes[i]);
    r[i] = byteToFloat(rightBytes[i]);
  }

  const src = audioCtx.createBufferSource();
  src.buffer = buffer;
  src.connect(analysisGain);
  const startAt = Math.max(nextPlayTime, now + 0.01);
  src.start(startAt);
  nextPlayTime = startAt + buffer.duration;
}

function logWebGLDiagnostics() {
  const gl = document.createElement('canvas').getContext('webgl2');
  if (!gl) {
    log('warn', 'WebGL2 diagnostics: not available');
    return;
  }
  const vendor = gl.getParameter(gl.VENDOR);
  const renderer = gl.getParameter(gl.RENDERER);
  const version = gl.getParameter(gl.VERSION);
  const shading = gl.getParameter(gl.SHADING_LANGUAGE_VERSION);
  const maxTexture = gl.getParameter(gl.MAX_TEXTURE_SIZE);
  const extensions = gl.getSupportedExtensions() || [];
  log('info', `WebGL2: ${vendor} / ${renderer} / ${version} / ${shading} / maxTex=${maxTexture} / ext=${extensions.length}`);

  const aniso =
    gl.getExtension('EXT_texture_filter_anisotropic') ||
    gl.getExtension('MOZ_EXT_texture_filter_anisotropic') ||
    gl.getExtension('WEBKIT_EXT_texture_filter_anisotropic');
  if (aniso) {
    const maxAniso = gl.getParameter(aniso.MAX_TEXTURE_MAX_ANISOTROPY_EXT);
    log('info', `WebGL2: anisotropic filtering max=${maxAniso}`);
  }
}

function loadPresetByIndex(index, transition = 2.5) {
  if (!visualizer || presetKeys.length === 0) {
    return;
  }
  const clamped = ((index % presetKeys.length) + presetKeys.length) % presetKeys.length;
  presetIndex = clamped;
  const presetName = presetKeys[presetIndex];
  visualizer.loadPreset(presets[presetName], transition);
  notifyPresetChanged(presetName, 'index');
}

function loadPresetByName(name, transition = 2.5) {
  if (!name) {
    return;
  }
  const idx = presetKeys.indexOf(name);
  if (idx === -1) {
    log('warn', `preset not found: ${name}`);
    return;
  }
  loadPresetByIndex(idx, transition);
}

function setBlockedPresets(names) {
  if (!Array.isArray(names)) {
    blockedPresetNames = new Set();
    return;
  }
  blockedPresetNames = new Set(names.filter((name) => typeof name === 'string'));
}

function setPlaylistPresets(names) {
  if (names === null || typeof names === 'undefined') {
    playlistPresetSet = null;
  } else if (Array.isArray(names)) {
    playlistPresetSet = new Set(names.filter((name) => typeof name === 'string'));
  } else {
    playlistPresetSet = null;
  }
  syncPlaylistSelection();
}

function isPresetBlocked(name) {
  return blockedPresetNames.has(name);
}

function activePresetKeys() {
  if (playlistPresetSet === null) {
    return presetKeys;
  }
  if (playlistPresetSet.size === 0) {
    return [];
  }
  return presetKeys.filter((name) => playlistPresetSet.has(name));
}

function syncPlaylistSelection() {
  if (playlistPresetSet === null) {
    resetAutoSwitchTimer();
    return;
  }
  if (!autoSwitchEnabled) {
    resetAutoSwitchTimer();
    return;
  }
  const keys = activePresetKeys();
  if (keys.length === 0) {
    resetAutoSwitchTimer();
    return;
  }
  if (currentPresetName && keys.includes(currentPresetName)) {
    resetAutoSwitchTimer();
    return;
  }
  const candidate = keys.find((name) => !isPresetBlocked(name)) || keys[0];
  if (candidate) {
    loadPresetByName(candidate, 0.5);
  }
  resetAutoSwitchTimer();
}

function nextAutoPresetName() {
  const keys = activePresetKeys();
  if (keys.length === 0) {
    return null;
  }
  if (!autoSwitchRandomized) {
    let startIndex = currentPresetName ? keys.indexOf(currentPresetName) : -1;
    if (startIndex < 0) {
      startIndex = 0;
    }
    for (let offset = 1; offset <= keys.length; offset += 1) {
      const idx = (startIndex + offset) % keys.length;
      if (!isPresetBlocked(keys[idx])) {
        return keys[idx];
      }
    }
    return keys[startIndex];
  }
  const candidates = keys.filter((name) => !isPresetBlocked(name));
  if (candidates.length === 0) {
    return keys[0];
  }
  let choice = candidates[Math.floor(Math.random() * candidates.length)];
  if (choice === currentPresetName && candidates.length > 1) {
    const fallback = candidates.find((name) => name !== currentPresetName);
    if (fallback) {
      choice = fallback;
    }
  }
  return choice;
}

function resetAutoSwitchTimer() {
  if (autoSwitchTimer) {
    clearTimeout(autoSwitchTimer);
    autoSwitchTimer = null;
  }
  const keys = activePresetKeys();
  if (!autoSwitchEnabled || keys.length <= 1 || !visualizer || isContextLost) {
    return;
  }
  autoSwitchTimer = setTimeout(() => {
    const nextName = nextAutoPresetName();
    if (nextName) {
      loadPresetByName(nextName, 2.5);
    }
    resetAutoSwitchTimer();
  }, autoSwitchIntervalMs);
}

function applyAutoSwitch(enabled, intervalMs, randomized) {
  autoSwitchEnabled = !!enabled;
  if (Number.isFinite(intervalMs) && intervalMs > 1000) {
    autoSwitchIntervalMs = intervalMs;
  }
  if (typeof randomized === 'boolean') {
    autoSwitchRandomized = randomized;
  }
  resetAutoSwitchTimer();
}

async function setupVisualizer({ reloadPresets } = {}) {
  if (isRebuilding) {
    return;
  }
  isRebuilding = true;
  try {
    const butterchurn = window.butterchurn;
    if (!butterchurn) {
      setStatus('Chromastage global not found.');
      log('error', 'Chromastage global not found');
      return;
    }

    const { width, height, pixelRatio } = getCanvasMetrics();
    ensureAudioGraph();
    visualizer = butterchurn.createVisualizer(audioCtx, canvas, {
      width,
      height,
      pixelRatio,
      textureRatio: 1,
    });
    log('info', `render.length=${visualizer?.render?.length}, hasConnectAudio=${!!visualizer?.connectAudio}`);
    if (visualizer?.connectAudio && analysisGain) {
      visualizer.connectAudio(analysisGain);
      log('info', 'connectAudio(analysisGain) attached');
    } else {
      log('warn', 'connectAudio not attached');
    }

    const extraImages = (window.imageData && (window.imageData.default || window.imageData)) || null;
    if (extraImages && visualizer.loadExtraImages) {
      visualizer.loadExtraImages(extraImages);
      log('info', `extra images loaded: ${Object.keys(extraImages).length}`);
    }

    logWebGLDiagnostics();

    if (reloadPresets || !basePresets || Object.keys(basePresets).length === 0) {
      basePresets = await loadPresetMap();
    }
    presets = applyPaletteToMap(basePresets);
    presetKeys = applyCuratedList(Object.keys(presets));
    log('info', `preset count: ${presetKeys.length}`);

    if (presetKeys.length === 0) {
      setStatus('No presets found.');
    } else {
      const activeKeys = activePresetKeys();
      const candidateKeys = activeKeys.length > 0 ? activeKeys : presetKeys;
      const desired =
        currentPresetName && candidateKeys.includes(currentPresetName)
          ? currentPresetName
          : candidateKeys[0];
      if (desired) {
        loadPresetByName(desired, 0.0);
      }
      setStatus('');
    }

    resize();
    resetAutoSwitchTimer();
    lastRenderTime = nowMs();
    startRenderLoop();
    startWatchdog();
  } finally {
    isRebuilding = false;
  }
}

function startRenderLoop() {
  if (renderLoopActive) {
    return;
  }
  renderLoopActive = true;
  const loop = () => {
    if (visualizer && !isContextLost) {
      visualizer.render();
      lastRenderTime = nowMs();
    }
    requestAnimationFrame(loop);
  };
  requestAnimationFrame(loop);
}

function startWatchdog() {
  if (watchdogTimer) {
    return;
  }
  watchdogTimer = setInterval(() => {
    if (!visualizer || isContextLost) {
      return;
    }
    const elapsed = nowMs() - lastRenderTime;
    if (elapsed > STALL_THRESHOLD_MS) {
      log('warn', `render stalled (${Math.round(elapsed)}ms), recreating`);
      rebuildVisualizer('stall');
    }
  }, WATCHDOG_INTERVAL_MS);
}

function rebuildVisualizer(reason) {
  if (isRebuilding) {
    return;
  }
  log('info', `rebuild visualizer: ${reason}`);
  setupVisualizer({ reloadPresets: false });
}

window.butterchurnNative = {
  updateAudio(monoB64, leftB64, rightB64) {
    if (monoB64) {
      audioLevels.timeByteArray = decodeBase64Into(monoB64, audioLevels.timeByteArray);
    }
    if (leftB64) {
      audioLevels.timeByteArrayL = decodeBase64Into(leftB64, audioLevels.timeByteArrayL);
    }
    if (rightB64) {
      audioLevels.timeByteArrayR = decodeBase64Into(rightB64, audioLevels.timeByteArrayR);
    }
    ensureAudioGraph();
    ensureAudioRunning();
    if (audioLevels.timeByteArrayL && audioLevels.timeByteArrayR) {
      scheduleStereoFromBytes(audioLevels.timeByteArrayL, audioLevels.timeByteArrayR);
    }
  },
  setPreset(name) {
    loadPresetByName(name, 2.5);
  },
  setPresetIndex(index) {
    loadPresetByIndex(index, 2.5);
  },
  setPalette(palette) {
    paletteColors = parsePalette(palette);
    rebuildPresets();
  },
  setAutoSwitchRandomized(randomized) {
    applyAutoSwitch(autoSwitchEnabled, autoSwitchIntervalMs, randomized);
  },
  setAutoSwitch(enabled, intervalMs, randomized) {
    applyAutoSwitch(enabled, intervalMs, randomized);
  },
  setBlockedPresets(names) {
    setBlockedPresets(names);
  },
  setPlaylistPresets(names) {
    setPlaylistPresets(names);
  },
};

window.addEventListener('error', (event) => {
  log('error', `window error: ${event.message}`);
});

window.addEventListener('unhandledrejection', (event) => {
  log('error', `unhandled rejection: ${event.reason}`);
});

function getCanvasMetrics() {
  return {
    width: Math.max(1, canvas.clientWidth),
    height: Math.max(1, canvas.clientHeight),
    pixelRatio: window.devicePixelRatio || 1,
  };
}

function resize() {
  const { width, height, pixelRatio } = getCanvasMetrics();
  canvas.width = Math.floor(width);
  canvas.height = Math.floor(height);
  if (visualizer) {
    visualizer.setRendererSize(width, height, { pixelRatio });
  }
}

window.addEventListener('resize', resize);
resize();

async function start() {
  try {
    log('info', 'visualizer.js start');
    await setupVisualizer({ reloadPresets: true });
  } catch (error) {
    setStatus(`Visualizer failed: ${error?.message || error}`);
    log('error', error?.message || String(error));
  }
}

start().catch((error) => {
  setStatus(`Visualizer failed: ${error?.message || error}`);
  log('error', error?.message || String(error));
});

if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nativeReady) {
  window.webkit.messageHandlers.nativeReady.postMessage({});
}

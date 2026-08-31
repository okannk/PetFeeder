// server.js — PetFeeder backend
const express = require('express');
const cors = require('cors');
const http = require('http');
const path = require('path');
const crypto = require('crypto');
const { WebSocketServer } = require('ws');
const store = require('./store');

const PORT = process.env.PORT || 3001;
const FEED_TIMEOUT_MS = 15000;

const app = express();
app.use(cors());
app.use(express.json());
app.use(express.static(path.join(__dirname, '..', 'web')));

// ─── API Anahtarı ─────────────────────────────────────────────────────────────
const API_KEY = store.ensureApiKey();
console.log('\n╔══════════════════════════════════════════════════════════╗');
console.log('║  PetFeeder Backend                                       ║');
console.log('║                                                          ║');
console.log(`║  API Anahtarı: ${API_KEY}  ║`);
console.log('║  Bu anahtarı uygulamanın Ayarlar ekranına girin.         ║');
console.log('╚══════════════════════════════════════════════════════════╝\n');

const server = http.createServer(app);
const wss = new WebSocketServer({ server, path: '/ws/device' });

const liveConnections = new Map();
const pendingFeeds = new Map();

function isOnline(deviceId) {
  const ws = liveConnections.get(deviceId);
  return !!ws && ws.readyState === ws.OPEN;
}

function sendToDevice(deviceId, payload) {
  const ws = liveConnections.get(deviceId);
  if (!ws || ws.readyState !== ws.OPEN) return false;
  ws.send(JSON.stringify(payload));
  return true;
}

// ─── API Key middleware ───────────────────────────────────────────────────────
function requireApiKey(req, res, next) {
  const key = req.headers['x-api-key'];
  if (!key || key !== API_KEY) {
    return res.status(401).json({ error: 'Geçersiz veya eksik API anahtarı' });
  }
  next();
}

// ─── WebSocket ────────────────────────────────────────────────────────────────
wss.on('connection', (ws, req) => {
  const url = new URL(req.url, 'http://localhost');
  const token = url.searchParams.get('token');
  const device = token && store.getDeviceByToken(token);

  if (!device) {
    console.warn('[WS] Geçersiz token ile bağlantı reddedildi.');
    ws.close(4001, 'invalid token');
    return;
  }

  console.log(`[WS] Cihaz bağlandı: ${device.name} (${device.id})`);
  liveConnections.set(device.id, ws);
  store.touchDevice(device.id);

  ws.on('message', (raw) => {
    let msg;
    try { msg = JSON.parse(raw.toString()); }
    catch { console.error('[WS] Geçersiz JSON'); return; }

    store.touchDevice(device.id);

    if (msg.type === 'device:ready') {
      // Yeni slots formatıyla zamanlama gönder
      sendToDevice(device.id, { cmd: 'schedule:update', slots: device.schedule.slots });
      return;
    }

    if (msg.type === 'pong' || msg.type === 'ping' || msg.status === 'schedule:updated') return;

    if (msg.feedingId) {
      store.addHistory({ deviceId: device.id, feedingId: msg.feedingId, status: msg.status, message: msg.message });
      const pending = pendingFeeds.get(msg.feedingId);
      if (pending) {
        clearTimeout(pending.timeout);
        pending.resolve(msg);
        pendingFeeds.delete(msg.feedingId);
      }
    }
  });

  ws.on('close', () => {
    console.log(`[WS] Cihaz ayrıldı: ${device.name} (${device.id})`);
    if (liveConnections.get(device.id) === ws) liveConnections.delete(device.id);
  });
});

// ─── REST API ─────────────────────────────────────────────────────────────────

// Otomatik kayıt — API key gerekmez (sadece yerel ağdan erişilebilir, ESP8266 kullanır)
app.post('/api/auto-register', (req, res) => {
  const { mac, name } = req.body || {};
  if (!mac || typeof mac !== 'string' || mac.trim().length < 12) {
    return res.status(400).json({ error: 'Geçersiz MAC adresi' });
  }
  const device = store.findOrCreateByMac(mac.trim(), name);
  res.json({ id: device.id, token: device.token, name: device.name });
});

// Aşağıdaki tüm endpoint'ler API key gerektirir
app.use('/api', requireApiKey);

app.post('/api/devices', (req, res) => {
  const device = store.createDevice(req.body?.name);
  res.status(201).json(device);
});

app.get('/api/devices', (req, res) => {
  const devices = store.listDevices().map((d) => ({ ...d, token: undefined, online: isOnline(d.id) }));
  res.json(devices);
});

app.get('/api/devices/:id', (req, res) => {
  const device = store.getDevice(req.params.id);
  if (!device) return res.status(404).json({ error: 'Cihaz bulunamadı' });
  res.json({ ...device, token: undefined, online: isOnline(device.id) });
});

// Cihaz yeniden adlandırma
app.patch('/api/devices/:id', (req, res) => {
  const { name } = req.body || {};
  if (!name || !name.trim()) return res.status(400).json({ error: 'Geçerli bir isim girin' });
  const device = store.renameDevice(req.params.id, name);
  if (!device) return res.status(404).json({ error: 'Cihaz bulunamadı' });
  res.json({ ...device, token: undefined, online: isOnline(device.id) });
});

// Cihaz silme
app.delete('/api/devices/:id', (req, res) => {
  if (!store.getDevice(req.params.id)) return res.status(404).json({ error: 'Cihaz bulunamadı' });
  const ws = liveConnections.get(req.params.id);
  if (ws) { ws.close(); liveConnections.delete(req.params.id); }
  store.deleteDevice(req.params.id);
  res.json({ ok: true });
});

app.get('/api/devices/:id/history', (req, res) => {
  const device = store.getDevice(req.params.id);
  if (!device) return res.status(404).json({ error: 'Cihaz bulunamadı' });
  const limit = Math.min(Number(req.query.limit) || 50, 200);
  res.json(store.getHistory(device.id, limit));
});

app.post('/api/devices/:id/feed', (req, res) => {
  const device = store.getDevice(req.params.id);
  if (!device) return res.status(404).json({ error: 'Cihaz bulunamadı' });
  if (!isOnline(device.id)) return res.status(409).json({ error: 'Cihaz çevrimdışı' });

  const portions = Math.min(Math.max(parseInt(req.body?.portions, 10) || 1, 1), 10);
  const feedingId = crypto.randomUUID();

  const resultPromise = new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      pendingFeeds.delete(feedingId);
      reject(new Error('Cihazdan yanıt alınamadı (zaman aşımı)'));
    }, FEED_TIMEOUT_MS);
    pendingFeeds.set(feedingId, { resolve, timeout });
  });

  sendToDevice(device.id, { cmd: 'feed', portions, feedingId });
  resultPromise
    .then((result) => res.json(result))
    .catch((err) => res.status(504).json({ error: err.message }));
});

app.post('/api/devices/:id/schedule', (req, res) => {
  const device = store.getDevice(req.params.id);
  if (!device) return res.status(404).json({ error: 'Cihaz bulunamadı' });

  const num = (v, def) => { const n = Number(v); return Number.isFinite(n) ? n : def; };

  if (Array.isArray(req.body?.slots)) {
    const slots = req.body.slots.map((s, i) => ({
      id: s.id || `slot${i + 1}`,
      label: s.label || `Öğün ${i + 1}`,
      enabled: !!s.enabled,
      hour: Math.min(Math.max(num(s.hour, 8), 0), 23),
      minute: Math.min(Math.max(num(s.minute, 0), 0), 59),
      portions: Math.min(Math.max(num(s.portions, 1), 1), 10),
    }));
    const schedule = { slots };
    store.setSchedule(device.id, schedule);
    const delivered = sendToDevice(device.id, { cmd: 'schedule:update', slots });
    return res.json({ schedule, delivered });
  }

  // Eski format uyumluluğu (morning/evening)
  const m = req.body?.morning;
  const e = req.body?.evening;
  const schedule = {
    slots: [
      { id: 'slot1', label: 'Sabah', enabled: !!m?.enabled, hour: Math.min(Math.max(num(m?.hour, 8), 0), 23), minute: Math.min(Math.max(num(m?.minute, 0), 0), 59), portions: Math.min(Math.max(num(m?.portions, 1), 1), 10) },
      { id: 'slot2', label: 'Öğle',  enabled: false, hour: 12, minute: 0, portions: 1 },
      { id: 'slot3', label: 'Akşam', enabled: !!e?.enabled, hour: Math.min(Math.max(num(e?.hour, 18), 0), 23), minute: Math.min(Math.max(num(e?.minute, 0), 0), 59), portions: Math.min(Math.max(num(e?.portions, 1), 1), 10) },
      { id: 'slot4', label: 'Gece',  enabled: false, hour: 22, minute: 0, portions: 1 },
    ],
  };
  store.setSchedule(device.id, schedule);
  const delivered = sendToDevice(device.id, { cmd: 'schedule:update', slots: schedule.slots });
  res.json({ schedule, delivered });
});

server.listen(PORT, () => {
  console.log(`[PetFeeder backend] http://localhost:${PORT} üzerinde çalışıyor`);
});

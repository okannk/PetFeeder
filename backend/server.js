// server.js — PetFeeder backend: cihaz icin WebSocket koprusu + web paneli icin REST API
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

const server = http.createServer(app);
const wss = new WebSocketServer({ server, path: '/ws/device' });

// deviceId -> WebSocket (canli baglantilar)
const liveConnections = new Map();
// feedingId -> { resolve, timeout }
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

wss.on('connection', (ws, req) => {
  const url = new URL(req.url, 'http://localhost');
  const token = url.searchParams.get('token');
  const device = token && store.getDeviceByToken(token);

  if (!device) {
    console.warn('[WS] Gecersiz token ile baglanti reddedildi.');
    ws.close(4001, 'invalid token');
    return;
  }

  console.log(`[WS] Cihaz baglandi: ${device.name} (${device.id})`);
  liveConnections.set(device.id, ws);
  store.touchDevice(device.id);

  ws.on('message', (raw) => {
    let msg;
    try {
      msg = JSON.parse(raw.toString());
    } catch (err) {
      console.error('[WS] Gecersiz JSON:', raw.toString());
      return;
    }

    store.touchDevice(device.id);

    // Cihaz baglanir baglanmaz backend'de kayitli zamanlamayi gonder (reboot/reconnect senkronu)
    if (msg.type === 'device:ready') {
      sendToDevice(device.id, { cmd: 'schedule:update', ...device.schedule });
      return;
    }

    if (msg.type === 'pong' || msg.type === 'ping' || msg.status === 'schedule:updated') {
      return;
    }

    if (msg.feedingId) {
      store.addHistory({
        deviceId: device.id,
        feedingId: msg.feedingId,
        status: msg.status,
        message: msg.message,
      });

      const pending = pendingFeeds.get(msg.feedingId);
      if (pending) {
        clearTimeout(pending.timeout);
        pending.resolve(msg);
        pendingFeeds.delete(msg.feedingId);
      }
    }
  });

  ws.on('close', () => {
    console.log(`[WS] Cihaz ayrildi: ${device.name} (${device.id})`);
    if (liveConnections.get(device.id) === ws) {
      liveConnections.delete(device.id);
    }
  });
});

// ─── REST API ───────────────────────────────────────────────────────────────

app.post('/api/devices', (req, res) => {
  const device = store.createDevice(req.body?.name);
  // Token sadece olusturma aninda tam olarak donuluyor; cihaza bir kere yazilir.
  res.status(201).json(device);
});

app.get('/api/devices', (req, res) => {
  const devices = store.listDevices().map((d) => ({ ...d, token: undefined, online: isOnline(d.id) }));
  res.json(devices);
});

app.get('/api/devices/:id', (req, res) => {
  const device = store.getDevice(req.params.id);
  if (!device) return res.status(404).json({ error: 'Cihaz bulunamadi' });
  res.json({ ...device, token: undefined, online: isOnline(device.id) });
});

app.get('/api/devices/:id/history', (req, res) => {
  const device = store.getDevice(req.params.id);
  if (!device) return res.status(404).json({ error: 'Cihaz bulunamadi' });
  const limit = Math.min(Number(req.query.limit) || 20, 200);
  res.json(store.getHistory(device.id, limit));
});

app.post('/api/devices/:id/feed', (req, res) => {
  const device = store.getDevice(req.params.id);
  if (!device) return res.status(404).json({ error: 'Cihaz bulunamadi' });
  if (!isOnline(device.id)) return res.status(409).json({ error: 'Cihaz cevrimdisi' });

  const portions = Math.min(Math.max(parseInt(req.body?.portions, 10) || 1, 1), 10);
  const feedingId = crypto.randomUUID();

  const resultPromise = new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      pendingFeeds.delete(feedingId);
      reject(new Error('Cihazdan yanit alinamadi (zaman asimi)'));
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
  if (!device) return res.status(404).json({ error: 'Cihaz bulunamadi' });

  const num = (v, def) => {
    const n = Number(v);
    return Number.isFinite(n) ? n : def;
  };
  const clampSlot = (slot, def) => ({
    enabled: !!slot?.enabled,
    hour: Math.min(Math.max(num(slot?.hour, def.hour), 0), 23),
    minute: Math.min(Math.max(num(slot?.minute, def.minute), 0), 59),
    portions: Math.min(Math.max(num(slot?.portions, def.portions), 1), 10),
  });

  const schedule = {
    morning: clampSlot(req.body?.morning, device.schedule.morning),
    evening: clampSlot(req.body?.evening, device.schedule.evening),
  };

  store.setSchedule(device.id, schedule);
  const delivered = sendToDevice(device.id, { cmd: 'schedule:update', ...schedule });

  res.json({ schedule, delivered });
});

server.listen(PORT, () => {
  console.log(`[PetFeeder backend] http://localhost:${PORT} uzerinde calisiyor`);
});

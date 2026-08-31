// store.js — JSON dosyası tabanlı kalıcı depolama
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const DATA_DIR = path.join(__dirname, 'data');
const DB_FILE = path.join(DATA_DIR, 'db.json');
const MAX_HISTORY = 200;

function ensureDataDir() {
  if (!fs.existsSync(DATA_DIR)) fs.mkdirSync(DATA_DIR, { recursive: true });
}

// Eski morning/evening formatını yeni slots formatına migrate et
function migrateSchedule(old) {
  const m = old?.morning;
  const e = old?.evening;
  return {
    slots: [
      { id: 'slot1', label: 'Sabah', enabled: m?.enabled || false, hour: m?.hour ?? 8,  minute: m?.minute ?? 0,  portions: m?.portions ?? 1 },
      { id: 'slot2', label: 'Öğle',  enabled: false, hour: 12, minute: 0, portions: 1 },
      { id: 'slot3', label: 'Akşam', enabled: e?.enabled || false, hour: e?.hour ?? 18, minute: e?.minute ?? 0,  portions: e?.portions ?? 1 },
      { id: 'slot4', label: 'Gece',  enabled: false, hour: 22, minute: 0, portions: 1 },
    ],
  };
}

function defaultSchedule() {
  return {
    slots: [
      { id: 'slot1', label: 'Sabah', enabled: false, hour: 8,  minute: 0, portions: 1 },
      { id: 'slot2', label: 'Öğle',  enabled: false, hour: 12, minute: 0, portions: 1 },
      { id: 'slot3', label: 'Akşam', enabled: false, hour: 18, minute: 0, portions: 1 },
      { id: 'slot4', label: 'Gece',  enabled: false, hour: 22, minute: 0, portions: 1 },
    ],
  };
}

function load() {
  ensureDataDir();
  if (!fs.existsSync(DB_FILE)) {
    return { devices: {}, history: [], apiKey: null };
  }
  try {
    const db = JSON.parse(fs.readFileSync(DB_FILE, 'utf8'));
    if (!db.devices) db.devices = {};
    if (!db.history) db.history = [];
    // Eski schedule formatını migrate et
    Object.values(db.devices).forEach((d) => {
      if (d.schedule && !d.schedule.slots) {
        d.schedule = migrateSchedule(d.schedule);
      }
    });
    return db;
  } catch (err) {
    console.error('[store] db.json okunamadı:', err.message);
    return { devices: {}, history: [], apiKey: null };
  }
}

let db = load();

function save() {
  ensureDataDir();
  fs.writeFileSync(DB_FILE, JSON.stringify(db, null, 2));
}

// ─── API Anahtarı ─────────────────────────────────────────────────────────────
function ensureApiKey() {
  if (!db.apiKey) {
    db.apiKey = crypto.randomBytes(24).toString('hex');
    save();
  }
  return db.apiKey;
}

function getApiKey() {
  return db.apiKey;
}

// ─── Cihaz işlemleri ──────────────────────────────────────────────────────────
function createDevice(name) {
  const id = crypto.randomUUID();
  const token = crypto.randomBytes(16).toString('hex');
  db.devices[id] = {
    id, name: name || 'PetFeeder', token, mac: null,
    createdAt: new Date().toISOString(), lastSeenAt: null,
    schedule: defaultSchedule(),
  };
  save();
  return db.devices[id];
}

function findOrCreateByMac(mac, name) {
  const normalizedMac = mac.toUpperCase().trim();
  const existing = Object.values(db.devices).find((d) => d.mac === normalizedMac);
  if (existing) {
    console.log(`[store] Mevcut cihaz bulundu: ${existing.name} (${existing.id})`);
    return existing;
  }
  const id = crypto.randomUUID();
  const token = crypto.randomBytes(16).toString('hex');
  const deviceName = name && name.trim() ? name.trim() : `PetFeeder-${normalizedMac.slice(-5).replace(':', '')}`;
  db.devices[id] = {
    id, name: deviceName, token, mac: normalizedMac,
    createdAt: new Date().toISOString(), lastSeenAt: null,
    schedule: defaultSchedule(),
  };
  save();
  console.log(`[store] Yeni cihaz oluşturuldu: ${deviceName} (${id}) MAC: ${normalizedMac}`);
  return db.devices[id];
}

function getDevice(id) {
  return db.devices[id] || null;
}

function getDeviceByToken(token) {
  return Object.values(db.devices).find((d) => d.token === token) || null;
}

function listDevices() {
  return Object.values(db.devices);
}

function touchDevice(id) {
  if (db.devices[id]) {
    db.devices[id].lastSeenAt = new Date().toISOString();
    save();
  }
}

function renameDevice(id, name) {
  if (!db.devices[id] || !name || !name.trim()) return null;
  db.devices[id].name = name.trim();
  save();
  return db.devices[id];
}

function deleteDevice(id) {
  if (!db.devices[id]) return false;
  delete db.devices[id];
  db.history = db.history.filter((h) => h.deviceId !== id);
  save();
  return true;
}

function setSchedule(id, schedule) {
  if (!db.devices[id]) return null;
  db.devices[id].schedule = schedule;
  save();
  return db.devices[id];
}

function addHistory(entry) {
  db.history.unshift({ ...entry, ts: new Date().toISOString() });
  db.history = db.history.slice(0, MAX_HISTORY);
  save();
}

function getHistory(deviceId, limit = 50) {
  return db.history.filter((h) => h.deviceId === deviceId).slice(0, limit);
}

module.exports = {
  ensureApiKey,
  getApiKey,
  createDevice,
  findOrCreateByMac,
  getDevice,
  getDeviceByToken,
  listDevices,
  touchDevice,
  renameDevice,
  deleteDevice,
  setSchedule,
  addHistory,
  getHistory,
};

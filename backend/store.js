// store.js — JSON dosyasi tabanli basit kalici depolama (harici DB gerektirmez)
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const DATA_DIR = path.join(__dirname, 'data');
const DB_FILE = path.join(DATA_DIR, 'db.json');
const MAX_HISTORY = 200;

function ensureDataDir() {
  if (!fs.existsSync(DATA_DIR)) fs.mkdirSync(DATA_DIR, { recursive: true });
}

function load() {
  ensureDataDir();
  if (!fs.existsSync(DB_FILE)) {
    return { devices: {}, history: [] };
  }
  try {
    return JSON.parse(fs.readFileSync(DB_FILE, 'utf8'));
  } catch (err) {
    console.error('[store] db.json okunamadi, bos veritabani ile baslaniyor:', err.message);
    return { devices: {}, history: [] };
  }
}

let db = load();

function save() {
  ensureDataDir();
  fs.writeFileSync(DB_FILE, JSON.stringify(db, null, 2));
}

function defaultSchedule() {
  return {
    morning: { enabled: false, hour: 8, minute: 0, portions: 1 },
    evening: { enabled: false, hour: 18, minute: 0, portions: 1 },
  };
}

function createDevice(name) {
  const id = crypto.randomUUID();
  const token = crypto.randomBytes(16).toString('hex');
  db.devices[id] = {
    id,
    name: name || 'PetFeeder',
    token,
    createdAt: new Date().toISOString(),
    lastSeenAt: null,
    schedule: defaultSchedule(),
  };
  save();
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

function getHistory(deviceId, limit = 20) {
  return db.history.filter((h) => h.deviceId === deviceId).slice(0, limit);
}

module.exports = {
  createDevice,
  getDevice,
  getDeviceByToken,
  listDevices,
  touchDevice,
  setSchedule,
  addHistory,
  getHistory,
};

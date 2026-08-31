// PetFeeder.ino — v4
// Backend yok. Uygulama direkt ESP'ye HTTP ile bağlanır.
// ESP8266WebServer (port 80) + mDNS (petfeeder-XXXX.local)
// Zamanlama ve geçmiş LittleFS'te saklanır.

#include <Arduino.h>
#include <ESP8266WiFi.h>
#include <ESP8266WebServer.h>
#include <ESP8266mDNS.h>
#include <LittleFS.h>
#include <ArduinoJson.h>
#include <Ticker.h>
#include <time.h>
#include "config.h"

// ─── Pinler ───────────────────────────────────────────────────────────────────
static const uint8_t MOTOR_PIN  = D1;
static const uint8_t LED_PIN    = D4;   // active-low (NodeMCU built-in LED)
static const uint8_t BUTTON_PIN = D3;

// ─── Sabitler ─────────────────────────────────────────────────────────────────
static const char*    AP_PREFIX       = "PetFeeder-";
static const uint32_t WIFI_TIMEOUT_MS = 20000;
static const uint32_t MOTOR_MS_PER_P  = 800;   // ms / porsiyon
static const uint8_t  MAX_HISTORY     = 20;
static const int      TZ_OFFSET_SEC   = 3 * 3600; // UTC+3 (Türkiye)

// ─── LED ──────────────────────────────────────────────────────────────────────
enum LedMode { LED_SETUP, LED_CONNECTING, LED_IDLE, LED_FEEDING, LED_ERROR };
LedMode gLed = LED_CONNECTING;
Ticker  ledTick;

void setLed(LedMode m) {
  gLed = m;
  ledTick.detach();
  if (m == LED_FEEDING) { digitalWrite(LED_PIN, LOW); return; }
  uint16_t ms = (m == LED_SETUP || m == LED_ERROR) ? 80 :
                (m == LED_CONNECTING) ? 300 : 2500;
  ledTick.attach_ms(ms, []() {
    static bool s = false; s = !s;
    digitalWrite(LED_PIN, s ? LOW : HIGH);
  });
}

// ─── Cihaz adı & mDNS ─────────────────────────────────────────────────────────
static char devName[32] = "PetFeeder";
static char mdnsHost[24] = "";   // "petfeeder-aabb"

void buildMdnsHost() {
  uint8_t mac[6]; WiFi.macAddress(mac);
  snprintf(mdnsHost, sizeof(mdnsHost), "petfeeder-%02x%02x", mac[4], mac[5]);
}

void loadConfig() {
  File f = LittleFS.open("/config.json", "r");
  if (!f) return;
  StaticJsonDocument<256> doc;
  if (!deserializeJson(doc, f)) strlcpy(devName, doc["name"] | "PetFeeder", sizeof(devName));
  f.close();
}

void saveConfig(const char* name) {
  strlcpy(devName, name, sizeof(devName));
  StaticJsonDocument<256> doc; doc["name"] = devName;
  File f = LittleFS.open("/config.json", "w");
  if (f) { serializeJson(doc, f); f.close(); }
}

// ─── WiFi config ──────────────────────────────────────────────────────────────
bool loadWifi(char ssid[64], char pass[64]) {
  File f = LittleFS.open("/wifi.json", "r");
  if (!f) return false;
  StaticJsonDocument<256> doc;
  bool ok = !deserializeJson(doc, f); f.close();
  if (!ok) return false;
  strlcpy(ssid, doc["ssid"] | "", 64);
  strlcpy(pass, doc["pass"] | "", 64);
  return strlen(ssid) > 0;
}

void saveWifi(const char* ssid, const char* pass) {
  StaticJsonDocument<256> doc; doc["ssid"] = ssid; doc["pass"] = pass;
  File f = LittleFS.open("/wifi.json", "w");
  if (f) { serializeJson(doc, f); f.close(); }
}

// ─── Zamanlama ────────────────────────────────────────────────────────────────
struct Slot {
  char    id[8];
  char    label[16];
  bool    enabled;
  uint8_t hour, minute, portions;
  bool    firedToday;
};
static Slot slots[4];

void defaultSchedule() {
  const char* ids[]    = {"slot1","slot2","slot3","slot4"};
  const char* labels[] = {"Sabah","Öğle","Akşam","Gece"};
  const uint8_t hrs[]  = {8, 12, 18, 22};
  for (int i = 0; i < 4; i++) {
    strlcpy(slots[i].id,    ids[i],    sizeof(slots[i].id));
    strlcpy(slots[i].label, labels[i], sizeof(slots[i].label));
    slots[i].enabled    = false;
    slots[i].hour       = hrs[i];
    slots[i].minute     = 0;
    slots[i].portions   = 1;
    slots[i].firedToday = false;
  }
}

void loadSchedule() {
  defaultSchedule();
  File f = LittleFS.open("/schedule.json", "r");
  if (!f) return;
  StaticJsonDocument<1024> doc;
  if (deserializeJson(doc, f)) { f.close(); return; }
  f.close();
  JsonArray arr = doc["slots"].as<JsonArray>();
  for (int i = 0; i < 4 && i < (int)arr.size(); i++) {
    JsonObject s = arr[i];
    strlcpy(slots[i].id,    s["id"]    | slots[i].id,    sizeof(slots[i].id));
    strlcpy(slots[i].label, s["label"] | slots[i].label, sizeof(slots[i].label));
    slots[i].enabled  = s["enabled"]  | false;
    slots[i].hour     = s["hour"]     | slots[i].hour;
    slots[i].minute   = s["minute"]   | slots[i].minute;
    slots[i].portions = s["portions"] | 1;
  }
}

void saveSchedule() {
  StaticJsonDocument<1024> doc;
  JsonArray arr = doc.createNestedArray("slots");
  for (int i = 0; i < 4; i++) {
    JsonObject o = arr.createNestedObject();
    o["id"]       = slots[i].id;
    o["label"]    = slots[i].label;
    o["enabled"]  = slots[i].enabled;
    o["hour"]     = slots[i].hour;
    o["minute"]   = slots[i].minute;
    o["portions"] = slots[i].portions;
  }
  File f = LittleFS.open("/schedule.json", "w");
  if (f) { serializeJson(doc, f); f.close(); }
}

// ─── Geçmiş (ring buffer) ─────────────────────────────────────────────────────
struct HistEntry { char ts[28]; uint8_t portions; char msg[48]; };
static HistEntry hist[MAX_HISTORY];
static uint8_t histCount = 0;
static uint8_t histHead  = 0;

void loadHistory() {
  File f = LittleFS.open("/history.json", "r");
  if (!f) return;
  DynamicJsonDocument doc(2048);
  if (deserializeJson(doc, f)) { f.close(); return; }
  f.close();
  JsonArray arr = doc.as<JsonArray>();
  histCount = 0; histHead = 0;
  for (JsonObject o : arr) {
    if (histCount >= MAX_HISTORY) break;
    strlcpy(hist[histCount].ts,  o["ts"]  | "", sizeof(hist[0].ts));
    hist[histCount].portions = o["portions"] | 0;
    strlcpy(hist[histCount].msg, o["msg"] | "", sizeof(hist[0].msg));
    histCount++;
  }
  histHead = histCount % MAX_HISTORY;
}

String nowIso() {
  time_t t = time(nullptr);
  if (t < 1000000000) {
    // NTP henüz sync olmadı — millis kullan
    char buf[28]; snprintf(buf, sizeof(buf), "boot+%lus", millis()/1000);
    return String(buf);
  }
  struct tm* tm = localtime(&t);
  char buf[28];
  snprintf(buf, sizeof(buf), "%04d-%02d-%02dT%02d:%02d:%02d",
    tm->tm_year+1900, tm->tm_mon+1, tm->tm_mday,
    tm->tm_hour, tm->tm_min, tm->tm_sec);
  return String(buf);
}

void addHistory(uint8_t portions, const char* msg) {
  String ts = nowIso();
  strlcpy(hist[histHead].ts, ts.c_str(), sizeof(hist[0].ts));
  hist[histHead].portions = portions;
  strlcpy(hist[histHead].msg, msg, sizeof(hist[0].msg));
  histHead = (histHead + 1) % MAX_HISTORY;
  if (histCount < MAX_HISTORY) histCount++;

  DynamicJsonDocument doc(2048);
  JsonArray arr = doc.to<JsonArray>();
  uint8_t start = (histCount < MAX_HISTORY) ? 0 : histHead;
  for (int i = histCount - 1; i >= 0; i--) {  // newest first
    uint8_t idx = (start + i) % MAX_HISTORY;
    JsonObject o = arr.createNestedObject();
    o["ts"]       = hist[idx].ts;
    o["portions"] = hist[idx].portions;
    o["msg"]      = hist[idx].msg;
  }
  File f = LittleFS.open("/history.json", "w");
  if (f) { serializeJson(doc, f); f.close(); }
}

// ─── Motor ────────────────────────────────────────────────────────────────────
String runMotor(uint8_t portions) {
  setLed(LED_FEEDING);
  digitalWrite(MOTOR_PIN, HIGH);
  delay((uint32_t)MOTOR_MS_PER_P * portions);
  digitalWrite(MOTOR_PIN, LOW);
  setLed(LED_IDLE);
  char msg[48]; snprintf(msg, sizeof(msg), "%d porsiyon verildi", portions);
  addHistory(portions, msg);
  return String(msg);
}

// ─── HTTP Sunucu ──────────────────────────────────────────────────────────────
ESP8266WebServer server(80);

void cors() {
  server.sendHeader("Access-Control-Allow-Origin",  "*");
  server.sendHeader("Access-Control-Allow-Methods", "GET,POST,OPTIONS");
  server.sendHeader("Access-Control-Allow-Headers", "Content-Type");
}

void handleOptions() { cors(); server.send(204); }

// ─────────── Normal mod rotaları (WiFi bağlı) ─────────────────────────────────
void scheduleJson(JsonDocument& doc) {
  JsonArray arr = doc.createNestedArray("slots");
  for (int i = 0; i < 4; i++) {
    JsonObject o = arr.createNestedObject();
    o["id"]       = slots[i].id;
    o["label"]    = slots[i].label;
    o["enabled"]  = slots[i].enabled;
    o["hour"]     = slots[i].hour;
    o["minute"]   = slots[i].minute;
    o["portions"] = slots[i].portions;
  }
}

void registerMainRoutes() {
  server.on("/status", HTTP_GET, []() {
    cors();
    DynamicJsonDocument doc(1024);
    doc["name"]   = devName;
    doc["mdns"]   = mdnsHost;
    doc["online"] = true;
    doc["ip"]     = WiFi.localIP().toString();
    scheduleJson(doc);
    String out; serializeJson(doc, out);
    server.send(200, "application/json", out);
  });

  server.on("/feed", HTTP_POST, []() {
    cors();
    StaticJsonDocument<128> req;
    deserializeJson(req, server.arg("plain"));
    uint8_t p = constrain((int)(req["portions"] | 1), 1, 10);
    String msg = runMotor(p);
    server.send(200, "application/json",
      "{\"ok\":true,\"message\":\"" + msg + "\"}");
  });

  server.on("/schedule", HTTP_GET, []() {
    cors();
    DynamicJsonDocument doc(512);
    scheduleJson(doc);
    String out; serializeJson(doc, out);
    server.send(200, "application/json", out);
  });

  server.on("/schedule", HTTP_POST, []() {
    cors();
    StaticJsonDocument<1024> doc;
    if (deserializeJson(doc, server.arg("plain"))) {
      server.send(400, "application/json", "{\"error\":\"JSON hatasi\"}");
      return;
    }
    JsonArray arr = doc["slots"].as<JsonArray>();
    for (int i = 0; i < 4 && i < (int)arr.size(); i++) {
      JsonObject s = arr[i];
      slots[i].enabled  = s["enabled"]  | false;
      slots[i].hour     = constrain((int)(s["hour"]     | 8),  0, 23);
      slots[i].minute   = constrain((int)(s["minute"]   | 0),  0, 59);
      slots[i].portions = constrain((int)(s["portions"] | 1),  1, 10);
      slots[i].firedToday = false;
    }
    saveSchedule();
    server.send(200, "application/json", "{\"ok\":true}");
  });

  server.on("/history", HTTP_GET, []() {
    cors();
    DynamicJsonDocument doc(2048);
    JsonArray arr = doc.to<JsonArray>();
    uint8_t start = (histCount < MAX_HISTORY) ? 0 : histHead;
    for (int i = histCount - 1; i >= 0; i--) {
      uint8_t idx = (start + i) % MAX_HISTORY;
      JsonObject o = arr.createNestedObject();
      o["ts"]       = hist[idx].ts;
      o["portions"] = hist[idx].portions;
      o["msg"]      = hist[idx].msg;
    }
    String out; serializeJson(doc, out);
    server.send(200, "application/json", out);
  });

  server.on("/name", HTTP_POST, []() {
    cors();
    StaticJsonDocument<128> doc;
    if (!deserializeJson(doc, server.arg("plain"))) {
      const char* n = doc["name"] | "";
      if (strlen(n)) saveConfig(n);
    }
    server.send(200, "application/json", "{\"ok\":true}");
  });

  server.on("/reset", HTTP_POST, []() {
    cors();
    server.send(200, "application/json", "{\"ok\":true}");
    delay(500);
    LittleFS.remove("/wifi.json");
    LittleFS.remove("/config.json");
    ESP.restart();
  });

  server.onNotFound([]() {
    cors();
    if (server.method() == HTTP_OPTIONS) { server.send(204); return; }
    server.send(404, "application/json", "{\"error\":\"not found\"}");
  });
}

// ─────────── Setup (AP) mod rotaları ──────────────────────────────────────────
void registerSetupRoutes() {
  server.on("/info", HTTP_GET, []() {
    cors();
    StaticJsonDocument<256> doc;
    doc["mac"]  = WiFi.macAddress();
    doc["mdns"] = mdnsHost;
    doc["name"] = devName;
    String out; serializeJson(doc, out);
    server.send(200, "application/json", out);
  });

  server.on("/configure", HTTP_POST, []() {
    cors();
    StaticJsonDocument<512> doc;
    if (deserializeJson(doc, server.arg("plain"))) {
      server.send(400, "application/json", "{\"error\":\"JSON hatasi\"}");
      return;
    }
    const char* ssid = doc["ssid"]     | "";
    const char* pass = doc["password"] | "";
    const char* name = doc["name"]     | "PetFeeder";
    if (!strlen(ssid)) {
      server.send(400, "application/json", "{\"error\":\"SSID gerekli\"}");
      return;
    }
    saveWifi(ssid, pass);
    saveConfig(name);
    StaticJsonDocument<128> resp;
    resp["ok"]   = true;
    resp["mdns"] = mdnsHost;
    String out; serializeJson(resp, out);
    server.send(200, "application/json", out);
    delay(1000);
    ESP.restart();
  });

  server.on("/reset", HTTP_POST, []() {
    cors();
    server.send(200, "application/json", "{\"ok\":true}");
    delay(500);
    LittleFS.remove("/wifi.json");
    LittleFS.remove("/config.json");
    ESP.restart();
  });

  server.onNotFound([]() {
    cors();
    if (server.method() == HTTP_OPTIONS) { server.send(204); return; }
    server.send(404, "application/json", "{\"error\":\"not found\"}");
  });
}

// ─── Zamanlama kontrolü (NTP ile) ─────────────────────────────────────────────
int lastScheduleMinute = -1;
int lastScheduleDay    = -1;

void checkSchedule() {
  time_t t = time(nullptr);
  if (t < 1000000000) return;  // NTP sync yok
  struct tm* tm = localtime(&t);
  int nowMin = tm->tm_hour * 60 + tm->tm_min;
  int nowDay = tm->tm_yday;

  // Gün değişti → firedToday sıfırla
  if (nowDay != lastScheduleDay) {
    for (int i = 0; i < 4; i++) slots[i].firedToday = false;
    lastScheduleDay = nowDay;
  }

  if (nowMin == lastScheduleMinute) return;
  lastScheduleMinute = nowMin;

  for (int i = 0; i < 4; i++) {
    if (!slots[i].enabled || slots[i].firedToday) continue;
    if (slots[i].hour == tm->tm_hour && slots[i].minute == tm->tm_min) {
      Serial.printf("[Zamanlama] %s: %d porsiyon\n", slots[i].label, slots[i].portions);
      slots[i].firedToday = true;
      runMotor(slots[i].portions);
    }
  }
}

// ─── Buton (3s basılı → fabrika ayarları) ────────────────────────────────────
uint32_t btnDown = 0;
bool     btnHeld = false;

void checkButton() {
  bool pressed = (digitalRead(BUTTON_PIN) == LOW);
  if (pressed && !btnHeld) { btnDown = millis(); btnHeld = true; }
  else if (!pressed) { btnHeld = false; }
  if (btnHeld && millis() - btnDown > 3000) {
    btnHeld = false;
    Serial.println("[BTN] Fabrika ayarları sıfırlanıyor...");
    LittleFS.remove("/wifi.json");
    LittleFS.remove("/config.json");
    LittleFS.remove("/schedule.json");
    LittleFS.remove("/history.json");
    ESP.restart();
  }
}

// ─── Setup / Loop ─────────────────────────────────────────────────────────────
bool setupMode = false;

void startSetupAP() {
  setupMode = true;
  setLed(LED_SETUP);
  WiFi.disconnect();
  WiFi.mode(WIFI_AP);

  // AP SSID: "PetFeeder-aabb" (son 4 hex MAC)
  String apSsid = String(AP_PREFIX) +
    String(mdnsHost).substring(String(mdnsHost).lastIndexOf('-') + 1);
  WiFi.softAP(apSsid.c_str(), SETUP_AP_PASSWORD);
  Serial.printf("[AP] SSID: %s  IP: %s\n",
    apSsid.c_str(), WiFi.softAPIP().toString().c_str());

  registerSetupRoutes();
  server.begin();
}

void setup() {
  Serial.begin(115200);
  Serial.println("\n[PetFeeder v4] Başlatılıyor...");

  pinMode(MOTOR_PIN,  OUTPUT); digitalWrite(MOTOR_PIN, LOW);
  pinMode(LED_PIN,    OUTPUT); digitalWrite(LED_PIN,  HIGH);
  pinMode(BUTTON_PIN, INPUT_PULLUP);

  if (!LittleFS.begin()) {
    Serial.println("[FS] Format ediliyor...");
    LittleFS.format();
    LittleFS.begin();
  }

  buildMdnsHost();
  Serial.printf("[mDNS] %s.local\n", mdnsHost);

  loadConfig();
  loadSchedule();
  loadHistory();

  setLed(LED_CONNECTING);

  char ssid[64], pass[64];
  if (!loadWifi(ssid, pass)) {
    Serial.println("[WiFi] Yapılandırma yok → setup AP");
    startSetupAP();
    return;
  }

  WiFi.mode(WIFI_STA);
  WiFi.begin(ssid, pass);
  Serial.printf("[WiFi] %s bağlanılıyor...\n", ssid);

  uint32_t t0 = millis();
  while (WiFi.status() != WL_CONNECTED) {
    if (millis() - t0 > WIFI_TIMEOUT_MS) {
      Serial.println("[WiFi] Zaman aşımı → setup AP");
      LittleFS.remove("/wifi.json");
      startSetupAP();
      return;
    }
    delay(200);
    yield();
  }

  Serial.printf("[WiFi] Bağlandı: %s\n", WiFi.localIP().toString().c_str());
  setLed(LED_IDLE);

  // NTP
  configTime(TZ_OFFSET_SEC, 0, "pool.ntp.org", "time.nist.gov");
  Serial.println("[NTP] Sync ediliyor...");

  // mDNS
  if (MDNS.begin(mdnsHost)) {
    MDNS.addService("http", "tcp", 80);
    Serial.printf("[mDNS] http://%s.local hazır\n", mdnsHost);
  } else {
    Serial.println("[mDNS] Başlatılamadı");
  }

  registerMainRoutes();
  server.begin();
  Serial.println("[HTTP] Sunucu hazır (port 80)");
  Serial.printf("[Cihaz] %s  mDNS: %s.local\n", devName, mdnsHost);
}

void loop() {
  if (setupMode) {
    server.handleClient();
    checkButton();
    yield();
    return;
  }

  server.handleClient();
  MDNS.update();
  checkButton();
  checkSchedule();
  yield();
}

// PetFeeder.ino — v5
// v4'e kıyasla eklenenler:
//   • MQTT client (PubSubClient) — cloud backend ile çift yönlü iletişim
//   • /configure artık mqtt_host, mqtt_port, mqtt_user, mqtt_pass alıyor
//   • Yerel HTTP sunucu korundu (fallback + local test)
//
// Kütüphane gereksinimleri:
//   Arduino IDE: Library Manager → "PubSubClient" by Nick O'Leary (>= 2.8)
//   platformio: lib_deps = knolleary/PubSubClient@^2.8

#include <Arduino.h>
#include <ESP8266WiFi.h>
#include <ESP8266WebServer.h>
#include <ESP8266mDNS.h>
#include <LittleFS.h>
#include <ArduinoJson.h>
#include <Ticker.h>
#include <PubSubClient.h>
#include <time.h>
#include "config.h"

// ─── Pinler ───────────────────────────────────────────────────────────────────
static const uint8_t MOTOR_PINS[4] = { D1, D2, D5, D6 };
static const uint8_t LED_PIN       = D4;
static const uint8_t BUTTON_PIN    = D3;

// ─── Sabitler ─────────────────────────────────────────────────────────────────
static const char*    AP_PREFIX         = "PetFeeder-";
static const uint32_t WIFI_TIMEOUT_MS   = 20000;
static const uint8_t  MAX_HISTORY       = 20;
static const int      TZ_OFFSET_SEC     = 3 * 3600;
static const uint16_t STEPS_PER_PORTION = 4076;
static const uint16_t STEP_DELAY_MS     = 2;
static const uint32_t MQTT_RECONNECT_MS = 8000;   // 8 sn'de bir bağlantı denemesi
static const uint32_t TELEMETRY_MS      = 30000;  // 30 sn'de bir telemetri

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
static char mdnsHost[24] = "";

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

// ─── MQTT config ──────────────────────────────────────────────────────────────
struct MqttCfg {
  char host[64];
  uint16_t port;
  char user[64];   // = device UUID (backend'in atadığı ID)
  char pass[64];
};
static MqttCfg mqttCfg;
static bool hasMqtt = false;

bool loadMqtt() {
  File f = LittleFS.open("/mqtt.json", "r");
  if (!f) return false;
  StaticJsonDocument<512> doc;
  bool ok = !deserializeJson(doc, f); f.close();
  if (!ok) return false;
  strlcpy(mqttCfg.host, doc["host"] | "", sizeof(mqttCfg.host));
  mqttCfg.port = doc["port"] | 1883;
  strlcpy(mqttCfg.user, doc["user"] | "", sizeof(mqttCfg.user));
  strlcpy(mqttCfg.pass, doc["pass"] | "", sizeof(mqttCfg.pass));
  return strlen(mqttCfg.host) > 0 && strlen(mqttCfg.user) > 0;
}

void saveMqtt(const char* host, uint16_t port,
              const char* user, const char* pass) {
  strlcpy(mqttCfg.host, host, sizeof(mqttCfg.host));
  mqttCfg.port = port;
  strlcpy(mqttCfg.user, user, sizeof(mqttCfg.user));
  strlcpy(mqttCfg.pass, pass, sizeof(mqttCfg.pass));
  StaticJsonDocument<512> doc;
  doc["host"] = host; doc["port"] = port;
  doc["user"] = user; doc["pass"] = pass;
  File f = LittleFS.open("/mqtt.json", "w");
  if (f) { serializeJson(doc, f); f.close(); }
}

// ─── Zamanlama ────────────────────────────────────────────────────────────────
struct Slot {
  char id[8]; char label[16];
  bool enabled; uint8_t hour, minute, portions;
  bool firedToday;
};
static Slot slots[4];

void defaultSchedule() {
  const char* ids[]    = {"slot1","slot2","slot3","slot4"};
  const char* labels[] = {"Sabah","Öğle","Akşam","Gece"};
  const uint8_t hrs[]  = {8, 12, 18, 22};
  for (int i = 0; i < 4; i++) {
    strlcpy(slots[i].id,    ids[i],    sizeof(slots[i].id));
    strlcpy(slots[i].label, labels[i], sizeof(slots[i].label));
    slots[i].enabled = false; slots[i].hour = hrs[i];
    slots[i].minute = 0; slots[i].portions = 1; slots[i].firedToday = false;
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
    o["id"] = slots[i].id; o["label"] = slots[i].label;
    o["enabled"] = slots[i].enabled; o["hour"] = slots[i].hour;
    o["minute"] = slots[i].minute; o["portions"] = slots[i].portions;
  }
  File f = LittleFS.open("/schedule.json", "w");
  if (f) { serializeJson(doc, f); f.close(); }
}

// ─── Geçmiş ───────────────────────────────────────────────────────────────────
struct HistEntry { char ts[28]; uint8_t portions; char msg[48]; };
static HistEntry hist[MAX_HISTORY];
static uint8_t histCount = 0, histHead = 0;

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
  if (t < 1000000000) { char buf[28]; snprintf(buf,sizeof(buf),"boot+%lus",millis()/1000); return buf; }
  struct tm* tm = localtime(&t);
  char buf[28];
  snprintf(buf,sizeof(buf),"%04d-%02d-%02dT%02d:%02d:%02d",
    tm->tm_year+1900,tm->tm_mon+1,tm->tm_mday,tm->tm_hour,tm->tm_min,tm->tm_sec);
  return String(buf);
}

void addHistory(uint8_t portions, const char* msg);  // forward decl

// ─── MQTT ─────────────────────────────────────────────────────────────────────
WiFiClient   wifiClient;
PubSubClient mqttClient(wifiClient);

// ─── Forward declarations (Motor bölümünde tanımlı) ──────────────────────────
bool gFeeding = false;   // tanım motor bölümünde tekrarlanmaz

// topic tamponu: "petfeeder/{user}/cmd"
static char topicCmd[96];
static char topicReport[96];

// Besleme reqId (MQTT komutu bekliyor ise)
static char pendingReqId[48] = "";

void mqttPublishReport(const char* reqId = nullptr,
                       bool ok = true,
                       const char* message = nullptr,
                       int portions = 0) {
  if (!mqttClient.connected()) return;
  StaticJsonDocument<512> doc;
  doc["online"]  = true;
  doc["feeding"] = gFeeding;
  doc["name"]    = devName;
  doc["fw"]      = "5.0";
  doc["ip"]      = WiFi.localIP().toString();
  if (reqId && strlen(reqId))  doc["reqId"]   = reqId;
  if (message && strlen(message)) doc["message"] = message;
  if (!ok) doc["ok"] = false; else doc["ok"] = true;
  if (portions > 0) doc["portions"] = portions;
  String out; serializeJson(doc, out);
  mqttClient.publish(topicReport, out.c_str(), /*retain=*/false);
}

void mqttOnMessage(char* topic, byte* payload, unsigned int len) {
  // payload'u null-terminate et
  char buf[512];
  if (len >= sizeof(buf)) len = sizeof(buf) - 1;
  memcpy(buf, payload, len); buf[len] = 0;

  StaticJsonDocument<512> doc;
  if (deserializeJson(doc, buf)) {
    Serial.println("[MQTT] JSON parse hatası");
    return;
  }

  const char* type  = doc["type"]  | "";
  const char* reqId = doc["reqId"] | "";
  Serial.printf("[MQTT] Komut: %s\n", type);

  if (strcmp(type, "status_req") == 0) {
    mqttPublishReport(reqId);

  } else if (strcmp(type, "feed") == 0) {
    uint8_t p = constrain((int)(doc["portions"] | 1), 1, 10);
    strlcpy(pendingReqId, reqId, sizeof(pendingReqId));
    String res = runMotor(p);
    // Hemen "besleme başladı" yanıtı gönder; bitiş motor callback'te yayınlanacak
    mqttPublishReport(reqId, true, res.c_str(), p);

  } else if (strcmp(type, "sched") == 0) {
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
    if (strlen(reqId)) mqttPublishReport(reqId, true, "Zamanlama guncellendi");

  } else if (strcmp(type, "name") == 0) {
    const char* n = doc["name"] | "";
    if (strlen(n)) { saveConfig(n); }

  } else if (strcmp(type, "reset") == 0) {
    mqttPublishReport(reqId, true, "Fabrika ayarlarina donuluyor");
    delay(500);
    LittleFS.remove("/wifi.json"); LittleFS.remove("/config.json");
    LittleFS.remove("/schedule.json"); LittleFS.remove("/history.json");
    LittleFS.remove("/mqtt.json");
    ESP.restart();
  }
}

bool mqttConnect() {
  if (!hasMqtt) return false;
  Serial.printf("[MQTT] %s:%d olarak %s bağlanılıyor...\n",
    mqttCfg.host, mqttCfg.port, mqttCfg.user);

  // MQTT Will: çevrimdışı telemetri
  char willPayload[] = "{\"online\":false}";

  bool ok = mqttClient.connect(
    mqttCfg.user,    // clientId = deviceId (benzersiz)
    mqttCfg.user,    // username
    mqttCfg.pass,    // password
    topicReport,     // willTopic
    1,               // willQos
    true,            // willRetain
    willPayload
  );

  if (ok) {
    Serial.println("[MQTT] Bağlandı ✓");
    mqttClient.subscribe(topicCmd, 1);
    mqttPublishReport();  // ilk telemetri
  } else {
    Serial.printf("[MQTT] Bağlantı hatası: %d\n", mqttClient.state());
  }
  return ok;
}

// ─── Motor ────────────────────────────────────────────────────────────────────
static const uint8_t STEP_SEQ[8][4] = {
  {1,0,0,0},{1,1,0,0},{0,1,0,0},{0,1,1,0},
  {0,0,1,0},{0,0,1,1},{0,0,0,1},{1,0,0,1}
};
static int      gStepIdx   = 0;
// gFeeding: yukarıda (MQTT bölümü öncesinde) tanımlandı
static uint32_t gStepsLeft = 0;
static uint8_t  gFeedPortions = 0;
Ticker          motorTick;

void motorOff() { for(int i=0;i<4;i++) digitalWrite(MOTOR_PINS[i],LOW); }

void IRAM_ATTR onMotorTick() {
  if (gStepsLeft == 0) {
    motorTick.detach(); motorOff();
    gFeeding = false;
    setLed(LED_IDLE);
    char msg[48]; snprintf(msg, sizeof(msg), "%d porsiyon verildi", gFeedPortions);
    addHistory(gFeedPortions, msg);
    // MQTT: besleme bitti bildirimi (motorTick IRAM'dan çalışıyor,
    // mqttPublishReport içinde String kullanmak güvensiz — sadece flag set)
    // Gerçek yayın loop()'ta yapılacak (bkz. feedDoneFlag)
    return;
  }
  gStepIdx = (gStepIdx + 1) % 8;
  for(int i=0;i<4;i++) digitalWrite(MOTOR_PINS[i], STEP_SEQ[gStepIdx][i]);
  gStepsLeft--;
}

// IRAM'dan güvenli çağrı için flag
static volatile bool feedDoneFlag = false;
static uint8_t feedDonePortions = 0;
static char    feedDoneMsg[48] = "";

void IRAM_ATTR onMotorTickSafe() {
  if (gStepsLeft == 0) {
    motorTick.detach(); motorOff();
    gFeeding = false; setLed(LED_IDLE);
    feedDonePortions = gFeedPortions;
    snprintf(feedDoneMsg, sizeof(feedDoneMsg), "%d porsiyon verildi", gFeedPortions);
    feedDoneFlag = true;
    return;
  }
  gStepIdx = (gStepIdx + 1) % 8;
  for(int i=0;i<4;i++) digitalWrite(MOTOR_PINS[i], STEP_SEQ[gStepIdx][i]);
  gStepsLeft--;
}

String runMotor(uint8_t portions) {
  if (gFeeding) return "Besleme zaten devam ediyor";
  gFeeding = true; gFeedPortions = portions; feedDoneFlag = false;
  gStepsLeft = (uint32_t)STEPS_PER_PORTION * portions;
  setLed(LED_FEEDING);
  motorTick.attach_ms(STEP_DELAY_MS, onMotorTickSafe);
  char msg[48]; snprintf(msg, sizeof(msg), "%d porsiyon baslatildi", portions);
  return String(msg);
}

// ─── Geçmiş (addHistory ile birlikte) ────────────────────────────────────────
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
  for (int i = histCount - 1; i >= 0; i--) {
    uint8_t idx = (start + i) % MAX_HISTORY;
    JsonObject o = arr.createNestedObject();
    o["ts"] = hist[idx].ts; o["portions"] = hist[idx].portions; o["msg"] = hist[idx].msg;
  }
  File f = LittleFS.open("/history.json", "w");
  if (f) { serializeJson(doc, f); f.close(); }
}

// ─── HTTP Sunucu ──────────────────────────────────────────────────────────────
ESP8266WebServer server(80);

void cors() {
  server.sendHeader("Access-Control-Allow-Origin",  "*");
  server.sendHeader("Access-Control-Allow-Methods", "GET,POST,OPTIONS");
  server.sendHeader("Access-Control-Allow-Headers", "Content-Type");
}

void scheduleJson(JsonDocument& doc) {
  JsonArray arr = doc.createNestedArray("slots");
  for (int i = 0; i < 4; i++) {
    JsonObject o = arr.createNestedObject();
    o["id"] = slots[i].id; o["label"] = slots[i].label;
    o["enabled"] = slots[i].enabled; o["hour"] = slots[i].hour;
    o["minute"] = slots[i].minute; o["portions"] = slots[i].portions;
  }
}

void registerMainRoutes() {
  server.on("/status", HTTP_GET, []() {
    cors();
    DynamicJsonDocument doc(1024);
    doc["name"] = devName; doc["mdns"] = mdnsHost;
    doc["online"] = true; doc["feeding"] = gFeeding;
    doc["ip"] = WiFi.localIP().toString();
    doc["mqtt"] = mqttClient.connected();
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
    DynamicJsonDocument doc(512); scheduleJson(doc);
    String out; serializeJson(doc, out);
    server.send(200, "application/json", out);
  });

  server.on("/schedule", HTTP_POST, []() {
    cors();
    StaticJsonDocument<1024> doc;
    if (deserializeJson(doc, server.arg("plain"))) {
      server.send(400, "application/json", "{\"error\":\"JSON hatasi\"}"); return;
    }
    JsonArray arr = doc["slots"].as<JsonArray>();
    for (int i = 0; i < 4 && i < (int)arr.size(); i++) {
      JsonObject s = arr[i];
      slots[i].enabled  = s["enabled"]  | false;
      slots[i].hour     = constrain((int)(s["hour"]    |8),0,23);
      slots[i].minute   = constrain((int)(s["minute"]  |0),0,59);
      slots[i].portions = constrain((int)(s["portions"]|1),1,10);
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
      o["ts"] = hist[idx].ts; o["portions"] = hist[idx].portions; o["msg"] = hist[idx].msg;
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
    LittleFS.remove("/wifi.json"); LittleFS.remove("/config.json");
    LittleFS.remove("/mqtt.json");
    ESP.restart();
  });

  server.onNotFound([]() {
    cors();
    if (server.method() == HTTP_OPTIONS) { server.send(204); return; }
    server.send(404, "application/json", "{\"error\":\"not found\"}");
  });
}

// ─── Setup (AP) mod rotaları ──────────────────────────────────────────────────
void registerSetupRoutes() {
  server.on("/info", HTTP_GET, []() {
    cors();
    StaticJsonDocument<256> doc;
    doc["mac"]  = WiFi.macAddress();
    doc["ap"]   = mdnsHost;
    doc["name"] = devName;
    String out; serializeJson(doc, out);
    server.send(200, "application/json", out);
  });

  // Güncellenmiş /configure — wifi + MQTT kimlik bilgilerini alıyor
  server.on("/configure", HTTP_POST, []() {
    cors();
    StaticJsonDocument<512> doc;
    if (deserializeJson(doc, server.arg("plain"))) {
      server.send(400, "application/json", "{\"error\":\"JSON hatasi\"}"); return;
    }
    const char* ssid      = doc["ssid"]      | "";
    const char* pass      = doc["password"]  | "";
    const char* name      = doc["name"]      | "PetFeeder";
    const char* mqttHost  = doc["mqtt_host"] | BACKEND_HOST_DEFAULT;
    uint16_t    mqttPort  = doc["mqtt_port"] | (uint16_t)1883;
    const char* mqttUser  = doc["mqtt_user"] | "";
    const char* mqttPass  = doc["mqtt_pass"] | "";

    if (!strlen(ssid)) {
      server.send(400, "application/json", "{\"error\":\"SSID gerekli\"}"); return;
    }

    saveWifi(ssid, pass);
    saveConfig(name);
    if (strlen(mqttUser)) saveMqtt(mqttHost, mqttPort, mqttUser, mqttPass);

    StaticJsonDocument<128> resp;
    resp["ok"] = true; resp["ap"] = mdnsHost;
    String out; serializeJson(resp, out);
    server.send(200, "application/json", out);
    delay(1000);
    ESP.restart();
  });

  server.on("/reset", HTTP_POST, []() {
    cors();
    server.send(200, "application/json", "{\"ok\":true}");
    delay(500);
    LittleFS.remove("/wifi.json"); LittleFS.remove("/config.json");
    LittleFS.remove("/mqtt.json");
    ESP.restart();
  });

  server.onNotFound([]() {
    cors();
    if (server.method() == HTTP_OPTIONS) { server.send(204); return; }
    server.send(404, "application/json", "{\"error\":\"not found\"}");
  });
}

// ─── Zamanlama kontrolü ───────────────────────────────────────────────────────
int lastScheduleMinute = -1, lastScheduleDay = -1;

void checkSchedule() {
  time_t t = time(nullptr);
  if (t < 1000000000) return;
  struct tm* tm = localtime(&t);
  int nowDay = tm->tm_yday;
  if (nowDay != lastScheduleDay) {
    for(int i=0;i<4;i++) slots[i].firedToday = false;
    lastScheduleDay = nowDay;
  }
  int nowMin = tm->tm_hour * 60 + tm->tm_min;
  if (nowMin == lastScheduleMinute) return;
  lastScheduleMinute = nowMin;
  for(int i=0;i<4;i++) {
    if (!slots[i].enabled || slots[i].firedToday) continue;
    if (slots[i].hour == tm->tm_hour && slots[i].minute == tm->tm_min) {
      Serial.printf("[Zamanlama] %s: %d porsiyon\n", slots[i].label, slots[i].portions);
      slots[i].firedToday = true;
      runMotor(slots[i].portions);
    }
  }
}

// ─── Buton ────────────────────────────────────────────────────────────────────
uint32_t btnDown = 0; bool btnHeld = false;
void checkButton() {
  bool pressed = (digitalRead(BUTTON_PIN) == LOW);
  if (pressed && !btnHeld) { btnDown = millis(); btnHeld = true; }
  else if (!pressed) { btnHeld = false; }
  if (btnHeld && millis() - btnDown > 3000) {
    btnHeld = false;
    Serial.println("[BTN] Fabrika ayarları sıfırlanıyor...");
    LittleFS.remove("/wifi.json"); LittleFS.remove("/config.json");
    LittleFS.remove("/schedule.json"); LittleFS.remove("/history.json");
    LittleFS.remove("/mqtt.json");
    ESP.restart();
  }
}

// ─── Setup / Loop ─────────────────────────────────────────────────────────────
bool setupMode = false;
uint32_t lastMqttAttempt  = 0;
uint32_t lastTelemetry    = 0;

void startSetupAP() {
  setupMode = true; setLed(LED_SETUP);
  WiFi.disconnect(); WiFi.mode(WIFI_AP);
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
  Serial.println("\n[PetFeeder v5] Başlatılıyor...");

  for(int i=0;i<4;i++) { pinMode(MOTOR_PINS[i], OUTPUT); digitalWrite(MOTOR_PINS[i], LOW); }
  pinMode(LED_PIN, OUTPUT); digitalWrite(LED_PIN, HIGH);
  pinMode(BUTTON_PIN, INPUT_PULLUP);

  if (!LittleFS.begin()) {
    Serial.println("[FS] Format ediliyor..."); LittleFS.format(); LittleFS.begin();
  }

  buildMdnsHost();
  loadConfig(); loadSchedule(); loadHistory();
  hasMqtt = loadMqtt();
  Serial.printf("[mDNS] %s.local\n", mdnsHost);
  if (hasMqtt) Serial.printf("[MQTT] Config: %s:%d user=%s\n",
    mqttCfg.host, mqttCfg.port, mqttCfg.user);

  setLed(LED_CONNECTING);

  // MQTT topic tamponu
  snprintf(topicCmd,    sizeof(topicCmd),    "petfeeder/%s/cmd",    mqttCfg.user);
  snprintf(topicReport, sizeof(topicReport), "petfeeder/%s/report", mqttCfg.user);

  char ssid[64], pass[64];
  if (!loadWifi(ssid, pass)) {
    Serial.println("[WiFi] Config yok → setup AP");
    startSetupAP(); return;
  }

  WiFi.mode(WIFI_STA);
  WiFi.begin(ssid, pass);
  Serial.printf("[WiFi] %s bağlanılıyor...\n", ssid);

  uint32_t t0 = millis();
  while (WiFi.status() != WL_CONNECTED) {
    if (millis() - t0 > WIFI_TIMEOUT_MS) {
      Serial.println("[WiFi] Zaman aşımı → setup AP");
      LittleFS.remove("/wifi.json");
      startSetupAP(); return;
    }
    delay(200); yield();
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
  }

  // MQTT
  if (hasMqtt) {
    mqttClient.setServer(mqttCfg.host, mqttCfg.port);
    mqttClient.setCallback(mqttOnMessage);
    mqttClient.setKeepAlive(60);
    mqttClient.setBufferSize(512);
    mqttConnect();
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
    yield(); return;
  }

  server.handleClient();
  MDNS.update();
  checkButton();
  checkSchedule();

  // Motor tamamlandı — MQTT'ye bildir
  if (feedDoneFlag) {
    feedDoneFlag = false;
    addHistory(feedDonePortions, feedDoneMsg);
    mqttPublishReport(pendingReqId, true, feedDoneMsg, feedDonePortions);
    pendingReqId[0] = 0;
  }

  // MQTT loop ve yeniden bağlantı
  if (hasMqtt) {
    if (!mqttClient.connected()) {
      uint32_t now = millis();
      if (now - lastMqttAttempt > MQTT_RECONNECT_MS) {
        lastMqttAttempt = now;
        mqttConnect();
      }
    } else {
      mqttClient.loop();
      // Periyodik telemetri
      uint32_t now = millis();
      if (now - lastTelemetry > TELEMETRY_MS) {
        lastTelemetry = now;
        mqttPublishReport();
      }
    }
  }

  yield();
}

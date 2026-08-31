/*
 * PetFeeder.ino — v3 (uygulama içi kurulum sihirbazı)
 * ESP8266 (NodeMCU) — Smart Pet Feeder Firmware
 *
 * Kurulum akışı:
 *   1. İlk açılışta (wifi.json yok) → "PetFeeder-XXXX" AP açar
 *   2. Uygulama 192.168.4.1/configure endpoint'ine WiFi + backend bilgisini gönderir
 *   3. Cihaz yeniden başlar, ev ağına bağlanır, /api/auto-register çağırır
 *   4. WebSocket ile backend'e bağlanır
 *
 * Sıfırlama: Butona 3 sn basılı tut → wifi.json silinir → setup AP açılır
 */

#include <ESP8266WiFi.h>
#include <ESP8266WebServer.h>
#include <ESP8266HTTPClient.h>
#include <WiFiClient.h>
#include <WebSocketsClient.h>
#include <ArduinoJson.h>
#include <Wire.h>
#include <RTClib.h>
#include <LittleFS.h>
#include <ArduinoOTA.h>
#include "config.h"

// ─── Stepper Motor ────────────────────────────────────────────────────────────
#define IN1 D1
#define IN2 D2
#define IN3 D3
#define IN4 D4
#define STEPS_PER_PORTION 509
#define STEP_DELAY_US     1200

const int stepSeq[8][4] = {
  {1,0,0,0},{1,1,0,0},{0,1,0,0},{0,1,1,0},
  {0,0,1,0},{0,0,1,1},{0,0,0,1},{1,0,0,1}
};
int stepIndex = 0;

// ─── Kullanıcı arayüzü ────────────────────────────────────────────────────────
#define BUTTON_PIN            D7
#define LED_PIN               D8
#define BUZZER_PIN            D0
#define MANUAL_FEED_PORTIONS  1
#define BUTTON_DEBOUNCE_MS    250
#define WIFI_RESET_HOLD_MS    3000

enum LedState { LED_SETUP, LED_CONNECTING, LED_IDLE, LED_FEEDING, LED_ERROR };
LedState ledState = LED_CONNECTING;
unsigned long lastLedToggleMs = 0;
bool ledOn = false;
unsigned long lastButtonMs = 0;
int lastButtonState = HIGH;

// ─── WebSocket ────────────────────────────────────────────────────────────────
WebSocketsClient wsClient;
bool wsConnected = false;
unsigned long lastPingMs = 0;
#define PING_INTERVAL_MS 30000

// ─── RTC ──────────────────────────────────────────────────────────────────────
RTC_DS1307 rtc;
bool rtcAvailable = false;
unsigned long lastRtcCheckMs = 0;
#define RTC_CHECK_INTERVAL_MS 20000

// ─── Yapılandırma ─────────────────────────────────────────────────────────────
String backendHost;
uint16_t backendPort;
String deviceToken;
bool inSetupMode = false;

// Setup HTTP server (sadece AP modunda aktif)
ESP8266WebServer setupServer(80);

// ─── Çoklu besleme slotları ───────────────────────────────────────────────────
#define MAX_SLOTS 4

struct ScheduleSlot {
  bool    enabled;
  uint8_t hour;
  uint8_t minute;
  uint8_t portions;
  bool    firedToday;
};

ScheduleSlot slots[MAX_SLOTS] = {
  {false, 8,  0, 1, false},
  {false, 12, 0, 1, false},
  {false, 18, 0, 1, false},
  {false, 22, 0, 1, false},
};

// ─── Fonksiyon prototipleri ────────────────────────────────────────────────────
void stepMotor(int steps);
void motorOff();
void runMotor(int portions);
void wsEvent(WStype_t type, uint8_t *payload, size_t length);
void handleWsMessage(const char *json);
void sendJson(JsonDocument &doc);
void checkSchedule();
void loadRuntimeConfig();
void saveRuntimeConfig();
void loadSchedule();
void saveSchedule();
void setupOta();
void setLedState(LedState s);
void updateLed();
void beep(int count, int durationMs);
void handleButton();
bool autoRegister();
void connectWebSocket();
bool loadWifiConfig();
void saveWifiConfig(const String &ssid, const String &password);
void startSetupAP();
void connectWifi();

// ─────────────────────────────────────────────────────────────────────────────
void setup() {
  Serial.begin(115200);
  delay(100);
  Serial.println("\n[PetFeeder v3] Başlatılıyor...");

  pinMode(IN1, OUTPUT); pinMode(IN2, OUTPUT);
  pinMode(IN3, OUTPUT); pinMode(IN4, OUTPUT);
  motorOff();
  pinMode(BUTTON_PIN, INPUT_PULLUP);
  pinMode(LED_PIN, OUTPUT);
  pinMode(BUZZER_PIN, OUTPUT);
  digitalWrite(LED_PIN, LOW);
  digitalWrite(BUZZER_PIN, LOW);

  if (!LittleFS.begin()) {
    Serial.println("[FS] Biçimlendiriliyor...");
    LittleFS.format();
    LittleFS.begin();
  }
  loadRuntimeConfig();
  loadSchedule();

  // Uzun basış → sıfırla (setup moduna geç)
  if (digitalRead(BUTTON_PIN) == LOW) {
    unsigned long t = millis();
    while (digitalRead(BUTTON_PIN) == LOW) {
      if (millis() - t > WIFI_RESET_HOLD_MS) {
        LittleFS.remove("/wifi.json");
        LittleFS.remove("/config.json");
        beep(3, 150);
        Serial.println("[RESET] WiFi ve token silindi.");
        break;
      }
      delay(20);
    }
  }

  Wire.begin(D5, D6);
  if (rtc.begin()) {
    rtcAvailable = true;
    if (!rtc.isrunning()) rtc.adjust(DateTime(F(__DATE__), F(__TIME__)));
    Serial.println("[RTC] Hazır.");
  } else {
    Serial.println("[RTC] Bulunamadı.");
  }

  // WiFi yapılandırması var mı?
  if (!loadWifiConfig()) {
    Serial.println("[WiFi] Yapılandırma yok → Setup AP başlatılıyor.");
    startSetupAP();  // <-- bu fonksiyon geri dönmez (sonsuz döngü)
  }

  connectWifi();
  setupOta();

  Serial.printf("[AUTO-REG] MAC: %s\n", WiFi.macAddress().c_str());
  if (!autoRegister()) {
    Serial.println("[AUTO-REG] Başarısız! Yeniden başlatılıyor.");
    setLedState(LED_ERROR);
    beep(3, 200);
    delay(5000);
    ESP.restart();
  }

  connectWebSocket();
  setLedState(LED_IDLE);
  beep(1, 100);
}

void loop() {
  ArduinoOTA.handle();
  wsClient.loop();

  if (wsConnected && millis() - lastPingMs > PING_INTERVAL_MS) {
    JsonDocument doc;
    doc["type"] = "ping";
    doc["ts"]   = millis();
    sendJson(doc);
    lastPingMs = millis();
  }

  if (rtcAvailable && millis() - lastRtcCheckMs > RTC_CHECK_INTERVAL_MS) {
    checkSchedule();
    lastRtcCheckMs = millis();
  }

  updateLed();
  handleButton();
}

// ─── WiFi yapılandırma yükleme / kaydetme ────────────────────────────────────
bool loadWifiConfig() {
  if (!LittleFS.exists("/wifi.json")) return false;
  File f = LittleFS.open("/wifi.json", "r");
  if (!f) return false;
  JsonDocument doc;
  bool ok = !deserializeJson(doc, f);
  f.close();
  if (!ok || !doc["ssid"].is<const char*>()) return false;
  String ssid = doc["ssid"].as<String>();
  if (ssid.length() == 0) return false;

  // WiFi credential tamam, ama host/port config.json'dan gelir
  // Burası sadece ssid/password kontrolü
  return true;
}

void saveWifiConfig(const String &ssid, const String &password) {
  JsonDocument doc;
  doc["ssid"]     = ssid;
  doc["password"] = password;
  File f = LittleFS.open("/wifi.json", "w");
  if (f) { serializeJson(doc, f); f.close(); }
}

// ─── WiFi'ye bağlan ───────────────────────────────────────────────────────────
void connectWifi() {
  File f = LittleFS.open("/wifi.json", "r");
  if (!f) { ESP.restart(); return; }
  JsonDocument doc;
  deserializeJson(doc, f);
  f.close();

  String ssid     = doc["ssid"].as<String>();
  String password = doc["password"].as<String>();

  Serial.printf("[WiFi] Bağlanılıyor: %s\n", ssid.c_str());
  setLedState(LED_CONNECTING);
  WiFi.mode(WIFI_STA);
  WiFi.begin(ssid.c_str(), password.c_str());

  unsigned long start = millis();
  while (WiFi.status() != WL_CONNECTED) {
    if (millis() - start > 20000) {
      Serial.println("[WiFi] Bağlanamadı → Setup AP başlatılıyor.");
      LittleFS.remove("/wifi.json");
      beep(5, 100);
      ESP.restart();
      return;
    }
    delay(200);
    updateLed();
  }
  Serial.printf("[WiFi] Bağlandı: %s\n", WiFi.localIP().toString().c_str());
}

// ─── Setup AP (uygulama içi kurulum) ─────────────────────────────────────────
void startSetupAP() {
  inSetupMode = true;
  String mac  = WiFi.macAddress();
  mac.replace(":", "");
  String apName = "PetFeeder-" + mac.substring(8); // son 4 karakter

  WiFi.mode(WIFI_AP);
  WiFi.softAP(apName, SETUP_AP_PASSWORD);
  Serial.printf("[SETUP] AP: %s  IP: %s\n",
    apName.c_str(), WiFi.softAPIP().toString().c_str());

  setLedState(LED_SETUP);

  // GET /info → cihaz bilgisi döner
  setupServer.on("/info", HTTP_GET, []() {
    setupServer.sendHeader("Access-Control-Allow-Origin", "*");
    JsonDocument doc;
    doc["mac"]   = WiFi.macAddress();
    doc["model"] = "PetFeeder";
    doc["ap"]    = WiFi.softAPSSID();
    String resp; serializeJson(doc, resp);
    setupServer.send(200, "application/json", resp);
  });

  // POST /configure → WiFi + backend bilgisi alır, kaydeder, yeniden başlar
  setupServer.on("/configure", HTTP_POST, []() {
    setupServer.sendHeader("Access-Control-Allow-Origin", "*");
    JsonDocument doc;
    if (deserializeJson(doc, setupServer.arg("plain"))) {
      setupServer.send(400, "application/json", "{\"error\":\"json parse hatasi\"}");
      return;
    }
    String ssid     = doc["ssid"]     | "";
    String password = doc["password"] | "";
    String host     = doc["host"]     | BACKEND_HOST_DEFAULT;
    int    port     = doc["port"]     | BACKEND_PORT_DEFAULT;
    String name     = doc["name"]     | "";

    if (ssid.length() == 0) {
      setupServer.send(400, "application/json", "{\"error\":\"ssid gerekli\"}");
      return;
    }

    saveWifiConfig(ssid, password);
    // Host + port config.json'a kaydet
    {
      JsonDocument cfg;
      cfg["host"]  = host;
      cfg["port"]  = port;
      cfg["token"] = "";
      if (name.length() > 0) cfg["name"] = name;
      File f = LittleFS.open("/config.json", "w");
      if (f) { serializeJson(cfg, f); f.close(); }
    }

    setupServer.send(200, "application/json", "{\"ok\":true}");
    beep(2, 100);
    delay(800);
    ESP.restart();
  });

  // POST /reset → her şeyi siler, yeniden başlar
  setupServer.on("/reset", HTTP_POST, []() {
    setupServer.sendHeader("Access-Control-Allow-Origin", "*");
    LittleFS.remove("/wifi.json");
    LittleFS.remove("/config.json");
    LittleFS.remove("/schedule.json");
    setupServer.send(200, "application/json", "{\"ok\":true}");
    delay(500);
    ESP.restart();
  });

  // OPTIONS (CORS preflight)
  setupServer.onNotFound([]() {
    setupServer.sendHeader("Access-Control-Allow-Origin", "*");
    setupServer.sendHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
    setupServer.sendHeader("Access-Control-Allow-Headers", "Content-Type");
    if (setupServer.method() == HTTP_OPTIONS) {
      setupServer.send(204);
    } else {
      setupServer.send(404, "text/plain", "Not found");
    }
  });

  setupServer.begin();
  Serial.println("[SETUP] HTTP sunucu hazır.");
  beep(2, 150);

  // Setup döngüsü — hiç çıkmaz
  while (true) {
    setupServer.handleClient();
    updateLed();
    handleButton();  // Butona basılırsa sıfırlanabilsin
    delay(5);
  }
}

// ─── MAC tabanlı otomatik kayıt ──────────────────────────────────────────────
bool autoRegister() {
  String url = "http://" + backendHost + ":" + String(backendPort) + "/api/auto-register";
  String mac = WiFi.macAddress();

  // config.json'da önceden belirlenen isim varsa onu gönder
  String deviceName = "PetFeeder";
  if (LittleFS.exists("/config.json")) {
    File f = LittleFS.open("/config.json", "r");
    JsonDocument tmp;
    if (!deserializeJson(tmp, f)) {
      if (tmp["name"].is<const char*>()) deviceName = tmp["name"].as<String>();
    }
    f.close();
  }

  String body = "{\"mac\":\"" + mac + "\",\"name\":\"" + deviceName + "\"}";
  Serial.printf("[AUTO-REG] POST %s\n", url.c_str());

  WiFiClient client;
  HTTPClient http;
  http.begin(client, url);
  http.addHeader("Content-Type", "application/json");
  http.setTimeout(8000);

  int code = http.POST(body);
  if (code != 200 && code != 201) {
    Serial.printf("[AUTO-REG] HTTP hatası: %d\n", code);
    http.end();
    return false;
  }

  String resp = http.getString();
  http.end();

  JsonDocument doc;
  if (deserializeJson(doc, resp) || !doc["token"].is<const char*>()) {
    Serial.println("[AUTO-REG] JSON parse hatası");
    return false;
  }

  String newToken = doc["token"].as<String>();
  if (newToken != deviceToken) {
    deviceToken = newToken;
    saveRuntimeConfig();
    Serial.println("[AUTO-REG] Yeni token kaydedildi.");
  }
  Serial.printf("[AUTO-REG] Cihaz: %s\n", doc["name"] | "?");
  return true;
}

void connectWebSocket() {
  String path = "/ws/device?token=" + deviceToken;
  wsClient.begin(backendHost.c_str(), backendPort, path.c_str());
  wsClient.onEvent(wsEvent);
  wsClient.setReconnectInterval(5000);
  wsClient.enableHeartbeat(15000, 3000, 2);
}

// ─── OTA ──────────────────────────────────────────────────────────────────────
void setupOta() {
  ArduinoOTA.setHostname("petfeeder");
  ArduinoOTA.setPassword(OTA_PASSWORD);
  ArduinoOTA.onStart([]() { motorOff(); setLedState(LED_ERROR); });
  ArduinoOTA.begin();
}

// ─── Kalıcı yapılandırma ──────────────────────────────────────────────────────
void loadRuntimeConfig() {
  backendHost  = BACKEND_HOST_DEFAULT;
  backendPort  = BACKEND_PORT_DEFAULT;
  deviceToken  = "";

  if (!LittleFS.exists("/config.json")) return;
  File f = LittleFS.open("/config.json", "r");
  if (!f) return;
  JsonDocument doc;
  if (!deserializeJson(doc, f)) {
    if (doc["host"].is<const char*>())  backendHost = doc["host"].as<String>();
    if (doc["port"].is<int>())          backendPort = doc["port"].as<int>();
    if (doc["token"].is<const char*>()) deviceToken = doc["token"].as<String>();
  }
  f.close();
}

void saveRuntimeConfig() {
  JsonDocument doc;
  doc["host"]  = backendHost;
  doc["port"]  = backendPort;
  doc["token"] = deviceToken;
  File f = LittleFS.open("/config.json", "w");
  if (f) { serializeJson(doc, f); f.close(); }
}

// ─── Schedule ─────────────────────────────────────────────────────────────────
void loadSchedule() {
  if (!LittleFS.exists("/schedule.json")) return;
  File f = LittleFS.open("/schedule.json", "r");
  if (!f) return;
  JsonDocument doc;
  if (!deserializeJson(doc, f)) {
    JsonArray arr = doc["slots"].as<JsonArray>();
    for (int i = 0; i < MAX_SLOTS && i < (int)arr.size(); i++) {
      slots[i].enabled  = arr[i]["enabled"] | false;
      slots[i].hour     = constrain((int)(arr[i]["hour"]    | (i==0?8:i==1?12:i==2?18:22)), 0, 23);
      slots[i].minute   = constrain((int)(arr[i]["minute"]  | 0), 0, 59);
      slots[i].portions = constrain((int)(arr[i]["portions"]| 1), 1, 10);
      slots[i].firedToday = false;
    }
  }
  f.close();
}

void saveSchedule() {
  JsonDocument doc;
  JsonArray arr = doc["slots"].to<JsonArray>();
  for (int i = 0; i < MAX_SLOTS; i++) {
    JsonObject s = arr.add<JsonObject>();
    s["enabled"]  = slots[i].enabled;
    s["hour"]     = slots[i].hour;
    s["minute"]   = slots[i].minute;
    s["portions"] = slots[i].portions;
  }
  File f = LittleFS.open("/schedule.json", "w");
  if (f) { serializeJson(doc, f); f.close(); }
}

// ─── WebSocket ────────────────────────────────────────────────────────────────
void wsEvent(WStype_t type, uint8_t *payload, size_t length) {
  switch (type) {
    case WStype_DISCONNECTED:
      wsConnected = false;
      setLedState(LED_CONNECTING);
      Serial.println("[WS] Bağlantı kesildi.");
      break;
    case WStype_CONNECTED:
      wsConnected = true;
      setLedState(LED_IDLE);
      {
        JsonDocument doc;
        doc["type"]   = "device:ready";
        doc["uptime"] = millis() / 1000;
        sendJson(doc);
      }
      break;
    case WStype_TEXT:
      handleWsMessage((char *)payload);
      break;
    default: break;
  }
}

void handleWsMessage(const char *json) {
  JsonDocument doc;
  if (deserializeJson(doc, json)) return;

  const char *cmd       = doc["cmd"]       | "";
  const char *feedingId = doc["feedingId"] | "";

  if (strcmp(cmd, "feed") == 0) {
    int portions = constrain((int)(doc["portions"] | 1), 1, 10);
    JsonDocument resp;
    resp["feedingId"] = feedingId;
    setLedState(LED_FEEDING);
    runMotor(portions);
    setLedState(LED_IDLE);
    beep(1, 100);
    resp["status"]  = "done";
    resp["message"] = String(portions) + " porsiyon verildi.";
    sendJson(resp);
  }

  else if (strcmp(cmd, "schedule:update") == 0) {
    if (doc["slots"].is<JsonArray>()) {
      JsonArray arr = doc["slots"].as<JsonArray>();
      for (int i = 0; i < MAX_SLOTS && i < (int)arr.size(); i++) {
        slots[i].enabled  = arr[i]["enabled"] | false;
        slots[i].hour     = constrain((int)(arr[i]["hour"]    | slots[i].hour), 0, 23);
        slots[i].minute   = constrain((int)(arr[i]["minute"]  | slots[i].minute), 0, 59);
        slots[i].portions = constrain((int)(arr[i]["portions"]| slots[i].portions), 1, 10);
        slots[i].firedToday = false;
      }
    }
    saveSchedule();
    JsonDocument resp;
    resp["status"] = "schedule:updated";
    sendJson(resp);
  }

  else if (strcmp(cmd, "ping") == 0) {
    JsonDocument resp;
    resp["type"]   = "pong";
    resp["uptime"] = millis() / 1000;
    sendJson(resp);
  }
}

// ─── Motor ────────────────────────────────────────────────────────────────────
void stepMotor(int steps) {
  for (int i = 0; i < steps; i++) {
    digitalWrite(IN1, stepSeq[stepIndex][0]);
    digitalWrite(IN2, stepSeq[stepIndex][1]);
    digitalWrite(IN3, stepSeq[stepIndex][2]);
    digitalWrite(IN4, stepSeq[stepIndex][3]);
    stepIndex = (stepIndex + 1) % 8;
    delayMicroseconds(STEP_DELAY_US);
    yield();
  }
}

void motorOff() {
  digitalWrite(IN1, LOW); digitalWrite(IN2, LOW);
  digitalWrite(IN3, LOW); digitalWrite(IN4, LOW);
}

void runMotor(int portions) {
  stepMotor(portions * STEPS_PER_PORTION);
  motorOff();
}

void sendJson(JsonDocument &doc) {
  char buf[512];
  serializeJson(doc, buf);
  wsClient.sendTXT(buf);
}

// ─── Çoklu slot zamanlama kontrolü ───────────────────────────────────────────
void checkSchedule() {
  DateTime now = rtc.now();
  if (now.hour() == 0 && now.minute() == 0) {
    for (int i = 0; i < MAX_SLOTS; i++) slots[i].firedToday = false;
  }

  for (int i = 0; i < MAX_SLOTS; i++) {
    if (!slots[i].enabled || slots[i].firedToday) continue;
    if (now.hour() != slots[i].hour || now.minute() != slots[i].minute) continue;

    slots[i].firedToday = true;
    Serial.printf("[SCHEDULE] Slot %d (%02d:%02d, %d porsiyon)\n",
      i, slots[i].hour, slots[i].minute, slots[i].portions);
    setLedState(LED_FEEDING);
    runMotor(slots[i].portions);
    setLedState(LED_IDLE);
    beep(1, 100);

    if (wsConnected) {
      JsonDocument doc;
      doc["status"]    = "done";
      doc["feedingId"] = "schedule-auto-" + String(i);
      doc["message"]   = "Zamanlı besleme: " + String(slots[i].portions) + " porsiyon.";
      sendJson(doc);
    }
  }
}

// ─── LED ──────────────────────────────────────────────────────────────────────
void setLedState(LedState s) { ledState = s; }

void updateLed() {
  if (ledState == LED_FEEDING) { digitalWrite(LED_PIN, HIGH); return; }
  // SETUP: çok hızlı yanıp sönme (uygulama bağlanmayı bekliyor)
  // CONNECTING: hızlı yanıp sönme
  // IDLE: yavaş yanıp sönme
  // ERROR: çok hızlı
  unsigned long interval =
    (ledState == LED_IDLE)       ? 2500 :
    (ledState == LED_SETUP)      ?   80 :
    (ledState == LED_CONNECTING) ?  150 : 80;

  if (millis() - lastLedToggleMs >= interval) {
    ledOn = !ledOn;
    digitalWrite(LED_PIN, ledOn ? HIGH : LOW);
    lastLedToggleMs = millis();
  }
}

// ─── Buzzer ───────────────────────────────────────────────────────────────────
void beep(int count, int durationMs) {
  for (int i = 0; i < count; i++) {
    digitalWrite(BUZZER_PIN, HIGH);
    delay(durationMs);
    digitalWrite(BUZZER_PIN, LOW);
    if (i < count - 1) delay(durationMs);
  }
}

// ─── Buton ────────────────────────────────────────────────────────────────────
void handleButton() {
  int state = digitalRead(BUTTON_PIN);
  unsigned long now = millis();

  // Uzun basış kontrolü (çalışma modu)
  if (state == LOW) {
    if (lastButtonState == HIGH) lastButtonMs = now;
    if (now - lastButtonMs > WIFI_RESET_HOLD_MS && !inSetupMode) {
      // Sıfırla
      LittleFS.remove("/wifi.json");
      LittleFS.remove("/config.json");
      beep(3, 150);
      delay(500);
      ESP.restart();
    }
  }

  // Kısa basış → manuel besleme
  if (state == LOW && lastButtonState == HIGH && now - lastButtonMs > BUTTON_DEBOUNCE_MS) {
    if (!inSetupMode) {
      setLedState(LED_FEEDING);
      runMotor(MANUAL_FEED_PORTIONS);
      setLedState(LED_IDLE);
      beep(2, 80);
      if (wsConnected) {
        JsonDocument doc;
        doc["status"]    = "done";
        doc["feedingId"] = "manual-button";
        doc["message"]   = "Manuel buton ile beslendi.";
        sendJson(doc);
      }
    }
  }
  lastButtonState = state;
}

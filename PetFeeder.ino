/*
 * PetFeeder.ino
 * ESP8266 (NodeMCU) — Smart Pet Feeder Firmware
 *
 * Hardware:
 *   - NodeMCU ESP8266
 *   - 28BYJ-48 Stepper + ULN2003 driver (IN1=D1, IN2=D2, IN3=D3, IN4=D4)
 *   - DS1307 RTC (SDA=D5, SCL=D6)
 *   - Manuel besleme butonu (D7, GND'e bağlı, INPUT_PULLUP)
 *   - Durum LED'i (D8, aktif HIGH)
 *   - Buzzer (D0, aktif HIGH)
 *   (Buton/LED/buzzer pinleri kendi kablajına göre config.h üzerinden değiştirilebilir)
 *
 * Libraries (Arduino Library Manager):
 *   - ArduinoJson       7.x
 *   - WebSockets        2.x  (Links2004/arduinoWebSockets)
 *   - RTClib            2.x
 *   - WiFiManager       2.x  (tzapu/WiFiManager)
 *   - ArduinoOTA / LittleFS: ESP8266 core ile birlikte gelir
 *
 * Config: arduino/PetFeeder/config.h dosyasını oluştur (örnek: config.h.example)
 *
 * İlk kurulum: Cihaz açıldığında kayıtlı bir WiFi ağı yoksa "PetFeeder-Setup"
 * adında bir erişim noktası açar. Telefon/laptop ile bu ağa bağlanıp açılan
 * sayfadan WiFi + backend adresi + cihaz token bilgilerini girebilirsin.
 * WiFi ayarlarını sıfırlamak için: açılışta butonu 3 saniye basılı tut.
 */

#include <ESP8266WiFi.h>
#include <WebSocketsClient.h>
#include <ArduinoJson.h>
#include <Wire.h>
#include <RTClib.h>
#include <LittleFS.h>
#include <WiFiManager.h>
#include <ArduinoOTA.h>
#include "config.h"

// ─── Stepper Motor ────────────────────────────────────────────────────────────
#define IN1 D1
#define IN2 D2
#define IN3 D3
#define IN4 D4

// 28BYJ-48: 2048 adım/tam devir, 4 bölüm → 512 adım/90°
// Kalibrasyon: 509 adım = 90° (ölü boşluk hesaba katılmış)
#define STEPS_PER_PORTION 509
#define STEP_DELAY_US     1200   // adım arası gecikme (µs)

// 4-adım yarım-adım sekansı (ULN2003)
const int stepSeq[8][4] = {
  {1,0,0,0},
  {1,1,0,0},
  {0,1,0,0},
  {0,1,1,0},
  {0,0,1,0},
  {0,0,1,1},
  {0,0,0,1},
  {1,0,0,1}
};
int stepIndex = 0;

// ─── Kullanıcı arayüzü (buton / LED / buzzer) ─────────────────────────────────
#define BUTTON_PIN            D7
#define LED_PIN               D8
#define BUZZER_PIN            D0
#define MANUAL_FEED_PORTIONS  1
#define BUTTON_DEBOUNCE_MS    250
#define WIFI_RESET_HOLD_MS    3000

enum LedState { LED_CONNECTING, LED_IDLE, LED_FEEDING, LED_ERROR };
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
// Dakika sınırını kaçırmamak için sık kontrol (RTC drift/gecikme toleransı)
#define RTC_CHECK_INTERVAL_MS 20000

// ─── Çalışma zamanı yapılandırması (WiFiManager portalinden değiştirilebilir) ─
WiFiManager wm;
bool shouldSaveConfig = false;
String backendHost;
uint16_t backendPort;
String deviceToken;

// Zamanlı besleme (backend senkronize eder, burada LittleFS'e de kalıcı yazılır)
struct Schedule {
  bool   enabled;
  uint8_t hour;
  uint8_t minute;
  uint8_t portions;
  bool    firedToday;
};
Schedule morningSchedule = {false, 8, 0, 1, false};
Schedule eveningSchedule = {false, 18, 0, 1, false};

// ─── Fonksiyon prototipleri ───────────────────────────────────────────────────
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
void setupWifiManager();
void saveConfigCallback();
void setupOta();
void setLedState(LedState s);
void updateLed();
void beep(int count, int durationMs);
void handleButton();

// ─────────────────────────────────────────────────────────────────────────────
void setup() {
  Serial.begin(115200);
  delay(100);
  Serial.println("\n[PetFeeder] Başlatılıyor...");

  // Motor pinleri
  pinMode(IN1, OUTPUT);
  pinMode(IN2, OUTPUT);
  pinMode(IN3, OUTPUT);
  pinMode(IN4, OUTPUT);
  motorOff();

  // Buton / LED / buzzer pinleri
  pinMode(BUTTON_PIN, INPUT_PULLUP);
  pinMode(LED_PIN, OUTPUT);
  pinMode(BUZZER_PIN, OUTPUT);
  digitalWrite(LED_PIN, LOW);
  digitalWrite(BUZZER_PIN, LOW);

  // Dosya sistemi + kayıtlı ayarlar
  if (!LittleFS.begin()) {
    Serial.println("[FS] LittleFS başlatılamadı, biçimlendiriliyor...");
    LittleFS.format();
    LittleFS.begin();
  }
  loadRuntimeConfig();
  loadSchedule();

  // Açılışta buton basılıysa: 3 sn sonra WiFi ayarlarını sıfırla
  if (digitalRead(BUTTON_PIN) == LOW) {
    Serial.println("[BUTTON] Açılışta basılı, 3 sn içinde bırakılmazsa WiFi ayarları sıfırlanacak...");
    unsigned long pressStart = millis();
    while (digitalRead(BUTTON_PIN) == LOW) {
      if (millis() - pressStart > WIFI_RESET_HOLD_MS) {
        Serial.println("[WiFi] Ayarlar sıfırlanıyor, kurulum portalı açılacak.");
        wm.resetSettings();
        beep(3, 150);
        break;
      }
      delay(20);
    }
  }

  // RTC başlat
  Wire.begin(D5, D6);  // SDA=D5, SCL=D6 — D1,D2 motora serbest kalır
  if (rtc.begin()) {
    rtcAvailable = true;
    if (!rtc.isrunning()) {
      Serial.println("[RTC] Çalışmıyor, derleme zamanı set ediliyor.");
      rtc.adjust(DateTime(F(__DATE__), F(__TIME__)));
    }
    Serial.println("[RTC] Hazır.");
  } else {
    Serial.println("[RTC] Bulunamadı, zamanlı besleme devre dışı.");
  }

  // WiFi kurulumu (kayıtlı ağ yoksa "PetFeeder-Setup" portalı açılır)
  setLedState(LED_CONNECTING);
  setupWifiManager();

  // OTA güncelleme
  setupOta();

  // WebSocket bağlantısı: ws://backendHost:backendPort/ws/device?token=deviceToken
  String path = "/ws/device?token=" + deviceToken;
  wsClient.begin(backendHost.c_str(), backendPort, path.c_str());
  wsClient.onEvent(wsEvent);
  wsClient.setReconnectInterval(5000);
  wsClient.enableHeartbeat(15000, 3000, 2);

  setLedState(LED_IDLE);
  beep(1, 100);
  Serial.println("[WS] Bağlantı kuruluyor...");
}

void loop() {
  ArduinoOTA.handle();
  wsClient.loop();

  // Ping (heartbeat yedek)
  if (wsConnected && millis() - lastPingMs > PING_INTERVAL_MS) {
    JsonDocument pingDoc;
    pingDoc["type"] = "ping";
    pingDoc["ts"]   = millis();
    sendJson(pingDoc);
    lastPingMs = millis();
  }

  // Zamanlı besleme kontrolü
  if (rtcAvailable && millis() - lastRtcCheckMs > RTC_CHECK_INTERVAL_MS) {
    checkSchedule();
    lastRtcCheckMs = millis();
  }

  updateLed();
  handleButton();
}

// ─── WiFi kurulumu (WiFiManager) ──────────────────────────────────────────────
void saveConfigCallback() {
  shouldSaveConfig = true;
}

void setupWifiManager() {
  WiFiManagerParameter custom_host("host", "Backend Host/IP", backendHost.c_str(), 40);
  WiFiManagerParameter custom_port("port", "Backend Port", String(backendPort).c_str(), 6);
  WiFiManagerParameter custom_token("token", "Cihaz Token", deviceToken.c_str(), 40);

  wm.addParameter(&custom_host);
  wm.addParameter(&custom_port);
  wm.addParameter(&custom_token);
  wm.setSaveConfigCallback(saveConfigCallback);
  wm.setConfigPortalTimeout(180);

  Serial.println("[WiFi] Kayıtlı ağa bağlanılıyor (yoksa 'PetFeeder-Setup' portalı açılacak)...");
  if (!wm.autoConnect("PetFeeder-Setup", SETUP_AP_PASSWORD)) {
    Serial.println("[WiFi] Kurulum zaman aşımına uğradı, yeniden başlatılıyor.");
    delay(1000);
    ESP.restart();
  }

  Serial.printf("[WiFi] Bağlandı! IP: %s\n", WiFi.localIP().toString().c_str());

  if (shouldSaveConfig) {
    backendHost = custom_host.getValue();
    backendPort = String(custom_port.getValue()).toInt();
    deviceToken = custom_token.getValue();
    saveRuntimeConfig();
    Serial.println("[CONFIG] Yeni backend ayarları kaydedildi.");
  }
}

// ─── OTA güncelleme ───────────────────────────────────────────────────────────
void setupOta() {
  ArduinoOTA.setHostname("petfeeder");
  ArduinoOTA.setPassword(OTA_PASSWORD);

  ArduinoOTA.onStart([]() {
    Serial.println("[OTA] Güncelleme başlıyor...");
    motorOff();
    setLedState(LED_ERROR); // hızlı yanıp sönme = güncelleme sürüyor
  });
  ArduinoOTA.onEnd([]() {
    Serial.println("[OTA] Güncelleme tamamlandı, yeniden başlatılıyor.");
  });
  ArduinoOTA.onError([](ota_error_t error) {
    Serial.printf("[OTA] Hata [%u]\n", error);
  });

  ArduinoOTA.begin();
  Serial.println("[OTA] Hazır.");
}

// ─── Kalıcı yapılandırma (LittleFS) ───────────────────────────────────────────
void loadRuntimeConfig() {
  backendHost = BACKEND_HOST_DEFAULT;
  backendPort = String(BACKEND_PORT_DEFAULT).toInt();
  deviceToken = DEVICE_TOKEN_DEFAULT;

  if (!LittleFS.exists("/config.json")) return;
  File f = LittleFS.open("/config.json", "r");
  if (!f) return;

  JsonDocument doc;
  if (!deserializeJson(doc, f)) {
    backendHost = (const char *)(doc["host"] | backendHost.c_str());
    backendPort = doc["port"] | backendPort;
    deviceToken = (const char *)(doc["token"] | deviceToken.c_str());
    Serial.println("[CONFIG] Kayıtlı backend ayarları yüklendi.");
  }
  f.close();
}

void saveRuntimeConfig() {
  JsonDocument doc;
  doc["host"]  = backendHost;
  doc["port"]  = backendPort;
  doc["token"] = deviceToken;

  File f = LittleFS.open("/config.json", "w");
  if (f) {
    serializeJson(doc, f);
    f.close();
  }
}

// ─── Kalıcı zamanlama (LittleFS) ──────────────────────────────────────────────
void loadSchedule() {
  if (!LittleFS.exists("/schedule.json")) return;
  File f = LittleFS.open("/schedule.json", "r");
  if (!f) return;

  JsonDocument doc;
  if (!deserializeJson(doc, f)) {
    morningSchedule.enabled  = doc["morning"]["enabled"]  | false;
    morningSchedule.hour     = doc["morning"]["hour"]     | 8;
    morningSchedule.minute   = doc["morning"]["minute"]   | 0;
    morningSchedule.portions = doc["morning"]["portions"] | 1;

    eveningSchedule.enabled  = doc["evening"]["enabled"]  | false;
    eveningSchedule.hour     = doc["evening"]["hour"]     | 18;
    eveningSchedule.minute   = doc["evening"]["minute"]   | 0;
    eveningSchedule.portions = doc["evening"]["portions"] | 1;

    Serial.println("[SCHEDULE] Kayıtlı zamanlama yüklendi.");
  }
  f.close();
}

void saveSchedule() {
  JsonDocument doc;
  doc["morning"]["enabled"]  = morningSchedule.enabled;
  doc["morning"]["hour"]     = morningSchedule.hour;
  doc["morning"]["minute"]   = morningSchedule.minute;
  doc["morning"]["portions"] = morningSchedule.portions;
  doc["evening"]["enabled"]  = eveningSchedule.enabled;
  doc["evening"]["hour"]     = eveningSchedule.hour;
  doc["evening"]["minute"]   = eveningSchedule.minute;
  doc["evening"]["portions"] = eveningSchedule.portions;

  File f = LittleFS.open("/schedule.json", "w");
  if (f) {
    serializeJson(doc, f);
    f.close();
  }
}

// ─── WebSocket olay işleyici ──────────────────────────────────────────────────
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
      Serial.printf("[WS] Bağlandı: %s\n", (char *)payload);
      {
        // Bağlandığında cihaz durumunu bildir
        JsonDocument doc;
        doc["type"]   = "device:ready";
        doc["uptime"] = millis() / 1000;
        sendJson(doc);
      }
      break;

    case WStype_TEXT:
      handleWsMessage((char *)payload);
      break;

    case WStype_ERROR:
      Serial.println("[WS] Hata!");
      break;

    default:
      break;
  }
}

// ─── Gelen mesaj işleme ───────────────────────────────────────────────────────
void handleWsMessage(const char *json) {
  Serial.printf("[WS] Mesaj: %s\n", json);

  JsonDocument doc;
  DeserializationError err = deserializeJson(doc, json);
  if (err) {
    Serial.printf("[JSON] Hata: %s\n", err.c_str());
    return;
  }

  const char *cmd = doc["cmd"] | "";
  const char *feedingId = doc["feedingId"] | "";

  // ── Besleme komutu ──────────────────────────────────────────────────────────
  if (strcmp(cmd, "feed") == 0) {
    int portions = doc["portions"] | 1;
    portions = constrain(portions, 1, 10);

    Serial.printf("[FEED] %d porsiyon besleniyor (feedingId=%s)\n", portions, feedingId);

    JsonDocument resp;
    resp["feedingId"] = feedingId;

    // Motor çalıştır
    setLedState(LED_FEEDING);
    runMotor(portions);
    setLedState(LED_IDLE);
    beep(1, 100);

    resp["status"]  = "done";
    resp["message"] = String(portions) + " porsiyon verildi.";
    sendJson(resp);

    Serial.println("[FEED] Tamamlandı.");
  }

  // ── Zamanlama güncelleme komutu ─────────────────────────────────────────────
  else if (strcmp(cmd, "schedule:update") == 0) {
    if (doc["morning"]["enabled"].is<bool>()) {
      morningSchedule.enabled  = doc["morning"]["enabled"];
      morningSchedule.hour     = constrain((int)(doc["morning"]["hour"]   | 8), 0, 23);
      morningSchedule.minute   = constrain((int)(doc["morning"]["minute"] | 0), 0, 59);
      morningSchedule.portions = constrain((int)(doc["morning"]["portions"] | 1), 1, 10);
      morningSchedule.firedToday = false;
    }
    if (doc["evening"]["enabled"].is<bool>()) {
      eveningSchedule.enabled  = doc["evening"]["enabled"];
      eveningSchedule.hour     = constrain((int)(doc["evening"]["hour"]   | 18), 0, 23);
      eveningSchedule.minute   = constrain((int)(doc["evening"]["minute"] | 0), 0, 59);
      eveningSchedule.portions = constrain((int)(doc["evening"]["portions"] | 1), 1, 10);
      eveningSchedule.firedToday = false;
    }
    saveSchedule();

    JsonDocument resp;
    resp["status"] = "schedule:updated";
    sendJson(resp);
    Serial.println("[SCHEDULE] Güncellendi ve kaydedildi.");
  }

  // ── Ping ────────────────────────────────────────────────────────────────────
  else if (strcmp(cmd, "ping") == 0) {
    JsonDocument resp;
    resp["type"]   = "pong";
    resp["uptime"] = millis() / 1000;
    sendJson(resp);
  }
}

// ─── Motor kontrol ───────────────────────────────────────────────────────────
void stepMotor(int steps) {
  for (int i = 0; i < steps; i++) {
    digitalWrite(IN1, stepSeq[stepIndex][0]);
    digitalWrite(IN2, stepSeq[stepIndex][1]);
    digitalWrite(IN3, stepSeq[stepIndex][2]);
    digitalWrite(IN4, stepSeq[stepIndex][3]);
    stepIndex = (stepIndex + 1) % 8;
    delayMicroseconds(STEP_DELAY_US);
    yield(); // WDT sıfırla
  }
}

void motorOff() {
  digitalWrite(IN1, LOW);
  digitalWrite(IN2, LOW);
  digitalWrite(IN3, LOW);
  digitalWrite(IN4, LOW);
}

void runMotor(int portions) {
  int totalSteps = portions * STEPS_PER_PORTION;
  Serial.printf("[MOTOR] %d adım çalışıyor (%d porsiyon)\n", totalSteps, portions);
  stepMotor(totalSteps);
  motorOff();
}

// ─── JSON gönder ──────────────────────────────────────────────────────────────
void sendJson(JsonDocument &doc) {
  char buf[512];
  serializeJson(doc, buf);
  wsClient.sendTXT(buf);
  Serial.printf("[WS] Gönderildi: %s\n", buf);
}

// ─── Zamanlı besleme kontrolü ─────────────────────────────────────────────────
void checkSchedule() {
  DateTime now = rtc.now();

  // Gece yarısı firedToday sıfırla
  if (now.hour() == 0 && now.minute() == 0) {
    morningSchedule.firedToday = false;
    eveningSchedule.firedToday = false;
  }

  // Sabah kontrolü
  if (morningSchedule.enabled && !morningSchedule.firedToday &&
      now.hour() == morningSchedule.hour &&
      now.minute() == morningSchedule.minute) {
    morningSchedule.firedToday = true;
    Serial.println("[SCHEDULE] Sabah beslemesi başlıyor...");
    setLedState(LED_FEEDING);
    runMotor(morningSchedule.portions);
    setLedState(LED_IDLE);
    beep(1, 100);

    if (wsConnected) {
      JsonDocument doc;
      doc["status"]     = "done";
      doc["feedingId"]  = "morning-auto";
      doc["message"]    = "Sabah zamanlı besleme tamamlandı.";
      sendJson(doc);
    }
  }

  // Akşam kontrolü
  if (eveningSchedule.enabled && !eveningSchedule.firedToday &&
      now.hour() == eveningSchedule.hour &&
      now.minute() == eveningSchedule.minute) {
    eveningSchedule.firedToday = true;
    Serial.println("[SCHEDULE] Akşam beslemesi başlıyor...");
    setLedState(LED_FEEDING);
    runMotor(eveningSchedule.portions);
    setLedState(LED_IDLE);
    beep(1, 100);

    if (wsConnected) {
      JsonDocument doc;
      doc["status"]     = "done";
      doc["feedingId"]  = "evening-auto";
      doc["message"]    = "Akşam zamanlı besleme tamamlandı.";
      sendJson(doc);
    }
  }
}

// ─── Durum LED'i (yanıp sönme durumları, non-blocking) ────────────────────────
void setLedState(LedState s) {
  ledState = s;
}

void updateLed() {
  if (ledState == LED_FEEDING) {
    digitalWrite(LED_PIN, HIGH);
    return;
  }

  unsigned long interval = (ledState == LED_IDLE) ? 2500 : 150; // yavaş nefes / hızlı uyarı
  if (millis() - lastLedToggleMs >= interval) {
    ledOn = !ledOn;
    digitalWrite(LED_PIN, ledOn ? HIGH : LOW);
    lastLedToggleMs = millis();
  }
}

// ─── Buzzer ────────────────────────────────────────────────────────────────────
void beep(int count, int durationMs) {
  for (int i = 0; i < count; i++) {
    digitalWrite(BUZZER_PIN, HIGH);
    delay(durationMs);
    digitalWrite(BUZZER_PIN, LOW);
    if (i < count - 1) delay(durationMs);
  }
}

// ─── Manuel besleme butonu ─────────────────────────────────────────────────────
void handleButton() {
  int state = digitalRead(BUTTON_PIN);

  if (state == LOW && lastButtonState == HIGH && millis() - lastButtonMs > BUTTON_DEBOUNCE_MS) {
    lastButtonMs = millis();
    Serial.println("[BUTTON] Manuel besleme tetiklendi.");

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

  lastButtonState = state;
}

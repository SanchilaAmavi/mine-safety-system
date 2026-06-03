#include <Arduino.h>
#include <SPI.h>
#include <LoRa.h>
#include <WiFi.h>
#include <HTTPClient.h>
#include <Wire.h>
#include <U8g2lib.h>

// Surface Node pins
const int LORA_SS = 10;
const int LORA_MOSI = 11;
const int LORA_SCK = 12;
const int LORA_MISO = 13;
const int LORA_RST = 14;
const int LORA_DIO0 = 9;

const int GSM_RX = 47;
const int GSM_TX = 48;
const int GSM_RST = 19;
const int OLED_SDA = 5;
const int OLED_SCL = 6;
const int BUZZER_PIN = 8;

const char WIFI_SSID[] = "YOUR_WIFI_SSID";
const char WIFI_PASSWORD[] = "YOUR_WIFI_PASSWORD";
const char FIREBASE_DB_URL[] = "https://YOUR_PROJECT_ID-default-rtdb.firebaseio.com";
const char ALERT_PHONE_NUMBER[] = "+94716643413";

const unsigned long WIFI_TIMEOUT_MS = 20000UL;
const unsigned long GSM_RETRY_MS = 30000UL;
const unsigned long SMS_COOLDOWN_MS = 30000UL;
const unsigned long BUZZER_ON_MS = 300UL;
const unsigned long BUZZER_OFF_MS = 300UL;
const uint8_t LORA_SYNC_WORD = 0xA3;

HardwareSerial sim800(1);
U8G2_SH1106_128X64_NONAME_F_HW_I2C u8g2(U8G2_R0, /* reset=*/ U8X8_PIN_NONE);
WiFiClientSecure wifiClient;
HTTPClient http;

struct MineState {
  String nodeId;
  uint16_t mq4;
  uint16_t mq7;
  uint16_t water;
  int flags;
  int rssi;
  bool inAlert;
  unsigned long lastSmsMs;
  unsigned long lastUpdateMs;
};

MineState mines[2] = {
  {"M1", 0, 0, 0, 0, -120, false, 0, 0},
  {"M2", 0, 0, 0, 0, -120, false, 0, 0}
};

bool wifiConnected = false;
bool gsmReady = false;
bool buzzerState = false;
unsigned long nextBuzzerChangeMs = 0;

void setup() {
  Serial.begin(115200);
  while (!Serial) ;

  pinMode(GSM_RST, OUTPUT);
  digitalWrite(GSM_RST, HIGH);
  pinMode(BUZZER_PIN, OUTPUT);
  digitalWrite(BUZZER_PIN, LOW);

  Wire.setPins(OLED_SDA, OLED_SCL);
  Wire.begin(OLED_SDA, OLED_SCL);
  u8g2.begin();
  u8g2.setFont(u8g2_font_6x10_tf);

  drawSplashScreen();
  connectWiFi();
  initializeGSM();
  initializeLoRa();
  drawReadyScreen();
}

void loop() {
  handleLoRaPackets();
  handleBuzzer();
  if (!wifiConnected && millis() % 10000 < 50) {
    connectWiFi();
  }
  if (!gsmReady && millis() - mines[0].lastSmsMs > GSM_RETRY_MS) {
    initializeGSM();
  }
}

void initializeLoRa() {
  SPI.begin(LORA_SCK, LORA_MISO, LORA_MOSI, LORA_SS);
  LoRa.setPins(LORA_SS, LORA_RST, LORA_DIO0);
  if (!LoRa.begin(433E6)) {
    Serial.println("[ERROR] LoRa init failed");
    return;
  }
  LoRa.setSyncWord(LORA_SYNC_WORD);
  LoRa.enableCrc();
  Serial.println("[OK] LoRa initialized");
}

void connectWiFi() {
  Serial.println("[WIFI] Connecting...");
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  unsigned long start = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - start < WIFI_TIMEOUT_MS) {
    delay(200);
  }
  wifiConnected = (WiFi.status() == WL_CONNECTED);
  if (wifiConnected) {
    wifiClient.setInsecure();
  }
  Serial.printf("[WIFI] %s\n", wifiConnected ? "Connected" : "Failed");
  drawWiFiStatus(wifiConnected);
}

void initializeGSM() {
  Serial.println("[GSM] Resetting module...");
  digitalWrite(GSM_RST, LOW);
  delay(200);
  digitalWrite(GSM_RST, HIGH);
  delay(1500);

  sim800.begin(9600, SERIAL_8N1, GSM_RX, GSM_TX);
  delay(2000);

  if (sendAT("AT", "OK", 5000) && sendAT("AT+CPIN?", "READY", 8000) && sendAT("AT+CMGF=1", "OK", 5000)) {
    gsmReady = true;
    Serial.println("[GSM] Ready");
  } else {
    gsmReady = false;
    Serial.println("[GSM] Initialization failed");
  }
  drawGsmStatus(gsmReady);
}

bool sendAT(const String &command, const String &expected, unsigned long timeoutMs) {
  flushSerial(sim800);
  sim800.print(command);
  sim800.print("\r");
  unsigned long start = millis();
  String response;
  while (millis() - start < timeoutMs) {
    while (sim800.available()) {
      response += char(sim800.read());
    }
    if (response.indexOf(expected) >= 0) {
      Serial.printf("[GSM] %s => %s\n", command.c_str(), expected.c_str());
      return true;
    }
    delay(50);
  }
  Serial.printf("[GSM] %s failed, response: %s\n", command.c_str(), response.c_str());
  return false;
}

void flushSerial(Stream &serial) {
  while (serial.available()) {
    serial.read();
  }
}

void handleLoRaPackets() {
  int packetSize = LoRa.parsePacket();
  if (packetSize == 0) return;

  String packet;
  while (LoRa.available()) {
    packet += char(LoRa.read());
  }

  int rssi = LoRa.packetRssi();
  Serial.printf("[LORA] Received: %s | RSSI=%d\n", packet.c_str(), rssi);
  processPacket(packet, rssi);
}

void processPacket(const String &packet, int rssi) {
  int idx1 = packet.indexOf(',');
  if (idx1 < 0) return;

  String nodeId = packet.substring(0, idx1);
  int mineIndex = (nodeId == "M1") ? 0 : (nodeId == "M2") ? 1 : -1;
  if (mineIndex < 0) return;

  int idx2 = packet.indexOf(',', idx1 + 1);
  int idx3 = packet.indexOf(',', idx2 + 1);
  int idx4 = packet.indexOf(',', idx3 + 1);
  if (idx2 < 0 || idx3 < 0 || idx4 < 0) return;

  uint16_t mq4 = packet.substring(idx1 + 1, idx2).toInt();
  uint16_t mq7 = packet.substring(idx2 + 1, idx3).toInt();
  uint16_t water = packet.substring(idx3 + 1, idx4).toInt();
  int flags = packet.substring(idx4 + 1).toInt();

  MineState &mine = mines[mineIndex];
  mine.mq4 = mq4;
  mine.mq7 = mq7;
  mine.water = water;
  mine.flags = flags;
  mine.rssi = rssi;
  mine.inAlert = (flags != 0);
  mine.lastUpdateMs = millis();

  if (mine.inAlert) {
    drawAlertScreen(mineIndex);
    if (gsmReady && millis() - mine.lastSmsMs >= SMS_COOLDOWN_MS) {
      sendSmsAlert(mineIndex);
      mine.lastSmsMs = millis();
    }
    if (wifiConnected) {
      uploadStatusToFirebase(mineIndex);
      uploadAlertToFirebase(mineIndex);
    }
  } else {
    bool anyAlert = mines[0].inAlert || mines[1].inAlert;
    if (!anyAlert) {
      drawReadyScreen();
    }
    if (wifiConnected) {
      uploadStatusToFirebase(mineIndex);
    }
  }
}

void sendSmsAlert(int index) {
  const MineState &mine = mines[index];
  String body = "MINE SAFETY ALERT!\n";
  body += "Mine ";
  body += mine.nodeId.substring(1);
  body += ":\n";
  if (mine.flags & 0x04) body += "* WATER LEVEL HIGH! Reading: " + String(mine.water) + "\n";
  if (mine.flags & 0x01) body += "* METHANE (CH4) HIGH! Reading: " + String(mine.mq4) + "\n";
  if (mine.flags & 0x02) body += "* CO HIGH! Reading: " + String(mine.mq7) + "\n";
  body += "RSSI=" + String(mine.rssi) + " dBm\n";
  body += "Act immediately!";

  if (!sendAT("AT+CMGF=1", "OK", 5000)) return;
  if (!sendAT("AT+CMGS=\"" + String(ALERT_PHONE_NUMBER) + "\"", ">", 8000)) return;

  flushSerial(sim800);
  sim800.print(body);
  sim800.write(26); // CTRL+Z

  unsigned long start = millis();
  String response;
  while (millis() - start < 10000) {
    while (sim800.available()) {
      response += char(sim800.read());
    }
    if (response.indexOf("+CMGS") >= 0 || response.indexOf("OK") >= 0) {
      Serial.println("[SMS] Sent successfully");
      return;
    }
    if (response.indexOf("ERROR") >= 0) {
      Serial.printf("[SMS] Failed: %s\n", response.c_str());
      return;
    }
    delay(50);
  }
  Serial.println("[SMS] Timeout waiting for send confirmation");
}

void handleBuzzer() {
  bool activeAlert = mines[0].inAlert || mines[1].inAlert;
  if (!activeAlert) {
    buzzerState = false;
    digitalWrite(BUZZER_PIN, LOW);
    return;
  }

  if (millis() >= nextBuzzerChangeMs) {
    buzzerState = !buzzerState;
    digitalWrite(BUZZER_PIN, buzzerState ? HIGH : LOW);
    nextBuzzerChangeMs = millis() + (buzzerState ? BUZZER_ON_MS : BUZZER_OFF_MS);
  }
}

void drawSplashScreen() {
  u8g2.clearBuffer();
  u8g2.setFont(u8g2_font_ncenB14_tr);
  u8g2.drawStr(2, 18, "SubterraGuard");
  u8g2.setFont(u8g2_font_6x10_tf);
  u8g2.drawStr(2, 32, "Mine Safety Gateway");
  u8g2.drawStr(2, 48, "Initializing...");
  u8g2.sendBuffer();
}

void drawReadyScreen() {
  u8g2.clearBuffer();
  u8g2.setFont(u8g2_font_6x10_tf);
  u8g2.drawStr(0, 12, "SubterraGuard Ready");
  u8g2.drawStr(0, 26, wifiConnected ? "WiFi: Connected" : "WiFi: Offline");
  u8g2.drawStr(0, 40, gsmReady ? "GSM: Ready" : "GSM: Not ready");
  u8g2.drawStr(0, 54, "Listening for LoRa alerts...");
  u8g2.sendBuffer();
}

void drawWiFiStatus(bool connected) {
  drawReadyScreen();
}

void drawGsmStatus(bool ready) {
  drawReadyScreen();
}

void drawAlertScreen(int index) {
  const MineState &mine = mines[index];
  u8g2.clearBuffer();
  u8g2.setFont(u8g2_font_6x10_tf);
  u8g2.drawStr(0, 10, "! HAZARD ALERT !");
  u8g2.drawStr(0, 24, ("Mine: " + mine.nodeId).c_str());

  char buffer[32];
  if (mine.flags & 0x01) {
    sprintf(buffer, "CH4 HIGH: %u", mine.mq4);
    u8g2.drawStr(0, 38, buffer);
  }
  if (mine.flags & 0x02) {
    sprintf(buffer, "CO HIGH: %u", mine.mq7);
    u8g2.drawStr(0, 50, buffer);
  }
  if (mine.flags & 0x04) {
    sprintf(buffer, "WATER HIGH: %u", mine.water);
    u8g2.drawStr(0, 62, buffer);
  }
  u8g2.sendBuffer();
}

String buildJsonPayload(int index) {
  MineState &mine = mines[index];
  String payload = "{";
  payload += "\"nodeId\":\"" + mine.nodeId + "\",";
  payload += "\"mq4\":" + String(mine.mq4) + ",";
  payload += "\"mq7\":" + String(mine.mq7) + ",";
  payload += "\"water\":" + String(mine.water) + ",";
  payload += "\"flags\":" + String(mine.flags) + ",";
  payload += "\"rssi\":" + String(mine.rssi) + ",";
  payload += "\"inAlert\":" + String(mine.inAlert ? "true" : "false") + ",";
  payload += "\"updatedAt\":" + String(millis());
  payload += "}";
  return payload;
}

bool uploadStatusToFirebase(int index) {
  if (!wifiConnected) return false;
  String node = mines[index].nodeId.toLowerCase();
  String url = String(FIREBASE_DB_URL) + "/status/" + node + ".json";
  String payload = buildJsonPayload(index);

  http.begin(wifiClient, url);
  http.addHeader("Content-Type", "application/json");
  int httpCode = http.PUT(payload);
  http.end();

  Serial.printf("[FB] Status update %s code=%d\n", node.c_str(), httpCode);
  return httpCode == HTTP_CODE_OK || httpCode == HTTP_CODE_NO_CONTENT;
}

bool uploadAlertToFirebase(int index) {
  if (!wifiConnected) return false;
  String node = mines[index].nodeId.toLowerCase();
  String latestUrl = String(FIREBASE_DB_URL) + "/alerts/" + node + "/latest.json";
  String historyUrl = String(FIREBASE_DB_URL) + "/alerts/" + node + "/history.json";
  String payload = buildJsonPayload(index);

  http.begin(wifiClient, latestUrl);
  http.addHeader("Content-Type", "application/json");
  int ok1 = http.PUT(payload);
  http.end();

  http.begin(wifiClient, historyUrl);
  http.addHeader("Content-Type", "application/json");
  int ok2 = http.POST(payload);
  http.end();

  Serial.printf("[FB] Alert upload %s latest=%d history=%d\n", node.c_str(), ok1, ok2);
  return (ok1 == HTTP_CODE_OK || ok1 == HTTP_CODE_NO_CONTENT) && (ok2 == HTTP_CODE_OK || ok2 == HTTP_CODE_NO_CONTENT);
}

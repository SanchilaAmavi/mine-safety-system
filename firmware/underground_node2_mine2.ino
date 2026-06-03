#include <Arduino.h>
#include <SPI.h>
#include <LoRa.h>

// Underground Node 2 (Mine 2)
// Hardware pins based on your PCB wiring.
const char NODE_ID[] = "M2";
const unsigned long SEND_INTERVAL_MS = 5000UL;
const unsigned long START_DELAY_MS = 1500UL;

const int LORA_SS = 10;
const int LORA_MOSI = 11;
const int LORA_SCK = 12;
const int LORA_MISO = 13;
const int LORA_RST = 14;
const int LORA_DIO0 = 9;

const int MQ4_PIN = 4;
const int MQ7_PIN = 5;
const int WATER_PIN = 6;
const int SIREN_PIN = 18;

const uint16_t THRESHOLD_MQ4 = 1500;
const uint16_t THRESHOLD_MQ7 = 1500;
const uint16_t THRESHOLD_WATER = 1800;

unsigned long nextSendMs = 0;

void setup() {
  Serial.begin(115200);
  while (!Serial) ;

  pinMode(SIREN_PIN, OUTPUT);
  digitalWrite(SIREN_PIN, LOW);

  analogReadResolution(12);
  analogSetAttenuation(ADC_11db);

  SPI.begin(LORA_SCK, LORA_MISO, LORA_MOSI, LORA_SS);
  LoRa.setPins(LORA_SS, LORA_RST, LORA_DIO0);

  Serial.println("[INIT] Underground Node 2 (Mine 2)");
  if (!LoRa.begin(433E6)) {
    Serial.println("[ERROR] LoRa init failed");
    while (true) {
      delay(1000);
    }
  }

  LoRa.setSyncWord(0xA3);
  LoRa.enableCrc();
  nextSendMs = millis() + START_DELAY_MS;

  Serial.println("[OK] LoRa ready");
}

void loop() {
  if (millis() >= nextSendMs) {
    sendTelemetry();
    nextSendMs = millis() + SEND_INTERVAL_MS;
  }
}

void sendTelemetry() {
  uint16_t mq4 = analogRead(MQ4_PIN);
  uint16_t mq7 = analogRead(MQ7_PIN);
  uint16_t water = analogRead(WATER_PIN);

  bool hazardMq4 = mq4 >= THRESHOLD_MQ4;
  bool hazardMq7 = mq7 >= THRESHOLD_MQ7;
  bool hazardWater = water >= THRESHOLD_WATER;
  bool hazard = hazardMq4 || hazardMq7 || hazardWater;

  digitalWrite(SIREN_PIN, hazard ? HIGH : LOW);

  uint8_t flags = 0;
  if (hazardMq4) flags |= 0x01;
  if (hazardMq7) flags |= 0x02;
  if (hazardWater) flags |= 0x04;

  String packet = String(NODE_ID);
  packet += ",";
  packet += mq4;
  packet += ",";
  packet += mq7;
  packet += ",";
  packet += water;
  packet += ",";
  packet += flags;

  LoRa.beginPacket();
  LoRa.print(packet);
  LoRa.endPacket();

  Serial.print("[SEND] ");
  Serial.println(packet);
  Serial.print("[SIREN] ");
  Serial.println(hazard ? "ON" : "OFF");
}

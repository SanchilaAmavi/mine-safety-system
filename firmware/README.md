# Firmware Guide

This folder contains the ESP32 firmware for your mine safety system.

## Files
- `underground_node1_mine1.ino` — Underground Node 1 firmware for Mine 1
- `underground_node2_mine2.ino` — Underground Node 2 firmware for Mine 2
- `surface_node.ino` — Surface Gateway firmware with LoRa, GSM SMS, OLED display, buzzer, and Firebase upload support

## Recommended Arduino IDE Settings
- Board: `ESP32S3 Dev Module`
- Flash Mode: `QIO` 80MHz
- Flash Size: `16MB (128Mb)`
- Partition Scheme: `Huge APP (3MB No OTA/1MB SPIFFS)`
- PSRAM: `OPI PSRAM`
- Upload Speed: `921600`

## Notes
- Calibrate MQ sensor thresholds after sensor warm-up.
- Use unique node IDs: `M1` and `M2`.
- The surface node uploads data to Firebase and also sends SMS alerts.
- Update `surface_node.ino` with your WiFi SSID, password and Firebase database URL.

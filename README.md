# SubterraGuard: Smart Mine Safety System

**Repository Name:** `subterraguard-mine-safety`

**Short Description:** Multi-node IoT mine safety monitoring system using ESP32-S3, LoRa, GSM, Firebase, Flutter and a real-time web dashboard.

## Project Summary

SubterraGuard is a professional mine safety solution engineered to protect miners with fast hazard detection, immediate local and cloud alerts, and polished monitoring apps.

The system uses two underground sensor nodes, each measuring methane (MQ-4), carbon monoxide (MQ-7), and water level. When a hazard threshold is exceeded, the underground node triggers the siren and sends a LoRa alert to the surface gateway.

The surface gateway then:
- Displays the hazard on an OLED screen
- Sounds a buzzer alarm
- Sends an SMS alert via SIM800L
- Uploads the hazard event to Firebase Realtime Database
- Notifies the web dashboard and mobile app

## Brand and Presentation

**Project name:** SubterraGuard

**Tagline:** Saving miners with intelligent underground hazard alerts and cloud monitoring.

**Visual identity:**
- Safety yellow accent
- Deep slate blue dashboard styling
- Clear hazard icons and alert badges
- Real-time telemetry panels for mine status

## Key Features

- Multi-node LoRa communication for up to multiple underground mines
- Real-time hazard reporting from methane, carbon monoxide, and water sensors
- Surface gateway with OLED alert display and buzzer notification
- SMS alerts for urgent mine safety warnings
- Firebase cloud storage for alert history and live monitoring
- Web dashboard for supervisors and control rooms
- Flutter mobile app for instant alerts and safety status anywhere

## System Architecture

```text
Underground Node 1 (Mine 1)
  ESP32-S3 + MQ-4 + MQ-7 + water sensor
                 |
                 |  LoRa 433 MHz
                 v
Underground Node 2 (Mine 2)
  ESP32-S3 + MQ-4 + MQ-7 + water sensor
                 |
                 |  LoRa 433 MHz
                 v
Surface Gateway
  ESP32-S3 + OLED + buzzer + SIM800L + WiFi
                 |        |           |
                 |        |           +--> Firebase Realtime Database
                 |        +--------------> SMS alert to supervisor
                 +----------------------> Local alarm display

Firebase Realtime Database
    ├─ /status/mine1
    ├─ /status/mine2
    ├─ /alerts/mine1/latest
    └─ /alerts/mine2/latest

Web Dashboard
    • Live mine status
    • Alert history
    • Event timestamps

Flutter Mobile App
    • Live alert monitor
    • Push notifications via Firebase Cloud Messaging
```

## Firebase Setup

1. Create a Firebase project at https://console.firebase.google.com/
2. Enable Realtime Database and choose a region.
3. Start in test mode during development.
4. Copy your database URL and update `surface_node.ino` with `FIREBASE_DB_URL`.
5. In `web_dashboard/app.js`, replace the placeholder Firebase config values with your project values.
6. Deploy the dashboard from `web_dashboard/` using Firebase Hosting:
   - `npm install -g firebase-tools`
   - `firebase login`
   - `firebase init hosting`
   - `firebase deploy`

## Firebase Cloud Functions

The `cloud_functions/` folder includes a sample function that sends topic notifications whenever a new alert is written to Realtime Database.

## Web Dashboard

- Displays live mine status for both underground nodes.
- Shows the latest hazard history from Firebase.
- Updates automatically when the surface gateway uploads data.

## Flutter Mobile App

- Uses Firebase Realtime Database to show current mine alerts.
- Subscribes to `mine_alerts` topic via Firebase Messaging.
- Displays a clean alert UI for quick decision-making.

## Professional Presentation

- Use the `assets/logo.svg` and web dashboard design consistently.
- Add screenshots of the dashboard and app in the final report.
- Explain how the cloud layer improves miner safety by delivering remote alerts instantly.

## Repository Contents

- `firmware/` � ESP32 firmware for underground and surface nodes
- `web_dashboard/` � Browser-based dashboard UI and Firebase integration
- `flutter_app/` � Flutter mobile app source code
- `assets/` � Brand logo and illustrations

## Academic Submission Advice

- Add screenshots of the dashboard and app in the final report.
- Include a block diagram showing data flow between underground nodes, surface gateway, Firebase, web dashboard, and mobile app.
- Emphasize safety benefits: instant alerts, remote monitoring, and multiple notification channels.
- Use the project branding consistently in slides and documentation.

## GitHub About Field

`IoT mine hazard alert system with ESP32-S3, LoRa, GSM, Firebase, Flutter, and real-time dashboard.`

## Next Steps

1. Complete and test the Firebase integration.
2. Deploy the web dashboard to Firebase Hosting.
3. Configure Flutter with Firebase and push notifications.
4. Add final images and screenshots to the repository.

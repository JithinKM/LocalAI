# Local AI (Multiplatform/Android)

A premium, minimalistic, and 100% offline AI chat application. Built with Flutter and powered by the high-performance `llamadart` engine, designed for high-speed inference on mobile devices.

## ✨ Key Features

- **100% Private & Offline**: No data ever leaves your device. All inference happens locally using `llamadart`.
- **Modern Flat Design**: A shadow-free, minimal UI with a premium Teal theme and smooth micro-animations.
- **Smart Generation States**:
  - **Thinking...**: Real-time feedback while the model processes your prompt.
  - **Streaming**: Tokens stream instantly to the screen.
  - **Completion Check**: Graceful verification once the response is finished.
- **Chat History & Sidebar**: Persistent conversation history stored locally using **Hive**.
- **Model Store**: Integrated downloader with support for **Resumable Downloads** (finish your 1.6GB downloads even if interrupted).
- **Auto-Persistence**: Remembers your last used model and "wakes it up" automatically on boot.
- **Theme Support**: Full support for Dark and Light modes.

## 🚀 Tech Stack

- **Framework**: Flutter (Material 3)
- **State Management**: Riverpod
- **Inference Engine**: [llamadart](https://pub.dev/packages/llamadart) (Powered by `llama.cpp`)
- **Database**: Hive (Chat History)
- **Networking**: Dio (Resumable Model Downloads)
- **Fonts**: Google Fonts (Outfit)

## 📱 Hardware Optimization (Android)

- **Backend**: Vulkan / GPU Acceleration.
- **Memory Management**: Optimized 1024 context size for stability on 6GB/8GB RAM devices.
- **Thread Control**: Dynamic thread allocation based on device processor count.

## 🛠️ Getting Started

### Prerequisites
- Flutter SDK (>=3.2.0)
- Android Studio / Android SDK

### Installation
1. Clone the repository:
   ```bash
   git clone <repo-url>
   cd LocalAI
   ```
2. Install dependencies:
   ```bash
   flutter pub get
   ```
3. Run the app:
   ```bash
   flutter run --debug
   ```

## 📂 Project Structure
- `lib/services/llm_service.dart`: Core inference logic using `llamadart`.
- `lib/services/download_service.dart`: Resumable HTTP download system.
- `lib/services/model_state_provider.dart`: Global state for downloads and availability.
- `lib/main.dart`: Clean, unified UI and history management.

## 📄 License
This project is for educational and personal use.

# Build Instructions for Local AI (Android)

This document provides step-by-step instructions for building a production-ready APK for the Local AI application.

## 🛠️ Build Steps

### 1. Resolve Dependencies
Ensure all Flutter and Android dependencies are correctly resolved:
```bash
flutter pub get
```

### 2. Clean Previous Builds
It is recommended to start with a clean build state to avoid cache issues:
```bash
flutter clean
```

### 3. Update Version Number (Optional but Recommended)
Before every production build, increment the version number in `pubspec.yaml` to ensure unique build identification:
```yaml
# pubspec.yaml
version: 1.0.0+1 # Change to 1.0.1+2, etc.
```

### 4. Build Release APK
Run the following command to generate an optimized, release-ready APK:
```bash
flutter build apk --release
```
*Note: This command uses the standard Flutter build pipeline. If you have specific signing keys, ensure they are configured in `android/key.properties`.*

### 4. Locate the APK
Once the build completes, the APK is located at:
`build/app/outputs/flutter-apk/app-release.apk`

### 5. Deployment / Renaming
To rename and move the file to your desktop (macOS example):
```bash
cp build/app/outputs/flutter-apk/app-release.apk ~/Desktop/local-ai-2.0.0.apk
```

## ⚙️ Build Configurations (Android)
- **Minification**: Enabled (`isMinifyEnabled = true`) for reduced size.
- **Shrinking**: Enabled (`isShrinkResources = true`) to remove unused resources.
- **Native Support**: Compiled with support for `llama.cpp` native libraries.
- **Architecture**: Builds for `arm64-v8a` (standard for modern Android devices like Pixel 6a).

## ⚠️ Troubleshooting
- **Memory Errors**: If the build fails with "Out of Memory", increase your Gradle heap size in `android/gradle.properties`.
- **Missing Libraries**: Ensure you have the Android NDK installed if you are modifying native `llamadart` components.

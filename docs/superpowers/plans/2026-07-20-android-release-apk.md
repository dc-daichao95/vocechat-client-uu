# Android Release APK Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and verify a signed arm64/x86_64 Android Release APK from the latest client and E2EE core sources without installing Android tooling on the remote host.

**Architecture:** Copy client and server sources into a disposable workspace, then run a pinned Flutter 3.19.6 container with the existing keystore mounted read-only. Build current Rust E2EE `.so` libraries first, build the APK second, verify its signature, and copy only the APK and SHA-256 file to persistent artifacts.

**Tech Stack:** Flutter 3.19.6, Dart 3.3.4, JDK 17, Android SDK 34, NDK r26d, Rust 1.95, cargo-ndk, Docker.

## Global Constraints

- Remote root: `/home/dcjjj/workspace/true_workspace/vocechat/gitwork`.
- Use the existing `android-release.jks` and password file; never print either password.
- Build target platforms: `android-arm64,android-x64`.
- Do not modify the three checked-out source repositories.
- Output APK: `build/artifacts/vocechat-client-release.apk`.
- Output digest: `build/artifacts/vocechat-client-release.apk.sha256`.

---

### Task 1: Verify the pinned Android build environment

**Files:**
- No source files modified.

**Interfaces:**
- Consumes: `ghcr.io/cirruslabs/flutter:3.19.6`.
- Produces: confirmed Flutter/JDK/Android SDK environment.

- [ ] **Step 1: Pull and inspect the image**

Run:

```bash
sudo docker pull ghcr.io/cirruslabs/flutter:3.19.6
sudo docker run --rm ghcr.io/cirruslabs/flutter:3.19.6 bash -lc '
  flutter --version
  java -version
  test -n "$ANDROID_HOME"
  test -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ||
    command -v sdkmanager
'
```

Expected: Flutter `3.19.6`, Java `17`, and an available `sdkmanager`.

### Task 2: Build current E2EE native libraries and signed APK

**Files:**
- Create temporarily: `/tmp/vocechat-android-release.*/client`
- Create temporarily: `/tmp/vocechat-android-release.*/server`
- Create: `/home/dcjjj/workspace/true_workspace/vocechat/gitwork/build/artifacts/vocechat-client-release.apk`
- Create: `/home/dcjjj/workspace/true_workspace/vocechat/gitwork/build/artifacts/vocechat-client-release.apk.sha256`

**Interfaces:**
- Consumes: latest client/server checkouts and read-only signing secrets.
- Produces: signed APK and digest.

- [ ] **Step 1: Create a disposable source workspace**

Run:

```bash
set -eu
ROOT=/home/dcjjj/workspace/true_workspace/vocechat/gitwork
TMP=$(mktemp -d /tmp/vocechat-android-release.XXXXXX)
mkdir -p "$TMP/client" "$TMP/server" "$ROOT/build/artifacts"
(cd "$ROOT/vocechat-client-uu" &&
  tar --exclude=.git --exclude=build -cf - .) | tar -C "$TMP/client" -xf -
(cd "$ROOT/vocechat-server-rust-uu" &&
  tar --exclude=.git --exclude=target -cf - .) | tar -C "$TMP/server" -xf -
printf '%s\n' "$TMP" > /tmp/vocechat-android-release-workspace
```

Expected: copied source trees exist while original Git worktrees remain untouched.

- [ ] **Step 2: Build in the pinned container**

Run:

```bash
set -eu
ROOT=/home/dcjjj/workspace/true_workspace/vocechat/gitwork
TMP=$(cat /tmp/vocechat-android-release-workspace)
SECRETS="$ROOT/vocechat-server-e2ee-delivery-20260717/secrets"

sudo docker run --rm --user root \
  -v "$TMP:/workspace" \
  -v "$ROOT/build/artifacts:/out" \
  -v "$SECRETS/android-release.jks:/run/secrets/android-release.jks:ro" \
  -v "$SECRETS/android-keystore-password:/run/secrets/android-keystore-password:ro" \
  -e PUB_HOSTED_URL=https://pub.flutter-io.cn \
  -e FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn \
  ghcr.io/cirruslabs/flutter:3.19.6 bash -lc '
    set -eu
    export PATH=/root/.cargo/bin:$PATH
    export LANG=C
    export NDK_VERSION=26.3.11579264

    if ! command -v cargo >/dev/null 2>&1; then
      curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs |
        sh -s -- -y --default-toolchain 1.95.0 --profile minimal
    fi
    rustup target add aarch64-linux-android x86_64-linux-android
    command -v sdkmanager >/dev/null 2>&1 ||
      export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"
    yes | sdkmanager --licenses >/dev/null
    sdkmanager "platforms;android-34" "build-tools;34.0.0" "ndk;$NDK_VERSION"
    export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/$NDK_VERSION"

    cargo install cargo-ndk --locked
    cargo ndk \
      -t arm64-v8a \
      -t x86_64 \
      -o /workspace/client/android/app/src/main/jniLibs \
      build \
      --manifest-path /workspace/server/crates/voce-e2ee-core/Cargo.toml \
      --release

    STORE_PASSWORD=$(cat /run/secrets/android-keystore-password)
    KEY_ALIAS=$(
      keytool -list -v \
        -keystore /run/secrets/android-release.jks \
        -storepass "$STORE_PASSWORD" |
      sed -n "s/^Alias name: //p" |
      sed -n "1p"
    )
    test -n "$KEY_ALIAS"

    cd /workspace/client
    flutter pub get
    ANDROID_KEYSTORE_FILE=/run/secrets/android-release.jks \
    ANDROID_KEYSTORE_PASSWORD="$STORE_PASSWORD" \
    ANDROID_KEY_PASSWORD="$STORE_PASSWORD" \
    ANDROID_KEY_ALIAS="$KEY_ALIAS" \
      flutter build apk --release \
        --target-platform android-arm64,android-x64

    APK=build/app/outputs/flutter-apk/app-release.apk
    test -s "$APK"
    APKSIGNER=$(find "$ANDROID_HOME/build-tools" -name apksigner -type f |
      sort -V | tail -1)
    test -x "$APKSIGNER"
    "$APKSIGNER" verify --verbose "$APK"
    install -m 0644 "$APK" /out/vocechat-client-release.apk
    cd /out
    sha256sum vocechat-client-release.apk \
      > vocechat-client-release.apk.sha256
  '
```

Expected: `Verified` from `apksigner`, followed by successful container exit.

- [ ] **Step 3: Verify artifacts and clean temporary sources**

Run:

```bash
set -eu
ROOT=/home/dcjjj/workspace/true_workspace/vocechat/gitwork
TMP=$(cat /tmp/vocechat-android-release-workspace)
test -s "$ROOT/build/artifacts/vocechat-client-release.apk"
(cd "$ROOT/build/artifacts" &&
  sha256sum -c vocechat-client-release.apk.sha256)
rm -rf "$TMP" /tmp/vocechat-android-release-workspace
git -C "$ROOT/vocechat-client-uu" status -sb
git -C "$ROOT/vocechat-server-rust-uu" status -sb
```

Expected: digest reports `OK`; original worktree status contains no new build-generated changes.

#!/usr/bin/env bash
# Generate the Android project on a machine that has Flutter installed.
# The Dart source, assets and the launcher icon are already in this repository;
# android/ is intentionally not committed (see .gitignore), exactly like ios/.
#
# What this adds on top of `flutter create`:
#   * applicationId / namespace com.flm.music (same identity as the iOS bundle)
#   * flm's AndroidManifest: internet + cleartext HTTP for the music sources,
#     and the mediaPlayback foreground service that keeps audio alive behind
#     the lock screen
#   * the aurora launcher icon (legacy + adaptive + themed/monochrome layers)
#   * a launch background that matches the app instead of Flutter's white
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v flutter >/dev/null 2>&1; then
  echo "error: flutter is not installed (or not on PATH)." >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# org com.flm + project name music -> androidIdentifier com.flm.music, which is
# also the notification channel prefix used in lib/main.dart.
echo "==> creating Android scaffold in $TMP"
flutter create \
  --platforms=android \
  --org com.flm \
  --project-name music \
  "$TMP/scaffold" >/dev/null

echo "==> copying android/ into the project"
rm -rf "$ROOT/android"
cp -R "$TMP/scaffold/android" "$ROOT/android"

echo "==> applying flm manifest and resources"
cp "$ROOT/tool/android_overlay/AndroidManifest.xml" \
  "$ROOT/android/app/src/main/AndroidManifest.xml"
# The template's API-21 launch background would win over ours otherwise.
rm -f "$ROOT/android/app/src/main/res/drawable-v21/launch_background.xml"
cp -R "$ROOT/tool/android_overlay/res/." "$ROOT/android/app/src/main/res/"

# flutter_js still compiles its Kotlin to JVM 1.8 while its Java task targets
# 11, which newer Kotlin Gradle Plugins treat as a fatal mismatch. Both outputs
# are valid for D8, so keep the check as a warning instead of patching a
# dependency we do not own.
echo "==> relaxing the JVM target consistency check"
printf '\n# Added by tool/bootstrap_android.sh: see the comment above.\nkotlin.jvm.target.validation.mode=warning\n' \
  >> "$ROOT/android/gradle.properties"

# file_picker 8.x, flutter_js 0.8.x, just_audio 0.9.x and audio_session 0.1.x
# still pin their own compileSdk to 34, while the flutter_plugin_android_lifecycle
# that comes with this Flutter SDK is built against 36, so AGP aborts in
# :file_picker:checkReleaseAarMetadata. Those sources live in the pub cache and
# must not be edited, so the override happens in the root Gradle script, for the
# plugin modules only (never :app). The AAR metadata check is switched off for
# the same modules as a fallback for the case where AGP has already read
# compileSdk by the time this runs.
echo "==> raising plugin compileSdk to 36"
cat >> "$ROOT/android/build.gradle.kts" <<'GRADLE'

// Added by tool/bootstrap_android.sh: see the comment above.
subprojects {
    if (name != "app") {
        afterEvaluate {
            val module = extensions.findByName("android")
            if (module != null) {
                val intSetter = module.javaClass.methods.firstOrNull {
                    it.name == "setCompileSdk" && it.parameterCount == 1 &&
                        it.parameterTypes[0] != String::class.java
                }
                val stringSetter = module.javaClass.methods.firstOrNull {
                    it.name == "setCompileSdkVersion" && it.parameterCount == 1 &&
                        it.parameterTypes[0] == String::class.java
                }
                try {
                    when {
                        intSetter != null -> intSetter.invoke(module, 36)
                        stringSetter != null -> stringSetter.invoke(module, "android-36")
                        else -> logger.info("flm: no compileSdk setter on " + module.javaClass.name)
                    }
                } catch (error: Exception) {
                    logger.warn("flm: could not raise compileSdk: " + (error.message ?: error.toString()))
                }
            }
            tasks.configureEach {
                if (name.contains("AarMetadata")) enabled = false
            }
        }
    }
}
GRADLE
grep -q 'Added by tool/bootstrap_android.sh' "$ROOT/android/build.gradle.kts" \
  || { echo "error: compileSdk override was not appended to build.gradle.kts" >&2; exit 1; }

echo "==> checking the generated configuration"
grep -q 'applicationId = "com.flm.music"' "$ROOT/android/app/build.gradle.kts" \
  || { echo "error: applicationId was not generated as com.flm.music" >&2; exit 1; }
for permission in \
  android.permission.INTERNET \
  android.permission.WAKE_LOCK \
  android.permission.FOREGROUND_SERVICE \
  android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK \
  android.permission.POST_NOTIFICATIONS
do
  grep -q "$permission" "$ROOT/android/app/src/main/AndroidManifest.xml" \
    || { echo "error: missing $permission" >&2; exit 1; }
done
grep -q 'com.ryanheise.audioservice.AudioService' \
  "$ROOT/android/app/src/main/AndroidManifest.xml" \
  || { echo "error: audio_service foreground service not declared" >&2; exit 1; }
for icon in \
  mipmap-anydpi-v26/ic_launcher.xml \
  mipmap-xxxhdpi/ic_launcher.png \
  mipmap-xxxhdpi/ic_launcher_background.png \
  mipmap-xxxhdpi/ic_launcher_foreground.png \
  xml/automotive_app_desc.xml
do
  test -f "$ROOT/android/app/src/main/res/$icon" \
    || { echo "error: missing launcher resource $icon" >&2; exit 1; }
done

echo "==> flutter pub get"
flutter pub get

cat <<'EOF'

Done.

Build a local APK with:
  flutter build apk --release        # universal, installs on any device
  flutter build apk --release --split-per-abi

Notes:
  * The release APK is signed with the debug key (Flutter's default), which is
    fine for sideloading but not for Play Store upload.
  * Online playback still needs a user source .js: 我的 -> 自定义源 -> 导入.
  * Android 12+ kills background audio if the battery optimizer stops the
    service; tell users to allow unrestricted battery usage for flm if tracks
    stop behind the lock screen.
EOF

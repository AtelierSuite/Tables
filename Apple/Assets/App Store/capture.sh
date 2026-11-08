#!/bin/zsh
# Captures raw App Store screenshots into Raw/<device>/<language>/.
# Usage: ./capture.sh [languages...]   (defaults to en ja)
#        DEVICES=iPad ./capture.sh    (defaults to both iPhone and iPad)
#
# Each run seeds the app with the documents from samples.py, then the
# AppStoreScreenshots UI test opens them and writes the captures. Run
# compose.swift afterwards to frame them.
set -e

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h:h}
BUNDLE_ID=com.tsubuzaki.Tables
DERIVED_DATA=/tmp/tables-screenshots-dd
LANGUAGES=($@)
(( $# )) || LANGUAGES=(en ja)
typeset -A DEVICE_TYPES=(
  iPhone com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro-Max
  iPad com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB
)

# MARK: - Simulators

simulator() {
  local name="Tables Screenshots $1" udid
  udid=$(xcrun simctl list devices available | grep "$name (" | head -1 | grep -oE '[0-9A-F-]{36}' || true)
  if [[ -z $udid ]]; then
    udid=$(xcrun simctl create "$name" $DEVICE_TYPES[$1] com.apple.CoreSimulator.SimRuntime.iOS-27-0)
  fi
  echo $udid
}

# The document browser runs out of process and follows the system language, not
# the app's, so the whole simulator is switched and restarted for each language.
# The preferences are edited while it is shut down: a `defaults write` through
# simctl spawn does not survive the restart.
boot() {
  local locale=$([[ $2 == ja ]] && echo ja_JP || echo en_US)
  local preferences=~/Library/Developer/CoreSimulator/Devices/$1/data/Library/Preferences/.GlobalPreferences.plist
  # The first boot is what creates the preferences.
  xcrun simctl boot $1 2>/dev/null || true
  xcrun simctl bootstatus $1 -b >/dev/null
  xcrun simctl shutdown $1
  plutil -replace AppleLanguages -json "[\"$2\"]" "$preferences"
  plutil -replace AppleLocale -string $locale "$preferences"
  xcrun simctl boot $1
  xcrun simctl bootstatus $1 -b >/dev/null
  xcrun simctl status_bar $1 override --time 9:41 \
    --batteryState discharging --batteryLevel 100 \
    --cellularMode active --cellularBars 4 --wifiBars 3 --operatorName ""
}

# MARK: - Build

xcodebuild build-for-testing -project "$PROJECT_DIR/Tables.xcodeproj" -scheme Tables \
  -destination "generic/platform=iOS Simulator" -derivedDataPath $DERIVED_DATA -quiet
APP=$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Tables.app
XCTESTRUN=$(ls $DERIVED_DATA/Build/Products/*.xctestrun | head -1)

# UI tests on a freshly booted simulator now and then miss a tap, so a failed run
# is given one more go. The test sets light and dark itself.
run_test() {
  run_test_once "$@" || run_test_once "$@"
}

# Prints only the assertion that failed, if any; -quiet would hide it.
run_test_once() {
  local log=$(mktemp) test_status=0
  TEST_RUNNER_SCREENSHOT_DIR=$3 TEST_RUNNER_SCREENSHOT_LANGUAGE=$2 \
    xcodebuild test-without-building -xctestrun $XCTESTRUN -destination "id=$1" \
    -only-testing:TablesUITests/AppStoreScreenshots/testScreens \
    -test-timeouts-enabled YES -maximum-test-execution-time-allowance 600 >$log 2>&1 || test_status=$?
  grep -E "error: -\[" $log || true
  rm -f $log
  return $test_status
}

# MARK: - Capture

# One language at a time on one device; the iPhone and iPad run side by side.
capture() {
  local device=$1 udid=$(simulator $1) language
  for language in $LANGUAGES; do
    raw_dir="$SCRIPT_DIR/Raw/$device/$language"
    mkdir -p "$raw_dir"
    boot $udid $language

    # A fresh install, so the browser has no recents and no document to restore.
    xcrun simctl terminate $udid $BUNDLE_ID 2>/dev/null || true
    xcrun simctl uninstall $udid $BUNDLE_ID 2>/dev/null || true
    xcrun simctl install $udid $APP

    samples="$(python3 "$SCRIPT_DIR/samples.py" $device $language)"
    documents="$(xcrun simctl get_app_container $udid $BUNDLE_ID data)/Documents"
    mkdir -p "$documents"
    cp "$samples/"* "$documents/"
    rm -r "$samples"
    # Match the file times in the browser to the 9:41 status bar.
    touch -t 202610040915 "$documents/"*

    run_test $udid $language "$raw_dir"
    echo "captured $device/$language"
  done
}

for device in ${=DEVICES:-iPhone iPad}; do
  capture $device &
done
wait

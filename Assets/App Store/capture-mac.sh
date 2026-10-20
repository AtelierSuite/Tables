#!/bin/zsh
# Captures raw Mac App Store screenshots into Raw/Mac/<language>/.
# Usage: ./capture-mac.sh [languages...]   (defaults to en ja)
#
# Opens the iPad sample documents from samples.py in a debug build of Tables
# for Mac, which stages each shot itself when launched with -ScreenshotStage,
# then captures its windows. Needs a Retina display: windows are 1440 × 900
# points, so 2880 × 1800 pixels. Run compose.swift afterwards to frame them.
set -e

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h:h}
DERIVED_DATA=/tmp/tables-mac-screenshots-dd
LANGUAGES=($@)
(( $# )) || LANGUAGES=(en ja)
WORK=$(mktemp -d /tmp/tables-mac-screenshots.XXXXXX)
trap 'rm -rf $WORK' EXIT

# Each shot: name, then the sample it opens, by language.
typeset -A EN_DOCUMENTS=(01-budget "Abydos Budget" 02-charts "Club Budgets" 03-macros "Festival Plan")
typeset -A JA_DOCUMENTS=(01-budget "アビドス予算" 02-charts "部活予算" 03-macros "合同祭計画")
SHOTS=(01-budget 02-charts 03-macros)

# MARK: - Build

# Signed to run locally only; the sandbox is left out, as an ad-hoc signed
# sandboxed app can't start outside /Applications.
xcodebuild build -project "$PROJECT_DIR/Tables.xcodeproj" -scheme "Tables for Mac" -configuration Debug \
  -destination "platform=macOS" -derivedDataPath $DERIVED_DATA \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS= -quiet
APP=$DERIVED_DATA/Build/Products/Debug/Tables.app
swiftc -O "$SCRIPT_DIR/windows.swift" -o $WORK/windows

# MARK: - Capture

for language in $LANGUAGES; do
  raw_dir="$SCRIPT_DIR/Raw/Mac/$language"
  mkdir -p "$raw_dir"
  samples="$(python3 "$SCRIPT_DIR/samples.py" Mac $language)"
  locale=$([[ $language == ja ]] && echo ja_JP || echo en_US)

  for shot in $SHOTS; do
    document=$([[ $language == ja ]] && echo $JA_DOCUMENTS[$shot] || echo $EN_DOCUMENTS[$shot])
    # A fresh copy each time, as staging changes the document.
    copy="$WORK/$shot/$document.xlsx"
    mkdir -p "$WORK/$shot"
    cp "$samples/$document.xlsx" "$copy"
    touch -t 202610040915 "$copy"

    $APP/Contents/MacOS/Tables "$copy" -ScreenshotStage $shot \
      -AppleLanguages "($language)" -AppleLocale $locale \
      -ApplePersistenceIgnoreState YES -NSQuitAlwaysKeepsWindows NO >/dev/null 2>&1 &
    pid=$!
    # Long enough to open, stage, and for popovers and macros to finish.
    sleep 7

    workbook="" macros=""
    while IFS=$'\t' read -r id title; do
      if [[ $title == "$document.xlsx" ]]; then workbook=$id; elif [[ -n $title ]]; then macros=$id; fi
    done < <($WORK/windows $pid)
    if [[ -z $workbook ]]; then
      echo "no window for $shot ($language)" >&2
      kill $pid 2>/dev/null || true
      exit 1
    fi
    # Without the system's shadow: compose.swift draws its own.
    screencapture -o -l $workbook "$raw_dir/$shot.png"
    rm -f "$raw_dir/$shot-macros.png"
    [[ -n $macros && $shot == 03-macros ]] && screencapture -o -l $macros "$raw_dir/$shot-macros.png"
    kill $pid 2>/dev/null || true
    wait $pid 2>/dev/null || true
    echo "captured Mac/$language/$shot"
  done
  rm -r "$samples"
done

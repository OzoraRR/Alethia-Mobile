#!/usr/bin/env bash
set -euo pipefail

serial="${ANDROID_SERIAL:-emulator-5554}"
deadline=$((SECONDS + 120))
consecutive=0

# boot_completed alone is insufficient: Gradle/ddmlib must also be able to read
# the full property set, and Android's package service must accept commands.
while (( SECONDS < deadline )); do
  properties="$(timeout 10 adb -s "$serial" shell getprop 2>/dev/null | tr -d '\r' || true)"
  sdk="$(sed -n 's/^\[ro.build.version.sdk\]: \[\([0-9]*\)\]$/\1/p' <<< "$properties")"
  if [[ "$properties" == *'[sys.boot_completed]: [1]'* && "$sdk" =~ ^[0-9]+$ ]] &&
     (( sdk >= 26 )) &&
     timeout 10 adb -s "$serial" shell pm path android 2>/dev/null | tr -d '\r' | grep -q '^package:'; then
    consecutive=$((consecutive + 1))
    if (( consecutive >= 3 )); then
      echo "Emulator $serial is responsive (API $sdk, properties and package service ready)."
      exit 0
    fi
  else
    consecutive=0
  fi
  echo "Waiting for emulator properties and package service ($consecutive/3 stable probes)."
  sleep 2
done

echo "Emulator did not become responsive within the readiness deadline." >&2
adb devices -l || true
exit 1

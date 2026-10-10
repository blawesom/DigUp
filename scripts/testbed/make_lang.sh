#!/bin/bash
# Bengali, Arabic and French files with known content (evals/multilingual.json, evals/french.json): notes,
# PDFs, screenshots and speech.
#   scripts/testbed/make_lang.sh <dir>       e.g. ~/DigUpTestbed/synthetic/lang
set -euo pipefail
L="${1:?usage: make_lang.sh <dir>}"; HERE="$(cd "$(dirname "$0")" && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swift "$HERE/make_lang.swift" "$L" >/dev/null
for f in "$L/bn/wallet_failed_bn.png" "$L/ar/payment_error_ar.png" "$L/fr/paiement_refuse_fr.png"; do xattr -w com.apple.metadata:kMDItemIsScreenCapture 1 "$f"; done
# The voices are macOS's own: Piya (Bengali), Majed (Arabic) and Thomas (French).
speak() { say -v "$1" -o "$L/tmp.aiff" "$3"; ffmpeg -loglevel error -y -i "$L/tmp.aiff" -ac 1 -ar 16000 "$2"; rm "$L/tmp.aiff"; }
speak Piya "$L/bn/speech_weather_bn.wav" "আগামীকাল ঢাকায় ভারী বৃষ্টি হবে, তাই বাইরে যাওয়ার সময় ছাতা নিয়ে বের হবেন। বিকেলে বজ্রসহ ঝড়ের সম্ভাবনা আছে।"
speak Majed "$L/ar/speech_weather_ar.wav" "غدا سيكون الطقس ممطرا في الرياض مع رياح قوية، فلا تنس المظلة عند خروجك من البيت."
speak Thomas "$L/fr/speech_weather_fr.wav" "Demain, il pleuvra sur Lyon avec des vents forts, alors prenez votre parapluie en sortant. Des orages sont prévus en fin d'après-midi."

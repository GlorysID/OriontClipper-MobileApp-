# OriontClipper — Mobile App

Flutter client for the OriontClipper clip pipeline (vertical 9:16 clips with burned-in
subtitles + hook, campaign compliance, thumbnails). The app is a thin UI over a
Python REST backend — heavy work (Whisper, LLM curation, ffmpeg render) always runs
server-side.

## Backend

The matching server lives in the main repo: [GlorysID/OriontClipper](https://github.com/GlorysID/OriontClipper)
(`api_server.py`, API v1.1 contract — see that repo's README for the endpoint table).

Run the backend first, then point the app at it (Settings → SERVER → base URL,
default `http://127.0.0.1:8768`). A token set on the server (`API_TOKEN`) must be
entered in Settings too; the app appends it automatically to media playback/download URLs.

## Run

```bash
flutter pub get

# Web (Chrome):
flutter run -d chrome

# Android device:
flutter run -d <device-id>
```

Static web build:

```bash
flutter build web --base-href /
python -m http.server 8767 --directory build/web
```

## Tests

```bash
flutter test
```

The suite includes regression guards for known product bugs (blank-body layout,
curation job surviving tab switches/reloads, honest compliance badges, cancel flow,
reset dialog semantics, v1.1 clip contract).

## Structure

```
lib/
  screens/    studio / catalog / style / settings
  services/   api_service (HTTP client + config), job_tracker (active-job state machine)
  models/     clip_item, hook_style, campaign_policy
  components/ preview dialog, render actions, shared widgets
  theme/      design tokens
```

## Notes

- One backend worker serializes jobs; the app polls progress and can cancel.
- "Topik / Ide" source produces conceptual clips only (no render — no video source).
- Clips' rendered files live on the server; the app downloads via `?dl=1`.

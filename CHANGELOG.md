# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-11-20

### Added
- Watch a Mixlr channel (`api.mixlr.com/users/<name>`) and start `yt-dlp` on `listen.mixlr.com/<id>` when it goes live.
- Channel is asked for at startup, or taken from an argument / `-c`; any link form works (scheme, `www.`, `.com`, `/recordings`, `/about`, `/events` ...).
- `events/<id>` links: that event is recorded at startup if it is live, then the channel keeps being watched.
- File names `<channel> - <broadcast slug> [<date_time>].<ext>`.
- Several simultaneous broadcasts; retries while a stream is live (`--max-tries`); `--once` leaves downloads running and avoids duplicates via pid files.
- Themed output: banner, live check line, dated notification events; native notifications (Termux, `notify-send`, macOS).
- `--test-notify`, `--dump-api`, `--ytdlp-arg`, `--once`.

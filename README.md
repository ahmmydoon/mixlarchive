# mixlarchive

> Watches a [Mixlr](https://mixlr.com) channel and records every live stream with `yt-dlp` the moment it starts.

```text
╔═══════════════════════════════════════════════════════════╗
║                                                           ║
║    ███╗   ███╗ ██╗ ██╗  ██╗ ██╗       █████╗  ██████╗     ║
║    ████╗ ████║ ██║ ╚██╗██╔╝ ██║      ██╔══██╗ ██╔══██╗    ║
║    ██╔████╔██║ ██║  ╚███╔╝  ██║      ███████║ ██████╔╝    ║
║    ██║╚██╔╝██║ ██║  ██╔██╗  ██║      ██╔══██║ ██╔══██╗    ║
║    ██║ ╚═╝ ██║ ██║ ██╔╝ ██╗ ███████╗ ██║  ██║ ██║  ██║    ║
║    ╚═╝     ╚═╝ ╚═╝ ╚═╝  ╚═╝ ╚══════╝ ╚═╝  ╚═╝ ╚═╝  ╚═╝    ║
║                                                           ║
║ ═════════════════════════════════════════════════════════ ║
║                   Mixlr Stream Archiver                   ║
║ ═════════════════════════════════════════════════════════ ║
╚═══════════════════════════════════════════════════════════╝

channel: my-channel
page: https://my-channel.mixlr.com/
interval: 30s
recordings: /home/you/recordings

[2026-11-19 20:05:12] Live now: my-channel | recording started (broadcast cfea8476)

[20:05:42] check #3: recording cfea8476 (0:00:30), 1 active
```

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Usage](#usage)
- [How it works](#how-it-works)
- [Configuration and state](#configuration-and-state)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [License](#license)

## Features

- Asks for the channel link when you do not give one, and accepts channel name too.
- Polls the channel every N seconds and starts recording as soon as it is live (`-i N`).
- Accepts an `events/<id>` link: records that event right away if it is still live, then keeps watching the channel.
- Starts recording immediately if the channel is already live when the script starts.
- Retries the download while the stream is still live (`--max-tries`).
- Handles several simultaneous live broadcasts on one channel.
- Native notification when a stream starts, is saved, or fails; the same line is always printed in the terminal/log.
- One live status line on a terminal; clean plain-text logs in files.
- Errors notify once per failure streak, not on every poll.

## Requirements

| Platform      | Install                                                                                  |
| ------------- | ---------------------------------------------------------------------------------------- |
| Termux        | `pkg install curl jq yt-dlp`                                                             |
| Debian/Ubuntu | `sudo apt install curl jq` and `pipx install yt-dlp` (the apt version is often outdated) |
| macOS         | `brew install bash curl jq yt-dlp`                                                       |

## Installation

```bash
chmod +x mixlarchive.sh
./mixlarchive.sh --help
```

## Quick start

```bash
 # verify notifications work
./mixlarchive.sh --test-notify                         

# asks for the channel link
./mixlarchive.sh

./mixlarchive.sh my-channel.mixlr.com -i 15 -d ~/recordings

# record this event if live, and keep watching
./mixlarchive.sh https://my-channel.mixlr.com/events/4395480

# background (plain-text log)
nohup ./mixlarchive.sh my-channel >>mixlarchive.log 2>&1 &
```

## Usage

```text
Usage: mixlarchive.sh [options] [CHANNEL]

Watch a Mixlr channel and record every live stream with yt-dlp.
CHANNEL is a channel name or any Mixlr link; you are asked for it when omitted.

Options:
  -c, --channel LINK   channel name or link (same as the CHANNEL argument)
  -i, --interval SEC   polling interval in seconds, min 5 (default: 30)
  -d, --dir DIR        folder for the recordings (default: ./recordings)
      --max-tries N    yt-dlp attempts per live broadcast (default: 99)
      --ytdlp-arg ARG  extra argument passed to yt-dlp, repeatable
      --once           run a single check, then exit
      --test-notify    send a sample notification, then exit
      --dump-api       print the raw API response, then exit (debugging)
  -v, --version        show the version
  -h, --help           show this help

Accepted channel forms:
  my-channel            my-channel.mixlr         my-channel.mixlr.com/about
  https://mixlr.com/my-channel/recordings
  https://my-channel.mixlr.com/events/4395480    (also records that event if
                                                  it is live, then keeps watching)

Environment: NO_COLOR=1 disables colors, MIXLARCHIVE_HOME changes the state
folder (default ~/.mixlarchive).
Exit codes: 0 ok, 1 runtime error, 2 usage error, 130 SIGINT, 143 SIGTERM.
```

| Option                            | Default          | Description                                 |
| --------------------------------- | ---------------- | ------------------------------------------- |
| `CHANNEL`, `-c`, `--channel LINK` | asked at startup | channel name or any Mixlr link (see below)  |
| `-i`, `--interval SEC`            | `30`             | polling interval in seconds, min 5          |
| `-d`, `--dir DIR`                 | `./recordings`   | folder for the recordings                   |
| `--max-tries N`                   | `99`             | yt-dlp attempts per live broadcast          |
| `--ytdlp-arg ARG`                 | none             | extra argument passed to yt-dlp, repeatable |
| `--once`                          | off              | run a single check, then exit               |
| `--test-notify`                   | off              | send a sample notification, then exit       |
| `--dump-api`                      | off              | print the raw API responses, then exit      |
| `-v`, `--version`                 |                  | show the version                            |
| `-h`, `--help`                    |                  | show help                                   |

Examples:

```bash
# save audio as mp3 (needs ffmpeg)
./mixlarchive.sh --ytdlp-arg -x --ytdlp-arg --audio-format=mp3
# any of these select the same channel
./mixlarchive.sh my-channel
./mixlarchive.sh my-channel.mixlr
./mixlarchive.sh https://www.my-channel.mixlr.com/recordings
./mixlarchive.sh mixlr.com/my-channel/about
```

## Channel links and event links

Only the channel name matters; everything around it is ignored. These all select `my-channel`:

| You type | Notes |
|---|---|
| `my-channel` | plain name |
| `my-channel.mixlr` / `my-channel.mixlr.com` | with or without `.com` |
| `https://my-channel.mixlr.com/about` | any scheme, `www.`, and any suffix (`/recordings`, `/about`, `/events` ...) |
| `https://mixlr.com/my-channel/recordings` | the `mixlr.com/<name>` form works too |
| `https://my-channel.mixlr.com/events/4395480` | also records that event if it is live |

Links that do not name a channel (`listen.mixlr.com/...`, numeric `mixlr.com/users/<id>` profile links) are rejected with a hint.

An `events/<id>` link is checked once at startup: if the event is live, it is recorded immediately; if it has ended or has not started, a line says so. In both cases the channel keeps being watched, so later streams are recorded as usual. The same broadcast is never recorded twice.

## How it works

1. Every interval the script asks the public Mixlr API (`https://api.mixlr.com/users/<name>?source=embed`) whether the channel is live and which broadcasts are running.
2. A live broadcast it is not recording yet triggers a notification and a background `yt-dlp` run on its stream URL (`https://listen.mixlr.com/<broadcast id>`, taken from the API response).
3. Files are written to the output folder as `<channel> - <broadcast slug> [<YYYY-MM-DD_HH-MM>].<ext>` (for example `my-channel - my-channels-live-event-45 [2026-11-19_20-05].aac`) with `--no-part`, so a cut-off recording is still playable.
4. When `yt-dlp` exits cleanly the broadcast is marked done and a "Recording saved" notification is sent.
5. If `yt-dlp` fails while the stream is still live it is restarted on the next poll (files get a ` (part N)` suffix), up to `--max-tries`.
6. Pressing Ctrl+C (or SIGTERM) stops running downloads; partial files stay in the output folder.
7. With `--once` (cron, scheduled tasks) the download is started with `nohup` and keeps running after the script exits. Later `--once` runs see it through its pid file and do not start a second one. No "saved" notification is sent in this mode, because the script is no longer around when the download ends.

There is no silent baseline: if the channel is already live at startup it is recorded right away.

On a terminal the check line is rewritten in place. When a notification fires it replaces that line with the date and details, an empty line follows, and the check line returns. In a log file every check is its own plain line.

## Configuration and state

State lives in `~/.mixlarchive/` (mode `700`, override with `MIXLARCHIVE_HOME`). Delete the directory to reset.

| Path                      | Content                                           |
| ------------------------- | ------------------------------------------------- |
| `<channel>.done`          | ids of broadcasts that were recorded to the end   |
| `<channel>.err`           | error latch (one notification per failure streak) |
| `pids/<channel>/<id>.pid` | pid of each running recording                     |
| `logs/<channel>-<id>.log` | yt-dlp output for each broadcast                  |

Environment: `NO_COLOR=1` disables colors; `MIXLARCHIVE_HOME` moves the state folder.

## Troubleshooting

| Message                                            | Fix                                                                                                |
| -------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `missing dependency 'jq'`                          | install it (see [Requirements](#requirements))                                                     |
| `error: network error / timeout`                   | check connectivity; yellow counter = transient                                                     |
| `'<text>' is not a Mixlr address`                  | the link is not from mixlr.com; paste the channel link or name                                     |
| `event <id>: could not check it (event not found)` | wrong event id; the channel is still watched                                                       |
| `error: HTTP 404`                                  | wrong channel name; check `https://<name>.mixlr.com/`                                              |
| `error: response was not the expected JSON`        | Mixlr changed its API; run `--dump-api` and compare                                                |
| `channel is live but no broadcast id was found`    | run `--dump-api` and check that `broadcast_ids` / `broadcasts` are present                         |
| `Recording failed`                                 | read `~/.mixlarchive/logs/<channel>-<id>.log`; update yt-dlp (`yt-dlp -U` / `pipx upgrade yt-dlp`) |
| no notification appears                            | run `--test-notify`; check notification permission/channel                                         |

## Contributing

```bash
shellcheck mixlarchive.sh && shfmt -d -i 2 mixlarchive.sh
```

Use [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `docs:` ...).

## License

This project is licensed under the **GNU General Public License v3.0** — see
[LICENSE](LICENSE).

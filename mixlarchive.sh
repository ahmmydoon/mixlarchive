#!/usr/bin/env bash
#=======================================================================
#  mixlarchive.sh -- records a Mixlr channel with yt-dlp when it goes live
#
#  Flow:
#    1. Poll the public Mixlr API every N seconds: is the channel live?
#    2. A live broadcast appears -> notify, then start yt-dlp in the
#       background on its stream (https://listen.mixlr.com/<id>).
#       If you gave an events/<id> link, that event is recorded right
#       away when it is live, and the channel is watched afterwards.
#    3. yt-dlp exits -> notify "saved". If the stream is still live the
#       download is retried (up to --max-tries per broadcast).
#    4. Errors notify once per failure streak (latch file), and clear
#       when a check succeeds again.
#  Output:   all UI goes to stderr; colors + the live check line only on
#            a terminal; log files get plain text (one line per check).
#  State:    ~/.mixlarchive/ (mode 700): finished-event list, error
#            latch, one yt-dlp log per broadcast. No secrets are stored.
#  Setup:    pkg/apt/brew install curl jq yt-dlp   (bash 4.4+)
#  Run:      ./mixlarchive.sh                       # asks for the channel link
#            ./mixlarchive.sh my-channel.mixlr.com -i 15 -d ~/recordings
#            nohup ./mixlarchive.sh my-channel >>mixlarchive.log 2>&1 &
#=======================================================================

set -u   # watcher: no -e, a failed request must not end the loop

[ "${BASH_VERSINFO[0]:-0}" -ge 4 ] || {
  printf 'error: bash 4.4+ is required (macOS: brew install bash)\n' >&2
  # shellcheck disable=SC2317  # 'return' only works when sourced, else exit
  return 1 2>/dev/null || exit 1
}

#------------------------------ defaults -------------------------------
VERSION="0.1.0"
DEFAULT_INTERVAL=30
DEFAULT_MAX_TRIES=99
API_BASE="${MIXLR_API_BASE:-https://api.mixlr.com}"
STATE_DIR="${MIXLARCHIVE_HOME:-$HOME/.mixlarchive}"
USER_AGENT="Mozilla/5.0 (compatible; mixlarchive/$VERSION)"

#------------------------------- globals -------------------------------
STATUS_ACTIVE=0             # 1 while a live \r status line is on screen (tty)
LAST_BLANK=0                # 1 right after a blank separator line
CHECK_N=0                   # poll counter shown in the check line
RESULT=""                   # text of the last check, fed to log_status
NOTIF_CHANNEL="${NOTIF_CHANNEL:-Mixlr}"   # Android notification channel (Termux)
NOTIFY_COUNT=0              # notifications raised during the current check
NOTIFY_ERR=""

CHANNEL_INPUT=""            # what the person typed (link or name)
STREAM=""                   # channel slug parsed from it
EVENT_ID=""                 # numeric id from an .../events/<id> link, if any
PARSE_ERR=""                # why the last _parse_mixlr_input failed
INTERVAL=$DEFAULT_INTERVAL
MAX_TRIES=$DEFAULT_MAX_TRIES
OUT_DIR="./recordings"
ONCE=0
TEST_NOTIFY=0
DUMP_API=0
YTDLP_ARGS=()               # extra arguments for yt-dlp (--ytdlp-arg)

BODY=""                     # last HTTP body (see _fetch)
HTTP=""                     # last HTTP status, 000 on transport failure
LIVE=0                      # 1 if the last lookup says the channel is live
LIVE_IDS=()                 # ids of the live broadcasts (hex strings)
LOOKUP_OK=0                 # 1 if the last lookup produced a usable answer
LOOKUP_ERR=""               # reason when it did not
ERR_FILE=""                 # error latch file (set after STREAM is known)
DONE_FILE=""                # finished event ids, one per line
LOG_DIR=""                  # per-event yt-dlp logs
PID_DIR=""                  # one <id>.pid file per running recording
SLEEP_PID=""

declare -A DL_PID=()        # broadcast id -> running yt-dlp pid
declare -A DL_TRY=()        # broadcast id -> attempts so far
declare -A DL_START=()      # broadcast id -> $SECONDS at the last start
declare -A DL_STAMP=()      # broadcast id -> date stamp used in the file name
declare -A DL_URL=()        # broadcast id -> stream url being recorded
declare -A DL_SLUG=()       # broadcast id -> broadcast slug for the file name
declare -A DL_BASE=()       # broadcast id -> file name without suffix/extension
declare -A LIVE_SLUG=()     # broadcast id -> slug from the last poll
declare -A LIVE_URL=()      # event id -> progressive stream url
declare -A DL_FAILED=()     # broadcast id -> 1 after --max-tries failures

# Live refresh + colors only on a terminal (plain text in log files).
# NO_COLOR (https://no-color.org) and TERM=dumb switch colors off.
if [ -t 2 ] && [ "${TERM:-}" != dumb ]; then LIVE_TTY=1; else LIVE_TTY=0; fi
if [ "$LIVE_TTY" -eq 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_DGRAY=$'\033[90m'   # keys + datetimes + banner frame
  C_LGRAY=$'\033[37m'   # values + message text
  C_RED=$'\033[31m'     # errors
  C_YELLOW=$'\033[33m'  # network / no-response errors, warnings
  C_MAGENTA=$'\033[35m' # healthy check counter
  C_LBLUE=$'\033[94m'   # hint text
  C_OFF=$'\033[0m'
else
  C_DGRAY='' C_LGRAY='' C_RED='' C_YELLOW='' C_MAGENTA='' C_LBLUE='' C_OFF=''
fi

#------------------------------- helpers -------------------------------

_blank() {  # one blank line between log entries -- never two in a row
  if [ "$LAST_BLANK" -eq 0 ]; then printf '\n' >&2; LAST_BLANK=1; fi
}

die() {  # $@ = message; red error line, exit 1
  _blank
  printf '%serror: %s%s\n' "$C_RED" "$*" "$C_OFF" >&2
  exit 1
}

usage_error() {  # $@ = message; error + hint on stderr, exit 2
  printf '%serror: %s%s\n' "$C_RED" "$*" "$C_OFF" >&2
  printf 'Try: %s --help\n' "${0##*/}" >&2
  exit 2
}

log() {  # $@ = message; dark gray datetime, light gray text
  if [ "$STATUS_ACTIVE" -eq 1 ]; then
    printf '\n' >&2; STATUS_ACTIVE=0; LAST_BLANK=0
  else
    _blank
  fi
  printf '%s[%s]%s %s%s%s\n' "$C_DGRAY" "$(date '+%Y-%m-%d %H:%M:%S')" \
    "$C_OFF" "$C_LGRAY" "$*" "$C_OFF" >&2
  LAST_BLANK=0
}

log_event() {  # $1 = text, $2 = info|warn|error
               # A notification happened: it REPLACES the live check line
               # (full date + time + info), then one empty line, then the
               # next check line is drawn fresh underneath.
  local color=$C_LGRAY text=${1//$'\n'/ }
  case ${2:-info} in warn) color=$C_YELLOW ;; error) color=$C_RED ;; esac
  if [ "$STATUS_ACTIVE" -eq 1 ]; then
    printf '\r\033[K' >&2; STATUS_ACTIVE=0     # wipe the live check line
  fi
  _blank
  printf '%s[%s]%s %s%s%s\n' "$C_DGRAY" "$(date '+%Y-%m-%d %H:%M:%S')" \
    "$C_OFF" "$color" "$text" "$C_OFF" >&2
  printf '\n' >&2; LAST_BLANK=1                 # empty line before next check
}

log_status() {  # $1 = text; the periodic check status: ONE line per check,
                # the "#N" counter carries the state color (magenta / red /
                # yellow), the text is light blue
  local text=$1 color=$C_MAGENTA
  text=${text//$'\n'/ }                # a status never spans multiple lines
  case $text in
    "error: no response"*|"error: network"*) color=$C_YELLOW ;;
    "error:"*)                              color=$C_RED ;;
  esac
  if [ "$LIVE_TTY" -eq 1 ]; then      # terminal: refresh one single line
    printf '\r\033[K%s[%s]%s check %s#%d%s:%s %s%s' "$C_DGRAY" "$(date '+%H:%M:%S')" \
      "$C_OFF" "$color" "$CHECK_N" "$C_OFF" "$C_LBLUE" "$text" "$C_OFF" >&2
    STATUS_ACTIVE=1
  else                               # file/pipe: one complete line per check
    _blank
    printf '%s[%s]%s check %s#%d%s:%s %s%s\n' "$C_DGRAY" "$(date '+%Y-%m-%d %H:%M:%S')" \
      "$C_OFF" "$color" "$CHECK_N" "$C_OFF" "$C_LBLUE" "$text" "$C_OFF" >&2
    LAST_BLANK=0
  fi
}

end_block() {  # close a run of print_kv lines with one empty line
  printf '\n' >&2; LAST_BLANK=1
}

print_kv() {  # $1 = "key: value" line -> dark gray key, light gray value
  local k=${1%%:*} v=${1#*: }
  if [ "$v" = "$1" ]; then           # not a "key: value" shape -> as-is
    printf '%s%s%s\n' "$C_LGRAY" "$1" "$C_OFF" >&2
  else
    printf '%s%s:%s %s%s%s\n' "$C_DGRAY" "$k" "$C_OFF" "$C_LGRAY" "$v" "$C_OFF" >&2
  fi
}

# Banner art lives in a function so the heredoc stays quoted. Regenerate with:
#   python3 scripts/make_banner.py "MIXLAR" "Mixlr Stream Archiver" --format bash
banner_art() {
  cat <<'BANNER'
%B╔═══════════════════════════════════════════════════════════╗%R
%B║%R                                                           %B║%R
%B║%R%M    ███╗   ███╗ ██╗ ██╗  ██╗ ██╗       █████╗  ██████╗     %R%B║%R
%B║%R%M    ████╗ ████║ ██║ ╚██╗██╔╝ ██║      ██╔══██╗ ██╔══██╗    %R%B║%R
%B║%R%M    ██╔████╔██║ ██║  ╚███╔╝  ██║      ███████║ ██████╔╝    %R%B║%R
%B║%R%M    ██║╚██╔╝██║ ██║  ██╔██╗  ██║      ██╔══██║ ██╔══██╗    %R%B║%R
%B║%R%M    ██║ ╚═╝ ██║ ██║ ██╔╝ ██╗ ███████╗ ██║  ██║ ██║  ██║    %R%B║%R
%B║%R%M    ╚═╝     ╚═╝ ╚═╝ ╚═╝  ╚═╝ ╚══════╝ ╚═╝  ╚═╝ ╚═╝  ╚═╝    %R%B║%R
%B║%R                                                           %B║%R
%B║%R%C ═════════════════════════════════════════════════════════ %R%B║%R
%B║%R%C                   Mixlr Stream Archiver                   %R%B║%R
%B║%R%C ═════════════════════════════════════════════════════════ %R%B║%R
%B╚═══════════════════════════════════════════════════════════╝%R
BANNER
}

print_banner() {  # dark gray frame, bold white block letters, plain title
  local esc=$'\033' sedexpr
  if [ -n "$C_DGRAY" ]; then
    sedexpr="s/%B/${esc}[90m/g;s/%M/${esc}[1;37m/g;s/%C/${esc}[0m/g;s/%R/${esc}[0m/g"
  else
    sedexpr='s/%[BMCR]//g'
  fi
  banner_art | sed "$sedexpr" >&2
  printf '\n' >&2
  LAST_BLANK=1
}

_install_hint() {
  if   command -v pkg     >/dev/null 2>&1; then printf 'pkg install'
  elif command -v apt-get >/dev/null 2>&1; then printf 'sudo apt install'
  elif command -v brew    >/dev/null 2>&1; then printf 'brew install'
  elif command -v dnf     >/dev/null 2>&1; then printf 'sudo dnf install'
  elif command -v pacman  >/dev/null 2>&1; then printf 'sudo pacman -S'
  else printf 'install'; fi
}

need() {  # $1 = command, $2 = package name if different
  command -v "$1" >/dev/null 2>&1 \
    || die "missing dependency '$1' (fix: $(_install_hint) ${2:-$1})"
}

usage() {  # printed to stdout for --help
  cat <<EOF
Usage: ${0##*/} [options] [CHANNEL]

Watch a Mixlr channel and record every live stream with yt-dlp.
CHANNEL is a channel name or any Mixlr link; you are asked for it when omitted.
Prefixes (https://, www.) and suffixes (/recordings, /about ...) do not matter.

Options:
  -c, --channel LINK   channel name or link (same as the CHANNEL argument)
  -i, --interval SEC   polling interval in seconds, min 5 (default: $DEFAULT_INTERVAL)
  -d, --dir DIR        folder for the recordings (default: ./recordings)
      --max-tries N    yt-dlp attempts per live broadcast (default: $DEFAULT_MAX_TRIES)
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
EOF
}

_fmt_dur() {  # $1 = seconds -> H:MM:SS
  printf '%d:%02d:%02d' $(($1 / 3600)) $(($1 % 3600 / 60)) $(($1 % 60))
}

# Turns anything the person pastes into a channel name (+ optional event id).
# Sets STREAM and EVENT_ID on success; returns 1 and sets PARSE_ERR otherwise.
_parse_mixlr_input() {  # $1 = channel name or any Mixlr link
  local s=${1,,} host path x ch="" eid="" i
  local -a seg=() p=() rest=()
  PARSE_ERR=""
  s=${s//[[:space:]]/}                  # pasted links often carry spaces/newlines
  s=${s%%[?#]*}                         # query string and fragment
  s=${s#*://}; s=${s#//}                # scheme (http, https, ...)
  host=${s%%/*}; host=${host#www.}; host=${host%%:*}
  path=""
  if [[ $s == */* ]]; then path=${s#*/}; fi
  IFS=/ read -r -a seg <<<"$path"
  for x in ${seg[@]+"${seg[@]}"}; do
    if [ -n "$x" ]; then p+=("$x"); fi
  done
  case $host in
    '') PARSE_ERR="no channel found in that text"; return 1 ;;
    mixlr.com|mixlr)                    # mixlr.com/<channel>/...  mixlr.com/embed/<channel>
      case ${p[0]:-} in
        '')    PARSE_ERR="no channel name in that link"; return 1 ;;
        users) PARSE_ERR="numeric profile links are not supported; use the channel name or <name>.mixlr.com"
               return 1 ;;
        embed) ch=${p[1]:-}; rest=("${p[@]:2}") ;;
        *)     ch=${p[0]};   rest=("${p[@]:1}") ;;
      esac ;;
    listen.mixlr.com|api.mixlr.com|app.mixlr.com|embed.mixlr.com|imagecdn.mixlr.com|imagescdn.mixlr.com)
      PARSE_ERR="that is not a channel address (use <name>.mixlr.com or mixlr.com/<name>)"
      return 1 ;;
    *.mixlr.com) ch=${host%.mixlr.com}; rest=(${p[@]+"${p[@]}"}) ;;   # <channel>.mixlr.com/...
    *.mixlr)     ch=${host%.mixlr};     rest=(${p[@]+"${p[@]}"}) ;;   # <channel>.mixlr
    *.*) PARSE_ERR="'$host' is not a Mixlr address"; return 1 ;;
    *)   ch=$host; rest=(${p[@]+"${p[@]}"}) ;;                        # bare name (+ /suffix)
  esac
  for ((i = 0; i < ${#rest[@]}; i++)); do   # .../events/<numeric id>
    if [ "${rest[i]}" = "events" ] && [[ ${rest[i + 1]:-} =~ ^[0-9]+$ ]]; then
      eid=${rest[i + 1]}; break
    fi
  done
  case $ch in
    ''|-*|*[!a-z0-9_-]*) PARSE_ERR="'$ch' is not a valid channel name"; return 1 ;;
  esac
  STREAM=$ch; EVENT_ID=$eid
  return 0
}

_safe_name() {  # $1 = text -> safe for a file name (keeps letters of any script)
  local v=${1//[\/\\:*?\"<>|]/_}
  v=${v//[[:cntrl:]]/}; v=${v#.}
  printf '%s' "${v:0:100}"
}

#---------------------------- notifications ----------------------------

_notify_native() {  # $1 = title, $2 = content; 0 = delivered, 1 = no backend / failed
  NOTIFY_ERR=""
  if command -v termux-notification >/dev/null 2>&1; then
    NOTIFY_ERR=$(termux-notification --title "$1" --content "$2" \
      --channel "$NOTIF_CHANNEL" --icon input --sound 2>&1) && return 0
    return 1
  elif command -v notify-send >/dev/null 2>&1; then
    NOTIFY_ERR=$(notify-send -- "$1" "$2" 2>&1) && return 0
    return 1
  elif command -v osascript >/dev/null 2>&1; then   # macOS; args, not string-built
    NOTIFY_ERR=$(osascript -e 'on run argv' \
      -e 'display notification (item 2 of argv) with title (item 1 of argv)' \
      -e 'end run' -- "$1" "$2" 2>&1) && return 0
    return 1
  fi
  return 1
}

notify() {  # $1 = title, $2 = content, $3 = info|warn|error
  local title=$1 content=$2 level=${3:-info}
  NOTIFY_COUNT=$((NOTIFY_COUNT + 1))
  if ! _notify_native "$title" "$content" && [ -n "$NOTIFY_ERR" ]; then
    log_event "notification delivery failed: $NOTIFY_ERR" warn
  fi
  log_event "$title | $content" "$level"   # always shown, replaces the check line
}

#--------------------------- core functions ----------------------------

_fetch() {  # $1 = url; sets BODY + HTTP; returns curl's exit code
  local out rc
  out=$(curl -sS -L --compressed --connect-timeout 15 --max-time 60 \
    -A "$USER_AGENT" -H 'Accept: application/json' \
    -w $'\n%{http_code}' -- "$1" 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then HTTP=000; BODY=""; return "$rc"; fi
  HTTP=${out##*$'\n'}
  BODY=${out%$'\n'*}
  return 0
}

_parse_user() {  # BODY of /users/<name> -> line 1 "true|false", then one
                 # "<id>|<stream url>|<slug>" line per live broadcast; "" if unknown shape
  printf '%s' "$BODY" | jq -r '
    if type == "object" and has("is_live") then
      (.is_live | tostring),
      ( if .is_live == true then
          ( [ (.broadcasts // [])[] | select(.is_live == true)
              | [ (.id | tostring), (.streams.progressive.url // ""), ((.slug // "") | tostring) ] ] ) as $b
          | ( if ($b | length) > 0 then $b
              else [ (.broadcast_ids // [])[] | [ tostring, "", "" ] ] end )
          | .[] | join("|")
        else empty end )
    else empty end' 2>/dev/null
}

_parse_event() {  # BODY of /v3/channels/<name>/events/<id> -> "<live>|<stream url>|<slug>"
  printf '%s' "$BODY" | jq -r '
    if type == "object" and (.included | type) == "array" and (.included | length) > 0 then
      ((.included[0] | objects | .attributes) // {}) as $a
      | ((.data | objects | .attributes) // {}) as $d
      | [ (($a.live // false) | tostring),
          (($a.progressive_stream_url // "") | tostring),
          (($a.slug // $d.slug // "") | tostring) ] | join("|")
    else empty end' 2>/dev/null
}

_http_reason() {  # sets LOOKUP_ERR from the last _fetch result (rc in $1)
  if [ "$1" -ne 0 ]; then LOOKUP_ERR="network error / timeout (curl exit $1)"
  elif [ "$HTTP" = "000" ]; then LOOKUP_ERR="no response (network down?)"
  elif [ "$HTTP" != "200" ]; then LOOKUP_ERR="HTTP $HTTP"
  else LOOKUP_ERR="response was not the expected JSON"; fi
}

# Is the channel live? Sets LOOKUP_OK, LIVE, LIVE_IDS, LIVE_URL
# (and LOOKUP_ERR on failure).
lookup_live() {
  local rc parsed="" flag="" id url slug
  LOOKUP_OK=0 LIVE=0 LOOKUP_ERR=""
  LIVE_IDS=(); LIVE_URL=(); LIVE_SLUG=()
  _fetch "$API_BASE/users/$STREAM?source=embed"; rc=$?
  if [ "$rc" -ne 0 ]; then _http_reason "$rc"; return 1; fi
  if [ "$HTTP" = "200" ]; then parsed=$(_parse_user); fi
  if [ -z "$parsed" ]; then _http_reason 0; return 1; fi
  {
    IFS= read -r flag
    while IFS='|' read -r id url slug; do
      [ -n "$id" ] || continue
      LIVE_IDS+=("$id")
      LIVE_URL[$id]=${url:-https://listen.mixlr.com/$id}
      LIVE_SLUG[$id]=$slug
    done
  } <<<"$parsed"
  if [ "$flag" = "true" ]; then LIVE=1; fi
  if [ "$LIVE" -eq 1 ] && [ "${#LIVE_IDS[@]}" -eq 0 ]; then
    LOOKUP_ERR="channel is live but no broadcast id was found (run --dump-api)"
    return 1
  fi
  LOOKUP_OK=1
  return 0
}

_is_live_id() {  # $1 = broadcast id; 0 if it is in the current live list
  local x
  for x in "${LIVE_IDS[@]}"; do
    if [ "$x" = "$1" ]; then return 0; fi
  done
  return 1
}

_pidfile() {  # $1 = broadcast id
  printf '%s/%s.pid' "$PID_DIR" "$1"
}

_running_pid() {  # $1 = broadcast id; prints the pid if a recording is running
                  # (started by this run or by an earlier --once run)
  local pf pid
  pf=$(_pidfile "$1")
  [ -r "$pf" ] || return 1
  pid=$(<"$pf")
  case $pid in ''|*[!0-9]*) rm -f -- "$pf"; return 1 ;; esac
  if kill -0 "$pid" 2>/dev/null; then printf '%s' "$pid"; return 0; fi
  [ -n "${DL_PID[$1]:-}" ] || rm -f -- "$pf"   # stale file of a dead foreign run
  return 1
}

_find_recording() {  # $1 = broadcast id -> path of the first non-empty file, "" if none
  local base=${DL_BASE[$1]:-} pat
  [ -n "$base" ] || return 0
  pat=${base//\\/\\\\}; pat=${pat//\[/\\[}; pat=${pat//\]/\\]}
  pat=${pat//\*/\\*}; pat=${pat//\?/\\?}
  find "$OUT_DIR" -maxdepth 1 -type f -name "$pat*" -size +0 2>/dev/null | head -n 1
}

_url_busy() {  # $1 = stream url, $2 = own id; 0 if another running recording uses that url
  local k
  for k in ${!DL_PID[@]+"${!DL_PID[@]}"}; do
    if [ "$k" != "$2" ] && [ "${DL_URL[$k]:-}" = "$1" ]; then return 0; fi
  done
  return 1
}

# Start yt-dlp in the background for broadcast $1 (stdin closed, output to a log).
# With --once the process is started with nohup so it outlives this script.
# File name: <channel> - <broadcast slug> [<date_time>].<ext>
start_download() {
  local id=$1 try suffix='' url slug tmpl
  local -a launcher=()
  url=${DL_URL[$id]:-https://listen.mixlr.com/$id}
  slug=$(_safe_name "${DL_SLUG[$id]:-$id}")
  try=$(( ${DL_TRY[$id]:-0} + 1 ))
  if [ "$try" -gt 1 ]; then suffix=" (part $try)"; fi
  if [ -z "${DL_STAMP[$id]:-}" ]; then DL_STAMP[$id]=$(date '+%Y-%m-%d_%H-%M'); fi
  DL_BASE[$id]="$STREAM - ${slug:-$id} [${DL_STAMP[$id]}]"
  tmpl="${OUT_DIR//%/%%}/${DL_BASE[$id]//%/%%}${suffix}.%(ext)s"
  if [ "$ONCE" -eq 1 ]; then launcher=(nohup); fi
  ${launcher[@]+"${launcher[@]}"} yt-dlp --no-progress --no-part --no-playlist --newline \
    -o "$tmpl" ${YTDLP_ARGS[@]+"${YTDLP_ARGS[@]}"} -- "$url" \
    </dev/null >>"$LOG_DIR/$STREAM-$id.log" 2>&1 &
  DL_PID[$id]=$!
  printf '%s\n' "$!" >"$(_pidfile "$id")"
  DL_TRY[$id]=$try
  DL_START[$id]=$SECONDS
}

# Make sure broadcast $1 (stream url $2, slug $3) is being recorded; notifies on
# (re)start and failure. Used for channel polls and for an --event link.
ensure_recording() {
  local id=$1 url=$2 slug=${3:-} tries
  tries=${DL_TRY[$id]:-0}
  [ -n "${DL_PID[$id]:-}" ] && return 0       # already running (ours)
  _running_pid "$id" >/dev/null && return 0   # running (started by another run)
  _is_done "$id" && return 0                  # finished earlier
  [ -n "${DL_FAILED[$id]:-}" ] && return 0    # gave up, already reported
  _url_busy "$url" "$id" && return 0          # same stream under another id
  DL_URL[$id]=$url
  DL_SLUG[$id]=$slug
  if [ "$tries" -ge "$MAX_TRIES" ]; then
    DL_FAILED[$id]=1
    notify "Recording failed: $STREAM" \
      "yt-dlp failed $tries times for broadcast ${id:0:8} (log: $LOG_DIR/$STREAM-$id.log)" error
    return 0
  fi
  start_download "$id"
  if [ "$tries" -eq 0 ]; then
    notify "Live now: $STREAM" "recording started (broadcast ${id:0:8})"
  else
    notify "Recording restarted: $STREAM" "broadcast ${id:0:8}, attempt $((tries + 1))/$MAX_TRIES" warn
  fi
}

# Event link: at startup, record that event right away if it is still live.
# The channel poll keeps running afterwards either way.
check_event() {
  local rc parsed="" live="" url="" slug="" key
  _fetch "$API_BASE/v3/channels/$STREAM/events/$EVENT_ID"; rc=$?
  if [ "$rc" -ne 0 ] || [ "$HTTP" != "200" ]; then
    if [ "$HTTP" = "404" ]; then LOOKUP_ERR="event not found"; else _http_reason "$rc"; fi
    log "event $EVENT_ID: could not check it ($LOOKUP_ERR); watching $STREAM anyway"
    return 0
  fi
  parsed=$(_parse_event)
  if [ -z "$parsed" ]; then
    log "event $EVENT_ID: unexpected API response; watching $STREAM anyway"
    return 0
  fi
  IFS='|' read -r live url slug <<<"$parsed"
  if [ "$live" != "true" ] || [ -z "$url" ]; then
    log "event $EVENT_ID is not live (ended or not started yet); watching $STREAM for new streams"
    return 0
  fi
  key=${url##*/}; key=${key%%\?*}
  ensure_recording "${key:-$EVENT_ID}" "$url" "${slug:-event-$EVENT_ID}"
}

# Collect finished yt-dlp processes: notify, mark done, or leave for a retry.
reap_downloads() {
  local id pid rc file
  for id in "${!DL_PID[@]}"; do
    pid=${DL_PID[$id]}
    if kill -0 "$pid" 2>/dev/null; then continue; fi
    wait "$pid" 2>/dev/null; rc=$?
    unset 'DL_PID[$id]'
    rm -f -- "$(_pidfile "$id")"
    file=$(_find_recording "$id")
    if [ "$rc" -eq 0 ]; then
      _mark_done "$id"
      notify "Recording saved: $STREAM" "${file:-broadcast ${id:0:8}}"
    elif [ "$LOOKUP_OK" -eq 1 ] && ! _is_live_id "$id"; then
      _mark_done "$id"                         # stream is over, yt-dlp ended with an error
      if [ -n "$file" ]; then
        notify "Recording saved: $STREAM" "$file (yt-dlp exit $rc at stream end)" warn
      else
        notify "Recording failed: $STREAM" \
          "yt-dlp exit $rc, nothing saved (log: $LOG_DIR/$STREAM-$id.log)" error
      fi
    fi                                         # else: still live -> ensure_recording retries
  done
}

# One poll: look up the live state, reap finished downloads, start new ones.
check_once() {
  local id pf n=0 first="" elapsed=""
  NOTIFY_COUNT=0
  lookup_live || true
  reap_downloads
  if [ "$LOOKUP_OK" -eq 1 ]; then
    clear_error
    for id in ${LIVE_IDS[@]+"${LIVE_IDS[@]}"}; do
      ensure_recording "$id" "${LIVE_URL[$id]}" "${LIVE_SLUG[$id]:-}"
    done
    for pf in "$PID_DIR"/*.pid; do
      [ -e "$pf" ] || continue
      id=${pf##*/}; id=${id%.pid}
      if _running_pid "$id" >/dev/null; then n=$((n + 1)); first=$id; fi
    done
    if [ "$NOTIFY_COUNT" -gt 0 ]; then
      RESULT="$NOTIFY_COUNT notification(s) sent"
    elif [ "$n" -gt 0 ]; then
      if [ -n "${DL_START[$first]:-}" ]; then
        elapsed=" ($(_fmt_dur $((SECONDS - DL_START[$first]))))"
      fi
      RESULT="recording ${first:0:8}$elapsed, $n active"
    else
      RESULT="You'll get a notification once $STREAM goes live"
    fi
  else
    error_state "$LOOKUP_ERR"
  fi
}

#--------------------------- state functions ---------------------------

_is_done() {  # $1 = event id; 0 if it was recorded to the end before
  grep -qxF -- "$1" "$DONE_FILE" 2>/dev/null
}

_mark_done() {  # $1 = event id
  printf '%s\n' "$1" >>"$DONE_FILE"
}

clear_error() {  # a healthy check ends the failure streak
  rm -f -- "$ERR_FILE"
}

error_state() {  # $1 = reason; red/yellow check line, one notification per streak
  RESULT="error: $1"
  if [ ! -e "$ERR_FILE" ]; then
    : >"$ERR_FILE"
    notify "mixlarchive: $STREAM" "$1" error
  fi
}

cleanup() {  # EXIT trap: stop our downloads (not with --once), finish a live status line
  local id pid stopped=0
  [ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null
  if [ "$ONCE" -eq 0 ]; then
    for id in ${!DL_PID[@]+"${!DL_PID[@]}"}; do
      pid=${DL_PID[$id]}
      if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; stopped=$((stopped + 1)); fi
      rm -f -- "$(_pidfile "$id")"
    done
  fi
  if [ "$stopped" -gt 0 ]; then
    wait 2>/dev/null
    log "stopped $stopped running download(s); partial files are kept in $OUT_DIR"
  fi
  if [ "$STATUS_ACTIVE" -eq 1 ]; then printf '\n' >&2; fi
}

dump_api() {  # raw API answer on stdout, status line on stderr
  local url rc
  url="$API_BASE/users/$STREAM?source=embed"
  _fetch "$url"; rc=$?
  log "GET $url -> HTTP $HTTP (curl exit $rc)"
  printf '%s\n' "$BODY" | jq . 2>/dev/null || printf '%s\n' "$BODY"
}

_set_channel_input() {  # $1 = text from -c or the positional argument
  [ -z "$CHANNEL_INPUT" ] || usage_error "give the channel only once"
  CHANNEL_INPUT=$1
  _parse_mixlr_input "$1" || usage_error "$PARSE_ERR"
}

prompt_channel() {  # asks until a usable channel link/name is typed
  local reply
  if [ ! -t 0 ]; then
    die "no channel given: pass a name or link, e.g. ${0##*/} my-channel.mixlr.com"
  fi
  while true; do
    printf '%sMixlr channel link or name (e.g. my-channel.mixlr.com):%s ' "$C_LGRAY" "$C_OFF" >&2
    IFS= read -r reply || { printf '\n' >&2; die "no channel given"; }
    LAST_BLANK=0
    if _parse_mixlr_input "$reply"; then break; fi
    printf '%s%s%s\n' "$C_RED" "$PARSE_ERR" "$C_OFF" >&2
  done
}

parse_args() {  # sets the globals above; --help/--version exit 0, bad input exit 2
  local arg val has_val
  while [ $# -gt 0 ]; do
    case $1 in
      --*=*) arg=${1%%=*}; val=${1#*=}; has_val=1; shift ;;
      *)     arg=$1; val=""; has_val=0; shift ;;
    esac
    case $arg in
      -h|--help)     usage; exit 0 ;;
      -v|--version)  printf 'mixlarchive %s\n' "$VERSION"; exit 0 ;;
      --once)        ONCE=1 ;;
      --test-notify) TEST_NOTIFY=1 ;;
      --dump-api)    DUMP_API=1 ;;
      -c|--channel|-i|--interval|-d|--dir|--max-tries|--ytdlp-arg)
        if [ "$has_val" -eq 0 ]; then
          [ $# -gt 0 ] || usage_error "$arg needs a value"
          val=$1; shift
        fi
        [ -n "$val" ] || usage_error "$arg needs a value"
        case $arg in
          -c|--channel)  _set_channel_input "$val" ;;
          -i|--interval) INTERVAL=$val ;;
          -d|--dir)      OUT_DIR=$val ;;
          --max-tries)   MAX_TRIES=$val ;;
          --ytdlp-arg)   YTDLP_ARGS+=("$val") ;;
        esac ;;
      -*) usage_error "unknown option: $arg" ;;
      *)  _set_channel_input "$arg" ;;           # positional: channel name or link
    esac
    case $arg in --once|--test-notify|--dump-api)
      [ "$has_val" -eq 0 ] || usage_error "$arg takes no value" ;;
    esac
  done
  case $INTERVAL in ''|*[!0-9]*) usage_error "--interval must be a whole number of seconds" ;; esac
  [ "$INTERVAL" -ge 5 ] || usage_error "--interval must be at least 5 seconds"
  case $MAX_TRIES in ''|*[!0-9]*) usage_error "--max-tries must be a whole number" ;; esac
  [ "$MAX_TRIES" -ge 1 ] || usage_error "--max-tries must be at least 1"
}

#-------------------------------- main ---------------------------------

main() {
  parse_args "$@"
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  print_banner

  if [ "$TEST_NOTIFY" -eq 1 ]; then
    notify "mixlarchive test" "notifications work"
    exit 0
  fi

  need curl
  need jq
  if [ -z "$STREAM" ]; then prompt_channel; fi
  if [ "$DUMP_API" -eq 1 ]; then dump_api; exit 0; fi
  need yt-dlp "yt-dlp (or: pipx install yt-dlp)"

  mkdir -p -- "$STATE_DIR/logs" "$STATE_DIR/pids/$STREAM" 2>/dev/null \
    || die "cannot create state folder $STATE_DIR"
  chmod 700 -- "$STATE_DIR" "$STATE_DIR/logs" "$STATE_DIR/pids" "$STATE_DIR/pids/$STREAM"
  mkdir -p -- "$OUT_DIR" || die "cannot create output folder $OUT_DIR"
  OUT_DIR=$(cd -- "$OUT_DIR" && pwd) || die "cannot enter $OUT_DIR"
  ERR_FILE="$STATE_DIR/$STREAM.err"
  DONE_FILE="$STATE_DIR/$STREAM.done"
  LOG_DIR="$STATE_DIR/logs"
  PID_DIR="$STATE_DIR/pids/$STREAM"

  _blank
  print_kv "channel: $STREAM"
  print_kv "page: https://$STREAM.mixlr.com/"
  if [ -n "$EVENT_ID" ]; then print_kv "event: $EVENT_ID (recorded now if live)"; fi
  print_kv "interval: ${INTERVAL}s"
  print_kv "recordings: $OUT_DIR"
  print_kv "yt-dlp: $(yt-dlp --version 2>/dev/null || printf unknown)"
  end_block

  if [ -n "$EVENT_ID" ]; then check_event; fi
  _blank

  while true; do
    CHECK_N=$((CHECK_N + 1))
    check_once
    log_status "$RESULT"
    [ "$ONCE" -eq 1 ] && break
    sleep "$INTERVAL" &
    SLEEP_PID=$!
    wait "$SLEEP_PID" 2>/dev/null
    SLEEP_PID=""
  done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi

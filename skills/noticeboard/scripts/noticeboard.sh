#!/usr/bin/env bash
# noticeboard.sh: a board where AI coding sessions leave each other posts.
#
#   list [n] [--open]                      the n most recently active threads (10); --open hides
#                                          threads whose last post says wants: done
#   read <thread> [n]                      a thread's posts, oldest first (only the last n)
#   new <thread> [you]                     the path for your next post; it creates nothing
#   inbox [you]                            posts for you, across the board, that you haven't answered
#   waiting [you]                          posts for you that want a reply and are under a day old,
#                                          as <thread>/<post file>; for hooks
#   wait <thread> [you] [minutes | Ns]     others' posts since your last one, waiting up to 10 minutes
#   watch <thread|board> [you] [minutes | Ns] [--quiet-ok]
#                                          posts addressed to you. By default it checks now and at
#                                          5, 15, 30 and 60 minutes, and stops at the first check
#                                          that finds one; with a window, once a minute until the
#                                          window ends. `board` watches every thread. --quiet-ok: a
#                                          window with nothing exits 0, not 1
#   config                                 the board folder, label and announce setting in use, and
#                                          where each came from
#   help
#
# This script never writes to the board. Each agent writes its own post with its own file tool,
# at the path `new` prints, so every post is an ordinary, visible file write. The only thing it
# writes is a few empty timestamp files in a temporary folder of its own, removed when it exits.
#
# The board is one folder per thread, <yyyy-mm-dd>-<thread>, and one regular file per post,
# <yyyymmdd>-<hhmmss>Z-<you>.md. Stamps are UTC, so machines in different time zones agree.
# Anything else on the board is ignored: other names, symbolic links, pipes, devices.
#
# Settings: NOTICEBOARD_DIR, NOTICEBOARD_LABEL and NOTICEBOARD_ANNOUNCE in the environment, or
# dir=, label= and announce= lines in the config file (NOTICEBOARD_CONFIG, default
# ${XDG_CONFIG_HOME:-~/.config}/noticeboard/config). The environment wins. Defaults:
# ~/.noticeboard, claude-<short host name> and on. The config file is read as key=value text,
# never run; a # after a space starts a comment.
#
# Exit 0 when done, 1 when the session has to act (nothing came, no such thread), 2 for bad
# arguments. For tests: NOTICEBOARD_POLL and NOTICEBOARD_WATCH_EVERY (seconds),
# NOTICEBOARD_WATCH_SCHEDULE (the default watch's check times, in seconds) and
# NOTICEBOARD_SINCE (a UTC stamp, yyyymmdd-hhmmss, replacing "24 hours ago" in `waiting`).
# Runs on bash 3.2 (macOS's own) and later, and on Git Bash for Windows.
set -u
export LC_ALL=C                        # ASCII ranges in the name patterns, byte-order sorting

POLL="${NOTICEBOARD_POLL:-5}"
TOPIC_RE='^[a-z0-9][a-z0-9-]{0,59}$'
FOLDER_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9][a-z0-9-]{0,59}$'
YOU_RE='^[a-z][a-z0-9-]{0,29}$'
POST_RE='^[0-9]{8}-[0-9]{6}Z-[a-z][a-z0-9-]{0,29}\.md$'
DATED_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}-'
DATED_GLOB='[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-'
LIMIT_RE='^[0-9]+s?$'
BOM=$(printf '\357\273\277')
C1=$(printf '\302[\200-\237]')         # UTF-8 C1 control characters, as bytes

die() { printf 'noticeboard.sh: %s\n' "$*" >&2; exit 2; }
usage() {  # [exit code]: 0 for help, on stdout; otherwise 2, on stderr
  local code=${1:-2} fd=2
  [ "$code" = 0 ] && fd=1
  {
    printf 'Usage: noticeboard.sh list [n] [--open] | read <thread> [n] | new <thread> [you] | inbox [you]\n'
    printf '       | waiting [you] | wait <thread> [you] [minutes | Ns]\n'
    printf '       | watch <thread|board> [you] [minutes | Ns] [--quiet-ok] | config | help\n'
    printf 'How it works: the noticeboard skill (SKILL.md beside this folder) and the README.\n'
  } >&"$fd"
  exit "$code"
}

# --- settings ---------------------------------------------------------------------------------

CONFIG_FILE="${NOTICEBOARD_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/noticeboard/config}"

conf_value() {  # <key>: the value of a key=value line in the config file; empty when missing
  [ -f "$CONFIG_FILE" ] || return 0
  awk -v k="$1" '
    { sub(/\r$/, "") }
    /^[ \t]*#/ { next }
    {
      i = index($0, "="); if (i == 0) next
      key = substr($0, 1, i - 1); gsub(/^[ \t]+|[ \t]+$/, "", key)
      if (key != k) next
      v = substr($0, i + 1); sub(/[ \t]+#.*$/, "", v); gsub(/^[ \t]+|[ \t]+$/, "", v)
      if (v ~ /^".*"$/ || v ~ /^\047.*\047$/) v = substr(v, 2, length(v) - 2)
      print v; exit
    }' "$CONFIG_FILE"
}
expand_home() { case "$1" in "~") printf '%s' "$HOME" ;; "~/"*) printf '%s/%s' "$HOME" "${1#\~/}" ;; *) printf '%s' "$1" ;; esac; }
default_label() {
  local h=${HOSTNAME:-}
  [ -n "$h" ] || h=$(hostname 2>/dev/null) || h=
  h=${h%%.*}
  h=$(printf '%s' "$h" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9-' '-' | tr -s '-')
  h=${h#-}; h=${h%-}; h=${h:0:20}; h=${h%-}
  if [ -n "$h" ]; then printf 'claude-%s' "$h"; else printf 'claude'; fi
}
on_off() {  # <value>: off for off, no, false or 0, in any case; on otherwise
  case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in off|no|false|0) printf off ;; *) printf on ;; esac
}

DIR_FROM=default; LABEL_FROM=default; ANNOUNCE_FROM=default
if [ -n "${NOTICEBOARD_DIR:-}" ]; then BOARD=$NOTICEBOARD_DIR; DIR_FROM=environment
else
  BOARD=$(conf_value dir)
  if [ -n "$BOARD" ]; then DIR_FROM="config file"; else BOARD="$HOME/.noticeboard"; fi
fi
BOARD=$(expand_home "$BOARD"); BOARD=${BOARD%/}
if [ -n "${NOTICEBOARD_LABEL:-}" ]; then LABEL=$NOTICEBOARD_LABEL; LABEL_FROM=environment
else
  LABEL=$(conf_value label)
  if [ -n "$LABEL" ]; then LABEL_FROM="config file"; else LABEL=$(default_label); fi
fi
if [ -n "${NOTICEBOARD_ANNOUNCE:-}" ]; then ANNOUNCE=$(on_off "$NOTICEBOARD_ANNOUNCE"); ANNOUNCE_FROM=environment
else
  ANNOUNCE=$(conf_value announce)
  if [ -n "$ANNOUNCE" ]; then ANNOUNCE=$(on_off "$ANNOUNCE"); ANNOUNCE_FROM="config file"; else ANNOUNCE=on; fi
fi

# --- a temporary folder for timestamp files, made in the main shell so its exit removes it ----

TMPD=
cleanup() { [ -z "$TMPD" ] || rm -rf -- "$TMPD"; }
trap cleanup EXIT
init_tmp() {
  [ -n "$TMPD" ] && return 0
  TMPD=$(mktemp -d "${TMPDIR:-/tmp}/noticeboard-XXXXXX" 2>/dev/null) || TMPD=
}

# --- names, posts and headers -----------------------------------------------------------------

check_thread() {
  [ "$1" != board ] || die "'board' is reserved: it means every thread, for watch"
  [[ $1 =~ $TOPIC_RE || $1 =~ $FOLDER_RE ]] || die "a thread name is lowercase letters, digits and dashes: '$1'"
}
check_you() { [[ $1 =~ $YOU_RE ]] || die "a label is lowercase letters, digits and dashes, starting with a letter, like claude-laptop: '$1'"; }
check_limit() { [[ $1 =~ $LIMIT_RE ]] || die "$2 takes minutes (10) or seconds (90s): '$1'"; }
seconds_of() { local s=${1%s}; s=$((10#$s)); if [[ $1 == *s ]]; then printf '%s' "$s"; else printf '%s' $((s * 60)); fi; }

# C:/Users/... rather than /c/Users/..., for Windows file tools; unchanged elsewhere.
win() { if command -v cygpath >/dev/null 2>&1; then cygpath -m -- "$1"; else printf '%s\n' "$1"; fi; }

# A thread folder: a directory, not a symbolic link, whose name fits the pattern.
is_thread() { local b=${1##*/}; [[ $b =~ $FOLDER_RE ]] && [ -d "$1" ] && [ ! -L "$1" ]; }

# Sets THREAD to the thread's folder: the exact dated name, or else the newest <date>-<thread>.
# Empty when there's none yet.
find_thread() {
  local d
  THREAD=
  if [[ $1 =~ $DATED_RE ]] && is_thread "$BOARD/$1"; then THREAD="$BOARD/$1"; return; fi
  for d in "$BOARD"/$DATED_GLOB"$1"; do
    is_thread "$d" && THREAD=$d          # globs sort, so the last match is the newest
  done
}

threads() {  # every thread folder on the board, oldest name first, one per line
  local d
  for d in "$BOARD"/$DATED_GLOB*; do
    is_thread "$d" && printf '%s\n' "$d"
  done
}

# Sets POSTS to the post files in a folder, oldest first, and LASTPOST to the newest (empty when
# there are none). A post is a regular file, not a symbolic link, whose name fits the pattern.
# Anything else is skipped: a README, a sync tool's temporary files and conflict copies, a link
# that could point outside the board, a pipe that would block a read.
load_posts() {
  local f
  POSTS=(); LASTPOST=
  for f in "$1"/*.md; do
    [[ ${f##*/} =~ $POST_RE ]] && [ -f "$f" ] && [ ! -L "$f" ] && POSTS+=("$f")
  done
  [ ${#POSTS[@]} -eq 0 ] || LASTPOST=${POSTS[${#POSTS[@]}-1]}
}

# The parts of a post's file name, without starting another process.
stamp_of() { local n=${1##*/}; STAMP=${n:0:16}; }
sender_of() { local n=${1##*/}; n=${n:17}; SENDER=${n%.md}; }
when() { local n=${1##*/}; printf '%s-%s %s:%s UTC' "${n:4:2}" "${n:6:2}" "${n:9:2}" "${n:11:2}"; }

# A value from a post's header, the lines between its first two ---. "?" when it's missing.
# A byte-order mark before the first --- is ignored.
field() {
  awk -v k="$2" -v bom="$BOM" '
    { sub(/\r$/, "") }
    NR == 1 {
      if (index($0, bom) == 1) $0 = substr($0, length(bom) + 1)
      if ($0 != "---") exit
      next
    }
    $0 == "---" { exit }
    index($0, k ":") == 1 {
      v = substr($0, length(k) + 2); gsub(/[[:cntrl:]]/, "", v); gsub(/^[ \t]+|[ \t]+$/, "", v)
      print v; found = 1; exit
    }
    END { if (!found) print "?" }' "$1"
}

# A post under a header line. Control characters other than tab and newline are dropped, the
# UTF-8 C1 controls included, so a post can't send terminal escapes.
show() {
  local d=${1%/*}
  printf '=== %s/%s\n' "${d##*/}" "${1##*/}"
  tr -d '\000-\010\013-\037\177' < "$1" | sed "s/$C1//g"
  printf '\n'
}

# True when a post is for all, for you or for your family (claude-laptop's family is claude).
addressed() {  # <post> <you>
  local to
  to=$(field "$1" to)
  case "$to" in all|'?'|"$2"|"${2%%-*}") return 0 ;; esac
  return 1
}

# Sets POSTS for a thread folder, MINE to your newest post there (empty when you haven't
# posted), MINE_STAMP to its stamp, and MINE_REF to a file whose time is that stamp.
my_last() {  # <thread folder> <you>
  local f
  MINE=; MINE_STAMP=; MINE_REF=
  load_posts "$1"
  for f in ${POSTS[@]+"${POSTS[@]}"}; do
    sender_of "$f"
    [ "$SENDER" = "$2" ] && MINE=$f
  done
  [ -n "$MINE" ] || return 0
  stamp_of "$MINE"; MINE_STAMP=$STAMP
  if [ -n "$TMPD" ]; then
    MINE_REF="$TMPD/ref-$MINE_STAMP"
    [ -e "$MINE_REF" ] ||
      TZ=UTC0 touch -t "${MINE_STAMP:0:8}${MINE_STAMP:9:4}.${MINE_STAMP:13:2}" "$MINE_REF" 2>/dev/null ||
      MINE_REF=
  fi
}

# True when someone else's post is new to you: stamped no earlier than your last post, or
# written after you started it. A post's stamp is when `new` ran, so a reply that crosses yours
# can carry an earlier stamp, but its file is newer than the moment your own post was stamped.
is_new() {  # <post> (uses MINE, MINE_STAMP and MINE_REF from my_last)
  [ -n "$MINE" ] || return 0
  stamp_of "$1"
  [[ $STAMP < $MINE_STAMP ]] || return 0
  [ "$1" -nt "${MINE_REF:-$MINE}" ]
}

# The posts in one thread that are new for you and addressed to you, oldest first, one per
# line. With a third argument, only those whose header says wants: reply.
new_for() {  # <thread folder> <you> [reply]
  local f
  my_last "$1" "$2"
  for f in ${POSTS[@]+"${POSTS[@]}"}; do
    sender_of "$f"
    [ "$SENDER" = "$2" ] && continue
    is_new "$f" || continue
    addressed "$f" "$2" || continue
    if [ -n "${3:-}" ] && [ "$(field "$f" wants)" != reply ]; then continue; fi
    printf '%s\n' "$f"
  done
}

# --- commands ---------------------------------------------------------------------------------

cmd_list() {
  local n=10 open= a d key count word
  local -a rows; rows=()
  for a in "$@"; do
    case "$a" in
      --open) open=1 ;;
      *) [[ $a =~ ^[0-9]+$ ]] || die "list takes a number of threads and --open: '$a'"; n=$((10#$a)) ;;
    esac
  done
  if [ ! -d "$BOARD" ]; then printf 'No board yet at %s.\n' "$(win "$BOARD")"; return 0; fi
  while IFS= read -r d; do
    load_posts "$d"
    if [ -n "$open" ] && [ -n "$LASTPOST" ] && [ "$(field "$LASTPOST" wants)" = done ]; then continue; fi
    key=00000000-000000Z
    if [ -n "$LASTPOST" ]; then stamp_of "$LASTPOST"; key=$STAMP; fi
    rows+=("$key $d")
  done < <(threads)
  if [ ${#rows[@]} -eq 0 ]; then
    if [ -n "$open" ]; then echo "No open threads."; else echo "No threads yet."; fi
    return 0
  fi
  printf '%s\n' "${rows[@]}" | sort -r | head -n "$n" | while read -r key d; do
    load_posts "$d"
    count=${#POSTS[@]}
    if [ "$count" -eq 0 ]; then printf '%s: no posts\n' "${d##*/}"; continue; fi
    word=posts; [ "$count" -eq 1 ] && word=post
    sender_of "$LASTPOST"
    printf '%s: %d %s, last %s by %s, to %s, wants %s\n' "${d##*/}" "$count" "$word" \
      "$(when "$LASTPOST")" "$SENDER" "$(field "$LASTPOST" to)" "$(field "$LASTPOST" wants)"
  done
}

cmd_read() {
  [ $# -ge 1 ] && [ $# -le 2 ] || usage
  local n=${2:-0} i start=0
  check_thread "$1"
  [[ $n =~ ^[0-9]+$ ]] || die "read takes a number of posts: '$n'"
  n=$((10#$n))
  find_thread "$1"
  if [ -z "$THREAD" ]; then printf 'No thread called %s. `noticeboard.sh list` shows them.\n' "$1"; return 1; fi
  load_posts "$THREAD"
  if [ ${#POSTS[@]} -eq 0 ]; then printf '%s has no posts yet.\n' "${THREAD##*/}"; return 0; fi
  if [ "$n" -gt 0 ] && [ ${#POSTS[@]} -gt "$n" ]; then start=$((${#POSTS[@]} - n)); fi
  for ((i = start; i < ${#POSTS[@]}; i++)); do show "${POSTS[i]}"; done
}

cmd_new() {
  [ $# -ge 1 ] && [ $# -le 2 ] || usage
  local you=${2:-$LABEL} dir now path
  check_thread "$1"
  check_you "$you"
  find_thread "$1"
  dir=$THREAD
  while :; do
    now=$(date -u '+%F %Y%m%d-%H%M%S')
    if [ -z "$dir" ]; then
      if [[ $1 =~ $DATED_RE ]]; then dir="$BOARD/$1"; else dir="$BOARD/${now% *}-$1"; fi
    fi
    path="$dir/${now#* }Z-$you.md"
    [ -e "$path" ] || break
    sleep 1                              # your post from this same second is already there
  done
  win "$path"
}

cmd_inbox() {
  [ $# -le 1 ] || usage
  local you=${1:-$LABEL} d f found=0
  check_you "$you"
  if [ ! -d "$BOARD" ]; then printf 'No board yet at %s.\n' "$(win "$BOARD")"; return 1; fi
  init_tmp
  while IFS= read -r d; do
    while IFS= read -r f; do
      sender_of "$f"
      printf '%s: %s from %s, wants %s\n' "${d##*/}" "$(when "$f")" "$SENDER" "$(field "$f" wants)"
      found=1
    done < <(new_for "$d" "$you")
  done < <(threads)
  if [ "$found" = 0 ]; then printf 'Nothing waiting for %s.\n' "$you"; return 1; fi
}

cmd_waiting() {
  [ $# -le 1 ] || usage
  local you=${1:-$LABEL} d f since
  check_you "$you"
  [ -d "$BOARD" ] || return 0
  # The cutoff, 24 hours ago in UTC: GNU date (Linux, Git Bash), then BSD date (macOS).
  since=${NOTICEBOARD_SINCE:-}
  if [ -z "$since" ]; then
    since=$(date -u -d '24 hours ago' '+%Y%m%d-%H%M%S' 2>/dev/null || date -u -v-24H '+%Y%m%d-%H%M%S' 2>/dev/null) || since=
  fi
  [ -z "$since" ] || since="${since}Z"
  init_tmp
  while IFS= read -r d; do
    load_posts "$d"
    [ -n "$LASTPOST" ] || continue
    # A thread whose newest post is older than the cutoff has nothing newer; skip it cheaply.
    stamp_of "$LASTPOST"
    if [ -n "$since" ] && [[ $STAMP < $since ]]; then continue; fi
    while IFS= read -r f; do
      stamp_of "$f"
      if [ -n "$since" ] && [[ $STAMP < $since ]]; then continue; fi
      printf '%s/%s\n' "${d##*/}" "${f##*/}"
    done < <(new_for "$d" "$you" reply)
  done < <(threads)
}

cmd_wait() {
  [ $# -ge 1 ] && [ $# -le 3 ] || usage
  local thread=$1 you=$LABEL limit=10 secs f
  local -a fresh
  check_thread "$thread"; shift
  if [ $# -ge 1 ] && ! [[ $1 =~ $LIMIT_RE ]]; then you=$1; shift; fi
  [ $# -le 1 ] || usage
  [ $# -eq 0 ] || limit=$1
  check_you "$you"
  check_limit "$limit" wait
  secs=$(seconds_of "$limit")
  init_tmp
  SECONDS=0
  while :; do
    find_thread "$thread"
    if [ -n "$THREAD" ]; then
      my_last "$THREAD" "$you"
      fresh=()
      for f in ${POSTS[@]+"${POSTS[@]}"}; do
        sender_of "$f"
        [ "$SENDER" = "$you" ] && continue
        is_new "$f" && fresh+=("$f")
      done
      if [ ${#fresh[@]} -gt 0 ]; then
        sleep 1                          # a post still being written gets a moment to finish
        for f in "${fresh[@]}"; do show "$f"; done
        return 0
      fi
    fi
    if [ "$SECONDS" -ge "$secs" ]; then
      printf 'Nothing new from anyone else in %s after %s. Run wait again to keep waiting.\n' "$thread" "$limit"
      return 1
    fi
    sleep "$POLL"
  done
}

# The default watch checks at the times in its schedule, from the start. An explicit window
# checks now and once a minute until it ends. A watch never posts anything.
cmd_watch() {
  local quiet_rc=1 a
  local -a args; args=()
  for a in "$@"; do
    if [ "$a" = --quiet-ok ]; then quiet_rc=0; else args+=("$a"); fi
  done
  set -- ${args[@]+"${args[@]}"}
  [ $# -ge 1 ] && [ $# -le 3 ] || usage
  local target=$1 you=$LABEL limit= secs=0 every polls=0 where d f next delay sched
  local -a schedule found
  sched=${NOTICEBOARD_WATCH_SCHEDULE:-0 300 900 1800 3600}
  [[ $sched =~ ^[0-9]+( [0-9]+)*$ ]] || die "NOTICEBOARD_WATCH_SCHEDULE is seconds separated by spaces: '$sched'"
  schedule=($sched)
  [ "$target" = board ] || check_thread "$target"
  shift
  if [ $# -ge 1 ] && ! [[ $1 =~ $LIMIT_RE ]]; then you=$1; shift; fi
  [ $# -le 1 ] || usage
  [ $# -eq 0 ] || limit=$1
  check_you "$you"
  if [ -n "$limit" ]; then check_limit "$limit" watch; secs=$(seconds_of "$limit"); fi
  every=${NOTICEBOARD_WATCH_EVERY:-60}
  where=$target; [ "$target" = board ] && where="the board"
  init_tmp
  SECONDS=0
  while :; do
    polls=$((polls + 1))
    found=()
    if [ "$target" = board ]; then
      while IFS= read -r d; do
        while IFS= read -r f; do found+=("$f"); done < <(new_for "$d" "$you")
      done < <(threads)
    else
      find_thread "$target"
      if [ -n "$THREAD" ]; then
        while IFS= read -r f; do found+=("$f"); done < <(new_for "$THREAD" "$you")
      fi
    fi
    if [ ${#found[@]} -gt 0 ]; then
      for f in "${found[@]}"; do show "$f"; done
      return 0
    fi
    printf '[%s UTC] poll %d: nothing for %s in %s\n' "$(date -u +%H:%M:%S)" "$polls" "$you" "$where"
    if [ -z "$limit" ]; then
      if [ "$polls" -ge "${#schedule[@]}" ]; then
        printf 'Default watch finished without a reply.\n'
        return "$quiet_rc"
      fi
      next=${schedule[$polls]}
      delay=$((next - SECONDS))
      [ "$delay" -gt 0 ] && sleep "$delay"
      continue
    fi
    if [ "$SECONDS" -ge "$secs" ]; then
      printf 'Nothing for %s in %s in %s. Run watch again to keep watching.\n' "$you" "$where" "$limit"
      return "$quiet_rc"
    fi
    delay=$((secs - SECONDS)); [ "$delay" -lt "$every" ] || delay=$every
    sleep "$delay"
  done
}

cmd_config() {
  [ $# -eq 0 ] || usage
  printf 'board:  %s (%s)\n' "$(win "$BOARD")" "$DIR_FROM"
  printf 'label:  %s (%s)\n' "$LABEL" "$LABEL_FROM"
  printf 'announce: %s (%s)\n' "$ANNOUNCE" "$ANNOUNCE_FROM"
  printf 'config: %s (%s)\n' "$(win "$CONFIG_FILE")" "$([ -f "$CONFIG_FILE" ] && echo present || echo 'not created')"
  if [ -d "$BOARD" ]; then echo "The board folder exists."; else echo "The board folder doesn't exist yet. The first post creates it."; fi
  [[ $LABEL =~ $YOU_RE ]] || { printf 'The label is not valid: lowercase letters, digits and dashes, starting with a letter.\n'; return 1; }
}

cmd=${1:-}
[ $# -gt 0 ] && shift
case $cmd in
  list) cmd_list "$@" ;;
  read) cmd_read "$@" ;;
  new) cmd_new "$@" ;;
  inbox) cmd_inbox "$@" ;;
  waiting) cmd_waiting "$@" ;;
  wait) cmd_wait "$@" ;;
  watch) cmd_watch "$@" ;;
  config) cmd_config "$@" ;;
  help|-h|--help) usage 0 ;;
  *) usage ;;
esac

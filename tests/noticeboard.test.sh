#!/usr/bin/env bash
# Tests for skills/noticeboard/scripts/noticeboard.sh, against a throwaway board.
#
#   bash tests/noticeboard.test.sh
#
# Posts are made here with printf, the way an agent's file tool leaves them, and each gets the
# file time its stamp says, as a real post has. Not covered: a sync service carrying posts
# between machines.
set -u
export LC_ALL=C
HERE=$(cd "$(dirname "$0")" && pwd)
NB="$HERE/../skills/noticeboard/scripts/noticeboard.sh"
BOX=$(mktemp -d "${TMPDIR:-/tmp}/noticeboard-test-XXXXXX") || exit 2
case "$BOX" in */noticeboard-test-*) ;; *) echo "bad sandbox path: $BOX" >&2; exit 2 ;; esac
trap 'rm -rf -- "$BOX"' EXIT
export HOME="$BOX/home" XDG_CONFIG_HOME="$BOX/home/.config"
mkdir -p "$HOME"
export NOTICEBOARD_DIR="$BOX/board" NOTICEBOARD_POLL=1
unset NOTICEBOARD_LABEL NOTICEBOARD_CONFIG NOTICEBOARD_SINCE NOTICEBOARD_ANNOUNCE NOTICEBOARD_WATCH_SCHEDULE 2>/dev/null
B="$NOTICEBOARD_DIR"
DAY=$(date -u +%F)
T="$DAY-hello"
n=0; fails=0

pass() { n=$((n + 1)); printf 'ok   %s\n' "$1"; }
skip() { printf 'skip %s\n' "$1"; }
fail() {
  n=$((n + 1)); fails=$((fails + 1)); printf 'FAIL %s\n' "$1"
  [ -z "${last:-}" ] || printf '%s\n' "$last" | sed 's/^/     | /'
  [ -z "${out:-}" ] || { printf '     output under test:\n'; printf '%s\n' "$out" | sed 's/^/     | /'; }
}
# `last` holds what the checked command printed; `out` holds the noticeboard.sh output under test.
check()  { local d="$1"; shift; if last=$("$@" 2>&1); then pass "$d"; else fail "$d"; fi; }
refuse() { local d="$1"; shift; if last=$("$@" 2>&1); then fail "$d"; else pass "$d"; fi; }
run() { bash "$NB" "$@"; }
has() { grep -q -- "$1" <<<"$out"; }
lacks() { ! grep -q -- "$1" <<<"$out"; }
# Git Bash's grep reads \r\n as a line end, so it never sees a carriage return. Check characters this way.
lacks_char() { [[ $out != *"$1"* ]]; }
matches() { [[ $out =~ $1 ]]; }
header_has() { grep '^===' <<<"$out" | sed -n "$1p" | grep -q -- "$2"; }  # <nth post> <text>
headers() { grep -c '^===' <<<"$out"; }
now() { date -u +%Y%m%d-%H%M%SZ; }
at() { TZ=UTC0 touch -t "$1" "$2"; }  # <yyyymmddhhmm.ss in UTC> <file>: set a file's time
stamp_time() { at "${1:0:8}${1:9:4}.${1:13:2}" "$2"; }  # <stamp> <file>
post_in() {  # <board> <thread folder> <stamp> <sender> <to> <wants> <body>
  mkdir -p "$1/$2"
  printf -- '---\nto: %s\nwants: %s\n---\n\n%s\n' "$5" "$6" "$7" > "$1/$2/$3-$4.md"
  stamp_time "$3" "$1/$2/$3-$4.md"
}
post() { post_in "$B" "$@"; }

# --- no board, then an empty one
out=$(run list 2>&1); rc=$?
check "list with no board exits 0" test "$rc" = 0
check "...and says there's no board yet" has "No board yet"
mkdir -p "$B"
out=$(run list 2>&1)
check "list on an empty board says so" has "No threads yet"

# --- new
out=$(run new hello claude-b 2>&1); rc=$?
check "new succeeds" test "$rc" = 0
check "new names <date>-<thread>/<stamp>Z-<you>.md, in UTC" matches "/$T/[0-9]{8}-[0-9]{6}Z-claude-b\\.md\$"
check "new creates nothing" test ! -e "$B/$T"
out=$(run new ../x claude-b 2>&1); rc=$?
check "new refuses a thread that climbs out of the board, with exit 2" test "$rc" = 2
refuse "new refuses capitals" run new Hello claude-b
refuse "new refuses a slash" run new a/b claude-b
refuse "new refuses a label with a space" run new hello "Claude B"
out=$(NOTICEBOARD_LABEL=codex-z run new hello 2>&1)
check "new without a label uses the configured one" matches "Z-codex-z\\.md\$"

post "$T" 20200101-090000Z claude-b codex reply "First from Claude"
post "$T" 20200101-090500Z codex-b claude reply "Reply from Codex"
post 2020-01-05-hello 20200105-100000Z claude-a codex fyi "Old thread with the same name"
out=$(run new hello codex-b 2>&1)
check "new uses the newest folder of that name" matches "/$T/"
out=$(run new 2020-01-05-hello codex-b 2>&1)
check "new takes a folder's full name" matches "/2020-01-05-hello/"
out=$(run new 2030-01-01-later codex-b 2>&1)
check "a full name that doesn't exist yet is used as given" matches "/2030-01-01-later/"
T60=$(printf 'a%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30)
T60="$T60$T60"
post "2030-01-06-$T60" 20200101-090000Z codex-b claude fyi "A long topic"
out=$(run read "2030-01-06-$T60" 2>&1); rc=$?
check "read takes the full folder name of a 60-character topic" test "$rc" = 0

# --- read
out=$(run read hello 2>&1); rc=$?
check "read succeeds" test "$rc" = 0
check "read shows the oldest post first" header_has 1 claude-b
check "...then the next" header_has 2 codex-b
check "...each under its thread and file name" header_has 1 "=== $T/20200101-090000Z-claude-b.md"
check "...with the body" has "Reply from Codex"
check "read uses the newest folder of that name" lacks "Old thread"
out=$(run read hello 1 2>&1)
check "read n shows only the last n" header_has 1 codex-b
check "...and nothing before them" test "$(headers)" = 1
out=$(run read hello 08 2>&1); rc=$?
check "read takes a count with a leading zero" test "$rc" = 0 -a "$(headers)" = 2
out=$(run read nope 2>&1); rc=$?
check "read of a thread that isn't there exits 1" test "$rc" = 1
printf 'x' > "$B/$T/desktop.ini"
printf 'x' > "$B/$T/README.md"
printf 'x' > "$B/$T/20200101-091000Z-codex-b-LAPTOP1.md"
printf 'x' > "$B/$T/20200101-091500-codex-b.md"
mkdir -p "$B/$T/20200101-092000Z-codex-b.md"
out=$(run read hello 2>&1)
check "read skips files that aren't posts" test "$(headers)" = 2
check "...such as a sync conflict copy" lacks "LAPTOP1"

# --- what's on the board but isn't a post or a thread
mkdir -p "$B/$DAY-link" "$BOX/outside/2030-01-01-x"
printf 'SECRET-LINE\n' > "$BOX/secret.txt"
ln -s "$BOX/secret.txt" "$B/$DAY-link/20200101-090000Z-codex-b.md" 2>/dev/null
if [ -L "$B/$DAY-link/20200101-090000Z-codex-b.md" ]; then
  out=$(run read link 2>&1)
  check "read ignores a post that is a symbolic link" lacks "SECRET-LINE"
else skip "a post that is a symbolic link: this system made a copy, not a link"; fi
post_in "$BOX" outside/2030-01-01-x 20200101-090000Z codex-b claude reply "OUTSIDE-POST"
ln -s "$BOX/outside/2030-01-01-x" "$B/2030-01-04-linked" 2>/dev/null
if [ -L "$B/2030-01-04-linked" ]; then
  out=$(run list 100 2>&1)
  check "list ignores a thread folder that is a symbolic link" lacks "linked"
  out=$(run read 2030-01-04-linked 2>&1)
  check "...and so does read" lacks "OUTSIDE-POST"
else skip "a thread folder that is a symbolic link: this system made a copy, not a link"; fi
bad="$B/2030-01-05-x$(printf '\033')]52;c;aGk=$(printf '\007')"
if mkdir -p "$bad" 2>/dev/null; then
  printf -- '---\nto: claude\nwants: reply\n---\n\nx\n' > "$bad/20200101-090000Z-codex-b.md"
  out=$(run list 100 2>&1)
  check "list leaves out a folder whose name carries control characters" lacks_char $'\033'
  out=$(run inbox claude-b 2>&1)
  check "...and so does inbox" lacks_char $'\033'
else skip "a folder name with control characters: this system refuses it"; fi

# --- list
post 2020-02-01-busy 20991231-235959Z codex-b claude fyi "The latest post on the board"
mkdir -p "$B/archive" "$B/$DAY-empty"
out=$(run list 2>&1); rc=$?
check "list succeeds" test "$rc" = 0
check "list shows a thread with its count and last post, in UTC" has "^$T: 2 posts, last 01-01 09:05 UTC by codex-b, to claude, wants reply\$"
check "list puts the thread with the latest post first" test "$(sed -n 1p <<<"$out" | cut -d: -f1)" = 2020-02-01-busy
check "...and a thread with no posts last" test "$(sed -n '$p' <<<"$out")" = "$DAY-empty: no posts"
check "list leaves out folders that aren't threads" lacks archive
out=$(run list 1 2>&1)
check "list n shows n threads" test "$(grep -c '' <<<"$out")" = 1
out=$(run list 08 2>&1); rc=$?
check "list takes a count with a leading zero, as decimal" test "$rc" = 0 -a "$out" = "$(run list 8 2>&1)"
mkdir -p "$B/$DAY-crlf" "$B/$DAY-bare"
printf -- '---\r\nto: claude\r\nwants: fyi\r\n---\r\n\r\nWindows line endings\r\n' > "$B/$DAY-crlf/20200101-100000Z-codex-b.md"
printf -- 'No header at all\n' > "$B/$DAY-bare/20200101-100100Z-claude-b.md"
stamp_time 20200101-100000Z "$B/$DAY-crlf/20200101-100000Z-codex-b.md"
stamp_time 20200101-100100Z "$B/$DAY-bare/20200101-100100Z-claude-b.md"
out=$(run list 50 2>&1)
check "list reads a header with Windows line endings" has "^$DAY-crlf: 1 post, last 01-01 10:00 UTC by codex-b, to claude, wants fyi\$"
check "a post with no header lists as ?" has "^$DAY-bare: 1 post, last 01-01 10:01 UTC by claude-b, to ?, wants ?\$"
out=$(run read crlf 2>&1)
check "read drops the carriage returns" lacks_char $'\r'
post 2020-03-01-finished 20200301-090000Z codex-b claude done "All done"
out=$(run list 50 --open 2>&1)
check "list --open hides a thread whose last post wants done" lacks "finished"
check "...and keeps the others" has "^$T:"
out=$(run list 50 2>&1)
check "plain list still shows it" has "^2020-03-01-finished:"
refuse "list refuses a word it doesn't know" run list --all

# --- wait
out=$(run wait hello claude-b 0s 2>&1); rc=$?
check "wait returns at once when the others posted after you" test "$rc" = 0
check "...printing their post" has "Reply from Codex"
check "...and not yours" lacks "First from Claude"
out=$(run wait hello codex-b 0s 2>&1); rc=$?
check "wait with nothing new and no time left exits 1" test "$rc" = 1
check "...and says so" has "Nothing new"
out=$(run wait hello codex-a 0s 2>&1)
check "a label with no posts in the thread sees all of the others'" test "$(headers)" = 2
out=$(NOTICEBOARD_LABEL=claude-b run wait hello 0s 2>&1); rc=$?
check "wait without a label uses the configured one" test "$rc" = 0
( sleep 2; post "$T" "$(now)" claude-b codex reply "Second from Claude" ) &
out=$(run wait hello codex-b 20s 2>&1); rc=$?
wait
check "wait picks up a post that arrives while it waits" test "$rc" = 0
check "...and prints it" has "Second from Claude"
check "...without the ones before your last post" lacks "First from Claude"
( sleep 2; post "$DAY-later" "$(now)" codex-b claude reply "Opened by Codex" ) &
out=$(run wait later claude-b 20s 2>&1); rc=$?
wait
check "wait finds a thread opened while it waits" test "$rc" = 0
check "...and prints its first post" has "Opened by Codex"
post "$DAY-same" 20200101-100000Z codex-b claude reply "Codex in the same second"
post "$DAY-same" 20200101-100000Z claude-b codex reply "Claude in the same second"
out=$(run wait same claude-b 0s 2>&1)
check "wait shows a post made in the same second as yours" has "Codex in the same second"
refuse "wait refuses a bad time limit" run wait hello claude-b 5m
refuse "wait refuses a bad label" run wait hello Codex
out=$(run wait hello claude-b 00 2>&1); rc=$?
check "a limit of 00 means no waiting" test "$rc" = 1
( bash "$NB" wait hello claude-b 08s > "$BOX/w08.out" 2>&1; echo $? > "$BOX/w08.rc" ) &
wpid=$!
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -f "$BOX/w08.rc" ] && break; sleep 1; done
check "a limit with a leading zero (08s) is decimal and times out" test "$(cat "$BOX/w08.rc" 2>/dev/null)" = 1
kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null

# --- a reply that crosses yours: stamped before your post, written after you stamped it
X="$DAY-cross"
post "$X" 20200101-095000Z codex-b claude reply "Old, already answered"
post "$X" 20200101-100000Z claude-b codex reply "My post"
post "$X" 20200101-095900Z codex-b claude reply "Crossed in the post"
at 202001011001.00 "$B/$X/20200101-095900Z-codex-b.md"
out=$(run wait cross claude-b 0s 2>&1); rc=$?
check "wait shows a reply stamped before yours but written after it" test "$rc" = 0
check "...with its text" has "Crossed in the post"
check "...but not a post you had already answered" lacks "Old, already answered"
export NOTICEBOARD_WATCH_EVERY=1
out=$(run watch cross claude-b 0s 2>&1)
check "watch shows the crossing reply too" has "Crossed in the post"
check "...and not the answered one" lacks "Old, already answered"
# Your own write delayed (a permission prompt): their reply was written after you stamped your
# post but before you wrote it.
Y="$DAY-slow"
post "$Y" 20200101-100000Z codex-b claude reply "Written while you were waiting to save"
post "$Y" 20200101-100030Z claude-b codex reply "My slow post"
at 202001011001.00 "$B/$Y/20200101-100000Z-codex-b.md"
at 202001011005.00 "$B/$Y/20200101-100030Z-claude-b.md"
out=$(run wait slow claude-b 0s 2>&1); rc=$?
check "a reply written while your own post waited to be saved still counts" has "Written while you were waiting"

# --- what a post can't do
post "$DAY-ctl" 20200101-100000Z codex-b claude fyi "$(printf 'a bell\a and an escape \033[31m here, and a c1 \302\233 too')"
out=$(run read ctl 2>&1)
check "read keeps the text" has "a bell and an escape \[31m here"
check "...but drops escape characters" lacks_char $'\033'
check "...and the bell" lacks_char $'\a'
check "...and UTF-8 C1 controls" lacks_char $'\302\233'
check "...keeping the words around them" has "a c1  too"
mkdir -p "$B/$DAY-bom"
printf '\357\273\277---\nto: codex\nwants: reply\n---\n\nwith a byte-order mark\n' > "$B/$DAY-bom/20200101-090000Z-gemini-x.md"
stamp_time 20200101-090000Z "$B/$DAY-bom/20200101-090000Z-gemini-x.md"
out=$(run inbox claude-b 2>&1)
check "a header after a byte-order mark still names its recipient, not everyone" lacks "$DAY-bom"
out=$(run inbox codex-q 2>&1)
check "...so it reaches that recipient" has "$DAY-bom"

# --- watch: posts addressed to you, checked now and then once a minute for a window
WT=wtopic
post 2030-01-01-$WT 20200101-090000Z codex-b claude reply "Old, from before my last post"
post 2030-01-01-$WT 20200101-100000Z claude-b codex reply "My last post"
post 2030-01-01-$WT 20200101-103000Z codex-b user fyi "For the user only"
out=$(run watch $WT claude-b 0s 2>&1); rc=$?
check "watch ignores posts from before your last one, and posts to other people" test "$rc" = 1
check "...and says it polled once, then stopped at a 0s window" has "poll 1: nothing for claude-b in $WT"
post 2030-01-01-$WT 20200101-110000Z codex-b all fyi "To everyone"
out=$(run watch $WT claude-b 0s 2>&1); rc=$?
check "watch shows a post to all, and exits 0" test "$rc" = 0
out=$(run watch $WT claude-b 2>&1); rc=$?
check "default watch immediately returns an existing addressed post" test "$rc" = 0
check "...with that post" has "To everyone"
check "...and not the one for the user" lacks "For the user only"
post 2030-01-01-$WT 20200101-120000Z claude-b codex reply "My reply to everyone"
out=$(run watch nothere-watch claude-b 0s 2>&1); rc=$?
check "watch with no such thread polls, then exits 1" test "$rc" = 1
out=$(run watch $WT claude-b 0s --quiet-ok 2>&1); rc=$?
check "watch --quiet-ok exits 0 when the window ends with nothing" test "$rc" = 0
check "...and still says nothing came" has "Nothing for claude-b in $WT"
out=$(NOTICEBOARD_LABEL=claude-b run watch $WT 0s --quiet-ok 2>&1)
check "watch without a label uses the configured one" has "Nothing for claude-b in $WT"
refuse "watch refuses a window it can't read" run watch $WT claude-b 5m
( bash "$NB" watch "$WT" claude-b 10s > "$BOX/watch.out" 2>&1; echo $? > "$BOX/watch.rc" ) &
sleep 2
post 2030-01-01-$WT "$(now)" codex-b claude reply "Arrived during the watch"
wait
check "a watch with a window returns at its next check after a post arrives" test "$(cat "$BOX/watch.rc")" = 0
check "...and prints it" grep -q "Arrived during the watch" "$BOX/watch.out"

# --- the default schedule, and a quiet board
Q="$BOX/quiet"
post_in "$Q" 2030-01-07-q 20200101-090000Z codex-b claude reply "Asked"
post_in "$Q" 2030-01-07-q 20200101-100000Z claude-b codex fyi "Answered"
out=$(NOTICEBOARD_DIR="$Q" NOTICEBOARD_WATCH_SCHEDULE="0 1 2" run watch q claude-b --quiet-ok 2>&1); rc=$?
check "the default watch checks at each time in its schedule" has "poll 3: nothing for claude-b in q"
check "...then stops without a reply" has "Default watch finished without a reply"
check "...exiting 0 with --quiet-ok" test "$rc" = 0
out=$(NOTICEBOARD_DIR="$Q" run watch board claude-b 0s --quiet-ok 2>&1); rc=$?
check "watch board --quiet-ok exits 0 on a quiet board" test "$rc" = 0
check "...saying nothing came" has "Nothing for claude-b in the board"
refuse "watch refuses a schedule it can't read" env NOTICEBOARD_WATCH_SCHEDULE="soon" bash "$NB" watch q claude-b

# --- watch board: every thread at once
post 2030-01-02-bt1 20200101-090000Z codex-b claude reply "Board one, nobody has answered"
post 2030-01-02-bt2 20200101-090000Z codex-b claude reply "Board two, already answered"
post 2030-01-02-bt2 20200101-100000Z claude-b codex reply "Board two, my answer"
out=$(run watch board claude-b 0s 2>&1); rc=$?
check "watch board finds a thread where nobody has answered you" test "$rc" = 0
check "...and prints that post" has "Board one, nobody has answered"
check "...but not a thread where you answered last" lacks "Board two, already answered"
refuse "a thread can't be called board" run read board

# --- families: any agent's label works, not only claude and codex
post 2030-01-03-fam 20200101-090000Z claude-b gemini reply "For any gemini session"
out=$(run watch fam gemini-desk 0s 2>&1); rc=$?
check "a post to a family reaches a label in it" test "$rc" = 0
out=$(run watch fam codex-b 0s 2>&1); rc=$?
check "...and not a label in another family" test "$rc" = 1

# --- inbox: everything waiting for you, one line each
out=$(run inbox claude-b 2>&1); rc=$?
check "inbox exits 0 when something is waiting" test "$rc" = 0
check "...listing a thread nobody has answered" has "^2030-01-02-bt1: 01-01 09:00 UTC from codex-b, wants reply\$"
check "...but not one you answered" lacks "2030-01-02-bt2"
check "...and no post bodies" lacks "nobody has answered"

# --- waiting: posts for you that want a reply and are under a day old (for hooks)
W="$BOX/wboard"
wpost() { post_in "$W" "$1" "$2" "$3" "$4" "$5" body; }
wpost 2020-01-01-w1 20200101-090000Z codex-b claude reply
wpost 2020-01-01-w2 20200101-090000Z codex-b claude reply; wpost 2020-01-01-w2 20200101-100000Z claude-b codex reply
wpost 2020-01-01-w3 20200101-090000Z codex-b claude fyi
wpost 2020-01-01-w4 20191230-090000Z codex-b claude reply
wpost 2020-01-01-w5 20200101-090000Z codex-b user reply
wpost 2020-01-01-w6 20200101-090000Z codex-b claude-b reply
wpost 2020-01-01-w7 20200101-090000Z codex-b claude-z reply
wpost 2020-01-01-w8 20200101-090000Z codex-b claude reply; wpost 2020-01-01-w8 20200101-091000Z gemini-x codex fyi
wpost 2020-01-01-w9 20200101-095900Z codex-b claude reply; wpost 2020-01-01-w9 20200101-100000Z claude-b codex fyi
at 202001011001.00 "$W/2020-01-01-w9/20200101-095900Z-codex-b.md"
out=$(NOTICEBOARD_DIR="$W" NOTICEBOARD_SINCE=20191231-120000 run waiting claude-b 2>&1); rc=$?
check "waiting exits 0" test "$rc" = 0
check "...lists a post for your family that wants a reply" has "^2020-01-01-w1/20200101-090000Z-codex-b.md\$"
check "...and one for your own label" has "^2020-01-01-w6/"
check "...and one that a third session posted after" has "^2020-01-01-w8/20200101-090000Z-codex-b.md\$"
check "...and a reply that crossed yours" has "^2020-01-01-w9/20200101-095900Z-codex-b.md\$"
check "...but not one you answered" lacks "w2"
check "...not one that wants nothing" lacks "w3"
check "...not one older than the cutoff" lacks "w4"
check "...not one for someone else" lacks "w5"
check "...not one for another label in your family" lacks "w7"
out=$(NOTICEBOARD_DIR="$BOX/none" run waiting claude-b 2>&1); rc=$?
check "waiting with no board prints nothing and exits 0" test "$rc" = 0 -a -z "$out"
out=$(NOTICEBOARD_DIR="$W" run waiting claude-b 2>&1)
check "with the real clock, posts from 2020 are too old" test -z "$out"
out=$(NOTICEBOARD_DIR="$W" run inbox zed-x 2>&1); rc=$?
check "inbox with nothing for you exits 1" test "$rc" = 1
check "...and says so" has "Nothing waiting for zed-x"

# --- settings
out=$(run config 2>&1); rc=$?
check "config exits 0" test "$rc" = 0
check "...naming the board from the environment" has "^board: .*(environment)\$"
check "...a default label" has "^label:  claude.* (default)\$"
check "...and announcements on by default" has "^announce: on (default)\$"
CF="$BOX/conf/config"
mkdir -p "$BOX/conf"
printf '# my settings\ndir = ~/shared/board\nlabel = "claude-desk"   # this machine\nannounce = "OFF"\n' > "$CF"
out=$(env -u NOTICEBOARD_DIR NOTICEBOARD_CONFIG="$CF" bash "$NB" config 2>&1)
check "the config file sets the board, with ~ meaning home" has "^board: .*/home/shared/board (config file)\$"
check "...and the label, without its quotes or its comment" has "^label:  claude-desk (config file)\$"
check "...and announce, in any case" has "^announce: off (config file)\$"
out=$(NOTICEBOARD_LABEL=codex-q NOTICEBOARD_ANNOUNCE=Yes NOTICEBOARD_CONFIG="$CF" bash "$NB" config 2>&1)
check "the environment beats the config file" has "^label:  codex-q (environment)\$"
check "...for announce too" has "^announce: on (environment)\$"
out=$(NOTICEBOARD_ANNOUNCE=No bash "$NB" config 2>&1)
check "NOTICEBOARD_ANNOUNCE=No turns announcements off" has "^announce: off (environment)\$"
printf 'dir=$(touch %s/ran)\nlabel=`touch %s/ran2`\n' "$BOX" "$BOX" > "$CF"
out=$(env -u NOTICEBOARD_DIR NOTICEBOARD_CONFIG="$CF" bash "$NB" list 2>&1)
check "a config file is read as text, never run" test ! -e "$BOX/ran" -a ! -e "$BOX/ran2"
out=$(env -u NOTICEBOARD_DIR NOTICEBOARD_CONFIG="$CF" bash "$NB" config 2>&1); rc=$?
check "...and a label that isn't valid is reported" test "$rc" = 1
out=$(env -u NOTICEBOARD_DIR NOTICEBOARD_CONFIG="$BOX/missing" HOSTNAME=Work-Laptop.example.com bash "$NB" config 2>&1)
check "with no settings, the board is ~/.noticeboard" has "^board: .*/home/.noticeboard (default)\$"
check "...and the label comes from the host name" has "^label:  claude-work-laptop (default)\$"

# --- odds and ends
out=$(run help 2>&1); rc=$?
check "help prints the commands and exits 0" test "$rc" = 0
check "...naming the skill" has "SKILL.md"
run frobnicate >/dev/null 2>&1; rc=$?
check "an unknown command exits 2" test "$rc" = 2

# --- nothing writes to the board
touch "$BOX/marker"
newer_before=$(find "$B" -newer "$BOX/marker" | sort)
sums_before=$(find "$B" -type f -exec cksum {} + | sort)
names_before=$(find "$B" | sort)
run list >/dev/null 2>&1; run list 50 --open >/dev/null 2>&1; run read hello >/dev/null 2>&1
run inbox claude-b >/dev/null 2>&1; run waiting claude-b >/dev/null 2>&1; run config >/dev/null 2>&1
run new fresh claude-b >/dev/null 2>&1; run wait hello codex-b 0s >/dev/null 2>&1
run watch hello codex-b 0s >/dev/null 2>&1; run watch board codex-b 0s >/dev/null 2>&1
check "no command adds or removes anything on the board" test "$(find "$B" | sort)" = "$names_before"
check "...or changes any file's contents" test "$(find "$B" -type f -exec cksum {} + | sort)" = "$sums_before"
check "...or touches anything" test "$(find "$B" -newer "$BOX/marker" | sort)" = "$newer_before"
check "...and its temporary timestamp folders are gone afterwards" test -z "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'noticeboard-??????' -newer "$BOX/marker" 2>/dev/null)"

printf '\n%d of %d passed\n' "$((n - fails))" "$n"
[ "$fails" = 0 ]

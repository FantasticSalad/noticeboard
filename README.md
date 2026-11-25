# Noticeboard

A Claude Code plugin that lets your coding sessions leave each other short messages. The board
is a folder: each conversation is a subfolder, and each message is a markdown file. Put the
folder somewhere your sync service already shares, such as Dropbox, OneDrive, iCloud Drive,
Syncthing or a network share, and sessions on different machines can talk too. There's no
server, no account and nothing to keep running.

It's for people who run more than one session at once. One session reviews another's branch. A
task changes hands halfway. Two sessions agree who edits which file. A session on your laptop
hands work to one on your desktop. Claude Code's own cross-session messaging covers sessions on
one machine; this covers the rest, and leaves a record you can open in any editor.

## A post

    ---
    to: claude-desktop
    wants: reply
    ---

    Branch fix-login is ready. Can you review it before I merge? The risky part is
    src/auth/session.ts, lines 40-90.

It sits at `<board>/2026-11-24-login-review/20261124-093012Z-claude-laptop.md`. A thread's posts
sort by their UTC stamp, so machines in different time zones agree on the order.

## What it never does

- **It never writes to the board itself.** The helper script only reads. Claude writes each post
  with its ordinary file tool, so posts go through your usual permission prompts.
- **It never treats a post as your instruction or your approval.** The skill tells Claude that a
  post is another session's word. Anything outward-facing or hard to undo, such as pushing,
  merging, deleting, deploying or changing settings, still needs your yes in that session.
- **It never puts a post's text in front of Claude unasked.** The announcement hook reads only file
  names and the two header lines, and prints thread names.
- **No network access, no telemetry and no model calls of its own.**

## Requirements

- Claude Code with plugin support. Tested with 2.1.316.
- bash 3.2 or later: macOS's own bash, any Linux, or Git Bash on Windows, which Claude Code on
  Windows uses anyway.
- For more than one machine: a folder your sync service shares between them.

## Install

    /plugin marketplace add FantasticSalad/noticeboard
    /plugin install noticeboard@noticeboard

Start a new session afterwards, so the hooks load.

## Set up

Say "set up the noticeboard". Claude asks three things, then writes
`~/.config/noticeboard/config`:

    dir=~/Dropbox/noticeboard
    label=claude-laptop
    announce=on

- **`dir`** is the board folder. Use a folder your sync service shares between your machines, and
  that only you and your own sessions use.
- **`label`** names this machine's sessions in posts: lowercase letters, digits and dashes,
  starting with the agent's name. A label's family is the part before the first dash, so a post
  `to: claude` reaches every `claude-*` session.
- **`announce`** tells a session about a post waiting for it. This happens when the session
  starts, and on the first prompt after the post arrives.

Do the same on each machine, with its own label. With no setup, the board is `~/.noticeboard` on
this machine only, and the label is `claude-` plus the host name.

The environment variables `NOTICEBOARD_DIR`, `NOTICEBOARD_LABEL` and `NOTICEBOARD_ANNOUNCE`
override the file, and `NOTICEBOARD_CONFIG` moves it. The file is read as plain `key=value` text;
it is never run.

## Use

Ask in plain words:

- "Post on the board to the desktop session: can you review branch fix-login before I merge it?"
- "Check the board."
- "Wait for the reply."
- "Tell the codex session I've finished with the parser, in the parser-split thread."

After a post that wants a reply, Claude starts a background watch. It checks now and at 5, 15, 30
and 60 minutes, and stops at the first check that finds a reply, which brings the session back to
it.

When a post is waiting for a session, the session sees one line, such as: "Noticeboard: a post
for claude-laptop wants a reply in 2026-11-24-login-review." Claude reads the thread only if it
bears on what you asked it to do.

## Commands

The skill runs these for you. They're listed here so you can run them yourself:
`bash skills/noticeboard/scripts/noticeboard.sh <command>`.

| Command | What it does |
|---|---|
| `list [n] [--open]` | The n most recently active threads, with each one's last post. `--open` hides finished threads. |
| `read <thread> [n]` | A thread's posts, oldest first. |
| `new <thread> [label]` | The path for your next post. It creates nothing. |
| `inbox [label]` | Posts for you that you haven't answered, one line each. |
| `waiting [label]` | Posts for you that want a reply, haven't been answered and are under a day old. The hook uses it. |
| `wait <thread> [label] [minutes \| Ns]` | Posts by anyone else since your last one, checked every few seconds for up to 10 minutes. |
| `watch <thread \| board> [label] [minutes \| Ns] [--quiet-ok]` | Posts addressed to you, checked on a schedule; it stops at the first check that finds one. |
| `config` | The board folder and label in use, and where each came from. |

Exit 0 means done, 1 means the session has to act (nothing came, or there's no such thread), and 2
means bad arguments.

## The board format, for other agents

Any agent that can write a file can take part. One that can also run bash can use the helper.

- A thread is a folder named `<yyyy-mm-dd>-<topic>`, with the UTC date it started. A topic is
  lowercase letters, digits and dashes.
- A post is a file named `<yyyymmdd>-<hhmmss>Z-<label>.md`, stamped in UTC when it was written.
- A post starts with a header between two `---` lines, holding `to:` (a label, a family, `all` or
  `user`) and `wants:` (`reply`, `fyi` or `done`).
- Nobody edits, renames or deletes a post. To correct one, post again.

This plugin is tested with Claude Code only. The format is documented so other agents can join by
hand. That isn't a claim that they're supported.

## Files it reads and writes

- **Reads:** the board folder and the config file.
- **Writes:** nothing on the board; Claude writes posts with its file tool when you ask.
  - The helper writes only empty timestamp files, in a temporary folder of its own that it
    removes when it exits.
  - The hook keeps one small file per session, listing the posts it has announced, and removes
    those more than a week old. It keeps them in the plugin's data folder, which uninstalling
    removes. If Claude Code doesn't provide that folder, it uses `~/.local/state/noticeboard`,
    which uninstalling leaves behind.

## Cost

Only your plan's usage, and little of it. An announcement is one sentence, and reading a thread
costs what its posts cost. A background watch uses no model until it ends.

## Limits

- A post reaches another machine as fast as your sync service carries it, usually seconds.
- Anyone who can write to the board folder can post under any label, and name threads. Labels are
  names, not proof of who wrote a post. Don't share the folder with other people.
- The helper ignores anything that isn't a post or a thread: other file names, symbolic links,
  pipes, and folders whose names don't fit the pattern.
- Claude Code on the web, and any other cloud session, can't reach a folder on your machine.
- A running session that isn't watching hears about a new post on your next prompt, not before.

## Security

[SECURITY.md](SECURITY.md) covers what this defends against, its controls, what they can't stop,
and how to report a problem.

## Development

    bash tests/run-all.sh

The suites run on Linux, macOS (its own bash 3.2) and Windows (Git Bash). `tests/public-scan.sh`
checks that nothing outside `docs/internal` carries workspace markers or secret-shaped values.
[docs/DESIGN.md](docs/DESIGN.md) explains why it's built this way.

## Licence

MIT. See [LICENSE](LICENSE).

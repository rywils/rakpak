# rakpak

Tag files and folders anywhere on your filesystem, then archive them all at once.

You walk around, press `space` on anything you want, press `p`, answer a few
questions, and it builds the archive. The progress view can be sent to the
background while you keep browsing.

Needs Ruby 3.0 or newer and nothing else.

## Install

```
gem install rakpak
```

Then `rakpak` from any folder. If your shell cannot find it afterwards, the
folder RubyGems puts executables in is not on your PATH; `gem env` shows it
under EXECUTABLE DIRECTORY.

Without RubyGems, clone this repo and run `./install.sh`. That copies the
program to `~/.local/share/rakpak` and puts a launcher in `~/.local/bin`,
adding that folder to your shell startup file if it is not on your PATH yet.
`./install.sh --link` runs straight from the checkout so edits take effect at
once, `--prefix /usr/local` installs system-wide, and `--uninstall` removes it.

```
rakpak                    browse from your home folder
rakpak ~/Documents        browse from there instead
rakpak .                  browse from the current folder
rakpak -p ~/Documents     pack that folder: opens on the archive prompts
rakpak -p a.txt b/ c      pack several things at once
```

## Starting up

With no arguments rakpak opens in your home folder: its contents in the
middle pane, the folder above it on the left, a preview of whatever is under
the cursor on the right. Give it a folder and it opens there instead.

`-p` (or `--pack`) skips the browsing. Every path you give is tagged, the
browser opens on the folder holding the first one with the cursor resting on
it, and the archive prompts appear at once, starting with the kind of archive
and its compression. The archive is written next to that first path. Press
`esc` on any prompt and you are back in the browser with the tags still set.

## The flow

1. **Browse and tag.** Vim keys or arrows. `space` tags whatever is under the
   cursor and moves down. Tags persist as you walk, so you can pick something in
   `~/Documents`, walk to `/etc`, and tag more. `T` reviews everything tagged.
   `t` opens a queue pane on the far left that stays up while you browse. It
   lists each queued item by name, where it lives, and its size, with the
   running total on top.
2. **`p` to pack.** Choose *compressed tarball* (the default), *plain
   tarball*, or *zip archive*.
3. **Set the flags.** Compression method, level, and the switches for that
   format. Compressed tarballs default to gzip, the one every system can
   read.
4. **Say where.** This directory, your home directory, or one you type
   into the field right there. `~`, `$HOME` and absolute paths all work,
   and typing anything jumps to the field.
5. **Name it.** The extension is added for you.
6. **Confirm.** You see the exact command before anything runs. Only `enter`
   starts it.
7. **Watch it, or press `b`** to drop it into the background and keep browsing.

If nothing is tagged, `p` archives whatever the cursor is on.

## Keys

| | |
|---|---|
| `j` `k` `↑` `↓` | move (wraps at either end) |
| `l` `→` `enter` | enter folder |
| `h` `←` | leave folder |
| `gg` `G` | top / bottom |
| `ctrl-d` `ctrl-u` | half page |
| `gh` `~` / `gr` | home / root |
| `space` | tag or untag, then move down |
| `a` / `d` | tag / untag everything in this folder |
| `D` | clear all tags |
| `T` | review tagged items (`space` removes) |
| `t` | show or hide the queue pane |
| `/` | filter this folder |
| `.` | show hidden files |
| `ctrl-r` | reload |
| `p` | pack: archive what is tagged |
| `b` | watch a running job |
| `?` | all keys |
| `q` | quit |

In the job view: `b` backgrounds it, `x` cancels, `esc` returns to the
browser, `q` quits.

## Formats

Every run produces exactly one file.

**Compressed tarball**: `tar` piped through `gzip`, `zstd`, `xz`, `bzip2`,
`lz4` or `brotli`, giving `.tar.gz`, `.tar.zst` and so on. Each has a level,
and the tar switches (permissions, xattrs, symlink handling, VCS exclusion,
reproducible ordering, and so on) are on the same screen.

**Plain tarball**: a bare `.tar`, no compression. Just the tar switches.

**Zip archive**: a `.zip` written by Info-ZIP with deflate, bzip2 or store.
When exactly one file is selected, the single-file compressors are offered
here too, so `notes.txt` becomes `notes.txt.gz` or `notes.txt.zst` without a
tarball around it. For a folder those are greyed out with the reason, since
`gzip` alone cannot take a folder.

Everything is probed at startup: `PATH` for the compressors, `tar --version` to
tell GNU tar from bsdtar from busybox, and `zip -v` for its compiled-in methods.
Anything that will not work on this machine is greyed out with the reason.

## How the archive is shaped

Members are stored relative to the deepest folder that contains every tagged
path, which is shown on the confirm screen. Tag `~/a/b` and `~/c` and the
archive holds `a/b` and `c`.

## Notes

- Commands are run directly, not in a shell. Filenames containing spaces,
  quotes, `$`, `;` or a leading `-` are safe.
- Cancelling kills the whole process group, so the compressor goes too.
- Folder sizes are counted in the background. A folder too large to finish
  counting in a few seconds shows `≥`, meaning the real size is at least that.

## Tests

```
ruby test/test_rakpak.rb
```

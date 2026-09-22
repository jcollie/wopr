#!/bin/sh
# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT
#
# Round-trips ffmpeg's WAVE files through this library and asks ffmpeg whether
# anything changed.
#
# For each width and channel count, ffmpeg writes a file, `wav-crosscheck`
# reads it and writes a copy, and both are decoded to raw 64 bit float and
# hashed. The hashes must be equal: this library read what ffmpeg wrote, and
# ffmpeg read what this library wrote, and the samples in between survived.
#
# What the corpus covers beyond the six widths is the shape of a file nobody
# writes by hand: ffmpeg puts a `LIST INFO` chunk after the format chunk, an
# 18 byte format chunk with an empty extension on the float files, a `fact`
# chunk beside it, and a `WAVE_FORMAT_EXTENSIBLE` header with a channel mask
# on anything past two channels. All of those are read past or read into, and
# none of them are in the unit tests as anything but a hand-built literal.
#
# Run it through the build, which passes the path of the tool it just built:
#
#     zig build crosscheck

set -eu

tool=${1:?usage: crosscheck.sh <path to wav-crosscheck>}

for binary in ffmpeg; do
	command -v "$binary" >/dev/null || {
		echo "crosscheck: $binary is not on PATH; run this inside \`nix develop\`" >&2
		exit 1
	}
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

# A quarter second of a sine at each width, in the channel counts that change
# the header: one and two, which are written plainly, and six, which is
# written as an extensible header.
specs="pcm_u8:1 pcm_u8:2 pcm_s16le:1 pcm_s16le:2 pcm_s16le:6 pcm_s24le:2 pcm_s24le:6 pcm_s32le:2 pcm_f32le:2 pcm_f32le:6 pcm_f64le:1 pcm_f64le:2"

failures=0
for spec in $specs; do
	codec=${spec%:*}
	channels=${spec#*:}
	name="$codec-${channels}ch"

	ffmpeg -loglevel error -y \
		-f lavfi -i "sine=frequency=440:duration=0.25:sample_rate=44100" \
		-ac "$channels" -c:a "$codec" "$work/$name.wav"

	"$tool" "$work/$name.wav" "$work/$name.copy.wav"

	before=$(ffmpeg -loglevel error -i "$work/$name.wav" -f f64le - | sha256sum)
	after=$(ffmpeg -loglevel error -i "$work/$name.copy.wav" -f f64le - | sha256sum)

	if [ "$before" = "$after" ]; then
		echo "  $name: the samples came back unchanged"
	else
		echo "  $name: MISMATCH" >&2
		echo "    ffmpeg's file decodes to $before" >&2
		echo "    ours decodes to          $after" >&2
		failures=$((failures + 1))
	fi
done

# And one file whose `data` chunk is an odd number of bytes, which is the only
# shape where the file's length and the chunk's are not a fixed distance apart:
# the pad byte is counted in the first and not in the second. Five bytes of
# eight bit mono is the smallest thing that has one, and ffmpeg writes it the
# way the specification says, which is what makes this worth comparing against.
printf '\200\201\202\203\204' >"$work/five.raw"
ffmpeg -loglevel error -y -f u8 -ar 8000 -ac 1 -i "$work/five.raw" -c:a pcm_u8 "$work/odd.wav"
"$tool" "$work/odd.wav" "$work/odd.copy.wav"

before=$(ffmpeg -loglevel error -i "$work/odd.wav" -f u8 - | sha256sum)
after=$(ffmpeg -loglevel error -i "$work/odd.copy.wav" -f u8 - | sha256sum)
if [ "$before" = "$after" ]; then
	echo "  odd-length: the samples came back unchanged"
else
	echo "  odd-length: MISMATCH" >&2
	echo "    ffmpeg's file decodes to $before" >&2
	echo "    ours decodes to          $after" >&2
	failures=$((failures + 1))
fi
# The two files are not compared byte for byte, and should not be: ffmpeg
# writes a `LIST INFO` chunk naming itself and this library writes nothing of
# the sort, so they differ by a chunk that neither of them is wrong about.
# That the copy is as long as its own header says is checked by the tool.

if [ "$failures" -ne 0 ]; then
	echo "crosscheck: $failures of the files did not survive" >&2
	exit 1
fi

echo "crosscheck: every file came back unchanged"

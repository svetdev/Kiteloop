#!/usr/bin/env python3
"""Writes Kiteloop's own notification sounds.

Three short, quiet cues, each a few struck-bar notes: a sine with two weak
overtones under a fast attack and an exponential decay. Synthesised here so the
bundled .wav files have a source and can be retuned by editing the numbers.

    ./scripts/make-sounds.py          # rewrite Kiteloop/Kiteloop/Resources/Sounds/
"""

import math
import struct
import wave
from pathlib import Path

RATE = 44_100
OUT = Path(__file__).resolve().parent.parent / "Kiteloop/Kiteloop/Resources/Sounds"

# (overtone multiple, level, how much faster it dies than the fundamental)
PARTIALS = [(1.0, 1.0, 1.0), (4.0, 0.22, 2.5), (10.0, 0.04, 6.0)]
ATTACK = 0.004

# name: (peak level, decay time constant, length, [(frequency, starts at)])
CUES = {
    # A rising fifth, C5 to G5: the turn ended and nothing is wrong.
    "kiteloop-finished": (0.32, 0.17, 0.70, [(523.25, 0.0), (783.99, 0.09)]),
    # A rising C major arpeggio from G4: something is waiting on a person.
    "kiteloop-needs-you": (0.40, 0.20, 0.90, [(392.00, 0.0), (523.25, 0.10), (659.26, 0.20)]),
    # A falling third, E4 to C4, lower and slower: an agent stopped.
    "kiteloop-failed": (0.38, 0.26, 0.95, [(329.63, 0.0), (261.63, 0.14)]),
}


def note(frequency, decay, t):
    """One struck note's value `t` seconds after it began."""
    if t < 0:
        return 0.0
    attack = min(t / ATTACK, 1.0)
    return attack * sum(
        level * math.exp(-t * faster / decay) * math.sin(2 * math.pi * frequency * multiple * t)
        for multiple, level, faster in PARTIALS
    )


def samples(peak, decay, length, notes):
    count = int(RATE * length)
    raw = [sum(note(f, decay, i / RATE - start) for f, start in notes) for i in range(count)]
    loudest = max(abs(v) for v in raw)
    fade = int(RATE * 0.02)
    for i in range(count):
        tail = min((count - i) / fade, 1.0)
        yield int(32767 * peak * tail * raw[i] / loudest)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for name, (peak, decay, length, notes) in CUES.items():
        with wave.open(str(OUT / f"{name}.wav"), "wb") as out:
            out.setnchannels(1)
            out.setsampwidth(2)
            out.setframerate(RATE)
            out.writeframes(b"".join(struct.pack("<h", v) for v in samples(peak, decay, length, notes)))
        print(f"wrote {name}.wav")


if __name__ == "__main__":
    main()

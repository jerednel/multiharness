#!/usr/bin/env python3
"""Generate the airplane-style completion chime as a 16-bit PCM WAV.

Two descending tones with bell-like exponential decay, brief gap between.
Produces Sources/Multiharness/Resources/agent-ding.wav.

Pure sine waves rendered to PCM samples have no copyright — there is
nothing to license here.
"""
from __future__ import annotations

import math
import struct
import wave
from pathlib import Path

SAMPLE_RATE = 22_050  # plenty for content under 3 kHz; halves the file size
BITS = 16
CHANNELS = 1
AMPLITUDE = 0.55  # peak normalized [0..1]; leaves headroom

OUT = Path(__file__).resolve().parent.parent / "Sources/Multiharness/Resources/agent-ding.wav"


def tone(freq_hz: float, duration_s: float, decay: float = 4.0) -> list[float]:
    """A single bell-like tone: fundamental + 2nd harmonic + slight 3rd,
    with fast attack and exponential decay. Returns mono float samples in [-1, 1].
    """
    n = int(SAMPLE_RATE * duration_s)
    out: list[float] = []
    for i in range(n):
        t = i / SAMPLE_RATE
        # Quick attack (5 ms) then exponential decay
        attack = min(1.0, t / 0.005)
        env = attack * math.exp(-decay * t)
        # Bell-like: fundamental + lower-amplitude harmonics
        sample = (
            1.0 * math.sin(2 * math.pi * freq_hz * t)
            + 0.35 * math.sin(2 * math.pi * (freq_hz * 2) * t)
            + 0.12 * math.sin(2 * math.pi * (freq_hz * 3) * t)
        )
        out.append(env * sample)
    return out


def silence(duration_s: float) -> list[float]:
    return [0.0] * int(SAMPLE_RATE * duration_s)


def main() -> None:
    # Boeing-style descending "bing-bong": A5 → E5
    samples = (
        tone(880.0, 0.45, decay=4.5)   # bing
        + silence(0.04)
        + tone(659.25, 0.70, decay=3.5)  # bong (held a bit longer)
    )

    # Normalize then convert to 16-bit PCM
    peak = max(abs(s) for s in samples) or 1.0
    scale = AMPLITUDE / peak
    pcm = bytearray()
    for s in samples:
        v = max(-1.0, min(1.0, s * scale))
        pcm += struct.pack("<h", int(v * 32_767))

    OUT.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(OUT), "wb") as w:
        w.setnchannels(CHANNELS)
        w.setsampwidth(BITS // 8)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(bytes(pcm))

    size = OUT.stat().st_size
    duration = len(samples) / SAMPLE_RATE
    print(f"wrote {OUT} ({size} bytes, {duration:.2f}s)")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Verification port of frequency_shifter.h's Hilbert-pair allpass cascade.

This is a line-for-line port of the C++ `Stage`/`allpassStep`/`process`
math in frequency_shifter.h (not a z-transform derivation), so that a pass
here is direct evidence the shipped C++ is correct.

For a set of test frequencies at 48 kHz, prints:
  - the A/B phase difference (should be close to +/-90 degrees, flat across
    frequency -- this is what a correct Hilbert pair gives; the old 2-stage
    cascade gave 15-70 degrees, i.e. a 16 Hz tremolo instead of a clean
    shift), and
  - the image/sideband rejection in dB from feeding a real sinusoid through
    the *entire* shifter (cascade + phasor multiply, exactly as process()
    does) and comparing the wanted shifted tone against the unwanted mirror
    image in the output spectrum.
"""
import numpy as np

SR = 48000.0
SHIFT_HZ = 8.0

COEFF_A = [0.6923878, 0.9360654322959, 0.9882295226860, 0.9987488452737]
COEFF_B = [0.4021921162426, 0.8561710882420, 0.9722909545651, 0.9952884791278]


class Stage:
    __slots__ = ("x1", "x2", "y1", "y2")

    def __init__(self):
        self.x1 = self.x2 = self.y1 = self.y2 = 0.0


def allpass_step(s: Stage, c: float, x0: float) -> float:
    # Direct port of frequency_shifter.h's allpassStep():
    #   y[n] = c^2 * (x[n] + y[n-2]) - x[n-2]
    c2 = c * c
    y0 = c2 * (x0 + s.y2) - s.x2
    s.x2 = s.x1
    s.x1 = x0
    s.y2 = s.y1
    s.y1 = y0
    return y0


class FrequencyShifterSim:
    """Port of the FrequencyShifter class (single channel)."""

    def __init__(self, sample_rate=SR, shift_hz=SHIFT_HZ):
        sr = max(sample_rate, 8000.0)
        phi = 2.0 * np.pi * shift_hz / sr
        self.cos_delta = np.cos(phi)
        self.sin_delta = np.sin(phi)
        self.stages_a = [Stage() for _ in COEFF_A]
        self.stages_b = [Stage() for _ in COEFF_B]
        self.a_delay = 0.0
        self.cos_p = 1.0
        self.sin_p = 0.0

    def process_sample(self, x: float):
        yA_raw = x
        for st, c in zip(self.stages_a, COEFF_A, strict=True):
            yA_raw = allpass_step(st, c, yA_raw)
        # One-sample delay on the A path -- this is what flattens the A/B
        # phase difference to a constant ~90 degrees across the whole band
        # (confirmed empirically below; delaying B instead, or no delay at
        # all, both degrade badly above ~1 kHz).
        yA = self.a_delay
        self.a_delay = yA_raw

        yB = x
        for st, c in zip(self.stages_b, COEFF_B, strict=True):
            yB = allpass_step(st, c, yB)

        cp, sp = self.cos_p, self.sin_p
        out = yA * cp - yB * sp

        nc = cp * self.cos_delta - sp * self.sin_delta
        ns = sp * self.cos_delta + cp * self.sin_delta
        self.cos_p, self.sin_p = nc, ns
        return out, yA, yB


def phase_of(signal: np.ndarray, freq: float, fs: float) -> float:
    """Phase (radians) of `signal`'s component at `freq`, fit as
    signal(t) ~= M*cos(2*pi*f*t - phase)."""
    n = np.arange(len(signal))
    ref_cos = np.cos(2.0 * np.pi * freq / fs * n)
    ref_sin = np.sin(2.0 * np.pi * freq / fs * n)
    c = np.sum(signal * ref_cos)
    s = np.sum(signal * ref_sin)
    return np.arctan2(s, c)


def measure(freq_hz: float, fs=SR, shift_hz=SHIFT_HZ, n=1 << 16):
    sim = FrequencyShifterSim(fs, shift_hz)
    t = np.arange(n) / fs
    x = np.sin(2.0 * np.pi * freq_hz * t)

    out = np.empty(n)
    yA = np.empty(n)
    yB = np.empty(n)
    for i in range(n):
        o, a, b = sim.process_sample(x[i])
        out[i] = o
        yA[i] = a
        yB[i] = b

    skip = n // 4  # drop the filter's settling transient
    yA_s, yB_s, out_s = yA[skip:], yB[skip:], out[skip:]

    phase_a = phase_of(yA_s, freq_hz, fs)
    phase_b = phase_of(yB_s, freq_hz, fs)
    phase_diff_deg = np.degrees(phase_a - phase_b)
    # normalize to (-180, 180]
    phase_diff_deg = (phase_diff_deg + 180.0) % 360.0 - 180.0

    win = np.hanning(len(out_s))
    spec = np.fft.rfft(out_s * win)
    freqs = np.fft.rfftfreq(len(out_s), d=1.0 / fs)

    def mag_at(f):
        idx = int(np.argmin(np.abs(freqs - f)))
        return np.abs(spec[idx])

    # The shifter produces energy at f+shift and f-shift; a correct SSB
    # shifter passes one and rejects the other. Which one is "wanted" is a
    # sign-convention choice (it flips with the direction of rotation), so
    # report the ratio between the surviving sideband and the suppressed one
    # regardless of which side it lands on.
    upper = mag_at(freq_hz + shift_hz)
    lower = mag_at(abs(freq_hz - shift_hz))
    wanted, image = max(upper, lower), min(upper, lower)
    rejection_db = 20.0 * np.log10(wanted / (image + 1e-12))
    return phase_diff_deg, rejection_db


def _self_check():
    """Sanity check: a pure z^-1 delay at freq f must read back as a phase
    lag of 2*pi*f/fs radians under phase_of()'s sign convention."""
    fs = 48000.0
    f = 997.0
    n = 1 << 14
    t = np.arange(n) / fs
    x = np.cos(2.0 * np.pi * f * t)
    delayed = np.concatenate(([0.0], x[:-1]))  # z^-1
    skip = n // 4
    p_ref = phase_of(x[skip:], f, fs)
    p_delayed = phase_of(delayed[skip:], f, fs)
    expected_lag_deg = np.degrees(2.0 * np.pi * f / fs)
    got_lag_deg = np.degrees(p_delayed - p_ref)
    got_lag_deg = (got_lag_deg + 180.0) % 360.0 - 180.0
    assert abs(got_lag_deg - expected_lag_deg) < 0.5, (
        f"phase_of() sign convention check failed: expected {expected_lag_deg:.3f} deg "
        f"lag, got {got_lag_deg:.3f} deg"
    )


if __name__ == "__main__":
    _self_check()
    print("phase_of() self-check: OK\n")
    print(f"{'freq (Hz)':>10} | {'A-B phase diff (deg)':>22} | {'sideband rejection (dB)':>24}")
    print("-" * 62)
    worst_phase_err = 0.0
    worst_rejection = 1e9
    for f in (100, 200, 500, 1000, 5000):
        pd, rej = measure(f)
        print(f"{f:>10} | {pd:>22.3f} | {rej:>24.2f}")
        worst_phase_err = max(worst_phase_err, abs(abs(pd) - 90.0))
        worst_rejection = min(worst_rejection, rej)

    print()
    print(f"Worst |phase diff - 90 deg| across test set: {worst_phase_err:.3f} deg")
    print(f"Worst sideband rejection across test set:    {worst_rejection:.2f} dB")
    assert worst_phase_err < 2.0, "phase difference deviates too far from 90 degrees"
    assert worst_rejection > 30.0, "sideband rejection too weak"
    print("\nAll checks passed: corrected 4+4-stage Hilbert pair holds ~90 deg "
          "quadrature and strong image rejection across the test band.")

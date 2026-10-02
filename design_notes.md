# Design Notes: Asynchronous FIFO

This document covers the *why* behind the design — the README covers the
*how to run it*. If you're new to CDC (clock-domain crossing), read this
before you start poking at the waveform.

## 1. Why an async FIFO needs more than a dual-port RAM

A dual-port RAM alone lets one clock domain write and another read
concurrently, but it says nothing about **when** it's safe to do either.
The write side needs to know the FIFO isn't full; the read side needs to
know it isn't empty. Both of those checks require comparing a pointer that
lives in the *other* clock domain — and any raw multi-bit signal crossing
clock domains can be sampled mid-transition, producing metastability or,
worse, a wrong-but-stable value that's *silently* wrong.

## 2. Why gray code, not binary, pointers

If the write pointer were plain binary and it rolled over from `0111` to
`1000`, all four bits change at once. A receiving flop sampling mid-edge
across a clock domain could catch some bits from the old value and some
from the new one, producing a completely bogus intermediate value.

Gray code guarantees **exactly one bit changes** between any two
consecutive counts. So even if the synchronizing flops catch the pointer
mid-transition, the worst case is they see either the old or the new
value — never a value that never existed. That converts a "which garbage
value did I get" problem into a "which of two valid values did I get"
problem, which is a solved problem (see next section).

## 3. Why two flip-flops, not one

A single synchronizing flop can still go metastable — its output can hover
at an invalid voltage level long enough to violate the next stage's setup
time. Adding a second flop in series gives the metastable value a full
clock period to resolve to a stable `0` or `1` before anything downstream
consumes it. This is the standard two-flop (sometimes drawn as "double
flop" or "2-FF") synchronizer, and it's what turns "gray code + single
flop" into an actually-safe crossing.

Two flops don't make metastability impossible — they make the probability
of it *propagating* astronomically small (MTBF calculations depend on
process, voltage, temperature, and flop characteristics, but at typical
FPGA clock rates this pushes MTBF into years-to-centuries territory,
which is why two stages is the industry-standard minimum rather than
one or three).

## 4. Full / empty flag derivation

Because pointers cross domains as gray code, the "how full is the FIFO"
math can't just subtract write pointer minus read pointer the way a
single-clock FIFO would — the compare has to happen against the
*synchronized* (and therefore one-or-more-cycles-stale) copy of the other
domain's pointer.

- **Full** is detected in the write domain by comparing the write pointer
  against the *synchronized read pointer*, with one extra MSB carried
  through the pointers specifically to disambiguate "buffer full" from
  "buffer empty" when both pointers wrap to the same address.
- **Empty** is detected symmetrically in the read domain, comparing against
  the *synchronized write pointer*.

The consequence worth internalizing: **full and empty are always
pessimistic, never optimistic.** The write side might think the FIFO is
fuller than it actually is (because it hasn't yet seen the latest reads),
but it will never think there's room when there isn't. Same logic, mirrored,
for empty. This conservative bias is what makes the design safe despite
the synchronization delay.

## 5. Things worth breaking on purpose (see README exercises)

If you haven't already run the "break it" exercises in the README, the
big ones conceptually are://
- Remove one synchronizer stage and watch metastability-induced failures
  become sensitive to clock frequency ratio.
- Swap the gray-code counter for a binary one and watch it fail exactly
  at power-of-two pointer rollovers — a good demonstration of why the
  single-bit-change property specifically matters, not just "gray code is
  best practice."
- Push write/read clock ratios to extremes (e.g. 10:1) to stress the
  full/empty pessimism and confirm no overflow/underflow ever occurs even
  under worst-case skew.

## 6. Further reading

- Clifford Cummings, "Simulation and Synthesis Techniques for
  Asynchronous FIFO Design" (SNUG 2002) — the canonical reference this
  style of design is descended from.

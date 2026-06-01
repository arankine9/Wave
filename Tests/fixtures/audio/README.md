# Audio fixtures

The end-to-end latency benchmark (`scripts/bench-latency.sh`) and the STT smoke check (`F3`) replay short recorded clips through the same audio pipeline the runtime uses. We don't ship the raw audio in git because it carries the dev's voice; record your own.

## What to record

Record 20 short clips (3–6 seconds each) in 16 kHz mono WAV at `Tests/fixtures/audio/01.wav` … `20.wav`. Pair each `NN.wav` with an `NN.txt` containing the **expected raw transcript** (what Parakeet should produce, not the cleaned output).

Suggested prompts (a mix of spoken code and plain prose):

| File | Spoken prompt |
|------|---------------|
| 01 | open paren self dot user underscore id close paren |
| 02 | function add a b return a plus b |
| 03 | if user underscore id equals null |
| 04 | self dot configure dot api underscore key |
| 05 | import numpy as np |
| 06 | let x equals five |
| 07 | const handler equals async function event |
| 08 | for i in range ten |
| 09 | no wait make it a function |
| 10 | return null |
| 11 | console dot log result |
| 12 | struct user has name and age |
| 13 | enum status idle running done |
| 14 | throw new error invalid input |
| 15 | await fetch slash users |
| 16 | u s e r underscore i d |
| 17 | a p i underscore k e y equals abc 123 |
| 18 | yes that works |
| 19 | thanks for the help |
| 20 | tomorrow morning |

## How to record

Easiest path on macOS is QuickTime → File → New Audio Recording → Options menu → Quality: Maximum, then export each clip and convert to 16 kHz mono with `afconvert`:

```bash
afconvert -f WAVE -d LEI16@16000 -c 1 input.m4a Tests/fixtures/audio/01.wav
```

## Privacy

`Tests/fixtures/audio/` is gitignored. Recordings stay on your machine.

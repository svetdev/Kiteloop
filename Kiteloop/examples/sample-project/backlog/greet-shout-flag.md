---
id: greet-shout-flag
title: greet.sh supports a --shout flag
size: XS
verify:
  - name: shout
    cmd: "bash tests/test_shout.sh"
---

## What

`greet.sh` accepts a `--shout` flag, anywhere in its arguments, that
upper-cases the whole greeting: `bash greet.sh Kiteloop --shout` prints
`HELLO, KITELOOP!`.

## How

Scan the arguments for `--shout` separately from the greeted name, and when
it's present pipe the greeting through something that upper-cases it (`tr` or
parameter expansion both work).

## Validation

- [ ] `bash greet.sh Kiteloop --shout` prints `HELLO, KITELOOP!`
- [ ] `bash tests/test_shout.sh` passes

## Out of Scope

- Any other flag.

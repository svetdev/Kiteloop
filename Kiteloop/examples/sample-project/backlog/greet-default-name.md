---
id: greet-default-name
title: greet.sh says hello to World by default
size: XS
verify:
  - name: default-name
    cmd: "bash tests/test_default_name.sh"
---

## What

Run with no argument, `greet.sh` prints `Hello, World!` instead of the
`Hello, !` it prints today.

## How

`greet.sh` reads its greeted name from `$1` with no fallback. Give it a
default of `World` when no argument is passed.

## Validation

- [ ] `bash greet.sh` (no argument) prints `Hello, World!`
- [ ] `bash tests/test_default_name.sh` passes

## Out of Scope

- The `--shout` flag — that is `greet-shout-flag`.

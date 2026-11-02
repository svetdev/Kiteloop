# Sample Project

A tiny demo repo Kiteloop bundles so a first autopilot run is one click away:
**Try a Sample Project** in the **+** menu at the end of the project tab bar
copies it to `~/.kiteloop/sample-project`, initialises git, assigns the two
bundled agents as worker and reviewer, and opens it.
`greet.sh` is a small, deliberately unfinished greeting script; `BACKLOG.md`
lists two XS items that finish it, already groomed and `ready` for autopilot
to pick up.

```
$ bash greet.sh
Hello, !
```

Run `bash tests/test_default_name.sh` and `bash tests/test_shout.sh` to see
which of the two backlog items still fail.

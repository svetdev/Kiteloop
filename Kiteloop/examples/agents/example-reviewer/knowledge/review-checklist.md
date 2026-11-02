# Review Checklist

## Before Starting
- Understand the intent: what problem does this change solve?
- Check the diff scope: is it focused or sprawling?

## Must Check
- [ ] No hardcoded secrets or credentials
- [ ] Error paths handled (not just happy path)
- [ ] No obvious SQL/command injection
- [ ] Tests cover new behavior
- [ ] No unintended behavior changes to existing code

## Common Issues
- Mutating shared state without synchronization
- Force unwraps in production code
- Missing nil/empty checks on external input
- Overly broad catch blocks that swallow errors
- TODO comments without tracking tickets

## Verdict Format
```json
{
  "verdict": "approve" | "request-changes",
  "blockers": ["..."],
  "suggestions": ["..."],
  "notes": "..."
}
```

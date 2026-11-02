# Development Workflows

## Making Changes

1. Create a feature branch from main
2. Make focused, atomic commits
3. Run the test suite before declaring done
4. If tests pass, publish a "pr_ready" event

## Code Review Integration

When another agent sends you a review with requested changes:
- Address each point specifically
- Re-run tests after fixes
- Reply with what you changed

## Memory

Use `propose_memory` when you discover:
- Non-obvious project conventions
- Gotchas that would trip up a future agent
- Architecture decisions with rationale

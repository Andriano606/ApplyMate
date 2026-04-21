# Writing Documentation for AI Agents

Guidelines for writing effective CLAUDE.md and reference documentation based on [HumanLayer best practices](https://www.humanlayer.dev/blog/writing-a-good-claude-md).

## Core Principles

1. **LLMs are stateless** - They have no memory between sessions. CLAUDE.md is your primary onboarding tool.

2. **Keep it concise** - Target under 60 lines for CLAUDE.md. LLMs can follow ~150-200 instructions with reasonable consistency.

3. **Progressive disclosure** - Reference separate docs instead of including everything. Let agents read guides when relevant.

## What to Include in CLAUDE.md

Focus on three things:

- **WHAT**: Tech stack, project structure, architecture
- **WHY**: Project purpose, component functions
- **HOW**: Workflows, commands, verification methods

## What NOT to Include

### Style Guidelines
LLMs are in-context learners - they follow existing code patterns without explicit instruction. Use linters instead.

**Bad:**
```markdown
- Use two spaces for indentation
- Use single quotes for strings
- Prefer frozen_string_literal: true
```

**Good:** Let RuboCop/Prettier handle it automatically.

### Meta-Instructions
Avoid instructions that tell Claude to update documentation itself. This bloats files over time.

**Bad:**
```markdown
- Always update this document with patterns you discover
- Every time you identify a pattern, immediately add a guideline
```

### Upfront Loading
Don't require reading all docs at startup. Let agents consult guides when needed.

**Bad:**
```markdown
REQUIRED: At startup, you MUST read ALL files referenced in this guide
```

**Good:**
```markdown
Consult these guides when working on specific areas:
- `.ai/docs/rspec.md` - RSpec patterns
```

## Reference Documents (.ai/docs/)

For detailed patterns, create separate reference docs:

- Keep each doc focused on one topic
- Include concrete examples (good vs bad patterns)
- Document anti-patterns to avoid
- Use code blocks with language hints

## Enforcement Strategy

Prefer automated enforcement over documentation:

| Instead of documenting... | Create... |
|---------------------------|-----------|
| Code style rules | RuboCop cops |
| Formatting preferences | Prettier config |
| Test patterns | Custom linter rules |

Documentation should explain *what* and *why*, not style choices that tools can enforce.

# Review Code Changes

Review the current code changes and provide feedback on (do review in Ukrainian):

- Code quality and adherence to project patterns
- Security considerations
- Performance implications
- Test coverage
- Documentation updates needed

## Before review

Please read all documents in .ai/
They contain important style guidance.

If the current git branch matches the pattern `*in-\d*-*` (e.g., `andrii/in-10441-upgrade-to-ztl-api-v2`), this is a
Linear issue branch. Use the Linear MCP tools to read the issue details and ensure the code changes actually solve the
issue requirements before reviewing.

## Usage

This command should be run after making significant code changes to get a comprehensive review of the modifications.

The review will check:

- Recent git changes
- Code style compliance
- Test coverage for new functionality
- Documentation completeness
- Adherence to project guidelines in CLAUDE.md and .ai/ files
# Issues

Issues are tracked with git-native-issuez (`git issue`). They live in the repository's git refs, not in files, and there is no Backlog.md and no `tasks/` folder.

- Agents use the `git-issue` MCP server (installed per user with `git issue mcp install`, command `git issue mcp`) to list, show, search, create, comment on, edit, close and reopen issues.
- On the command line: `git issue ls`, `git issue tree`, `git issue show <id>`, `git issue create`, `git issue edit`, `git issue close`. Run `git issue <command> --help` for details.
- Issues migrated from the old task files keep their id in the title (`TASK-140.1: …`) and as the original id. Phases are parent issues, and dependencies are `blocked-by` links.
- An issue's description holds its Description, Acceptance Criteria, Implementation Notes and Final Summary sections. Keep the notes current while you work. Set the workflow to `in-progress` when you start, and close the issue with `--reason completed` when it is done.
- Issues sync with `git issue sync <remote>`. Don't push them without being asked.

The DOD migration plan is `docs/DODMigrationPlan.md`. Engineering rules are in `TIGER_STYLE.md`.

Each issue should have success criteria defined. An implementation issue is only considered complete if one or more unit tests validate the success criteria.

# Tests

DO NOT parse all fixtures, just reference the filenames and only parse a single file while working on the specific unit test that refefences that file.

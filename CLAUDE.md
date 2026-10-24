# Tasks

Tasks live as plain markdown files under `tasks/` (`tasks/open/`, `tasks/done/`). See `tasks/README.md` for the file format.
The DOD migration plan is `docs/DODMigrationPlan.md`.

Each task should have a success criteria defined. An implementation task is only considered complete if one or more unit tests validate the success criteria.

# Tests

DO NOT parse all fixtures, just reference the filenames and only parse a single file while working on the specific unit test that refefences that file.

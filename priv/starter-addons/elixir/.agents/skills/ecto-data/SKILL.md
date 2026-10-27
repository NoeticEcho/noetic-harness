---
name: ecto-data
description: How to change the data layer with Ecto: changesets as the only way in, migrations that can be rolled back, and queries that say what they load.
---

# Ecto data layer

- **Every write goes through a changeset**, and every rule about valid data is a
  validation or a constraint there, mirrored by a database constraint where
  the database can hold it.
- **Migrations are reversible**, or say in the migration why they are not and
  what rolling back costs. Never edit a migration that has run anywhere shared.
- **Preload what you use, explicitly.** A query that loads associations on
  demand in a loop is N+1 queries.
- **Test against the real database** in the test environment, with the SQL
  sandbox, rather than mocking the repo.

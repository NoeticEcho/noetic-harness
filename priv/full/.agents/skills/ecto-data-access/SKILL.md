---
name: ecto-data-access
description: Ecto schemas, changesets, queries, transactions, migrations, indexes and PostgreSQL.
---

# Ecto

Separate persistence schema, domain invariants and transport schema.

Migrations are history: consider size, locking, reversibility and rollback.
Queries should avoid N+1 behavior and use explicit indexes where needed.
Make transaction boundaries obvious.

the product semantic truth remains in TypeDB; do not turn convenient SQL joins into ontology truth.

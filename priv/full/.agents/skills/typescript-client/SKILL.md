---
name: typescript-client
description: The TypeScript side of the client — the store, channel payloads, the hook lifecycle, and how it is actually checked. Load for any change under assets/js.
---

# The TypeScript client

`esbuild` strips types and checks nothing. The client sat unchecked long enough
to accumulate a `new AbstractMesh` and a missing import — two real defects no
Elixir test could reach.

```bash
mix do --app my_app_web cmd mix assets.check   # tsc --noEmit  +  node --test
```

`node --test` runs `js/**/*.test.ts` through `assets/test-hooks.mjs`, whose
resolve hook teaches Node the extensionless imports the bundler already
understands. Both halves must run; either alone is a partial check.

## The store is the client's single truth

`state/` holds it. Everything else reads from it. A component that keeps its own
copy of product state will disagree with the store at the worst moment — during a
transition, when both are changing.

## Channel payloads are a two-sided contract

`the product's API` validates operations and payload keys on the server and refuses
anything else. The TypeScript type for a payload and the server's
`@client_operations` entry are the same contract written twice; changing one
without the other produces a runtime rejection that looks like a network
problem. Change both in the same commit.

## The hook owns the canvas

`hook.ts` is the LiveView hook: it mounts, it owns the Babylon engine, and it
tears down. Anything that outlives the hook — a timer, a listener, an observable
subscription — is a leak that survives navigation.

## Verifying

`verify-in-browser`: Playwright with SwiftShader, walk the product, read the store
back, check the onlooker's pose, read the console. A type-check is not a render.

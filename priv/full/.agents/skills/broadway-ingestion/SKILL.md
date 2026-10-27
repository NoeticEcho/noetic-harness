---
name: broadway-ingestion
description: Broadway staged concurrent data pipelines with back-pressure.
---

# Broadway

Use:
```text
producer → parse → validate → normalize → resolve → persist
```

Define demand, concurrency, batch sizing, failure strategy and idempotency.
Use Broadway when throughput/back-pressure justify it; do not force it onto every connector.

---
name: Pydantic sensitive field repr=False vs exclude=True
description: Why repr=False is the correct choice for secret fields in MongoDB-backed Pydantic models — exclude=True breaks DB persistence.
---

## Rule

Use `repr=False` to hide sensitive values from logs/repr output.
**Never** use `exclude=True` on fields that must be persisted to MongoDB.

## Why

`_to_dict(model)` calls `model.model_dump(...)` to produce the document written to MongoDB.
`Field(exclude=True)` makes Pydantic exclude the field from every `model_dump()` call by default,
so the secret value is silently dropped and never written (or overwritten with Nothing on update).

`repr=False` only suppresses the value in `repr(model)` / f-string interpolation — structlog
captures model repr in log events, so `repr=False` is sufficient to prevent leakage there.

## How to apply

Any secret field in a `CollectionModel` subclass (bot_token, jwt_secret_key, api keys, password,
binary blobs) should be declared as:

```python
secret_field: str = Field(default="", repr=False, description="...")
```

If the field should truly never be serialized to the API layer, handle that at the response
schema level (exclude from the Pydantic response model), not at the DB model level.

## Where applied (2026-06-25)

- `database/models/telegram.py` — `bot_token`, `telegram_api_hash`
- `database/models/wallet.py` — `password`, `trakteer_api_key`, `trakteer_webhook_token`
- `database/models/webs.py` — `telegram_secret_token`, `jwt_secret_key`
- `database/models/bin.py` — all binary blob fields

---
name: CollectionModel config inheritance
description: model_config lives only in CollectionModel (base.py); leaf models that already extend CollectionModel/DaemonModel/UtilityModel must not redeclare it.
---

# model_config belongs only in CollectionModel

`CollectionModel` in `database/models/base.py` declares:

```python
model_config = ConfigDict(validate_assignment=True, extra="ignore", populate_by_name=True)
```

`DaemonModel` and `UtilityModel` both extend `CollectionModel` and inherit the config automatically.

**Why:** Pydantic merges `model_config` from parent to child; redeclaring the identical dict is redundant noise and hides the real source of the config.

**How to apply:**
- Never add `model_config = ConfigDict(...)` to a class that already inherits from `CollectionModel`, `DaemonModel`, or `UtilityModel`.
- The only valid exception is `ProductPacketModel(BaseModel)` in `product.py` — it extends plain `BaseModel` (not CollectionModel) and needs its own config.
- `ConfigDict` should not appear in the pydantic import of any leaf model file unless that file has a class extending plain `BaseModel` directly.

**Cleaned up (2026-07-13):** 12 leaf models had the redundant declaration removed: AriaModel, BotModel, ChatClonerModel, FFMpegModel, GDriveModel, QBitModel, RcloneModel, RssConfigModel, SevenZModel, WebsModel, YouTubeModel, TelegramModel.

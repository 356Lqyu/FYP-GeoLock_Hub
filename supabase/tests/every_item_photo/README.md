# Every item needs a photo: local tests

Tests for `supabase/migrations/20261128120000_require_photo_for_every_item.sql`. They run against a disposable local PostgreSQL 16 database only, never against a Supabase project. They reuse the harness in `../item_level_donation_photos/`.

## Order of a run (`run_every_item_photo.sh`)

1. Rebuild the audited baseline, load the fixtures, apply `20261126120000` and run its 165 tests. This is the deployed state, including donations made under the earlier "at least one photo" rule.
2. `22_snapshot_before_every_item_photo.sql` records the catalogue, every donation/item/photo/request/listing row and the reader outputs.
3. Apply `20261128120000_require_photo_for_every_item.sql`.
4. `25_tests_every_item_photo.sql`: 64 assertions. Section R revises the earlier B3, B5 and B30b cases, which are now rejections.
5. Run the migration again: it must stop with `EVERY_ITEM_PHOTO_ALREADY_APPLIED`.
6. Apply the rollback, then `35_rollback_checks_every_item_photo.sql` (3 assertions). Run the rollback again: it must stop with `EVERY_ITEM_PHOTO_ROLLBACK_ALREADY_APPLIED`.

```bash
# local cluster on socket dir /tmp/pgip, port 55433, superuser postgres
./run_every_item_photo.sh t2
```

## Files

| File | Purpose |
|---|---|
| `20261128120000_require_photo_for_every_item.rollback.sql` | Rollback. Kept out of `supabase/migrations` |
| `KLSEL_EVERY_ITEM_PHOTO_PREDEPLOY_AUDIT.sql` | Read-only check before deploying (SQL Editor) |
| `KLSEL_EVERY_ITEM_PHOTO_POSTDEPLOY_VERIFY.sql` | Read-only check after deploying; expect `pass = true` |

The same limits as the earlier harness apply: no PostGIS, pgRouting or pg_cron locally, so road eligibility is table-stubbed.

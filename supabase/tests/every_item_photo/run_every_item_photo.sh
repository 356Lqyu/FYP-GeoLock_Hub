#!/bin/bash
# Local run: baseline -> fixtures -> 20261126120000 -> its 165 tests (the deployed state, including
# donations made under the earlier rule) -> snapshot -> 20261128120000 -> new tests -> rerun guard.
set -e; cd "$(dirname "$0")"; DB=${1:-t2}; BASE=${BASE:-../item_level_donation_photos}
P="-h /tmp/pgip -p 55433 -U postgres -d $DB -X -v ON_ERROR_STOP=1"
(cd "$BASE" && ./rebuild.sh "$DB")
psql $P -q -f "$BASE/10_fixtures_before_migration.sql" >/dev/null
psql $P -q -f "$BASE/20261126120000_item_level_donation_photos.sql" >/dev/null
psql $P -f "$BASE/20_tests_after_migration.sql" | tail -3
psql $P -q -f 22_snapshot_before_every_item_photo.sql >/dev/null
psql $P -q -f 20261128120000_require_photo_for_every_item.sql >/dev/null
psql $P -f 25_tests_every_item_photo.sql
echo "--- second run of the migration must stop and change nothing:"
psql $P -q -f 20261128120000_require_photo_for_every_item.sql 2>&1 | grep -o 'EVERY_ITEM_PHOTO_ALREADY_APPLIED' || { echo 'RERUN GUARD FAILED'; exit 1; }
echo "--- rollback:"
psql $P -q -c "CREATE TABLE test_harness.every_photo_rb_rows AS
  SELECT 'donation:' || donation_id AS key, md5(to_jsonb(d)::text) AS value FROM public.donations d
  UNION ALL SELECT 'item:' || item_id, md5(to_jsonb(i)::text) FROM public.donation_items i
  UNION ALL SELECT 'image:' || image_id, md5(to_jsonb(g)::text) FROM public.donation_images g
  UNION ALL SELECT 'request:' || request_id, md5(to_jsonb(q)::text) FROM public.donation_create_requests q;
  GRANT SELECT ON test_harness.every_photo_rb_rows TO authenticated, anon;"
psql $P -q -f 20261128120000_require_photo_for_every_item.rollback.sql >/dev/null
psql $P -f 35_rollback_checks_every_item_photo.sql
psql $P -q -f 20261128120000_require_photo_for_every_item.rollback.sql 2>&1 | grep -o 'EVERY_ITEM_PHOTO_ROLLBACK_ALREADY_APPLIED' || { echo 'ROLLBACK RERUN GUARD FAILED'; exit 1; }

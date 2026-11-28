#!/bin/bash
# Full local run: fresh DB -> baseline -> fixtures -> migration -> tests
set -e; cd "$(dirname "$0")"; DB=${1:-t1}; P="-h /tmp/pgip -p 55433 -U postgres -d $DB -X -v ON_ERROR_STOP=1"
./rebuild.sh $DB
psql $P -q -f 10_fixtures_before_migration.sql >/dev/null
psql $P -q -f 20261126120000_item_level_donation_photos.sql >/dev/null
psql $P -f 20_tests_after_migration.sql

#!/bin/bash
# Rebuild a disposable local database: baseline -> fixtures [-> migration]
set -e
DB=${1:-t1}; P="-h /tmp/pgip -p 55433 -U postgres"
psql $P -X -q -c "drop database if exists $DB" -c "create database $DB" 2>/dev/null
BOOT=/mnt/user-data/uploads/GeoLock-Claude-Output/new-project-bootstrap/bootstrap \
REPO_MIGRATION=/mnt/user-data/uploads/FYP-GeoLock_Hub/supabase/migrations/20261123210000_donation_information_readers.sql \
  ./harness/load_baseline.sh $P -d $DB >/tmp/load_$DB.log 2>&1 || { tail -5 /tmp/load_$DB.log; exit 1; }

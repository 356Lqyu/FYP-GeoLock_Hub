
-- Advisory locking does NOT fence nonparticipants or extra schedules. Review ALL.
SELECT statement_timestamp() AS checked_at,count(*) AS recovery_schedule_count,
 coalesce(jsonb_agg(to_jsonb(j) ORDER BY jobid),'[]'::jsonb) AS recovery_schedules
FROM cron.job j WHERE command ~* '\mrecover_expired_claims\M';

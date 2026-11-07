"""Stage 3I final preparation, filesystem-only. Never connects to a database.

Runtime deadline wrapper around the approved guarded activation. No recovery or
migration source is edited. Receipt/session GUC is transaction-local, not a table.
"""
import argparse
import hashlib
import json
from pathlib import Path
import claim_recovery_e2e_package as base


def activation_template():
    sql=base.artifacts()['03_activate.sql']
    sql=sql.replace("SET LOCAL statement_timeout='10s';",
      "SET LOCAL statement_timeout='10s';\nSET LOCAL idle_in_transaction_session_timeout='10s';")
    sql=sql.replace('v record; v_jobs jsonb;',
      'v record; v_jobs jsonb; v_activation_at timestamptz; v_pause_deadline timestamptz;')
    old="""   OR (v_manifest->>'stop_at')::timestamptz IS NULL
   OR (v_manifest->>'stop_at')::timestamptz<=clock_timestamp()
   OR (v_manifest->>'stop_at')::timestamptz>clock_timestamp()+interval '5 minutes'"""
    new="""   OR (v_manifest->>'max_activation_seconds')::integer IS DISTINCT FROM 300
   OR v_manifest->>'deadline_mode' IS DISTINCT FROM 'server_clock_immediately_before_activation'"""
    if old not in sql:
        raise ValueError('Canonical deadline guard drift')
    sql=sql.replace(old,new,1)
    sql=sql.replace(' PERFORM cron.alter_job(3,active := true);',""" -- Capture a conservative real activation-statement anchor, before COMMIT.
 v_activation_at:=clock_timestamp();
 v_pause_deadline:=v_activation_at+make_interval(secs=>(v_manifest->>'max_activation_seconds')::integer);
 v_manifest:=v_manifest||jsonb_build_object('activation_statement_at',v_activation_at,'stop_at',v_pause_deadline);
 PERFORM set_config('geolock.stage3i_receipt',jsonb_build_object(
   'operator',v_manifest->>'operator','claim_id',v_manifest->>'claim_id',
   'activation_statement_utc',to_char(v_activation_at AT TIME ZONE 'UTC','YYYY-MM-DD HH24:MI:SS.US'),
   'pause_deadline_utc',to_char(v_pause_deadline AT TIME ZONE 'UTC','YYYY-MM-DD HH24:MI:SS.US'),
   'pause_deadline_myt',to_char(v_pause_deadline AT TIME ZONE 'Asia/Kuala_Lumpur','YYYY-MM-DD HH24:MI:SS.US'),
   'pause_deadline',v_pause_deadline,'window_seconds',300,
   'committed',false,'note','Receipt generated before COMMIT; confirm COMMIT and cron state separately')::text,true);
 PERFORM cron.alter_job(3,active := true);""",1)
    sql=sql.replace("   RAISE EXCEPTION 'ACTIVATION_POSTCONDITION_FAILED'; END IF;",
      "   RAISE EXCEPTION 'ACTIVATION_POSTCONDITION_FAILED'; END IF;\n"
      " IF clock_timestamp()>=v_pause_deadline THEN RAISE EXCEPTION 'ACTIVATION_WINDOW_ALREADY_ELAPSED'; END IF;",1)
    sql=sql.replace('$stage3i$;\nCOMMIT;',
      "$stage3i$;\nSELECT current_setting('geolock.stage3i_receipt')::jsonb AS activation_receipt;\nCOMMIT;",1)
    sql=sql.replace('-- stop_at is a human deadline, NOT automatic cron deactivation. Watch continuously.\n-- Capture actual COMMIT time. Pause immediately after result or by stop_at.',
      '-- Receipt anchor is immediately BEFORE ALTER, hence deadline is no later than COMMIT +5m.\n'
      '-- The actual COMMIT timestamp cannot be predicted in a preparation-only package.\n'
      '-- Start a five-minute timer BEFORE Run; pause on first outcome or receipt deadline, sooner wins.\n'
      '-- Receipt is NOT commit proof and is not persisted. Save output; verify COMMIT/cron separately.\n'
      '-- If no receipt is visible, pause immediately. No automatic stop job is installed.')
    return sql


def artifacts(manifest):
    result=base.artifacts()
    result['03_activate.sql']=activation_template()
    result['04_monitor.sql']=result['04_monitor.sql'].replace(
      "(j->>'stop_at')::timestamptz AS operator_stop_at,",
      "(j->>'stop_at')::timestamptz AS receipt_deadline_if_copied,\n"
      " 'Use saved activation_receipt absolute deadline; NULL here is not permission to extend the window'::text AS deadline_instruction,")
    return {name:base.render(sql,manifest) for name,sql in result.items()}


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--manifest',type=Path,required=True)
    p.add_argument('--output-dir',type=Path,required=True)
    a=p.parse_args()
    manifest=json.loads(a.manifest.read_text(encoding='utf-8'))
    a.output_dir.mkdir(parents=True,exist_ok=False)
    hashes=[]
    for name,sql in artifacts(manifest).items():
        data=sql.encode()
        (a.output_dir/name).write_bytes(data)
        hashes.append(hashlib.sha256(data).hexdigest().upper()+'  '+name)
    (a.output_dir/'SHA256SUMS.txt').write_text('\n'.join(hashes)+'\n',encoding='utf-8',newline='\n')

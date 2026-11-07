"""Focused opt-in claim audit tests: disposable loopback PostgreSQL, never Supabase."""
import argparse
import json
from pathlib import Path
import re
import unittest
import uuid

import exact_two_recovery_isolated_test as local

ROOT=local.ROOT
MIGRATION=ROOT/'supabase/migrations/20261031_claim_audit_and_failure_capture.sql'
ACTOR=local.uid(99)
OTHER=local.uid(98)

class ClaimAuditTests(local.ExactTwoTests):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.db='postgres'
        cls.query(f"""
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS
 $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.ngo_profiles(user_id uuid PRIMARY KEY,active_flag boolean,location_verified_at timestamptz,road_node_id text);
INSERT INTO public.ngo_profiles VALUES('{ACTOR}',true,now(),'synthetic-node'),('{OTHER}',true,now(),'synthetic-node');
INSERT INTO public.user_profiles VALUES('{ACTOR}','NGO'),('{OTHER}','NGO');
ALTER TABLE public.donation_claims ADD request_id uuid UNIQUE;
ALTER TABLE public.donation_claims ALTER claim_id SET DEFAULT gen_random_uuid();
ALTER TABLE public.donation_claims ALTER claim_status SET DEFAULT 'ACTIVE';
ALTER TABLE public.claim_leases ALTER lease_id SET DEFAULT gen_random_uuid();
ALTER TABLE public.claim_leases ALTER lease_status SET DEFAULT 'ACTIVE';
ALTER TABLE public.claim_leases ALTER issued_at SET DEFAULT clock_timestamp();
ALTER TABLE public.pickup_tasks ADD pickup_road_node_id text;
ALTER TABLE public.pickup_tasks ADD load_kg numeric;
ALTER TABLE public.pickup_tasks ALTER task_id SET DEFAULT gen_random_uuid();
ALTER TABLE public.pickup_tasks ALTER task_status SET DEFAULT 'CONFIRMED';
ALTER TABLE public.listings ADD pickup_road_node_id text DEFAULT 'synthetic-node';
ALTER TABLE public.listings ADD listing_weight_kg numeric DEFAULT 20;
ALTER TABLE public.audit_events ADD request_id uuid;
ALTER TABLE public.audit_events ALTER entity_type SET NOT NULL;
ALTER TABLE public.audit_events ALTER event_type SET NOT NULL;
ALTER TABLE public.audit_events ALTER outcome SET NOT NULL;
ALTER TABLE public.audit_events ALTER details SET DEFAULT '{{}}'::jsonb;
ALTER TABLE public.audit_events ALTER details SET NOT NULL;
ALTER TABLE public.audit_events ALTER occurred_at SET NOT NULL;
ALTER TABLE public.donations ADD donor_user_id uuid;
ALTER TABLE public.claim_reconciliation_cases ADD resolved_at timestamptz;
ALTER TABLE public.claim_reconciliation_cases ADD resolution_reason text;
ALTER TABLE public.claim_reconciliation_cases ADD opened_at timestamptz DEFAULT clock_timestamp();
ALTER TABLE public.claim_reconciliation_evidence ADD request_id uuid PRIMARY KEY;
ALTER TABLE public.claim_reconciliation_evidence ADD actor_user_id uuid;
ALTER TABLE public.claim_reconciliation_evidence ADD handover_confirmed boolean;
ALTER TABLE public.claim_reconciliation_evidence ADD response jsonb;
CREATE TABLE public.claim_cancellation_requests(request_id uuid PRIMARY KEY,claim_id uuid,actor_user_id uuid,
 request_fingerprint text,response jsonb,completed_at timestamptz);
ALTER TABLE public.pickup_route_stops ADD route_id uuid;
ALTER TABLE public.active_task_route_assignments ADD route_id uuid;
CREATE TABLE public.claim_requests(request_id uuid PRIMARY KEY,listing_id uuid,ngo_user_id uuid,request_digest text,
 outcome text,result_claim_id uuid,reason_code text,completed_at timestamptz);
-- Road eligibility is an explicit test double, never a live road result.
CREATE FUNCTION public.geolock_ngo_listing_road_check(uuid,uuid) RETURNS jsonb LANGUAGE sql AS $$ SELECT '{{"outcome":"ELIGIBLE"}}'::jsonb $$;
""")
        cls.query(local.lifecycle.routine('claim_listing'))
        for name in ('start_pickup','complete_pickup','cancel_claim','submit_claim_reconciliation','get_authorized_audit_events'):
            cls.query(local.lifecycle.routine(name))
        cls.query('REVOKE ALL ON FUNCTION public.geolock_transition_listing_donations(uuid,text,text) FROM PUBLIC,anon,authenticated,service_role;')
        cls.query('REVOKE ALL ON FUNCTION public.claim_listing(uuid,uuid) FROM PUBLIC,anon; GRANT EXECUTE ON FUNCTION public.claim_listing(uuid,uuid) TO authenticated;')
        schema=(ROOT/'geolock-v3-public-schema.sql').read_text()
        match=re.search(r'CREATE FUNCTION public.prevent_audit_mutation\(\).*?AS (\$\w*\$).*?\1;',schema,re.S)
        assert match
        cls.query(match.group(0)+'\nCREATE TRIGGER trg_audit_append_only BEFORE UPDATE OR DELETE ON public.audit_events FOR EACH ROW EXECUTE FUNCTION public.prevent_audit_mutation();')
        cls.query(MIGRATION.read_text())
        cls.db='template1'

    def setUp(self):
        local.transport.source.IntegrationTests.setUp(self)
        self.listing=str(uuid.uuid4());self.donation=str(uuid.uuid4())
        self.query(f"BEGIN; INSERT INTO public.donations(donation_id,collection_path,donation_status,total_weight_kg) VALUES('{self.donation}','DIRECT_PICKUP','AVAILABLE',20); INSERT INTO public.listings(listing_id,source_type,donation_id,listing_status) VALUES('{self.listing}','DIRECT_DONATION','{self.donation}','AVAILABLE'); COMMIT;")

    def claim(self,request=None,actor=ACTOR):
        request=request or str(uuid.uuid4())
        return json.loads(self.query(f"BEGIN; SET LOCAL ROLE authenticated; SET LOCAL request.jwt.claim.sub='{actor}'; SELECT public.claim_listing('{self.listing}','{request}'); COMMIT;"))

    def audit(self):
        return json.loads(self.query("SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY event_type),'[]'::jsonb) FROM public.audit_events a;"))

    def fault(self):
        self.query("CREATE FUNCTION public.fail_claim_audit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.event_type='CLAIM_ATTEMPT' THEN RAISE EXCEPTION 'synthetic SQL error containing private detail'; END IF; RETURN NEW; END $$; CREATE TRIGGER fail_claim_audit BEFORE INSERT ON public.audit_events FOR EACH ROW EXECUTE FUNCTION public.fail_claim_audit();")

    def test_success_audit_fields_and_replay(self):
        request=str(uuid.uuid4());result=self.claim(request)
        self.assertEqual(result['outcome'],'SUCCESS');self.assertIsNone(result['reason_code'])
        events=self.audit();self.assertEqual(len(events),2)
        tx=set()
        for event in events:
            self.assertEqual(event['actor_user_id'],ACTOR)
            self.assertEqual(event['actor_role'],'NGO')
            self.assertEqual(event['previous_state'],'AVAILABLE')
            self.assertEqual(event['requested_state'],'CLAIMED');self.assertEqual(event['resulting_state'],'CLAIMED')
            self.assertEqual(event['request_id'],request);self.assertEqual(event['correlation_id'],request)
            self.assertTrue(event['occurred_at']);self.assertTrue(event['lease_id'])
            self.assertEqual(event['reason_code'],'CLAIM_ACCEPTED');self.assertEqual(event['outcome'],'SUCCESS')
            self.assertEqual(event['software_version'],'geolock-claim-audit-v1');self.assertEqual(event['configuration_version'],'isolated')
            self.assertEqual(event['details']['donation_id'],self.donation);tx.add(event['details']['transaction_id'])
        self.assertEqual(len(tx),1)
        before=self.audit();replay=self.claim(request)
        self.assertTrue(replay['replayed']);self.assertEqual(replay['claim_id'],result['claim_id'])
        self.assertEqual(before,self.audit())
        for table in ('donation_claims','claim_leases','pickup_tasks'):
            self.assertEqual(self.query(f'SELECT count(*) FROM public.{table};'),'1')

    def test_conflict_rejection_audit_no_invented_lease(self):
        self.claim();request=str(uuid.uuid4());result=self.claim(request,OTHER)
        self.assertEqual(result['outcome'],'CONFLICT');self.assertEqual(result['reason_code'],'CLAIM_CONFLICT')
        event=next(e for e in self.audit() if e['request_id']==request)
        self.assertEqual(event['outcome'],'REJECTED');self.assertIsNone(event['lease_id'])
        self.assertEqual(event['details']['donation_id'],self.donation)
        self.assertEqual(event['previous_state'],'CLAIMED');self.assertEqual(event['resulting_state'],'CLAIMED')
        before=self.audit();self.assertTrue(self.claim(request,OTHER)['replayed']);self.assertEqual(before,self.audit())

    def test_confirmed_rollback_is_durable_deduplicated_and_retryable(self):
        self.fault();request=str(uuid.uuid4());result=self.claim(request)
        self.assertEqual(result['outcome'],'ERROR');self.assertTrue(result['rollback_confirmed'])
        self.assertTrue(result['failure_audit_id']);self.assertIsNone(result['claim_id'])
        for table in ('claim_requests','donation_claims','claim_leases','pickup_tasks','audit_events'):
            self.assertEqual(self.query(f'SELECT count(*) FROM public.{table};'),'0')
        failure=json.loads(self.query('SELECT to_jsonb(f) FROM public.operation_failure_events f;'))
        self.assertEqual(failure['actor_user_id'],ACTOR);self.assertEqual(failure['donation_id'],self.donation)
        self.assertIsNone(failure['details']['lease_id']);self.assertEqual(failure['details']['outcome'],'ERROR')
        self.assertTrue(failure['details']['transaction_id']);self.assertEqual(failure['details']['correlation_id'],request)
        self.assertEqual(failure['details']['previous_state'],'AVAILABLE');self.assertEqual(failure['details']['resulting_state'],'AVAILABLE')
        self.assertNotIn('private detail',json.dumps(failure))
        self.assertEqual(self.claim(request)['failure_audit_id'],result['failure_audit_id'])
        self.assertEqual(self.query('SELECT count(*) FROM public.operation_failure_events;'),'1')
        self.query('DROP TRIGGER fail_claim_audit ON public.audit_events;')
        self.assertEqual(self.claim(request)['outcome'],'SUCCESS')
        self.assertEqual(self.query('SELECT count(*) FROM public.operation_failure_events;'),'1')

    def test_failure_audit_failure_never_reports_confirmation(self):
        self.fault()
        self.query("CREATE FUNCTION public.fail_failure_audit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'FAILURE_LOG_UNAVAILABLE'; END $$; CREATE TRIGGER fail_failure_audit BEFORE INSERT ON public.operation_failure_events FOR EACH ROW EXECUTE FUNCTION public.fail_failure_audit();")
        with self.assertRaisesRegex(RuntimeError,'FAILURE_LOG_UNAVAILABLE'):self.claim()
        for table in ('claim_requests','donation_claims','claim_leases','pickup_tasks','audit_events','operation_failure_events'):
            self.assertEqual(self.query(f'SELECT count(*) FROM public.{table};'),'0')

    def test_client_cannot_forge_failure_audit(self):
        self.query("BEGIN; SET LOCAL ROLE authenticated; INSERT INTO public.operation_failure_events(operation_name,reason_code) VALUES('claim_listing','FORGED'); COMMIT;",'permission denied')
        self.query("BEGIN; SET LOCAL ROLE anon; SELECT public.claim_listing('"+self.listing+"','"+str(uuid.uuid4())+"'); COMMIT;",'permission denied')

    def test_cancellation_is_not_caught_as_confirmed_failure(self):
        self.query("CREATE FUNCTION public.cancel_claim_test() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION USING ERRCODE='57014',MESSAGE='SYNTHETIC_CANCELLATION'; END $$; CREATE TRIGGER cancel_claim_test BEFORE INSERT ON public.audit_events FOR EACH ROW EXECUTE FUNCTION public.cancel_claim_test();")
        with self.assertRaisesRegex(RuntimeError,'SYNTHETIC_CANCELLATION'):self.claim()
        self.assertEqual(self.query('SELECT count(*) FROM public.operation_failure_events;'),'0')

    def test_expired_lease_replay_remains_historical_result(self):
        request=str(uuid.uuid4());first=self.claim(request)
        self.query("UPDATE public.claim_leases SET issued_at=now()-interval '2 days',expires_at=now()-interval '1 day';")
        before=self.audit();retry=self.claim(request)
        self.assertEqual(retry['outcome'],'SUCCESS');self.assertTrue(retry['replayed'])
        self.assertEqual(retry['claim_id'],first['claim_id']);self.assertEqual(before,self.audit())

    def test_concurrent_failure_retries_have_one_failure_event(self):
        self.fault();request=str(uuid.uuid4())
        with self.concurrent(f"BEGIN; SET LOCAL ROLE authenticated; SET LOCAL request.jwt.claim.sub='{ACTOR}'; SELECT public.claim_listing('{self.listing}','{request}'); SELECT pg_sleep(1.2); COMMIT;"):
            retry=self.claim(request)
        self.assertEqual(retry['outcome'],'ERROR');self.assertTrue(retry['rollback_confirmed'])
        self.assertEqual(self.query('SELECT count(*) FROM public.operation_failure_events;'),'1')
        self.assertEqual(self.query('SELECT count(*) FROM public.donation_claims;'),'0')

    def test_hub_batch_audit_contains_all_member_donation_ids(self):
        self.listing=str(uuid.uuid4());donation=str(uuid.uuid4());batch=str(uuid.uuid4());hub=str(uuid.uuid4())
        self.query(f"BEGIN; INSERT INTO public.donations(donation_id,collection_path,donation_status,total_weight_kg) VALUES('{donation}','HUB_COLLECTION','BATCHED',5); INSERT INTO public.hub_batches VALUES('{batch}','{hub}','PUBLISHED',1); INSERT INTO public.hub_batch_members VALUES('{batch}','{donation}','ACTIVE'); INSERT INTO public.hub_inventory VALUES('{donation}','{hub}','BATCHED'); INSERT INTO public.listings(listing_id,source_type,batch_id,listing_status,listing_weight_kg) VALUES('{self.listing}','HUB_BATCH','{batch}','AVAILABLE',5); COMMIT;")
        self.assertEqual(self.claim()['outcome'],'SUCCESS')
        event=next(e for e in self.audit() if e['event_type']=='CLAIM_ATTEMPT')
        self.assertIsNone(event['details']['donation_id'])
        self.assertEqual(event['details']['donation_ids'],[donation])
        transition=next(e for e in self.audit() if e['event_type']=='DONATION_STATUS_CHANGED')
        self.assertEqual(transition['entity_id'],donation)
        self.assertEqual(transition['correlation_id'],event['correlation_id'])
        self.assertEqual(transition['details']['transaction_id'],event['details']['transaction_id'])
        rows=self.retrieved(donation)
        self.assertEqual({e['event_type'] for e in rows},{'CLAIM_ATTEMPT','DONATION_STATUS_CHANGED'})

    def retrieved(self,entity,actor=ACTOR):
        return json.loads(self.query(f"BEGIN; SET LOCAL ROLE authenticated; SET LOCAL request.jwt.claim.sub='{actor}'; SELECT coalesce(jsonb_agg(to_jsonb(a)),'[]'::jsonb) FROM public.get_authorized_audit_events('DONATION','{entity}') a; COMMIT;"))

    def test_request_reuse_reason_is_distinct_without_changing_original(self):
        request=str(uuid.uuid4());original=self.claim(request);before=self.audit()
        # The other NGO cannot obtain the original actor's replay response.
        self.query(f"INSERT INTO public.operation_failure_events(request_id,actor_user_id,actor_role,operation_name,listing_id,reason_code) VALUES('{request}','{OTHER}','NGO','claim_listing','{self.listing}','CLAIM_TRANSACTION_ROLLED_BACK');")
        reused=self.claim(request,OTHER)
        self.assertEqual(reused['outcome'],'ERROR');self.assertTrue(reused['rollback_confirmed'])
        self.assertEqual(reused['reason_code'],'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD')
        row=json.loads(self.query("SELECT to_jsonb(f) FROM public.operation_failure_events f WHERE reason_code='IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';"))
        self.assertEqual(row['reason_code'],reused['reason_code'])
        self.assertEqual(row['actor_user_id'],OTHER);self.assertIsNone(row['claim_id'])
        self.assertEqual(before,self.audit())
        self.assertEqual(self.claim(request)['claim_id'],original['claim_id'])
        self.assertEqual(self.query('SELECT count(*) FROM public.donation_claims;'),'1')
        self.assertEqual(self.query('SELECT count(*) FROM public.operation_failure_events;'),'2')

    def test_failure_schema_drift_aborts_without_historical_changes(self):
        guard=re.search(r'DO \$audit_schema_guard\$.*?END \$audit_schema_guard\$;',MIGRATION.read_text(),re.S).group(0)
        self.query("INSERT INTO public.operation_failure_events(operation_name,reason_code) VALUES('HISTORY','KEEP');")
        before=self.query('SELECT to_jsonb(f) FROM public.operation_failure_events f;')
        self.query('BEGIN; ALTER TABLE public.operation_failure_events ALTER reason_code TYPE varchar; '+guard+' COMMIT;','AUDIT_SCHEMA_DRIFT')
        self.assertEqual(before,self.query('SELECT to_jsonb(f) FROM public.operation_failure_events f;'))
        self.query("BEGIN; ALTER TABLE public.operation_failure_events ALTER failure_id DROP DEFAULT; "+guard+" COMMIT;",'FAILURE_AUDIT_DEFAULT_DRIFT')
        self.assertEqual(before,self.query('SELECT to_jsonb(f) FROM public.operation_failure_events f;'))

    def test_wrong_existing_failure_index_fails_closed(self):
        guard=re.search(r'DO \$failure_index_guard\$.*?END \$failure_index_guard\$;',MIGRATION.read_text(),re.S).group(0)
        self.query('BEGIN; DROP INDEX public.operation_failure_claim_request_unique; CREATE INDEX operation_failure_claim_request_unique ON public.operation_failure_events(request_id); '+guard+' COMMIT;','FAILURE_AUDIT_IDEMPOTENCY_INDEX_DRIFT')

    def test_rejected_ngo_retrieves_only_own_attempt(self):
        self.claim();self.claim(actor=OTHER)
        events=self.retrieved(self.listing,OTHER)
        self.assertEqual(len(events),1);self.assertEqual(events[0]['actor_user_id'],OTHER)
        self.assertEqual(events[0]['reason_code'],'CLAIM_CONFLICT')

    def transition_event(self):
        return [e for e in self.audit() if e['event_type']=='DONATION_STATUS_CHANGED'][-1]

    def test_cancel_links_current_claim_and_cancellation_request(self):
        first=self.claim();request=str(uuid.uuid4())
        result=json.loads(self.query(f"BEGIN; SET LOCAL request.jwt.claim.sub='{ACTOR}'; SELECT public.cancel_claim('{first['claim_id']}','{request}'); COMMIT;"))
        self.assertEqual(result['outcome'],'SUCCESS')
        event=next(e for e in self.audit() if e['event_type']=='DONATION_STATUS_CHANGED' and e['resulting_state']=='AVAILABLE')
        self.assertEqual(event['claim_id'],first['claim_id']);self.assertEqual(event['request_id'],request)
        self.assertEqual(event['reason_code'],'NGO_CANCELLED_BEFORE_PICKUP')

    def test_recovery_does_not_reuse_original_claim_request_id(self):
        request=str(uuid.uuid4());first=self.claim(request)
        self.query("UPDATE public.claim_leases SET issued_at=now()-interval '2 days',expires_at=now()-interval '1 day';")
        self.assertEqual(self.query('SELECT public.recover_expired_claims(2);'),'1')
        event=next(e for e in self.audit() if e['event_type']=='DONATION_STATUS_CHANGED' and e['resulting_state']=='AVAILABLE')
        self.assertEqual(event['claim_id'],first['claim_id']);self.assertIsNone(event['request_id'])
        self.assertTrue(event['lease_id']);self.assertTrue(event['correlation_id'])
        self.assertEqual(event['reason_code'],'EXPIRED_SAFE_RELEASE')

    def test_pickup_start_and_complete_link_the_actual_claim(self):
        first=self.claim()
        self.query(f"BEGIN; SET LOCAL request.jwt.claim.sub='{ACTOR}'; SELECT public.start_pickup('{first['claim_id']}'); SELECT public.complete_pickup('{first['claim_id']}',true); COMMIT;")
        events=[e for e in self.audit() if e['event_type']=='DONATION_STATUS_CHANGED' and e['resulting_state'] in ('PICKUP_IN_PROGRESS','COLLECTED')]
        self.assertEqual(len(events),2)
        for event in events:
            self.assertEqual(event['claim_id'],first['claim_id']);self.assertIsNone(event['request_id'])
            self.assertTrue(event['lease_id']);self.assertTrue(event['correlation_id'])

    def test_three_argument_helper_never_guesses_historical_claim(self):
        # Three-argument compatibility caller receives deliberately absent operation context.
        first=self.claim()
        self.query(f"BEGIN; UPDATE public.donation_claims SET claim_status='RELEASED',closed_at=now() WHERE claim_id='{first['claim_id']}'; UPDATE public.claim_leases SET lease_status='RELEASED'; UPDATE public.pickup_tasks SET task_status='STALE'; UPDATE public.listings SET listing_status='AVAILABLE'; SELECT public.geolock_transition_listing_donations('{self.listing}','CLAIMED','AVAILABLE'); COMMIT;")
        event=next(e for e in self.audit() if e['event_type']=='DONATION_STATUS_CHANGED' and e['resulting_state']=='AVAILABLE')
        self.assertIsNone(event['claim_id']);self.assertIsNone(event['lease_id']);self.assertIsNone(event['request_id'])
        self.query(f"BEGIN; SET LOCAL ROLE authenticated; SELECT public.geolock_transition_listing_donations('{self.listing}','AVAILABLE','CLAIMED','{first['claim_id']}',NULL,'FORGED'); COMMIT;",'permission denied')

    def test_confirmed_failures_are_retrievable_without_a_claim(self):
        self.fault();self.claim()
        records=self.retrieved(self.listing)
        self.assertEqual(len(records),1);event=records[0]
        self.assertEqual(event['event_type'],'CLAIM_FAILURE');self.assertEqual(event['outcome'],'ERROR')
        self.assertEqual(event['details']['donation_id'],self.donation)
        self.assertTrue(event['correlation_id']);self.assertTrue(event['details']['transaction_id'])
        self.assertEqual(event['software_version'],'geolock-claim-audit-v1')
        self.assertEqual(event['configuration_version'],'isolated');self.assertIsNone(event['lease_id'])
        with self.assertRaisesRegex(RuntimeError,'AUDIT_NOT_FOUND_OR_FORBIDDEN'):
            self.retrieved(self.listing,OTHER)

    def test_reconciliation_release_uses_evidence_request_context(self):
        first=self.claim();claim=first['claim_id'];donor=local.uid(77);case=str(uuid.uuid4())
        self.query(f"BEGIN; INSERT INTO public.user_profiles VALUES('{donor}','DONOR'); UPDATE public.donations SET donor_user_id='{donor}' WHERE donation_id='{self.donation}'; UPDATE public.donation_claims SET claim_status='RECONCILIATION_REQUIRED'; UPDATE public.claim_leases SET lease_status='RECONCILIATION_REQUIRED'; INSERT INTO public.claim_reconciliation_cases(case_id,claim_id,listing_id,donation_id,source_type,case_status) VALUES('{case}','{claim}','{self.listing}','{self.donation}','DIRECT_DONATION','OPEN'); COMMIT;")
        self.query(f"BEGIN; SET LOCAL request.jwt.claim.sub='{donor}'; SELECT public.submit_claim_reconciliation('{claim}',false,'{uuid.uuid4()}'); COMMIT;")
        request=str(uuid.uuid4())
        response=json.loads(self.query(f"BEGIN; SET LOCAL request.jwt.claim.sub='{ACTOR}'; SELECT public.submit_claim_reconciliation('{claim}',false,'{request}'); COMMIT;"))
        self.assertEqual(response['outcome'],'SUCCESS')
        event=next(e for e in self.audit() if e['event_type']=='DONATION_STATUS_CHANGED' and e['resulting_state']=='AVAILABLE')
        self.assertEqual(event['claim_id'],claim);self.assertEqual(event['request_id'],request)
        self.assertEqual(event['reason_code'],'RECONCILED_NO_HANDOVER')

    def test_merged_audit_retrieval_keeps_failure_success_chronology(self):
        self.fault();request=str(uuid.uuid4());self.claim(request)
        self.query('DROP TRIGGER fail_claim_audit ON public.audit_events;')
        self.claim(request)
        records=self.retrieved(self.listing)
        self.assertEqual(records[0]['event_type'],'CLAIM_FAILURE')
        self.assertEqual(len(records),3)
        self.assertEqual([r['occurred_at'] for r in records],sorted(r['occurred_at'] for r in records))

    def test_caller_logic_unchanged_except_explicit_audit_arguments(self):
        source=MIGRATION.read_text()
        pattern=re.compile(r'CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+public\.(\w+)\s*\(.*?\bAS\s+(\$[\w]*\$)(.*?)\2\s*;',re.S|re.I)
        functions={m.group(1):m.group(3) for m in pattern.finditer(source)}
        originals={m.group(1):m.group(3) for m in pattern.finditer((ROOT/'supabase/migrations/20261027_persisted_donation_lifecycle.sql').read_text())}
        originals['recover_expired_claims']=local.transport.builder.function(ROOT/'supabase/migrations/20261030_fix_claim_recovery_unresolved_reconciliation.sql','public.recover_expired_claims').group(3)
        changes={
          'start_pickup':(",p_claim,NULL,'PICKUP_STARTED'",''),
          'complete_pickup':(",p_claim,NULL,'PICKUP_COLLECTED'",''),
          'cancel_claim':(",p_claim,p_request,'NGO_CANCELLED_BEFORE_PICKUP'",''),
          'recover_expired_claims':(",v_c.claim_id,NULL,'EXPIRED_SAFE_RELEASE'",''),
          'submit_claim_reconciliation':(",p_claim,p_request,'RECONCILED_NO_HANDOVER'",''),
        }
        for name,(added,empty) in changes.items():
            self.assertEqual(functions[name].count(added),1)
            self.assertEqual(functions[name].replace(added,empty),originals[name])

    def test_legacy_or_uncertain_failure_is_not_promoted_to_confirmed(self):
        self.query(f"INSERT INTO public.operation_failure_events(actor_user_id,operation_name,listing_id,reason_code,details) VALUES('{ACTOR}','claim_listing','{self.listing}','NETWORK_UNKNOWN','{{\"rollback_confirmed\":false}}');")
        with self.assertRaisesRegex(RuntimeError,'AUDIT_NOT_FOUND_OR_FORBIDDEN'):
            self.retrieved(self.listing)
        self.assertEqual(self.query("SELECT reason_code FROM public.operation_failure_events;"),'NETWORK_UNKNOWN')

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-isolated',action='store_true',required=True)
    args=parser.parse_args();local.ENABLED=True
    local.OUT=ROOT/'results/claim-audit-local-tests'
    local.OUT.mkdir(exist_ok=True)
    local.transport.EVIDENCE_DIR=local.OUT
    suite=unittest.TestSuite(ClaimAuditTests(n) for n in ClaimAuditTests.__dict__ if n.startswith('test_'))
    result=unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(not result.wasSuccessful())

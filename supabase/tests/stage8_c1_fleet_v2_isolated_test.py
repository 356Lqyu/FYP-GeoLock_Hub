"""Review v2 against a NEW disposable loopback PostgreSQL, never DEV.

Reuses the 29 original behavioral tests; overrides the intentionally revised
service-role expectation. Reduced task/stop/assignment fixtures are explicit.
"""
import argparse
import json
import shutil
import unittest
import stage8_c1_fleet_isolated_test as base

base.SQL=(base.FOLDER/'proposed_migration_v2.sql').read_text(encoding='utf-8')
base.FIXTURE+="""
CREATE TABLE public.pickup_tasks(task_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),task_status text NOT NULL);
CREATE TABLE public.pickup_route_stops(route_id uuid REFERENCES public.pickup_routes,
 task_id uuid REFERENCES public.pickup_tasks,PRIMARY KEY(route_id,task_id));
CREATE TABLE public.active_task_route_assignments(task_id uuid PRIMARY KEY REFERENCES public.pickup_tasks,
 route_id uuid REFERENCES public.pickup_routes);
"""
A=base.A


class FleetV2Tests(base.FleetTests):
    @classmethod
    def query(cls,sql,expect_error=None):
        # Only fixture-reset TRUNCATE statements from the inherited suite gain
        # CASCADE for the extra reduced child FKs. Role-denial tests are unchanged.
        sql=sql.replace('TRUNCATE public.pickup_routes,public.vehicles,public.audit_events;',
          'TRUNCATE public.pickup_routes,public.vehicles,public.audit_events CASCADE;')
        sql=sql.replace('TRUNCATE public.pickup_routes,public.vehicles;',
          'TRUNCATE public.pickup_routes,public.vehicles CASCADE;')
        return super().query(sql,expect_error)

    def setUp(self):
        self.query('TRUNCATE public.pickup_tasks,public.pickup_route_stops,public.active_task_route_assignments;')
        super().setUp()

    def test_direct_writes_reads_helpers_and_service_denied(self):
        # Ordinary clients lose all access; trusted backend keeps selected rights.
        self.register()
        for role in ['anon','authenticated']:
            for statement in ['SELECT * FROM public.vehicles',
                              f"INSERT INTO public.vehicles(ngo_user_id,vehicle_label,payload_capacity_kg) VALUES('{A}','x',1)",
                              'UPDATE public.vehicles SET active_flag=false','DELETE FROM public.vehicles','TRUNCATE public.vehicles']:
                self.query(f'SET ROLE {role}; {statement};','permission denied')
        for role in ['anon','authenticated','service_role']:
            self.query(f'SET ROLE {role}; SELECT fleet_private.require_ngo();','permission denied')
        self.rpc('public.list_my_vehicles()',role='service_role',error='permission denied')

    def test_service_selected_privileges_and_no_grant_option(self):
        self.register()
        self.assertEqual(self.query('SET ROLE service_role; SELECT count(*) FROM public.vehicles;'),'1')
        self.query(f"SET ROLE service_role; INSERT INTO public.vehicles(ngo_user_id,vehicle_label,payload_capacity_kg) VALUES('{A}','Backend import',2);")
        self.query("SET ROLE service_role; UPDATE public.vehicles SET vehicle_label='Backend edit' WHERE vehicle_label='Backend import';")
        for priv in ['SELECT','INSERT','UPDATE']:
            self.assertEqual(self.query(f"SELECT has_table_privilege('service_role','public.vehicles','{priv}');"),'t')
            self.assertEqual(self.query(f"SELECT has_table_privilege('service_role','public.vehicles','{priv} WITH GRANT OPTION');"),'f')
        for priv in ['DELETE','TRUNCATE','REFERENCES','TRIGGER','MAINTAIN']:
            self.assertEqual(self.query(f"SELECT has_table_privilege('service_role','public.vehicles','{priv}');"),'f')
        self.query('SET ROLE service_role; DELETE FROM public.vehicles;','permission denied')
        self.query('SET ROLE service_role; TRUNCATE public.vehicles CASCADE;','permission denied')
        for role in ['anon','authenticated','service_role']:
            self.assertEqual(self.query(f"SELECT has_table_privilege('{role}','public.pickup_routes','TRUNCATE');"),'f')

    def test_service_cannot_bypass_vehicle_guards(self):
        v=self.register(); vid=v['vehicle_id']; self.route(vid,'AUTHORISED')
        self.query(f"SET ROLE service_role; UPDATE public.vehicles SET available_for_planning=false WHERE vehicle_id='{vid}';",'VEHICLE_HAS_ACTIVE_ROUTE')
        self.query(f"SET ROLE service_role; UPDATE public.vehicles SET ngo_user_id='{base.B}' WHERE vehicle_id='{vid}';",'IMMUTABLE_VEHICLE_IDENTITY')
        self.query(f"SET ROLE service_role; UPDATE public.vehicles SET vehicle_version=100 WHERE vehicle_id='{vid}';",'VEHICLE_METADATA_MANAGED')
        self.query(f"SET ROLE service_role; UPDATE public.vehicles SET updated_at=now() WHERE vehicle_id='{vid}';",'VEHICLE_METADATA_MANAGED')

    def task_activity(self,rid,status='PLANNED',assigned=True):
        task=self.query(f"INSERT INTO public.pickup_tasks(task_status) VALUES('{status}') RETURNING task_id;")
        self.query(f"INSERT INTO public.pickup_route_stops VALUES('{rid}','{task}');")
        if assigned: self.query(f"INSERT INTO public.active_task_route_assignments VALUES('{task}','{rid}');")
        return task

    def test_cancel_or_stale_cannot_release_unresolved_route(self):
        v=self.register(); rid=self.route(v['vehicle_id']); self.task_activity(rid)
        for status in ['CANCELLED','STALE','COMPLETED']:
            self.query(f"UPDATE public.pickup_routes SET route_status='{status}' WHERE route_id='{rid}';",'ROUTE_HAS_UNRESOLVED_ACTIVITY')

    def test_completed_requires_collected_members_and_assignment_cleanup(self):
        v=self.register(); rid=self.route(v['vehicle_id']); task=self.task_activity(rid,'DISPATCHED')
        self.query(f"UPDATE public.pickup_tasks SET task_status='COLLECTED' WHERE task_id='{task}';")
        self.query(f"UPDATE public.pickup_routes SET route_status='COMPLETED' WHERE route_id='{rid}';",'ROUTE_HAS_UNRESOLVED_ACTIVITY')
        self.query(f"DELETE FROM public.active_task_route_assignments WHERE task_id='{task}';")
        self.query(f"UPDATE public.pickup_routes SET route_status='COMPLETED' WHERE route_id='{rid}';")
        self.rpc(f"public.deactivate_my_vehicle('{v['vehicle_id']}',1)")

    def test_terminal_route_with_legacy_activity_still_holds_vehicle(self):
        v=self.register(); rid=self.route(v['vehicle_id'],'CANCELLED')
        # Represents pre-existing inconsistent legacy state, not an approved writer.
        task=self.task_activity(rid,'DISPATCHED',False)
        self.rpc(f"public.deactivate_my_vehicle('{v['vehicle_id']}',1)",error='VEHICLE_HAS_ACTIVE_ROUTE')
        self.query(f"UPDATE public.pickup_tasks SET task_status='COLLECTED' WHERE task_id='{task}';")
        self.rpc(f"public.deactivate_my_vehicle('{v['vehicle_id']}',1)")

    def test_terminal_route_not_reactivated_after_fleet_change(self):
        v=self.register(); rid=self.route(v['vehicle_id'],'STALE')
        self.rpc(f"public.update_my_vehicle('{v['vehicle_id']}',1,'V','VAN',200,25,0.45,240)")
        self.query(f"UPDATE public.pickup_routes SET route_status='AUTHORISED' WHERE route_id='{rid}';",'ROUTE_TERMINAL_STATE_IMMUTABLE')

    def test_stale_releases_only_after_explicit_task_resolution(self):
        v=self.register(); rid=self.route(v['vehicle_id']); task=self.task_activity(rid)
        self.query(f"UPDATE public.pickup_tasks SET task_status='STALE' WHERE task_id='{task}'; DELETE FROM public.active_task_route_assignments WHERE task_id='{task}';")
        self.query(f"UPDATE public.pickup_routes SET route_status='STALE' WHERE route_id='{rid}';")
        self.rpc(f"public.set_my_vehicle_availability('{v['vehicle_id']}',1,false)")

    def test_completion_first_then_vehicle_edit(self):
        v=self.register(); rid=self.route(v['vehicle_id'])
        with self.concurrent(f"BEGIN; UPDATE public.pickup_routes SET route_status='COMPLETED' WHERE route_id='{rid}'; SELECT pg_sleep(1.2); COMMIT;"):
            self.rpc(f"public.deactivate_my_vehicle('{v['vehicle_id']}',1)")

    def test_cancellation_rollback_keeps_vehicle_held(self):
        v=self.register(); rid=self.route(v['vehicle_id'])
        with self.concurrent(f"BEGIN; UPDATE public.pickup_routes SET route_status='CANCELLED' WHERE route_id='{rid}'; SELECT pg_sleep(1.2); ROLLBACK;"):
            self.rpc(f"public.deactivate_my_vehicle('{v['vehicle_id']}',1)",error='VEHICLE_HAS_ACTIVE_ROUTE')

    def test_cancellation_commit_releases_vehicle(self):
        v=self.register(); rid=self.route(v['vehicle_id'])
        with self.concurrent(f"BEGIN; UPDATE public.pickup_routes SET route_status='CANCELLED' WHERE route_id='{rid}'; SELECT pg_sleep(1.2); COMMIT;"):
            self.rpc(f"public.deactivate_my_vehicle('{v['vehicle_id']}',1)")

    def test_named_constraint_drift_aborts(self):
        definition=self.query("SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid='public.vehicles'::regclass AND conname='vehicles_c1_fields';")
        self.query('ALTER TABLE public.vehicles DROP CONSTRAINT vehicles_c1_fields; ALTER TABLE public.vehicles ADD CONSTRAINT vehicles_c1_fields CHECK(true);')
        try: self.query(base.SQL,'FLEET_SCHEMA_DRIFT')
        finally:
            self.query(f'ALTER TABLE public.vehicles DROP CONSTRAINT vehicles_c1_fields; ALTER TABLE public.vehicles ADD CONSTRAINT vehicles_c1_fields {definition};')

    def test_column_acl_drift_removed_on_repeat(self):
        self.query('GRANT UPDATE(vehicle_label) ON public.vehicles TO authenticated;')
        self.query(base.SQL)
        self.query('SET ROLE authenticated; UPDATE public.vehicles SET vehicle_label=\'x\';','permission denied')

    def test_column_type_drift_aborts_without_repair(self):
        self.query('ALTER TABLE public.vehicles ALTER COLUMN fixed_cost_rm TYPE numeric(12,2);')
        try: self.query(base.SQL,'FLEET_SCHEMA_DRIFT')
        finally: self.query('ALTER TABLE public.vehicles ALTER COLUMN fixed_cost_rm TYPE numeric;')

    def test_disabled_original_depot_trigger_aborts(self):
        self.query('ALTER TABLE public.vehicles DISABLE TRIGGER trg_vehicle_depot_node;')
        try: self.query(base.SQL,'FLEET_SCHEMA_DRIFT')
        finally: self.query('ALTER TABLE public.vehicles ENABLE TRIGGER trg_vehicle_depot_node;')

    def test_schema_collision_aborts(self):
        old=self.query("SELECT obj_description('fleet_private'::regnamespace,'pg_namespace');")
        self.query("COMMENT ON SCHEMA fleet_private IS 'unreviewed';")
        try: self.query(base.SQL,'UNREVIEWED_FLEET_SCHEMA')
        finally: self.query(f"COMMENT ON SCHEMA fleet_private IS '{old}';")


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-isolated',action='store_true',required=True)
    parser.parse_args()
    FleetV2Tests.bins={n:shutil.which(n) for n in ['initdb','pg_ctl','psql']}
    if not all(FleetV2Tests.bins.values()): parser.error('PostgreSQL binaries must be on PATH')
    unittest.main(argv=[__file__],verbosity=2)

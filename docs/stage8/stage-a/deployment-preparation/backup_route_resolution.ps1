# LOCAL preparation. Definitions only; no connection or export when dot-sourced.
function Get-RouteResolutionBackupBaseline {
    $path=Join-Path $PSScriptRoot 'route_resolution_backup_baseline.json'
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne 'cf7892dc014117d57b052684c82650bce2f6312ef99badced721b41283938768') { throw 'Reviewed route-resolution backup baseline drift.' }
    $baseline=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $migration=Join-Path $stage003Root 'docs\stage8\stage-a\forward-migrations\20261106_route_interruption_resolution.sql'
    if ((Get-FileHash -LiteralPath $migration -Algorithm SHA256).Hash.ToLowerInvariant() -ne $baseline.migration_sha256) { throw 'Pinned route-resolution migration drift.' }
    if ($PreClaimScopedReconciliation) {
        $perStopMigration=Join-Path $stage003Root 'docs\stage8\stage-a\forward-migrations\20261108_per_stop_reconciliation.sql'
        if ((Get-FileHash -LiteralPath $perStopMigration -Algorithm SHA256).Hash.ToLowerInvariant() -ne $baseline.current_route_resolution_functions.stage8_through_20261108_migration_sha256) { throw 'Pinned per-stop reconciliation migration drift.' }
        $localReference=Join-Path $stage003Root $baseline.current_route_resolution_functions.local_reference
        if ((Get-FileHash -LiteralPath $localReference -Algorithm SHA256).Hash.ToLowerInvariant() -ne $baseline.current_route_resolution_functions.local_reference_sha256) { throw 'Disposable PostgreSQL route-function fingerprint artifact drift.' }
    }
    return $baseline
}

function New-CurrentInventoryFields {
    $baseline=Get-RouteResolutionBackupBaseline
    $functionBaseline = if ($PreClaimScopedReconciliation) { @($baseline.functions) } else { @($baseline.pre_route_resolution_functions) }
    $quoted=($functionBaseline | ForEach-Object { "'"+$_.signature.Replace("'","''")+"'" }) -join ','
    $records=@('policies','graphs','snapshots','matrices','candidates','validations','bindings','items','requests') | ForEach-Object {
        $projection=if ($_ -eq 'policies') { 'to_jsonb(t)' } elseif ($_ -eq 'bindings') { "to_jsonb(t)-'plan'" } elseif ($_ -eq 'requests') { "to_jsonb(t)-'result'" } else { "to_jsonb(t)-'body'" }
        "'$_',(SELECT coalesce(jsonb_agg($projection),'[]'::jsonb) FROM routing_private.$_ t)"
    }
    $recordSql=$records -join ",`n"
    return @"
 'capture_purpose',$(if ($PreClaimScopedReconciliation) { "'PRE_CLAIM_SCOPED_RECONCILIATION_CURRENT_DEV'" } else { "'PRE_ROUTE_RESOLUTION_CURRENT_DEV'" }),
 'tls_version',(SELECT version FROM pg_stat_ssl WHERE pid=pg_backend_pid()),
 'can_read_roles',has_table_privilege(current_user,'pg_catalog.pg_roles','SELECT'),
 'can_read_memberships',has_table_privilege(current_user,'pg_catalog.pg_auth_members','SELECT'),
 'permission_gaps',(SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
   WHERE c.relkind IN('r','p','m','S') AND n.nspname NOT IN('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_%'
   AND CASE WHEN c.relkind='S' THEN NOT has_sequence_privilege(current_user,c.oid,'SELECT') ELSE NOT has_table_privilege(current_user,c.oid,'SELECT') END),
 'resolution_schema_absent',to_regnamespace('resolution_private') IS NULL,
 'resolution_schema_present',to_regnamespace('resolution_private') IS NOT NULL,
 'resolution_function_conflicts',(SELECT count(*) FROM pg_proc p WHERE p.pronamespace='public'::regnamespace AND p.proname IN('report_my_route_interruption','submit_route_resolution_evidence','report_route_resolution_incident','list_my_route_resolution_cases','get_my_route_resolution','get_my_route_resolution_receipt','finalize_route_resolution','register_route_test_provenance','get_route_resolution_for_operator')),
 'resolution_functions_present',(SELECT count(*) FROM unnest(ARRAY['public.report_my_route_interruption(uuid,text,uuid)','public.submit_route_resolution_evidence(uuid,uuid,text,bigint,uuid)','public.report_route_resolution_incident(uuid,uuid,text,uuid)','public.list_my_route_resolution_cases()','public.get_my_route_resolution(uuid)','public.get_my_route_resolution_receipt(uuid)','public.finalize_route_resolution(uuid,bigint,uuid)','public.register_route_test_provenance(uuid,text,uuid,uuid,uuid[],uuid)','public.get_route_resolution_for_operator(uuid)']) sig WHERE to_regprocedure(sig) IS NOT NULL),
 'authority_trigger_enabled',EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.pickup_tasks'::regclass AND tgname='routing_task_authority' AND tgenabled='O'),
 'policy_digest_valid',NOT EXISTS(SELECT 1 FROM routing_private.policies WHERE digest IS DISTINCT FROM encode(sha256(convert_to(body::text,'UTF8')),'hex')),
 'functions',(SELECT jsonb_agg(jsonb_build_object('signature',sig,'name',n.nspname||'.'||p.proname,'body_md5',md5(replace(p.prosrc,E'\r\n',E'\n')),'acl',coalesce(p.proacl::text,'DEFAULT')) FROM unnest(ARRAY[$quoted]) sig LEFT JOIN pg_proc p ON p.oid=to_regprocedure(sig) LEFT JOIN pg_namespace n ON n.oid=p.pronamespace),
 'preserved_route',(SELECT jsonb_build_object('route_id',r.route_id,'status',r.route_status,'vehicle_id',v.vehicle_id,'vehicle_label',v.vehicle_label,'vehicle_version',v.vehicle_version,'bound_vehicle_version',b.vehicle_version,'started_at',b.started_at,'closed_at',b.closed_at,'assignments',(SELECT count(*) FROM public.active_task_route_assignments a WHERE a.route_id=r.route_id)) FROM public.pickup_routes r JOIN routing_private.bindings b ON b.route_id=r.route_id JOIN public.vehicles v ON v.vehicle_id=b.vehicle_id WHERE r.route_id='db1b455e-92d0-4d58-9fa1-5de07d7ab0f9'),
 'completed_v3',(SELECT jsonb_build_object('route_id',r.route_id,'status',r.route_status,
 'closed_at',b.closed_at,'candidate_id',b.candidate_id,'snapshot_id',c.snapshot_id,
 'assignments',(SELECT count(*) FROM public.active_task_route_assignments a WHERE a.route_id=r.route_id),
 'completed_items',(SELECT count(*) FROM routing_private.items i JOIN public.pickup_tasks t USING(task_id)
 JOIN public.donation_claims dc USING(claim_id) JOIN public.claim_leases le USING(claim_id)
 JOIN public.listings l ON l.listing_id=t.listing_id JOIN public.donations d ON d.donation_id=l.donation_id
 WHERE i.route_id=r.route_id AND t.task_status='COLLECTED' AND dc.claim_status='COMPLETED'
 AND le.lease_status='COMPLETED' AND l.listing_status='CLOSED' AND d.donation_status='COLLECTED'),
 'closure_audit_count',(SELECT count(*) FROM public.audit_events a WHERE a.entity_id=r.route_id
 AND a.event_type='CLOSE_COLLECTED_ROUTE' AND a.outcome='SUCCESS' AND a.actor_user_id=b.ngo_id),
 'receipt_count',(SELECT count(*) FROM routing_private.requests q WHERE q.ngo_id=b.ngo_id
 AND q.result->'route_ids' @> jsonb_build_array(r.route_id)))
 FROM public.pickup_routes r JOIN routing_private.bindings b USING(route_id)
 JOIN routing_private.candidates c ON c.candidate_id=b.candidate_id
 WHERE r.route_id='7dd2d00a-ff03-4021-994f-155bbfc8e12c'),
 'recovery_records',jsonb_build_object($recordSql),
"@
}

function Assert-CurrentInventory($Inventory) {
    $baseline=Get-RouteResolutionBackupBaseline
    $functionBaseline = if ($PreClaimScopedReconciliation) { @($baseline.functions) } else { @($baseline.pre_route_resolution_functions) }
    $expectedPurpose = if ($PreClaimScopedReconciliation) { 'PRE_CLAIM_SCOPED_RECONCILIATION_CURRENT_DEV' } else { 'PRE_ROUTE_RESOLUTION_CURRENT_DEV' }
    foreach ($condition in @(
        @('CAPTURE_PURPOSE', ($Inventory.capture_purpose -eq $expectedPurpose)),
        @('TLS_SSL', [bool]$Inventory.ssl), @('TLS_VERSION', [bool]$Inventory.tls_version),
        @('EXPORT_ROLE_BYPASSRLS', [bool]$Inventory.bypassrls),
        @('ROLE_CATALOG_SELECT', [bool]$Inventory.can_read_roles),
        @('ROLE_MEMBERSHIP_CATALOG_SELECT', [bool]$Inventory.can_read_memberships),
        @('TABLE_SEQUENCE_SELECT_COVERAGE', ([int]$Inventory.permission_gaps -eq 0))
    )) { if (!$condition[1]) { throw "BACKUP_INVENTORY_FAILED:$($condition[0])" } }
    if ($PreClaimScopedReconciliation) {
        if (!$Inventory.resolution_schema_present) { throw 'BACKUP_INVENTORY_FAILED:ROUTE_RESOLUTION_SCHEMA_MISSING' }
        if ([int]$Inventory.resolution_functions_present -ne 9) { throw "BACKUP_INVENTORY_FAILED:ROUTE_RESOLUTION_FUNCTIONS_PRESENT:$($Inventory.resolution_functions_present):expected=9" }
    } else {
        if (!$Inventory.resolution_schema_absent) { throw 'BACKUP_INVENTORY_FAILED:PRE_ROUTE_RESOLUTION_SCHEMA_ABSENT' }
        if ([int]$Inventory.resolution_function_conflicts -ne 0) { throw "BACKUP_INVENTORY_FAILED:PRE_ROUTE_RESOLUTION_FUNCTION_COUNT:$($Inventory.resolution_function_conflicts)" }
    }
    if (!$Inventory.authority_trigger_enabled) { throw 'BACKUP_INVENTORY_FAILED:ROUTING_TASK_AUTHORITY_TRIGGER_ENABLED' }
    if (!$Inventory.policy_digest_valid) { throw 'BACKUP_INVENTORY_FAILED:ROUTING_POLICY_DIGEST_VALID' }
    if (@($Inventory.functions).Count -ne $functionBaseline.Count) { throw "BACKUP_INVENTORY_FAILED:FUNCTION_INVENTORY_COUNT:expected=$($functionBaseline.Count):observed=$(@($Inventory.functions).Count)" }
    foreach ($expected in $functionBaseline) {
        $fn=@($Inventory.functions | Where-Object { $_.signature -eq $expected.signature })
        if ($fn.Count -ne 1) { throw "BACKUP_INVENTORY_FAILED:FUNCTION_SIGNATURE_COUNT:$($expected.signature):$($fn.Count)" }
        if (!$fn[0].name) { throw "BACKUP_INVENTORY_FAILED:FUNCTION_NAME_MISSING:$($expected.signature)" }
        if ($fn[0].body_md5 -ne $expected.body_md5) { throw "BACKUP_INVENTORY_FAILED:FUNCTION_BODY_HASH:$($expected.signature):expected=$($expected.body_md5):observed=$($fn[0].body_md5)" }
    }
    $hubFn=@($Inventory.functions | Where-Object { $_.signature -eq 'public.get_eligible_hubs(uuid)' })
    if ($hubFn.Count -eq 1 -and $hubFn[0].acl -ne '{postgres=X/postgres,authenticated=X/postgres}') {
        throw "BACKUP_INVENTORY_FAILED:FUNCTION_ACL:public.get_eligible_hubs(uuid):expected=postgres,authenticated:observed=$($hubFn[0].acl)"
    }
    $graph=@($Inventory.recovery_records.graphs)
    if ($graph.Count -ne 1) { throw "BACKUP_INVENTORY_FAILED:PINNED_GRAPH_COUNT:$($graph.Count)" }
    if ($graph[0].graph_id -ne 'eab1f7ee-a8e0-4bed-a0e1-2c4bff024936') { throw 'BACKUP_INVENTORY_FAILED:PINNED_GRAPH_ID' }
    if ($graph[0].content_digest -ne '5e06dab0fb4d2b97ac53fd9a1178dc46aa6b98811aefbaef96528c604a04012a') { throw 'BACKUP_INVENTORY_FAILED:PINNED_GRAPH_DIGEST' }
    if ($graph[0].node_count -ne 926414) { throw "BACKUP_INVENTORY_FAILED:PINNED_GRAPH_NODE_COUNT:$($graph[0].node_count)" }
    if ($graph[0].edge_count -ne 2145828) { throw "BACKUP_INVENTORY_FAILED:PINNED_GRAPH_EDGE_COUNT:$($graph[0].edge_count)" }
    $policy=@($Inventory.recovery_records.policies)
    if ($policy.Count -ne 1) { throw "BACKUP_INVENTORY_FAILED:PINNED_POLICY_COUNT:$($policy.Count)" }
    if ($policy[0].policy_id -ne '80db858b-93e8-4a0a-94e2-dbe14940f0a1') { throw 'BACKUP_INVENTORY_FAILED:PINNED_POLICY_ID' }
    if ($policy[0].digest -ne 'b4f97b8c5ec2f41b986ea5a9bcd805cd16877d77c1d99c047c788ba4e81f734c') { throw 'BACKUP_INVENTORY_FAILED:PINNED_POLICY_DIGEST' }
    $route=$Inventory.preserved_route
    if (!$route) { throw 'BACKUP_INVENTORY_FAILED:PRESERVED_ROUTE_MISSING' }
    foreach ($condition in @(
        @('PRESERVED_ROUTE_ID', ($route.route_id -eq 'db1b455e-92d0-4d58-9fa1-5de07d7ab0f9')),
        @('PRESERVED_ROUTE_STATUS', ($route.status -eq 'IN_PROGRESS')),
        @('PRESERVED_ROUTE_VEHICLE', ($route.vehicle_label -eq 'V2')),
        @('PRESERVED_ROUTE_STARTED', [bool]$route.started_at),
        @('PRESERVED_ROUTE_NOT_CLOSED', !$route.closed_at),
        @('PRESERVED_ROUTE_ASSIGNMENTS', ($route.assignments -eq 3)),
        @('PRESERVED_ROUTE_VEHICLE_VERSION', ($route.vehicle_version -eq $route.bound_vehicle_version))
    )) { if (!$condition[1]) { throw "BACKUP_INVENTORY_FAILED:$($condition[0])" } }
    $v3=$Inventory.completed_v3
    if (!$v3) { throw 'BACKUP_INVENTORY_FAILED:COMPLETED_V3_ROUTE_MISSING' }
    foreach ($condition in @(
        @('COMPLETED_V3_ROUTE_ID', ($v3.route_id -eq '7dd2d00a-ff03-4021-994f-155bbfc8e12c')),
        @('COMPLETED_V3_STATUS', ($v3.status -eq 'COMPLETED')),
        @('COMPLETED_V3_CLOSED', [bool]$v3.closed_at),
        @('COMPLETED_V3_ASSIGNMENTS', ($v3.assignments -eq 0)),
        @('COMPLETED_V3_ITEMS', ($v3.completed_items -eq 3)),
        @('COMPLETED_V3_CLOSURE_AUDIT', ($v3.closure_audit_count -eq 1)),
        @('COMPLETED_V3_RECEIPT', ($v3.receipt_count -eq 1)),
        @('COMPLETED_V3_CANDIDATE', ($v3.candidate_id -eq 'fba83a33-fd32-49fa-a123-a4f1d68908d4')),
        @('COMPLETED_V3_SNAPSHOT', ($v3.snapshot_id -eq '269e6a6e-a38b-4904-aa5e-cd21f6667805'))
    )) { if (!$condition[1]) { throw "BACKUP_INVENTORY_FAILED:$($condition[0])" } }
}

function Test-CurrentArchive([string]$Directory,[string]$Archive,$Inventory) {
    Assert-CurrentInventory -Inventory $Inventory
    $arguments=@('--data-only','--schema','routing_private')
    foreach ($table in @('policies','graphs','snapshots','matrices','candidates','validations','bindings','items','requests')) { $arguments+=@('--table',$table) }
    $arguments+=@('--file',(Join-Path $Directory 'routing-recovery-data.sql'),$Archive)
    & (Join-Path $stage003Bin 'pg_restore.exe') @arguments
    if ($LASTEXITCODE -ne 0) { throw 'Routing recovery metadata decode failed.' }
    $verifyPurpose = if ($PreClaimScopedReconciliation) { 'PRE_CLAIM_SCOPED_RECONCILIATION_CURRENT_DEV' } else { 'PRE_ROUTE_RESOLUTION_CURRENT_DEV' }
    & (Join-Path $stage003Root '.venv-stage8/Scripts/python.exe') -B (Join-Path $PSScriptRoot 'backup_current_verify.py') --directory $Directory --purpose $verifyPurpose
    if ($LASTEXITCODE -ne 0) { throw 'Current archive verification failed; no recovery PASS.' }
}

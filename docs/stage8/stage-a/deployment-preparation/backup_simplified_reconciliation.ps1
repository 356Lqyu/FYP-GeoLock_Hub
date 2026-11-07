# Definitions only. Loaded by backup_pre003.ps1 -PreSimplifiedReconciliation.
# No connections, capture or restore occurs when this file is dot-sourced.
function Get-RouteResolutionBackupBaseline {
    $baseline=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'simplified_reconciliation_backup_baseline.json') -Raw | ConvertFrom-Json
    if ($baseline.project_ref -ne 'rcgyuwiidqvrgbxswhqj' -or $baseline.purpose -ne 'PRE_SIMPLIFIED_RECONCILIATION_CURRENT_DEV' -or @($baseline.functions).Count -ne 31) { throw 'BACKUP_INVENTORY_FAILED:SIMPLIFIED_BASELINE_INVALID' }
    return $baseline
}

function New-CurrentInventoryFields {
    $baseline=Get-RouteResolutionBackupBaseline
    $quoted=($baseline.functions | ForEach-Object { "'"+$_.signature.Replace("'","''")+"'" }) -join ','
    $records=@('policies','graphs','snapshots','matrices','candidates','validations','bindings','items','requests') | ForEach-Object {
        $projection=if ($_ -eq 'policies') { 'to_jsonb(t)' } elseif ($_ -eq 'bindings') { "to_jsonb(t)-'plan'" } elseif ($_ -eq 'requests') { "to_jsonb(t)-'result'" } else { "to_jsonb(t)-'body'" }
        "'$_',(SELECT coalesce(jsonb_agg($projection),'[]'::jsonb) FROM routing_private.$_ t)"
    }
    $recordSql=$records -join ",`n"
    return @"
 'capture_purpose','PRE_SIMPLIFIED_RECONCILIATION_CURRENT_DEV',
 'tls_version',(SELECT version FROM pg_stat_ssl WHERE pid=pg_backend_pid()),
 'can_read_roles',has_table_privilege(current_user,'pg_catalog.pg_roles','SELECT'),
 'can_read_memberships',has_table_privilege(current_user,'pg_catalog.pg_auth_members','SELECT'),
 'permission_gaps',(SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE c.relkind IN('r','p','m','S') AND n.nspname NOT IN('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_%'
  AND CASE WHEN c.relkind='S' THEN NOT has_sequence_privilege(current_user,c.oid,'SELECT') ELSE NOT has_table_privilege(current_user,c.oid,'SELECT') END),
 'application_ledger_absent',to_regclass('supabase_migrations.schema_migrations') IS NULL,
 'coordination_absent',to_regprocedure('public.submit_claim_reconciliation_v2(uuid,boolean,integer,bigint,uuid)') IS NULL
  AND to_regprocedure('public.get_my_authorized_route_pre_coordination(uuid)') IS NULL
  AND to_regclass('routing_private.coord_current_evidence') IS NULL
  AND NOT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='claim_reconciliation_cases' AND column_name='evidence_round'),
 'authority_trigger_enabled',EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.pickup_tasks'::regclass AND tgname='routing_task_authority' AND tgenabled='O'),
 'fleet_trigger_enabled',EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.pickup_routes'::regclass AND tgname='c1_route_vehicle_guard' AND tgenabled='O'),
 'functions',(SELECT jsonb_agg(jsonb_build_object('signature',sig,'name',n.nspname||'.'||p.proname,
  'body_md5',md5(replace(p.prosrc,chr(13),'')),'owner',p.proowner::regrole::text,'definer',p.prosecdef,'acl',p.proacl::text))
  FROM unnest(ARRAY[$quoted]) expected(sig) JOIN pg_proc p ON p.oid=to_regprocedure(sig) JOIN pg_namespace n ON n.oid=p.pronamespace),
 'recovery_records',jsonb_build_object($recordSql),
"@
}

function Assert-CurrentInventory($Inventory) {
    $baseline=Get-RouteResolutionBackupBaseline
    foreach ($condition in @(
        @('CAPTURE_PURPOSE', ($Inventory.capture_purpose -eq $baseline.purpose)),
        @('TLS_SSL', [bool]$Inventory.ssl), @('TLS_VERSION', [bool]$Inventory.tls_version),
        @('EXPORT_ROLE_BYPASSRLS', [bool]$Inventory.bypassrls),
        @('ROLE_CATALOG_SELECT', [bool]$Inventory.can_read_roles),
        @('ROLE_MEMBERSHIP_CATALOG_SELECT', [bool]$Inventory.can_read_memberships),
        @('TABLE_SEQUENCE_SELECT_COVERAGE', ($null -ne $Inventory.permission_gaps -and [int]$Inventory.permission_gaps -eq 0)),
        @('EXPECTED_MANUAL_LEDGER_BASELINE', [bool]$Inventory.application_ledger_absent),
        @('COORDINATION_NOT_INSTALLED', [bool]$Inventory.coordination_absent),
        @('ROUTING_TASK_AUTHORITY_TRIGGER_ENABLED', [bool]$Inventory.authority_trigger_enabled),
        @('FLEET_TRIGGER_ENABLED', [bool]$Inventory.fleet_trigger_enabled)
    )) { if (!$condition[1]) { throw "BACKUP_INVENTORY_FAILED:$($condition[0])" } }
    if (@($Inventory.functions).Count -ne @($baseline.functions).Count) { throw 'BACKUP_INVENTORY_FAILED:FUNCTION_INVENTORY_COUNT' }
    foreach ($expected in $baseline.functions) {
        $fn=@($Inventory.functions | Where-Object { $_.signature -eq $expected.signature })
        if ($fn.Count -ne 1) { throw 'BACKUP_INVENTORY_FAILED:FUNCTION_SIGNATURE_COUNT' }
        foreach ($field in @('name','body_md5','owner','definer','acl')) {
            if ($fn[0].$field -cne $expected.$field) { throw "BACKUP_INVENTORY_FAILED:FUNCTION_$field" }
        }
    }
    foreach ($table in @('policies','graphs','snapshots','matrices','candidates','validations','bindings','items','requests')) {
        if ($null -eq $Inventory.recovery_records.PSObject.Properties[$table]) { throw 'BACKUP_INVENTORY_FAILED:RECOVERY_SECTION_MISSING' }
    }
}

function Test-CurrentArchive([string]$Directory,[string]$Archive,$Inventory) {
    Assert-CurrentInventory -Inventory $Inventory
    $arguments=@('--data-only','--schema','routing_private')
    foreach ($table in @('policies','graphs','snapshots','matrices','candidates','validations','bindings','items','requests')) { $arguments+=@('--table',$table) }
    $arguments+=@('--file',(Join-Path $Directory 'routing-recovery-data.sql'),$Archive)
    & (Join-Path $stage003Bin 'pg_restore.exe') @arguments
    if ($LASTEXITCODE -ne 0) { throw 'Routing recovery metadata decode failed.' }
    & (Join-Path $stage003Root '.venv-stage8/Scripts/python.exe') -B (Join-Path $PSScriptRoot 'backup_current_verify.py') --directory $Directory --purpose 'PRE_SIMPLIFIED_RECONCILIATION_CURRENT_DEV'
    if ($LASTEXITCODE -ne 0) { throw 'Current archive verification failed; no recovery PASS.' }
}

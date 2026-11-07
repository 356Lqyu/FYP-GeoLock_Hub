# Helpers for the existing native backup runner. Dot-sourcing performs no IO.
function Protect-CurrentCaptureDirectory([string]$Directory) {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetOwner($sid)
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($principal in @($sid, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'), [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($principal,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Directory -AclObject $acl -ErrorAction Stop
    $privateAcl = Get-Acl -LiteralPath $Directory
    if (!$privateAcl.AreAccessRulesProtected) { throw 'Private capture ACL not enforced.' }
    $probe = Join-Path $Directory $stage003ArchiveName
    & git -C $stage003Root check-ignore --quiet -- $probe
    if ($LASTEXITCODE -ne 0) { throw 'Backup destination is not Git-ignored; no export started.' }
    $tracked = @(& git -C $stage003Root ls-files -- $Directory)
    if ($LASTEXITCODE -ne 0 -or $tracked.Count -ne 0) { throw 'Backup destination tracking check failed.' }
}

function New-CurrentInventoryFields {
    $expected = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'expected-functions.json') -Raw | ConvertFrom-Json
    $signatures = @(@($expected.baseline.PSObject.Properties.Name) + @($expected.post003.PSObject.Properties.Name) | Sort-Object -Unique)
    $quoted = ($signatures | ForEach-Object { "'" + $_.Replace("'","''") + "'" }) -join ','
    $records = @('policies','graphs','snapshots','matrices','candidates','validations') | ForEach-Object {
        $projection = if ($_ -eq 'policies') { 'to_jsonb(t)' } else { "to_jsonb(t)-'body'" }
        "'$_',(SELECT coalesce(jsonb_agg($projection),'[]'::jsonb) FROM routing_private.$_ t)"
    }
    $recordSql = $records -join ",`n"
    return @"
 'capture_purpose','PRE_AUTOMATIC_DEPARTURE_CURRENT_DEV',
 'tls_version',(SELECT version FROM pg_stat_ssl WHERE pid=pg_backend_pid()),
 'can_read_roles',has_table_privilege(current_user,'pg_catalog.pg_roles','SELECT'),
 'can_read_memberships',has_table_privilege(current_user,'pg_catalog.pg_auth_members','SELECT'),
 'permission_gaps',(SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
   WHERE c.relkind IN ('r','p','m','S') AND n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_%'
   AND CASE WHEN c.relkind='S' THEN NOT has_sequence_privilege(current_user,c.oid,'SELECT') ELSE NOT has_table_privilege(current_user,c.oid,'SELECT') END),
 'new_receipt_absent',to_regprocedure('public.get_my_routing_authorization_receipt(uuid)') IS NULL,
 'authority_trigger_enabled',EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.pickup_tasks'::regclass AND tgname='routing_task_authority' AND tgenabled='O'),
 'policy_digest_valid',NOT EXISTS(SELECT 1 FROM routing_private.policies WHERE digest IS DISTINCT FROM encode(sha256(convert_to(body::text,'UTF8')),'hex')),
 'functions',(SELECT jsonb_agg(jsonb_build_object('signature',sig,'name',n.nspname||'.'||p.proname,'body_md5',md5(replace(p.prosrc,E'\r\n',E'\n'))))
   FROM unnest(ARRAY[$quoted]) sig LEFT JOIN pg_proc p ON p.oid=to_regprocedure(sig) LEFT JOIN pg_namespace n ON n.oid=p.pronamespace),
 'recovery_records',jsonb_build_object($recordSql),
"@
}

function Assert-CurrentInventory($Inventory) {
    foreach ($condition in @(
        @('TLS_SSL', [bool]$Inventory.ssl), @('TLS_VERSION', [bool]$Inventory.tls_version),
        @('EXPORT_ROLE_BYPASSRLS', [bool]$Inventory.bypassrls),
        @('ROLE_CATALOG_SELECT', [bool]$Inventory.can_read_roles),
        @('ROLE_MEMBERSHIP_CATALOG_SELECT', [bool]$Inventory.can_read_memberships),
        @('TABLE_SEQUENCE_SELECT_COVERAGE', ([int]$Inventory.permission_gaps -eq 0))
    )) { if (!$condition[1]) { throw "BACKUP_INVENTORY_FAILED:$($condition[0])" } }
    foreach ($condition in @(
        @('PRE_AUTOMATIC_DEPARTURE_RECEIPT_ABSENCE', [bool]$Inventory.new_receipt_absent),
        @('ROUTING_TASK_AUTHORITY_TRIGGER_ENABLED', [bool]$Inventory.authority_trigger_enabled),
        @('ROUTING_POLICY_DIGEST_VALID', [bool]$Inventory.policy_digest_valid)
    )) { if (!$condition[1]) { throw "BACKUP_INVENTORY_FAILED:$($condition[0])" } }
    foreach ($fn in $Inventory.functions) { if (!$fn.name -or !$fn.body_md5) { throw "BACKUP_INVENTORY_FAILED:REQUIRED_FUNCTION_MISSING:$($fn.signature)" } }
    # Approved later Stage 8 bodies: 20261104_routing_automatic_departure.sql
    # and 20261108_per_stop_reconciliation.sql. Hashes normalize CRLF to LF.
    foreach ($pair in @(@('public.authorize_my_routing_candidate(uuid,uuid,timestamptz)','e383a34bfadba383cf71ac07b0854a47'),@('public.get_my_authorized_route(uuid)','d2e9e87bda5611f0a4afe2013a8f9235'))) {
        $fn = @($Inventory.functions | Where-Object { $_.signature -eq $pair[0] })
        if ($fn.Count -ne 1) { throw "BACKUP_INVENTORY_FAILED:FUNCTION_SIGNATURE_COUNT:$($pair[0]):$($fn.Count)" }
        if ($fn[0].body_md5 -ne $pair[1]) { throw "BACKUP_INVENTORY_FAILED:FUNCTION_BODY_HASH:$($pair[0]):expected=$($pair[1]):observed=$($fn[0].body_md5)" }
    }
    $graph = @($Inventory.recovery_records.graphs | Where-Object { $_.graph_id -eq 'eab1f7ee-a8e0-4bed-a0e1-2c4bff024936' })
    if ($graph.Count -ne 1) { throw "BACKUP_INVENTORY_FAILED:PINNED_GRAPH_COUNT:$($graph.Count)" }
    if ($graph[0].content_digest -ne '5e06dab0fb4d2b97ac53fd9a1178dc46aa6b98811aefbaef96528c604a04012a') { throw 'BACKUP_INVENTORY_FAILED:PINNED_GRAPH_DIGEST' }
    if ($graph[0].node_count -ne 926414) { throw "BACKUP_INVENTORY_FAILED:PINNED_GRAPH_NODE_COUNT:$($graph[0].node_count)" }
    if ($graph[0].edge_count -ne 2145828) { throw "BACKUP_INVENTORY_FAILED:PINNED_GRAPH_EDGE_COUNT:$($graph[0].edge_count)" }
    $policy = @($Inventory.recovery_records.policies | Where-Object { $_.policy_id -eq '80db858b-93e8-4a0a-94e2-dbe14940f0a1' })
    if ($policy.Count -ne 1) { throw "BACKUP_INVENTORY_FAILED:PINNED_POLICY_COUNT:$($policy.Count)" }
    if ($policy[0].digest -ne 'b4f97b8c5ec2f41b986ea5a9bcd805cd16877d77c1d99c047c788ba4e81f734c') { throw 'BACKUP_INVENTORY_FAILED:PINNED_POLICY_DIGEST' }
    $candidate = @($Inventory.recovery_records.candidates | Where-Object { $_.candidate_id -eq 'a00bc45c-33f9-4193-8cb6-f313d92e4b5c' })
    $validation = @($Inventory.recovery_records.validations | Where-Object { $_.candidate_id -eq 'a00bc45c-33f9-4193-8cb6-f313d92e4b5c' })
    if ($candidate.Count -ne 1) { throw "BACKUP_INVENTORY_FAILED:PINNED_CANDIDATE_COUNT:$($candidate.Count)" }
    if ($candidate[0].digest -ne 'f27336b441ecc1e180102ca85bea9078864f8f01cfba0a04b00d6bf097e5c23e') { throw 'BACKUP_INVENTORY_FAILED:PINNED_CANDIDATE_DIGEST' }
    if ($validation.Count -ne 1) { throw "BACKUP_INVENTORY_FAILED:PINNED_VALIDATION_COUNT:$($validation.Count)" }
    if ($validation[0].candidate_digest -ne $candidate[0].digest) { throw 'BACKUP_INVENTORY_FAILED:VALIDATION_CANDIDATE_DIGEST' }
    $snapshot = @($Inventory.recovery_records.snapshots | Where-Object { $_.snapshot_id -eq 'f597018e-e068-486f-a99b-4e194a2c57dc' })
    $matrix = @($Inventory.recovery_records.matrices | Where-Object { $_.matrix_id -eq '82eff664-095b-4d53-9c7f-c1f7e9ff6347' })
    if ($snapshot.Count -ne 1) { throw "BACKUP_INVENTORY_FAILED:PINNED_SNAPSHOT_COUNT:$($snapshot.Count)" }
    if ($snapshot[0].digest -ne '5b9575e299e3eb0bb184ef38cab0d0d9a335c3eceb3e074ffc8b3dc7bc22699e') { throw 'BACKUP_INVENTORY_FAILED:PINNED_SNAPSHOT_DIGEST' }
    if ($matrix.Count -ne 1) { throw "BACKUP_INVENTORY_FAILED:PINNED_MATRIX_COUNT:$($matrix.Count)" }
    if ($matrix[0].digest -ne 'cbd17ffe9cfc5d95a18124aa78e9e8f76525db5526d66be2372262be24a7885b') { throw 'BACKUP_INVENTORY_FAILED:PINNED_MATRIX_DIGEST' }
    if ($candidate[0].snapshot_id -ne $snapshot[0].snapshot_id) { throw 'BACKUP_INVENTORY_FAILED:CANDIDATE_SNAPSHOT_BINDING' }
    if ($snapshot[0].matrix_id -ne $matrix[0].matrix_id) { throw 'BACKUP_INVENTORY_FAILED:SNAPSHOT_MATRIX_BINDING' }
    if ($matrix[0].graph_id -ne $graph[0].graph_id) { throw 'BACKUP_INVENTORY_FAILED:MATRIX_GRAPH_BINDING' }
    foreach ($id in @('2aa2c13b-091f-49fc-81c1-891f6d414676','d761e0a1-6bd6-4c75-a7da-de40aa973dd7','d0e82ff8-40cd-4199-99cd-e3330e97e690','f597018e-e068-486f-a99b-4e194a2c57dc')) {
        $historicalCount = @($Inventory.recovery_records.snapshots | Where-Object { $_.snapshot_id -eq $id }).Count
        if ($historicalCount -ne 1) { throw "BACKUP_INVENTORY_FAILED:HISTORICAL_SNAPSHOT_COUNT:${id}:${historicalCount}" }
    }
}

function Test-CurrentArchive([string]$Directory,[string]$Archive,$Inventory) {
    Assert-CurrentInventory -Inventory $Inventory
    $currentRestoreArguments = @('--data-only','--schema','routing_private')
    foreach ($table in @('policies','graphs','snapshots','matrices','candidates','validations')) { $currentRestoreArguments += @('--table',$table) }
    $currentRestoreArguments += @('--file',(Join-Path $Directory 'routing-recovery-data.sql'),$Archive)
    & (Join-Path $stage003Bin 'pg_restore.exe') @currentRestoreArguments
    if ($LASTEXITCODE -ne 0) { throw 'Current routing evidence decode failed.' }
    $python = Join-Path $stage003Root '.venv-stage8/Scripts/python.exe'
    & $python -B (Join-Path $PSScriptRoot 'backup_current_verify.py') --directory $Directory
    if ($LASTEXITCODE -ne 0) { throw 'Current-state archive comparison failed. Not a verified backup.' }
}

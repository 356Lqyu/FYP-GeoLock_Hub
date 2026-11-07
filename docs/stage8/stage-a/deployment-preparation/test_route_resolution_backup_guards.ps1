# Offline synthetic inventory only: no process, DB, network or archive operation.
$ErrorActionPreference='Stop'
$stage003Root=(Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
. (Join-Path $PSScriptRoot 'backup_route_resolution.ps1')
$baseline=Get-RouteResolutionBackupBaseline
$inventory=[ordered]@{
 capture_purpose='PRE_ROUTE_RESOLUTION_CURRENT_DEV';ssl=$true;bypassrls=$true;tls_version='TLSv1.3'
 can_read_roles=$true;can_read_memberships=$true;permission_gaps=0;resolution_schema_absent=$true
 resolution_schema_present=$false;resolution_function_conflicts=0;resolution_functions_present=9
 authority_trigger_enabled=$true;policy_digest_valid=$true
 functions=@($baseline.pre_route_resolution_functions | ForEach-Object { [ordered]@{signature=$_.signature;name=($_.signature -replace '\(.*$','');body_md5=$_.body_md5;acl=$(if($_.signature -eq 'public.get_eligible_hubs(uuid)'){'{postgres=X/postgres,authenticated=X/postgres}'}else{'{postgres=X/postgres}'})} })
 recovery_records=@{
  graphs=@(@{graph_id='eab1f7ee-a8e0-4bed-a0e1-2c4bff024936';content_digest='5e06dab0fb4d2b97ac53fd9a1178dc46aa6b98811aefbaef96528c604a04012a';node_count=926414;edge_count=2145828})
  policies=@(@{policy_id='80db858b-93e8-4a0a-94e2-dbe14940f0a1';digest='b4f97b8c5ec2f41b986ea5a9bcd805cd16877d77c1d99c047c788ba4e81f734c'})
 }
 preserved_route=@{route_id='db1b455e-92d0-4d58-9fa1-5de07d7ab0f9';status='IN_PROGRESS';vehicle_label='V2';started_at='SYNTHETIC';closed_at=$null;assignments=3;vehicle_version=1;bound_vehicle_version=1}
 completed_v3=@{route_id='7dd2d00a-ff03-4021-994f-155bbfc8e12c';status='COMPLETED';closed_at='SYNTHETIC';assignments=0;completed_items=3;closure_audit_count=1;receipt_count=1;candidate_id='fba83a33-fd32-49fa-a123-a4f1d68908d4';snapshot_id='269e6a6e-a38b-4904-aa5e-cd21f6667805'}
}
$encoded=$inventory | ConvertTo-Json -Depth 20
$passed=0
Assert-CurrentInventory -Inventory ($encoded | ConvertFrom-Json)
$passed++
$PreClaimScopedReconciliation=$true
$claimInventory=$encoded | ConvertFrom-Json
$claimInventory.capture_purpose='PRE_CLAIM_SCOPED_RECONCILIATION_CURRENT_DEV'
$claimInventory.resolution_schema_absent=$false
$claimInventory.resolution_schema_present=$true
$claimInventory.resolution_function_conflicts=9
$claimInventory.resolution_functions_present=9
$claimInventory.functions=@($baseline.functions | ForEach-Object { [ordered]@{signature=$_.signature;name=($_.signature -replace '\(.*$','');body_md5=$_.body_md5;acl=$(if($_.signature -eq 'public.get_eligible_hubs(uuid)'){'{postgres=X/postgres,authenticated=X/postgres}'}else{'{postgres=X/postgres}'})} })
Assert-CurrentInventory -Inventory $claimInventory
$passed++
$PreClaimScopedReconciliation=$false
$probe=$encoded | ConvertFrom-Json
$probe.resolution_schema_absent=$false
try { Assert-CurrentInventory -Inventory $probe; throw 'Expected pre-route schema guard did not reject.' }
catch { if ($_.Exception.Message -ne 'BACKUP_INVENTORY_FAILED:PRE_ROUTE_RESOLUTION_SCHEMA_ABSENT') { throw } }
$passed++
$probe=$encoded | ConvertFrom-Json
($probe.functions | Where-Object { $_.signature -eq 'public.get_eligible_hubs(uuid)' } | Select-Object -First 1).acl='{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'
try { Assert-CurrentInventory -Inventory $probe; throw 'Expected function ACL guard did not reject.' }
catch { if ($_.Exception.Message -notmatch '^BACKUP_INVENTORY_FAILED:FUNCTION_ACL:public\.get_eligible_hubs\(uuid\):') { throw } }
$passed++
$probe=$encoded | ConvertFrom-Json
($probe.functions | Where-Object { $_.signature -eq 'public.get_eligible_hubs(uuid)' } | Select-Object -First 1).body_md5='1444c3c9a1cee2700426558ed95fdf58'
try { Assert-CurrentInventory -Inventory $probe; throw 'Expected function hash guard did not reject.' }
catch { if ($_.Exception.Message -notmatch '^BACKUP_INVENTORY_FAILED:FUNCTION_BODY_HASH:public\.get_eligible_hubs\(uuid\):') { throw } }
$passed++
foreach ($field in @('status','closed_at','assignments','completed_items','closure_audit_count','receipt_count','candidate_id','snapshot_id')) {
 $probe=$encoded | ConvertFrom-Json
 switch ($field) {
  'status' { $probe.completed_v3.status='IN_PROGRESS' }
  'closed_at' { $probe.completed_v3.closed_at=$null }
  'assignments' { $probe.completed_v3.assignments=1 }
  'completed_items' { $probe.completed_v3.completed_items=2 }
  'closure_audit_count' { $probe.completed_v3.closure_audit_count=0 }
  'receipt_count' { $probe.completed_v3.receipt_count=0 }
  'candidate_id' { $probe.completed_v3.candidate_id='00000000-0000-0000-0000-000000000000' }
  'snapshot_id' { $probe.completed_v3.snapshot_id='00000000-0000-0000-0000-000000000000' }
 }
 $rejected=$false
 try { Assert-CurrentInventory -Inventory $probe } catch { $rejected=$true }
 if (!$rejected) { throw ('Missing V3 rejection: '+$field) }
 $passed++
}
$probe=$encoded | ConvertFrom-Json
$probe.preserved_route.assignments=2
$rejected=$false
try { Assert-CurrentInventory -Inventory $probe } catch { $rejected=$true }
if (!$rejected) { throw 'Missing preserved V2 assignment rejection.' }
$passed++
$sql=New-CurrentInventoryFields
if ($sql -notmatch 'completed_v3' -or $sql -notmatch 'closure_audit_count' -or $sql -notmatch 'receipt_count') { throw 'Generated inventory missing V3 checks.' }
$passed++
[ordered]@{status='PASS';synthetic_checks=$passed;connection_attempted=$false;backup_executed=$false} | ConvertTo-Json

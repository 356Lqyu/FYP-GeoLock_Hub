# Synthetic/offline only. No credentials, archive, process start or DB connections.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'backup_simplified_reconciliation.ps1')
$baseline=Get-RouteResolutionBackupBaseline
$inventory=[pscustomobject]@{
    capture_purpose=$baseline.purpose;ssl=$true;tls_version='TLSv1.3';bypassrls=$true
    can_read_roles=$true;can_read_memberships=$true;permission_gaps=0
    application_ledger_absent=$true;coordination_absent=$true;authority_trigger_enabled=$true;fleet_trigger_enabled=$true
    functions=$baseline.functions;recovery_records=[pscustomobject]@{policies=@();graphs=@();snapshots=@();matrices=@();candidates=@();validations=@();bindings=@();items=@();requests=@()}
}
Assert-CurrentInventory $inventory
$cases=0
foreach ($field in @('ssl','tls_version','bypassrls','can_read_roles','can_read_memberships','application_ledger_absent','coordination_absent','authority_trigger_enabled','fleet_trigger_enabled')) {
    $original=$inventory.$field;$inventory.$field=$false
    $rejected=$false
    try { Assert-CurrentInventory $inventory } catch { $rejected=$true }
    if (!$rejected) { throw "Synthetic negative accepted: $field" }
    $inventory.$field=$original;$cases++
}
foreach ($field in @('name','body_md5','owner','definer','acl')) {
    $original=$inventory.functions[0].$field
    $inventory.functions[0].$field=if ($field -eq 'definer') { !$original } else { 'SYNTHETIC_DRIFT' }
    # Baseline is read afresh, so mutation of this inventory cannot alter it.
    $rejected=$false
    try { Assert-CurrentInventory $inventory } catch { $rejected=$true }
    if (!$rejected) { throw "Synthetic function drift accepted: $field" }
    $inventory.functions[0].$field=$original;$cases++
}
$sql=New-CurrentInventoryFields
if ($sql -notmatch 'PRE_SIMPLIFIED_RECONCILIATION_CURRENT_DEV' -or $sql -match '(?i)\b(INSERT INTO|UPDATE public\.|DELETE FROM|CREATE TABLE)') { throw 'Invalid inventory SQL' }
foreach ($file in @('backup_pre003.ps1','backup_simplified_reconciliation.ps1','test_simplified_backup_guards.ps1')) {
    $parseTokens=$null;$parseErrors=$null
    $null=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $file),[ref]$parseTokens,[ref]$parseErrors)
    if ($parseErrors.Count -ne 0) { throw "PowerShell syntax failed: $file" }
}
[ordered]@{status='PASS';synthetic_negative_cases=$cases;baseline_functions=@($baseline.functions).Count;connected=$false;backup_executed=$false;restore_executed=$false}|ConvertTo-Json

# Offline regression: extracts only the pure SQL builder, never runs the backup.
param([Parameter(Mandatory=$true)][string]$OutputDirectory, [string]$ScriptDirectory=$PSScriptRoot)
$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$runner = Join-Path $ScriptDirectory 'backup_pre003.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($runner,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Backup PowerShell parser failed' }
$builder = $ast.Find({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-Stage003InventorySql'},$true)
if (!$builder) { throw 'Pure inventory builder missing' }
Invoke-Expression $builder.Extent.Text
$policyPath = Join-Path $ScriptDirectory 'routing-initialization\policy.proposed.json'
$policy = Get-Content -LiteralPath $policyPath -Raw
$sql = New-Stage003InventorySql -ForFreeze -PolicyPath $policyPath
$tag = '$approved_policy$'
$start = $sql.IndexOf($tag)+$tag.Length
$end = $sql.IndexOf($tag,$start)
if ($start -lt $tag.Length -or $end -lt $start -or $sql.Substring($start,$end-$start) -cne $policy) { throw 'Generated SQL changed approved JSON' }
if ($sql -notmatch '^BEGIN READ ONLY;' -or $sql.TrimEnd() -notmatch 'ROLLBACK;$' -or $sql -match '__POLICY_JSON__|__PREFREEZE_FIELDS__') { throw 'Invalid generated transaction/template' }
$path = Join-Path $OutputDirectory 'inventory with spaces.sql'
[IO.File]::WriteAllText($path,$sql,(New-Object System.Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'baseline.sql'),(New-Stage003InventorySql),(New-Object System.Text.UTF8Encoding($false)))
$root = (Resolve-Path (Join-Path $ScriptDirectory '..\..\..\..')).Path
$python = Join-Path $root '.venv-stage8\Scripts\python.exe'
$probe = Join-Path $ScriptDirectory 'backup_argv_probe.py'
$received = (& $python $probe --file $path) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $received.Count -ne 2 -or $received[1] -cne $path) { throw 'File argument transport failed' }
$old = (& $python $probe --command $sql) | ConvertFrom-Json
$legacyCorruptsJson = ($old.Count -ne 2 -or $old[1] -cne $sql)
if ($PSVersionTable.PSVersion.Major -eq 5 -and !$legacyCorruptsJson) { throw 'Expected original Windows PowerShell quoting defect not reproduced' }
$runnerText = [IO.File]::ReadAllText($runner)
if ($runnerText -match 'Operation Inventory -Sql' -or $runnerText -notmatch "'--file',\`$stage003InventoryFile") { throw 'Runner reverted to SQL command-line transport' }
if ($runnerText -notmatch 'FAILED / NOT A VERIFIED BACKUP' -or $runnerText -notmatch 'INCOMPLETE / NOT A VERIFIED BACKUP') { throw 'Failure status guards missing' }
[pscustomobject]@{powershell=$PSVersionTable.PSVersion.ToString();exact_json_preserved=$true;file_argument_transport='PASS';original_legacy_corruption_reproduced=$legacyCorruptsJson;database_connections=0} | ConvertTo-Json

"""Offline static checks for KLSEL publishable-key handling. No PowerShell, profiles or network."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[3]
WINDOWS = ROOT / 'backend/routing/windows'
UPDATE = (WINDOWS / 'Update-PlannerPublishableKey.ps1').read_text(encoding='utf-8')
SAVE = (WINDOWS / 'Save-WorkerConfig.ps1').read_text(encoding='utf-8')
HARNESS = (WINDOWS / 'Test-PlannerPublishableKeyUpdate.ps1').read_text(encoding='utf-8')
RULE = re.compile(r'^sb_publishable_[A-Za-z0-9_-]+\Z')


def key_ok(value):
    """Python mirror of Assert-PublishableKey's acceptance rule."""
    return (value.startswith('sb_publishable_') and len(value) > 15 and not re.search(r'\s', value)
            and RULE.match(value) is not None)


class FormatRuleTests(unittest.TestCase):
    def test_rule_accepts_real_shaped_keys_and_rejects_captured_control_characters(self):
        tracked_dev_key = re.search(r"'(sb_publishable_[^']+)'",
                                    (ROOT / 'frontend/geolock_hub_app/lib/supabase_config.dart').read_text()).group(1)
        self.assertTrue(key_ok(tracked_dev_key))                       # DEV's existing key still passes
        self.assertTrue(key_ok('sb_publishable_' + 'X' * 1024 + '_DUMMY_ONLY'))   # console-paste test dummy
        for bad in ('\x16', 'sb_publishable_SYNTHETIC\x16', 'sb_publishable_', 'sb_secret_SYNTHETIC',
                    'sb_publishable_SYNTHETIC with spaces', ' sb_publishable_ABC', 'sb_publishable_ABC\n', 'eyJhbGciOi'):
            with self.subTest(bad=repr(bad)):
                self.assertFalse(key_ok(bad))
        self.assertIn("$plain -cnotmatch '^sb_publishable_[A-Za-z0-9_-]+$'", UPDATE)
        self.assertIn("$plain -match '\\s'", UPDATE)


class UpdateScriptTests(unittest.TestCase):
    def test_dev_is_default_and_keeps_its_values_prompts_and_startup_check(self):
        self.assertIn("param([switch]$CheckOnly,[ValidateSet('DEV','KLSEL')][string]$Environment='DEV')", UPDATE)
        self.assertIn("DEV  =@{Project='rcgyuwiidqvrgbxswhqj';Directory='GeoLockHubRoutingDev';Label='DEV';ProjectCheck='DevProjectMatches'", UPDATE)
        self.assertIn("GraphId='eab1f7ee-a8e0-4bed-a0e1-2c4bff024936';PoolerHost='aws-0-ap-northeast-2.pooler.supabase.com'}", UPDATE)
        # Default labels reproduce the original DEV texts exactly.
        self.assertIn("function Read-PublishableKeyHidden([string]$Label='DEV') {", UPDATE)
        self.assertIn("Write-Host ('Paste ONLY the complete '+$Label+' sb_publishable_ key (hidden; press Enter): ') -NoNewline", UPDATE)
        self.assertIn("function Assert-PublishableKey([Security.SecureString]$Value,[string]$Label='DEV') {", UPDATE)
        self.assertIn("function Set-ProtectedPlannerKey([string]$PlannerFile,[Security.SecureString]$Value,[string]$Label='DEV') {", UPDATE)
        self.assertIn("& (Join-Path $PSScriptRoot 'Start-Worker.ps1') -Mode $mode -GraphId 'eab1f7ee-a8e0-4bed-a0e1-2c4bff024936' -CheckConfig", UPDATE)

    def test_klsel_targets_only_its_own_folder_project_graph_and_pooler(self):
        self.assertIn("KLSEL=@{Project='ppwmdsyoesvhgmqiaoxa';Directory='GeoLockHubRoutingKLSEL';Label='NEW (KL/Selangor)';ProjectCheck='ProjectMatches'", UPDATE)
        self.assertIn("GraphId='19c44bd2-8871-4eca-bf6b-4262f1bf766d';PoolerHost=$null}", UPDATE)
        self.assertIn("$directory=Join-Path $env:LOCALAPPDATA $selected.Directory", UPDATE)
        self.assertIn("$serviceFile=Join-Path $directory 'pg_service.conf'", UPDATE)
        self.assertIn(".EndsWith('.pooler.supabase.com')", UPDATE)
        self.assertIn("& (Join-Path $PSScriptRoot 'Start-Worker.ps1') -Environment $Environment -Mode $mode -CheckConfig", UPDATE)
        self.assertNotIn('GeoLockHubRoutingDev\\', UPDATE.split('$environments=@{')[1].split('$selected=')[1])

    def test_only_the_encrypted_publishable_key_field_is_replaced(self):
        self.assertNotIn('Export-Clixml', UPDATE)                 # profiles are never recreated
        self.assertNotIn('Remove-Item', UPDATE)
        self.assertIn("@N='PublishableKey'", UPDATE)
        self.assertIn('(Get-KeyNode $updated).InnerText=(ConvertFrom-SecureString -SecureString $Value)', UPDATE)
        self.assertIn("if ($before.OuterXml -cne $after.OuterXml) { throw 'Unexpected configuration change: STOP.' }", UPDATE)
        self.assertIn('[IO.File]::Replace($staging,$PlannerFile,$backup)', UPDATE)
        for field in ('GraphPassword', 'PlannerPassword', 'ValidatorPassword'):
            self.assertNotIn(field, UPDATE)                         # never read, decrypted or written

    def test_klsel_cache_is_informational_and_dev_readiness_keys_unchanged(self):
        self.assertIn("$informational['PreparedGraphCachePresent']=$checks['PreparedGraphCachePresent']", UPDATE)
        self.assertIn("$checks.Remove('PreparedGraphCachePresent')", UPDATE)
        for key in ('ApprovedPoolerMatches', 'CaFilesExist', 'PublishableKeyFormatValid', 'SharedValidatorTokenMatches',
                    'PlannerPortAvailable', 'ValidatorPortAvailable', 'PreparedGraphCachePresent'):
            self.assertIn(key, UPDATE)


class SaveWorkerConfigTests(unittest.TestCase):
    def test_dev_prompt_unchanged(self):
        self.assertIn("if ($Environment -eq 'DEV') {\n    $publishable = Read-Host -AsSecureString ($label + ' sb_publishable_ key (masked; NOT a service-role key)')", SAVE)

    def test_klsel_key_is_read_hidden_and_validated_before_anything_is_written(self):
        klsel = SAVE.index("$publishable = Read-PublishableKeyHidden $label")
        check = SAVE.index("Assert-PublishableKey $publishable $label")
        first_write = min(SAVE.index('[IO.File]::WriteAllText'), SAVE.index('Export-Clixml'))
        self.assertLess(klsel, check)
        self.assertLess(check, first_write)
        self.assertIn("Join-Path $PSScriptRoot 'Update-PlannerPublishableKey.ps1'", SAVE)
        self.assertIn("foreach ($helper in @('Read-PublishableKeyHidden', 'Assert-PublishableKey'))", SAVE)


class HarnessTests(unittest.TestCase):
    def test_windows_harness_rejects_captured_ctrl_v(self):
        self.assertIn("[string][char]0x16,('sb_publishable_SYNTHETIC'+[char]0x16)", HARNESS)


if __name__ == '__main__':
    unittest.main()

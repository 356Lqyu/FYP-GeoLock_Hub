"""Synthetic conninfo/password transport checks. No authentication or network."""
import base64
import json
import configparser
from pathlib import Path
import shutil
import subprocess
import unittest

from psycopg.conninfo import conninfo_to_dict
from backend.routing.worker_service.transport import RoleRpc

ROOT=Path(__file__).resolve().parents[4]
LAUNCHER=ROOT/'docs/stage8/functional-routing/run_readonly_graph_probe.ps1'


class ProbeLauncherTests(unittest.TestCase):
    def test_diagnostic_and_full_probe_are_exclusive(self):
        text=LAUNCHER.read_text()
        self.assertIn('if ($Run -and $ConnectionDiagnostic)',text)
        diagnostic=text.split('if ($ConnectionDiagnostic) {',1)[1].split('} else {',1)[0]
        self.assertIn('worker_service.connection_diagnostic_native17',diagnostic)
        self.assertNotIn('--matrix',diagnostic)
        self.assertNotIn('readonly_pilot_probe --run',diagnostic)
    def test_synthetic_passwords_roundtrip_libpq_without_argv_escaping(self):
        # Fake values only. Actual passwords never enter command arguments/tests.
        samples=['synthetic spaces',"synthetic'quote",'synthetic\\backslash\\',
                 'synthetic"$`;&', 'synthetic ü漢字', ' synthetic ends ']
        for shell in (shutil.which('pwsh'),):
            path=str(LAUNCHER).replace("'","''")
            quoted=','.join("'"+s.replace("'","''")+"'" for s in samples)
            code=("$t=$null;$e=$null;$a=[System.Management.Automation.Language.Parser]::ParseFile('"+path+"',[ref]$t,[ref]$e);"
                  "if($e.Count){throw 'Parser failed'};"
                  "$f=$a.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-GraphProbeDsn'},$true);"
                  "Invoke-Expression $f.Extent.Text; @("+quoted+") | ForEach-Object { New-GraphProbeDsn -Password $_ } | ConvertTo-Json")
            command=base64.b64encode(code.encode('utf-16-le')).decode()
            result=subprocess.run([shell,'-NoProfile','-EncodedCommand',command],capture_output=True,text=True,encoding='utf-8',check=True)
            for dsn,password in zip(json.loads(result.stdout),samples):
                self.assertEqual(conninfo_to_dict(dsn)['password'],password)
                RoleRpc.validate_dsn(dsn)
                self.assertNotIn('options',conninfo_to_dict(dsn))
                self.assertNotIn('service',conninfo_to_dict(dsn))
                profile=configparser.ConfigParser(interpolation=None)
                profile.read(ROOT/'docs/stage8/stage-a/deployment-preparation/routing-initialization/pg_service.proposed.conf')
                reference=profile['geolock_dev_graph_initializer']
                for field in ('host','port','dbname','user','sslmode','sslrootcert'):
                    self.assertEqual(conninfo_to_dict(dsn)[field],reference[field])

    def test_launcher_passes_secret_only_through_child_environment(self):
        text=LAUNCHER.read_text()
        self.assertIn("Read-Host 'Dedicated geolock_graph_login database password (hidden)' -AsSecureString",text)
        self.assertIn("$info.EnvironmentVariables['GEOLOCK_GRAPH_DSN'] = $dsn",text)
        self.assertNotIn('$dsn',next(line for line in text.splitlines() if "$info.Arguments = '-B -m" in line))
        self.assertIn('ZeroFreeBSTR',text)
        self.assertIn("'^(PG|GEOLOCK_)'",text)

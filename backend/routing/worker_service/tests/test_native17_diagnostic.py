"""Offline native-client pin and child inheritance checks; no authentication."""
import json
import os
import subprocess
import sys
import unittest
from unittest.mock import patch

from backend.routing.worker_service import connection_diagnostic_native17 as bootstrap


class Native17Tests(unittest.TestCase):
    @unittest.skipUnless(sys.platform=='win32','Installed Windows PostgreSQL17 runtime')
    def test_installed_native17_client_loads_without_connecting(self):
        env={k:v for k,v in os.environ.items() if not k.startswith(('PG','GEOLOCK_','PSYCOPG_'))}
        result=subprocess.run([sys.executable,'-B','-m',bootstrap.__name__,'--check-local'],
                              env=env,capture_output=True,text=True,check=True)
        report=json.loads(result.stdout)
        self.assertEqual(report['status'],'NATIVE17_CLIENT_READY / NOT CONNECTED')
        self.assertEqual(report['client']['libpq_version'],170011)
        self.assertEqual(report['client']['implementation'],'python')

    def test_diagnostic_child_reenters_the_same_pinned_bootstrap(self):
        from backend.routing.worker_service import connection_diagnostic
        with patch.object(connection_diagnostic,'main',return_value=0) as diagnostic, \
             patch.object(bootstrap.sys,'argv',['module']), \
             patch.object(bootstrap,'configure_client',return_value=(type('Handle',(),{'close':lambda self:None})(),{})):
            self.assertEqual(bootstrap.main(),0)
            diagnostic.assert_called_once_with(child_module=bootstrap.__name__)

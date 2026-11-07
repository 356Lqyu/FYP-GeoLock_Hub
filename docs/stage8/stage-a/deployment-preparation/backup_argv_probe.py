"""Offline native argv echo; never imports a database client or reads credentials."""
import json
import sys

print(json.dumps(sys.argv[1:]))

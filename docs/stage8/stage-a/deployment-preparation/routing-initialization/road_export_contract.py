"""Read-only road export contract. No connections or SQL execution on import."""
import configparser
import hashlib
import json
import re
import struct
from decimal import Decimal
from functools import lru_cache
from pathlib import Path

if not __debug__:
    raise RuntimeError('Optimized Python is unsupported: verification assertions must remain enabled')

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]
REFERENCE = ROOT/'supabase/road_network/output'
PROJECT = 'rcgyuwiidqvrgbxswhqj'
SNAPSHOT = 'OSM-OPS-20261018'
POLICY_SHA = '30826f3fdb5c52bde2b29605e54b30b19692740fbbb97d098daf4b22a3c0b030'
POLICY_REQUEST = '0b8db479-20c8-4595-9d41-d831650cba93'
NODES, EDGES = 926414, 2145828
HASHES = {
 'road_network_nodes.csv':'a8cd24823990b7e8b354ed85fc4207043b45cb1dd92b6780d32ad0f8fabacdf7',
 'road_network_edges.csv':'dbfb052c9cf19d583690765d60613e3c8ff1b062c5070c214a5dfde971d541fd',
 'operational_road_coverage.sql':'06b78e5f8502fa8aa02b0599003e99fcdc20d008b2ec76fc17fd501df9ad162f'}

def sha(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        for chunk in iter(lambda:f.read(1024*1024),b''): h.update(chunk)
    return h.hexdigest()

def reference_check():
    result={name:sha(REFERENCE/name) for name in HASHES}
    assert result==HASHES,'Reference input hash mismatch'
    assert sha(HERE/'policy.proposed.json')==POLICY_SHA,'Policy changed without approval'
    assert json.loads((HERE/'requests.proposed.json').read_text())['policy_request_id']==POLICY_REQUEST
    return result

def approved_profile():
    path=ROOT/'backups/stage-a003/pg_service.conf'
    parser=configparser.ConfigParser(interpolation=None)
    assert parser.read(path),'Approved profile missing'
    params=dict(parser['geolock_dev_owner_export'])
    expected={'host':'aws-0-ap-northeast-2.pooler.supabase.com','port':'5432',
       'dbname':'postgres','user':'postgres.'+PROJECT,'sslmode':'verify-full',
       'sslrootcert':'C:/Users/User/Downloads/prod-ca-2021.crt',
       'options':'-c default_transaction_read_only=on','connect_timeout':'15'}
    assert params==expected,'Approved read-only profile drift; stop for review'
    assert Path(params['sslrootcert']).is_file(),'SSL root certificate missing'
    return path,params

def ratio_round_even(n,d):
    q,r=divmod(n,d)
    return q+int(2*r>d or (2*r==d and q%2))

@lru_cache(maxsize=200000)
def real_bits(text):
    """Exact positive decimal -> IEEE754 binary32 nearest, ties to even.

    Uses integer ratios, avoiding decimal -> binary64 -> binary32 double rounding.
    This is the expected conversion for the importer COPYing decimal text to REAL.
    """
    value=Decimal(text)
    assert value.is_finite() and value>0,'Nonpositive/nonfinite import cost'
    n,d=value.as_integer_ratio()
    exponent=n.bit_length()-d.bit_length()
    below=(n < d<<exponent) if exponent>=0 else (n<<(-exponent) < d)
    if below: exponent-=1
    assert -126<=exponent<=127,'Unsupported normal REAL range'
    shift=23-exponent
    mantissa=ratio_round_even(n<<shift,d) if shift>=0 else ratio_round_even(n,d<<(-shift))
    if mantissa==1<<24: mantissa>>=1; exponent+=1
    assert exponent<=127 and 1<<23<=mantissa<1<<24
    return struct.pack('!I',((exponent+127)<<23)|(mantissa-(1<<23))).hex()

def coverage_reference():
    """Parse pinned WKT as data, never execute the import SQL."""
    sql=(REFERENCE/'operational_road_coverage.sql').read_text()
    match=re.search(r"ST_GeomFromText\('([^']+)',\s*4326\)",sql)
    assert match,'Expected 2D MULTIPOLYGON WKT missing'
    tokens=re.findall(r'MULTIPOLYGON|[(),]|[-+]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][-+]?\d+)?',match[1])
    it=iter(tokens)
    assert next(it)=='MULTIPOLYGON'
    # Nested parenthesis parser: multipolygon -> polygons -> rings -> coordinate pairs.
    def group():
        items=[]
        for token in it:
            if token=='(': items.append(group())
            elif token==')': return items
            elif token!=',': items.append(float(token))
        raise ValueError('Unterminated WKT')
    assert next(it)=='('
    polygons=group()
    assert next(it,None) is None
    wkb=b'\x01'+struct.pack('<II',6,len(polygons))
    for rings in polygons:
        wkb+=b'\x01'+struct.pack('<II',3,len(rings))
        for coords in rings:
            assert len(coords)%2==0 and len(coords)>=8
            wkb+=struct.pack('<I',len(coords)//2)+struct.pack('<'+'d'*len(coords),*coords)
    provenance=re.search(r"500,\s*'([^']+)',\s*'OPERATIONAL',\s*926414,\s*2145828",sql)
    assert provenance,'Expected provenance metadata missing'
    return {'wkb_sha256':hashlib.sha256(wkb).hexdigest(),'provenance':provenance[1]}

IDENTITY_SQL = """SELECT jsonb_build_object(
 'observed_at',statement_timestamp(),'database',current_database(),'current_user',current_user,
 'session_user',session_user,'server_version_num',current_setting('server_version_num')::integer,
 'read_only',current_setting('transaction_read_only'),'float_output',current_setting('extra_float_digits'),
 'snapshot',pg_current_snapshot()::text,'backend_pid',pg_backend_pid(),
 'ssl',(SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()),
 'tls_version',(SELECT version FROM pg_stat_ssl WHERE pid=pg_backend_pid()),
 'bypassrls',(SELECT rolbypassrls FROM pg_roles WHERE rolname=current_user))"""

COVERAGE_SQL = """SELECT coalesce(jsonb_agg(to_jsonb(c)-'coverage_area'||jsonb_build_object(
 'wkb_sha256',encode(sha256(extensions.ST_AsBinary(c.coverage_area,'NDR')),'hex'),
 'srid',extensions.ST_SRID(c.coverage_area),'dimensions',extensions.ST_NDims(c.coverage_area),
 'valid_geometry',extensions.ST_IsValid(c.coverage_area),'geometry_type',extensions.GeometryType(c.coverage_area))), '[]'::jsonb)
 FROM public.road_network_coverage c"""

ACCESS_SQL = """SELECT n.nspname AS schema,c.relname AS relation,c.relrowsecurity,c.relforcerowsecurity,
 has_table_privilege(current_user,c.oid,'SELECT') AS can_select FROM pg_class c
 JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public'
 AND c.relname IN ('road_network_nodes','road_network_edges','road_network_coverage') ORDER BY c.relname"""

TYPES_SQL = """SELECT c.relname,a.attname,format_type(a.atttypid,a.atttypmod) AS type
 FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname='public' AND c.relname IN ('road_network_nodes','road_network_edges')
 AND a.attnum>0 AND NOT a.attisdropped ORDER BY c.relname,a.attnum"""

NODE_SQL = """SELECT osm_node_id,network_snapshot_id,latitude::text AS latitude,
 encode(float8send(latitude),'hex') AS latitude_hex,longitude::text AS longitude,
 encode(float8send(longitude),'hex') AS longitude_hex,component_id,active_flag
 FROM public.road_network_nodes ORDER BY osm_node_id"""
EDGE_SQL = """SELECT edge_id,source_node,target_node,road_km::text AS road_km,
 encode(float4send(road_km),'hex') AS road_km_hex,travel_minutes::text AS travel_minutes,
 encode(float4send(travel_minutes),'hex') AS travel_minutes_hex
 FROM public.road_network_edges ORDER BY source_node,target_node"""

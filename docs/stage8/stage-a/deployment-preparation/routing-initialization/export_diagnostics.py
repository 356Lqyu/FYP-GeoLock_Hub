"""Credential-safe error classification: raw exception text is NEVER returned/logged."""
import re

# Only fixed public codes leave this function, never matching input substrings.
PATTERNS=(
 ('TLS_HOSTNAME_MISMATCH',r'(?:does not match host name|hostname mismatch|host name mismatch)'),
 ('TLS_CERTIFICATE_VERIFICATION_FAILED',r'(?:certificate verify failed|certificate verification failed|unable to get local issuer|self.signed certificate)'),
 ('TLS_CERTIFICATE_EXPIRED',r'(?:certificate has expired|certificate expired)'),
 ('TLS_CERTIFICATE_FILE_ERROR',r'(?:root certificate file|could not (?:read|load).*certificate|sslrootcert)'),
 ('TLS_HANDSHAKE_ERROR',r'(?:ssl error:|tls alert|tlsv\d[^\n]*alert|ssl handshake|tls handshake)'),
 ('PASSWORD_AUTHENTICATION_FAILED',r'password authentication failed'),
 ('POOLER_TENANT_OR_USER_NOT_FOUND',r'(?:tenant or user not found|tenant not found)'),
 ('DATABASE_OR_ROLE_NOT_FOUND',r'(?:database .* does not exist|role .* does not exist)'),
 ('DNS_RESOLUTION_FAILED',r'(?:could not translate host name|name or service not known|getaddrinfo failed|nodename nor servname)'),
 ('CONNECTION_REFUSED',r'connection refused|actively refused'),
 ('NETWORK_UNREACHABLE',r'(?:network is unreachable|no route to host|host is unreachable)'),
 ('CONNECTION_OR_NETWORK_TIMEOUT',r'(?:timeout expired|connection timed out|operation timed out)'),
 ('STARTUP_PARAMETER_REJECTED',r'(?:unsupported startup parameter|unrecognized configuration parameter)'),
 ('SERVER_OR_POOLER_DISCONNECTED',r'(?:server closed the connection unexpectedly|connection reset|connection forcibly closed|ssl connection has been closed|connection is closed)'),
 ('PROTOCOL_NEGOTIATION_ERROR',r'(?:expected authentication request|invalid authentication request|received invalid response|unsupported protocol)'),
 ('QUERY_CANCELLED_OR_TIMED_OUT',r'canceling statement due to (?:statement timeout|user request)'),
 ('LOCK_TIMEOUT',r'canceling statement due to lock timeout'),
 ('POOLER_CIRCUIT_BREAKER_OPEN',r'circuit breaker open|new connections are temporarily blocked'),
)

def safe_error(error,phase):
    # Raw text inspected in memory only. It may contain credentials and is discarded.
    message=str(error)
    codes=[code for code,pattern in PATTERNS if re.search(pattern,message,re.I)]
    state=getattr(error,'sqlstate',None)
    if not isinstance(state,str) or not re.fullmatch(r'[A-Z0-9]{5}',state): state=None
    if not codes:
        codes=[{'28P01':'PASSWORD_AUTHENTICATION_FAILED','28000':'AUTHORIZATION_REJECTED',
                '57014':'QUERY_CANCELLED_OR_TIMED_OUT','55P03':'LOCK_NOT_AVAILABLE',
                '08001':'CONNECTION_ESTABLISHMENT_FAILED','08006':'CONNECTION_FAILURE'}.get(state,'UNCLASSIFIED_ERROR')]
    auth_state=state in ('28P01','28000')
    fatal_auth=bool(re.search(r'\bFATAL\s*:\s*password authentication failed\b',message,re.I))
    auth_phrase=bool(re.search(r'password authentication failed',message,re.I))
    tls=any(code.startswith('TLS_') for code in codes)
    network=any(code in codes for code in ('DNS_RESOLUTION_FAILED','CONNECTION_REFUSED',
        'NETWORK_UNREACHABLE','CONNECTION_OR_NETWORK_TIMEOUT','SERVER_OR_POOLER_DISCONNECTED'))
    if tls and (auth_state or fatal_auth or auth_phrase): domain='MIXED_AUTH_AND_TLS_MESSAGES'
    elif auth_state: domain='STRUCTURED_AUTHORIZATION_REJECTION'
    elif fatal_auth: domain='SERVER_OR_POOLER_STYLE_FATAL_AUTH_REJECTION'
    elif auth_phrase: domain='AUTH_PHRASE_ONLY_ORIGIN_UNVERIFIED'
    elif 'POOLER_CIRCUIT_BREAKER_OPEN' in codes: domain='POOLER_TEMPORARY_REJECTION'
    elif tls: domain='TLS_FAILURE_REPORTED'
    elif network: domain='CONNECTION_FAILURE_REPORTED'
    else: domain='UNRESOLVED'
    return {'error_type':type(error).__name__,'sqlstate':state,'failed_phase':phase,
            'classifications':codes,'raw_message_saved':False,
            'failure_domain':domain,
            'evidence_flags':{'structured_auth_sqlstate':auth_state,'server_style_fatal_auth_message':fatal_auth,
                'auth_phrase_present':auth_phrase,'tls_failure_marker':tls,'connection_failure_marker':network},
            'origin_limit':'Text flags do not identify whether PostgreSQL or the pooler produced the message; no password correctness inference',
            'classification_note':'Fixed codes from in-memory exception matching; no exception text, DSN or password recorded'}

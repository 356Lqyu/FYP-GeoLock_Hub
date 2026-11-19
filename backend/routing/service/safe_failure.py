"""Allowlisted diagnostic metadata; never returns exception text or connection data."""
import re


def safe_failure(error, phase):
    state=getattr(error,'sqlstate',None)
    if not isinstance(state,str) or not re.fullmatch(r'[A-Z0-9]{5}',state): state=None
    # Inspect only in memory. Return fixed classifications, never matched substrings.
    message=str(error).lower()
    markers=[]
    for code,pattern in (
        ('AUTH_REJECTION_MARKER',r'password authentication failed|tenant or user not found'),
        ('TLS_FAILURE_MARKER',r'certificate verify failed|certificate verification failed|root certificate|sslrootcert|does not match host name|tls handshake|ssl error'),
        ('CONNECTION_FAILURE_MARKER',r'connection refused|could not translate host name|connection reset|server closed the connection|connection is closed'),
        ('TIMEOUT_MARKER',r'timeout expired|timed out|statement timeout|lock timeout'),
    ):
        if re.search(pattern,message): markers.append(code)
    if state and state.startswith('28'): domain='STRUCTURED_AUTHORIZATION_REJECTION'
    elif state=='42501': domain='SQL_PERMISSION_REJECTION'
    elif state in ('57014','55P03'): domain='SQL_CANCELLATION_OR_LOCK_TIMEOUT'
    elif state and state.startswith('25'): domain='SQL_TRANSACTION_STATE_REJECTION'
    elif state: domain='SQL_ERROR'
    elif isinstance(error,(TypeError,AttributeError,ValueError,KeyError,IndexError)):
        domain='LOCAL_APPLICATION_EXCEPTION'
    elif getattr(error,'code',None): domain='WORKER_CONTRACT_REJECTION'
    elif phase in ('connect','connection_open','connection_configuration'):
        domain='UNSTRUCTURED_CONNECTION_FAILURE'
    else: domain='UNCLASSIFIED_FAILURE'
    # Type is also a fixed set, not an arbitrary class name supplied by an error.
    known={'OperationalError','ProgrammingError','DatabaseError','InterfaceError',
           'TypeError','AttributeError','ValueError','KeyError','IndexError','WorkerError'}
    kind=type(error).__name__
    return dict(failed_operation=phase,error_type=kind if kind in known else 'OtherException',
                sqlstate=state,failure_domain=domain,markers=markers,raw_message_saved=False,
                classification_limit='Message markers are not proof of origin/password correctness; no raw text retained')

"""INACTIVE analysis proposal. Never used by benchmark, workers or authority."""
def classify(a,b):
    result={'proposal_only':True,'activated':False,'grants_authority':False}
    keys=('snapshot_sha256','matrix_sha256','solver_version','python','platform','hash_seed')
    result['inputs_and_environment_match']=all(a[k]==b[k] for k in keys)
    result['inputs_and_environment_match'] &= (a.get('candidate',{}).get('plan',{}).get('config')==b.get('candidate',{}).get('plan',{}).get('config'))
    result['same_solution']=a['routes_sha256']==b['routes_sha256']
    result['same_metrics']=a['metrics_sha256']==b['metrics_sha256']
    result['same_candidate_bytes']=a['candidate_canonical_json']==b['candidate_canonical_json']
    if not result['inputs_and_environment_match']:label='NOT_COMPARABLE'
    elif not all(x['validation']['valid'] for x in (a,b)):label='INVALID_REJECT'
    elif not all(x['validation']['feasible'] for x in (a,b)):label='NO_FEASIBLE_PAIR_KEEP_OUTCOMES'
    elif result['same_solution'] and result['same_metrics']:label='SAME_SOLUTION_AND_METRICS'
    elif result['same_metrics']:label='DIFFERENT_VALID_SOLUTIONS_EQUAL_METRICS'
    else:label='VARIABLE_VALID_METRICS_REPORT_DISTRIBUTION'
    result['diagnostic_class']=label
    return result

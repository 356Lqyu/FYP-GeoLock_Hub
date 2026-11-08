"""Small deterministic paired bootstrap helpers for fixed benchmark scenarios."""
import random
import statistics


def paired_bootstrap(differences, *, seed=20260915, replicates=10_000, alpha=0.05):
    """Bootstrap the mean paired difference; scenarios are resampling units."""
    values = [float(value) for value in differences]
    if not values:
        return dict(mean_difference=None, ci_low=None, ci_high=None,
                    resampling_unit='paired benchmark scenario', replicates=0,
                    seed=seed, interpretation='no eligible paired scenarios')
    if replicates < 1 or not 0 < alpha < 1:
        raise ValueError('invalid bootstrap parameters')
    rng = random.Random(seed)
    n = len(values)
    means = sorted(statistics.mean(rng.choices(values, k=n)) for _ in range(replicates))
    lo = max(0, min(replicates-1, int((alpha/2)*replicates)))
    hi = max(0, min(replicates-1, int((1-alpha/2)*replicates)))
    return dict(mean_difference=statistics.mean(values), ci_low=means[lo], ci_high=means[hi],
                resampling_unit='paired benchmark scenario', replicates=replicates,
                seed=seed, interpretation='descriptive fixed-benchmark scenario uncertainty; not population inference')

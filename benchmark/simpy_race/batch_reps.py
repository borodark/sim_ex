"""
Batch Replications — SimPy benchmark.
Run barbershop N times with different seeds. The "input uncertainty" use case.

Usage: python batch_reps.py
"""
import simpy
import random
import time

INTERARRIVAL = 18.0
SERVICE = 16.0

def customer(env, server, stats):
    arrival = env.now
    with server.request() as req:
        yield req
        stats['total_wait'] += env.now - arrival
        yield env.timeout(random.expovariate(1.0 / SERVICE))
        stats['served'] += 1

def source(env, server, stats, stop_time):
    while True:
        yield env.timeout(random.expovariate(1.0 / INTERARRIVAL))
        if env.now > stop_time:
            break
        env.process(customer(env, server, stats))

def run_one(seed, stop_time):
    random.seed(seed)
    env = simpy.Environment()
    server = simpy.Resource(env, capacity=1)
    stats = {'served': 0, 'total_wait': 0.0}

    env.process(source(env, server, stats, stop_time))
    env.run()

    return stats['served'], stats['total_wait'] / max(stats['served'], 1)

if __name__ == '__main__':
    stop_time = 10_000

    for n_reps in [10, 100, 1000]:
        t0 = time.monotonic()
        results = [run_one(seed=i, stop_time=stop_time) for i in range(n_reps)]
        wall = time.monotonic() - t0

        waits = [w for _, w in results]
        mean_wait = sum(waits) / len(waits)
        per_rep_ms = wall * 1000 / n_reps

        print(f"  {n_reps:>5} reps  mean_wait={mean_wait:>7.2f}  "
              f"wall={wall*1000:>8.1f}ms  per_rep={per_rep_ms:>6.1f}ms")

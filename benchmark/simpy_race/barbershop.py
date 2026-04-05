"""
M/M/1 Barbershop — SimPy benchmark.
Same parameters as sim_ex: interarrival=18, service=16, stop=50000.

Usage: python barbershop.py
"""
import simpy
import random
import time
import sys

INTERARRIVAL = 18.0
SERVICE = 16.0
SEED = 42

def customer(env, server, stats):
    arrival = env.now
    with server.request() as req:
        yield req
        wait = env.now - arrival
        stats['total_wait'] += wait
        yield env.timeout(random.expovariate(1.0 / SERVICE))
        stats['served'] += 1

def source(env, server, stats, stop_time):
    while True:
        yield env.timeout(random.expovariate(1.0 / INTERARRIVAL))
        if env.now > stop_time:
            break
        stats['arrivals'] += 1
        env.process(customer(env, server, stats))

def run(stop_time):
    random.seed(SEED)
    env = simpy.Environment()
    server = simpy.Resource(env, capacity=1)
    stats = {'arrivals': 0, 'served': 0, 'total_wait': 0.0}

    env.process(source(env, server, stats, stop_time))
    env.run()

    mean_wait = stats['total_wait'] / max(stats['served'], 1)
    return stats['arrivals'], stats['served'], mean_wait

if __name__ == '__main__':
    for stop_time in [10_000, 50_000, 200_000]:
        t0 = time.monotonic()
        arrivals, served, mean_wait = run(stop_time)
        wall = time.monotonic() - t0

        print(f"  stop={stop_time:>8}  served={served:>6}  "
              f"wait={mean_wait:>8.2f}  wall={wall*1000:>8.1f}ms")

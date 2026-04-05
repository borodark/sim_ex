"""
Job Shop with Rework Loop — SimPy benchmark.
3 machines, 15% rework probability, exponential service.

Usage: python rework.py
"""
import simpy
import random
import time

CAPACITY = 3
SERVICE_MEAN = 5.0
REWORK_MEAN = 8.0
REWORK_PROB = 0.15
INTERARRIVAL = 4.0
SEED = 42

def part(env, machine, rework_station, stats):
    arrival = env.now

    # Main processing
    with machine.request() as req:
        yield req
        yield env.timeout(random.expovariate(1.0 / SERVICE_MEAN))

    # Inspection: 15% rework
    if random.random() < REWORK_PROB:
        stats['rework'] += 1
        with rework_station.request() as req:
            yield req
            yield env.timeout(random.expovariate(1.0 / REWORK_MEAN))

    stats['completed'] += 1
    stats['total_time'] += env.now - arrival

def source(env, machine, rework_station, stats, stop_time):
    while True:
        yield env.timeout(random.expovariate(1.0 / INTERARRIVAL))
        if env.now > stop_time:
            break
        stats['arrivals'] += 1
        env.process(part(env, machine, rework_station, stats))

def run(stop_time):
    random.seed(SEED)
    env = simpy.Environment()
    machine = simpy.Resource(env, capacity=CAPACITY)
    rework_station = simpy.Resource(env, capacity=1)
    stats = {'arrivals': 0, 'completed': 0, 'rework': 0, 'total_time': 0.0}

    env.process(source(env, machine, rework_station, stats, stop_time))
    env.run()

    rework_pct = stats['rework'] / max(stats['completed'], 1) * 100
    return stats['arrivals'], stats['completed'], stats['rework'], rework_pct

if __name__ == '__main__':
    for stop_time in [10_000, 50_000, 200_000]:
        t0 = time.monotonic()
        arrivals, completed, rework, rework_pct = run(stop_time)
        wall = time.monotonic() - t0

        print(f"  stop={stop_time:>8}  completed={completed:>6}  "
              f"rework={rework:>5} ({rework_pct:>4.1f}%)  "
              f"wall={wall*1000:>8.1f}ms")

"""
5-Stage Job Shop — SimPy benchmark.
5 sequential stages, capacity 2 each, exponential service.

Usage: python job_shop.py
"""
import simpy
import random
import time

STAGES = 5
CAPACITY = 2
SERVICE_MEANS = [8.0, 6.0, 10.0, 5.0, 7.0]
INTERARRIVAL = 4.0
SEED = 42

def part(env, stages, stats):
    arrival = env.now
    for i, (stage, svc_mean) in enumerate(zip(stages, SERVICE_MEANS)):
        with stage.request() as req:
            yield req
            yield env.timeout(random.expovariate(1.0 / svc_mean))
    stats['completed'] += 1
    stats['total_time'] += env.now - arrival

def source(env, stages, stats, stop_time):
    job_id = 0
    while True:
        yield env.timeout(random.expovariate(1.0 / INTERARRIVAL))
        if env.now > stop_time:
            break
        job_id += 1
        stats['arrivals'] += 1
        env.process(part(env, stages, stats))

def run(stop_time):
    random.seed(SEED)
    env = simpy.Environment()
    stages = [simpy.Resource(env, capacity=CAPACITY) for _ in range(STAGES)]
    stats = {'arrivals': 0, 'completed': 0, 'total_time': 0.0}

    env.process(source(env, stages, stats, stop_time))
    env.run()

    mean_time = stats['total_time'] / max(stats['completed'], 1)
    return stats['arrivals'], stats['completed'], mean_time

if __name__ == '__main__':
    for stop_time in [10_000, 50_000, 200_000]:
        t0 = time.monotonic()
        arrivals, completed, mean_time = run(stop_time)
        wall = time.monotonic() - t0

        print(f"  stop={stop_time:>8}  completed={completed:>6}  "
              f"mean_time={mean_time:>8.2f}  wall={wall*1000:>8.1f}ms")

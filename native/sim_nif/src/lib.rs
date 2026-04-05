use rand::prelude::*;
use rand_xoshiro::Xoshiro256StarStar;
use rustler::{Atom, NifResult};
use std::cmp::Reverse;
use std::collections::{BinaryHeap, HashMap, VecDeque};

mod atoms {
    rustler::atoms! {
        ok,
    }
}

// ============================================================
// DSL Step — the interpreted instruction set
// ============================================================

#[derive(Clone, Debug)]
enum Step {
    Seize(usize),              // resource index
    Hold(Distribution),
    Release(usize),            // resource index
    Depart,
    Label,                     // no-op jump target
    Assign,                    // no-op (attrs not tracked in Rust)
    Decide { prob: f64, target: usize },
    DecideMulti(Vec<(f64, usize)>),  // cumulative prob, target step
    Route(Distribution),       // travel delay (like Hold but no resource)
    Batch(usize),              // accumulate N parts
    Split(usize),              // 1 becomes N
    Combine(usize),            // N become 1
}

#[derive(Clone, Debug)]
enum Distribution {
    Exponential(f64),
    Constant(f64),
    Uniform(f64, f64),
}

impl Distribution {
    fn sample(&self, rng: &mut Xoshiro256StarStar) -> f64 {
        match self {
            Distribution::Exponential(mean) => {
                let u: f64 = rng.gen();
                -mean * u.ln()
            }
            Distribution::Constant(val) => *val,
            Distribution::Uniform(a, b) => {
                let u: f64 = rng.gen();
                a + u * (b - a)
            }
        }
    }
}

// ============================================================
// Calendar — BinaryHeap min-heap via Reverse
// ============================================================

#[derive(Clone, Debug, PartialEq, Eq)]
struct Event {
    tick: u64,
    diasca: u32,
    seq: u64,
    target: Target,
    payload: Payload,
}

impl Ord for Event {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        (self.tick, self.diasca, self.seq)
            .cmp(&(other.tick, other.diasca, other.seq))
    }
}

impl PartialOrd for Event {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum Target {
    Process(usize),
    Resource(usize),
    Source(usize),
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum Payload {
    Generate,
    Arrive(u64),                         // job_id
    SeizeRequest(u64, usize),            // job_id, process_idx
    Grant(usize, u64),                   // resource_idx, job_id
    HoldComplete(u64),                   // job_id
    Release(u64),                        // job_id
    Continue(u64),                       // job_id — resume after batch/split/combine
}

// ============================================================
// Entities
// ============================================================

struct ProcessEntity {
    steps: Vec<Step>,
    instances: HashMap<u64, ProcessInstance>,
    batch_buffers: HashMap<usize, Vec<u64>>,     // step_idx -> parked job_ids
    combine_buffers: HashMap<usize, Vec<u64>>,   // step_idx -> parked job_ids
    rng: Xoshiro256StarStar,
    completed: u64,
    total_wait: f64,
    total_hold: f64,
}

struct ProcessInstance {
    step: usize,
    arrival_tick: u64,
    hold_start: u64,
}

struct Resource {
    capacity: u32,
    busy: u32,
    queue: VecDeque<(u64, usize)>, // (job_id, process_idx)
    grants: u64,
    releases: u64,
}

struct Source {
    process_idx: usize,
    interarrival: Distribution,
    batch_size: u32,
    rng: Xoshiro256StarStar,
    count: u64,
}

// ============================================================
// Engine — the tight loop
// ============================================================

struct Engine {
    calendar: BinaryHeap<Reverse<Event>>,
    processes: Vec<ProcessEntity>,
    resources: Vec<Resource>,
    sources: Vec<Source>,
    seq: u64,
    tick: u64,
    diasca: u32,
    stop_tick: u64,
    events_processed: u64,
}

impl Engine {
    fn run(&mut self) {
        while let Some(Reverse(event)) = self.calendar.pop() {
            if event.tick > self.stop_tick {
                break;
            }
            self.tick = event.tick;
            self.diasca = event.diasca;
            self.dispatch(event);
            self.events_processed += 1;
        }
    }

    fn dispatch(&mut self, event: Event) {
        match event.target {
            Target::Source(idx) => self.handle_source(idx, event.tick, event.diasca),
            Target::Process(idx) => self.handle_process(idx, event.payload, event.tick, event.diasca),
            Target::Resource(idx) => self.handle_resource(idx, event.payload, event.tick, event.diasca),
        }
    }

    fn handle_source(&mut self, idx: usize, tick: u64, diasca: u32) {
        let batch = self.sources[idx].batch_size;
        let process_idx = self.sources[idx].process_idx;

        // Generate batch of arrivals
        let mut events = Vec::with_capacity(batch as usize + 1);
        for _ in 0..batch {
            self.sources[idx].count += 1;
            let job_id = self.sources[idx].count;
            events.push(Event {
                tick, diasca: diasca + 1, seq: 0,
                target: Target::Process(process_idx),
                payload: Payload::Arrive(job_id),
            });
        }

        // Schedule next generation
        let dist = self.sources[idx].interarrival.clone();
        let delay = dist.sample(&mut self.sources[idx].rng).max(1.0) as u64;
        events.push(Event {
            tick: tick + delay.max(1), diasca: 0, seq: 0,
            target: Target::Source(idx),
            payload: Payload::Generate,
        });

        // Push all events (assigns seq numbers)
        for mut e in events {
            self.seq += 1;
            e.seq = self.seq;
            self.calendar.push(Reverse(e));
        }
    }

    fn handle_process(&mut self, idx: usize, payload: Payload, tick: u64, diasca: u32) {
        match payload {
            Payload::Arrive(job_id) => {
                let proc = &mut self.processes[idx];
                proc.instances.insert(job_id, ProcessInstance {
                    step: 0,
                    arrival_tick: tick,
                    hold_start: 0,
                });
                self.advance_process(idx, job_id, tick, diasca);
            }
            Payload::Grant(_res_idx, job_id) => {
                let proc = &mut self.processes[idx];
                if let Some(inst) = proc.instances.get_mut(&job_id) {
                    let wait = (tick as f64) - (inst.arrival_tick as f64);
                    proc.total_wait += wait.max(0.0);
                    inst.step += 1;
                }
                self.advance_process(idx, job_id, tick, diasca);
            }
            Payload::HoldComplete(job_id) => {
                let proc = &mut self.processes[idx];
                if let Some(inst) = proc.instances.get_mut(&job_id) {
                    let hold_dur = (tick as f64) - (inst.hold_start as f64);
                    proc.total_hold += hold_dur;
                    inst.step += 1;
                }
                self.advance_process(idx, job_id, tick, diasca);
            }
            Payload::Continue(job_id) => {
                // Resume a parked job (after batch/split/combine released it)
                self.advance_process(idx, job_id, tick, diasca);
            }
            _ => {}
        }
    }

    fn advance_process(&mut self, idx: usize, job_id: u64, tick: u64, diasca: u32) {
        loop {
            let proc = &mut self.processes[idx];
            let inst = match proc.instances.get(&job_id) {
                Some(i) => i,
                None => return,
            };
            let step_idx = inst.step;

            if step_idx >= proc.steps.len() {
                // Past last step — depart
                proc.instances.remove(&job_id);
                proc.completed += 1;
                return;
            }

            let step = proc.steps[step_idx].clone();
            match step {
                Step::Seize(res_idx) => {
                    self.push_event(tick, diasca + 1, Target::Resource(res_idx),
                        Payload::SeizeRequest(job_id, idx));
                    return; // wait for grant
                }
                Step::Hold(dist) => {
                    let duration = dist.sample(&mut self.processes[idx].rng);
                    let delay_ticks = (duration as u64).max(1);
                    self.processes[idx].instances.get_mut(&job_id).unwrap().hold_start = tick;
                    self.push_event(tick + delay_ticks, 0, Target::Process(idx),
                        Payload::HoldComplete(job_id));
                    return; // wait for hold complete
                }
                Step::Release(res_idx) => {
                    self.push_event(tick, diasca + 1, Target::Resource(res_idx),
                        Payload::Release(job_id));
                    // Continue to next step immediately
                    self.processes[idx].instances.get_mut(&job_id).unwrap().step += 1;
                    // loop continues
                }
                Step::Depart => {
                    let proc = &mut self.processes[idx];
                    proc.instances.remove(&job_id);
                    proc.completed += 1;
                    return;
                }
                Step::Label => {
                    // No-op jump target — just advance
                    self.processes[idx].instances.get_mut(&job_id).unwrap().step += 1;
                    // loop continues
                }
                Step::Assign => {
                    // No-op in Rust engine (attrs not tracked)
                    self.processes[idx].instances.get_mut(&job_id).unwrap().step += 1;
                    // loop continues
                }
                Step::Decide { prob, target } => {
                    let u: f64 = self.processes[idx].rng.gen();
                    if u < prob {
                        self.processes[idx].instances.get_mut(&job_id).unwrap().step = target;
                    } else {
                        self.processes[idx].instances.get_mut(&job_id).unwrap().step += 1;
                    }
                    // loop continues (synchronous, no event)
                }
                Step::DecideMulti(ref routes) => {
                    let u: f64 = self.processes[idx].rng.gen();
                    let mut jumped = false;
                    for &(cum_prob, target) in routes.iter() {
                        if u < cum_prob {
                            self.processes[idx].instances.get_mut(&job_id).unwrap().step = target;
                            jumped = true;
                            break;
                        }
                    }
                    if !jumped {
                        // Fallthrough: use last route target (handles floating-point rounding)
                        if let Some(&(_, target)) = routes.last() {
                            self.processes[idx].instances.get_mut(&job_id).unwrap().step = target;
                        } else {
                            self.processes[idx].instances.get_mut(&job_id).unwrap().step += 1;
                        }
                    }
                    // loop continues
                }
                Step::Route(dist) => {
                    // Travel delay — same as Hold mechanically
                    let duration = dist.sample(&mut self.processes[idx].rng);
                    let delay_ticks = (duration as u64).max(1);
                    self.processes[idx].instances.get_mut(&job_id).unwrap().hold_start = tick;
                    self.push_event(tick + delay_ticks, 0, Target::Process(idx),
                        Payload::HoldComplete(job_id));
                    return; // wait for hold complete
                }
                Step::Batch(count) => {
                    let buffer = self.processes[idx].batch_buffers
                        .entry(step_idx)
                        .or_insert_with(Vec::new);
                    buffer.push(job_id);

                    if buffer.len() >= count {
                        // Batch complete — drain buffer, advance all jobs
                        let ready: Vec<u64> = self.processes[idx].batch_buffers
                            .remove(&step_idx)
                            .unwrap();

                        // Advance all buffered jobs to step+1 and push Continue events
                        for jid in &ready {
                            if let Some(inst) = self.processes[idx].instances.get_mut(jid) {
                                inst.step = step_idx + 1;
                            }
                        }

                        // Push Continue events for all (including current job_id)
                        for jid in ready {
                            self.push_event(tick, diasca + 1, Target::Process(idx),
                                Payload::Continue(jid));
                        }
                        return; // will resume via Continue events
                    } else {
                        // Not enough yet — park this job
                        return;
                    }
                }
                Step::Split(count) => {
                    // Advance original to next step
                    self.processes[idx].instances.get_mut(&job_id).unwrap().step = step_idx + 1;

                    // Create N-1 clones
                    let base_id = job_id * 1_000_000;
                    for i in 1..count {
                        let clone_id = base_id + i as u64;
                        self.processes[idx].instances.insert(clone_id, ProcessInstance {
                            step: step_idx + 1,
                            arrival_tick: tick,
                            hold_start: 0,
                        });
                        // Push Continue event for clone
                        self.push_event(tick, diasca + 1, Target::Process(idx),
                            Payload::Continue(clone_id));
                    }

                    // Push Continue for original too (so all resume via events)
                    self.push_event(tick, diasca + 1, Target::Process(idx),
                        Payload::Continue(job_id));
                    return;
                }
                Step::Combine(count) => {
                    let buffer = self.processes[idx].combine_buffers
                        .entry(step_idx)
                        .or_insert_with(Vec::new);
                    buffer.push(job_id);

                    if buffer.len() >= count {
                        // Combine complete — first survives, rest consumed
                        let ready: Vec<u64> = self.processes[idx].combine_buffers
                            .remove(&step_idx)
                            .unwrap();

                        let survivor = ready[0];

                        // Remove consumed instances
                        for &cid in &ready[1..] {
                            self.processes[idx].instances.remove(&cid);
                        }

                        // Advance survivor
                        if let Some(inst) = self.processes[idx].instances.get_mut(&survivor) {
                            inst.step = step_idx + 1;
                        }

                        // Resume survivor via Continue
                        self.push_event(tick, diasca + 1, Target::Process(idx),
                            Payload::Continue(survivor));
                        return;
                    } else {
                        // Not enough yet — park
                        return;
                    }
                }
            }
        }
    }

    fn handle_resource(&mut self, idx: usize, payload: Payload, tick: u64, diasca: u32) {
        let res = &mut self.resources[idx];
        match payload {
            Payload::SeizeRequest(job_id, process_idx) => {
                if res.busy < res.capacity {
                    res.busy += 1;
                    res.grants += 1;
                    self.push_event(tick, diasca + 1, Target::Process(process_idx),
                        Payload::Grant(idx, job_id));
                } else {
                    res.queue.push_back((job_id, process_idx));
                }
            }
            Payload::Release(job_id) => {
                let _ = job_id; // used for identification in protocol
                res.releases += 1;
                if let Some((next_job, next_proc)) = res.queue.pop_front() {
                    res.grants += 1;
                    self.push_event(tick, diasca + 1, Target::Process(next_proc),
                        Payload::Grant(idx, next_job));
                } else {
                    res.busy -= 1;
                }
            }
            _ => {}
        }
    }

    fn push_event(&mut self, tick: u64, diasca: u32, target: Target, payload: Payload) {
        self.seq += 1;
        self.calendar.push(Reverse(Event {
            tick, diasca, seq: self.seq, target, payload,
        }));
    }
}

// ============================================================
// NIF Interface
// ============================================================

/// Run a DSL-defined simulation entirely in Rust.
///
/// Args:
///   process_steps: list of lists of {step_type, [args]} tuples per process
///     step_type: "seize", "hold_exp", "hold_const", "hold_uniform",
///                "release", "depart", "label", "assign",
///                "decide", "decide_multi",
///                "route_exp", "route_const", "route_uniform",
///                "batch", "split", "combine"
///   resource_caps: list of capacity per resource
///   arrival_means: list of mean interarrival time per process
///   stop_tick: simulation end tick
///   seed: PRNG seed
///   batch_size: arrivals per tick per source
#[rustler::nif(schedule = "DirtyCpu")]
fn run_simulation(
    process_steps: Vec<Vec<(String, Vec<f64>)>>,
    resource_caps: Vec<u32>,
    arrival_means: Vec<f64>,
    stop_tick: u64,
    seed: u64,
    batch_size: u32,
) -> NifResult<(
    Atom,           // :ok
    u64,            // events_processed
    Vec<u64>,       // completions per process
    Vec<f64>,       // mean_wait per process
    Vec<f64>,       // mean_hold per process
    Vec<u64>,       // grants per resource
    Vec<u64>,       // releases per resource
)> {
    // Parse steps
    let processes: Vec<Vec<Step>> = process_steps.iter().map(|steps| {
        steps.iter().map(|(stype, args)| {
            match stype.as_str() {
                "seize" => Step::Seize(args[0] as usize),
                "hold_exp" => Step::Hold(Distribution::Exponential(args[0])),
                "hold_const" => Step::Hold(Distribution::Constant(args[0])),
                "hold_uniform" => Step::Hold(Distribution::Uniform(args[0], args[1])),
                "release" => Step::Release(args[0] as usize),
                "depart" => Step::Depart,
                "label" => Step::Label,
                "assign" => Step::Assign,
                "decide" => Step::Decide {
                    prob: args[0],
                    target: args[1] as usize,
                },
                "decide_multi" => {
                    // args = [prob1, idx1, prob2, idx2, ...]
                    // Convert to cumulative probabilities
                    let mut routes = Vec::new();
                    let mut cum = 0.0;
                    let mut i = 0;
                    while i + 1 < args.len() {
                        cum += args[i];
                        routes.push((cum, args[i + 1] as usize));
                        i += 2;
                    }
                    Step::DecideMulti(routes)
                }
                "route_exp" => Step::Route(Distribution::Exponential(args[0])),
                "route_const" => Step::Route(Distribution::Constant(args[0])),
                "route_uniform" => Step::Route(Distribution::Uniform(args[0], args[1])),
                "batch" => Step::Batch(args[0] as usize),
                "split" => Step::Split(args[0] as usize),
                "combine" => Step::Combine(args[0] as usize),
                _ => Step::Depart,
            }
        }).collect()
    }).collect();

    // Build resources
    let resources: Vec<Resource> = resource_caps.iter().map(|&cap| {
        Resource { capacity: cap, busy: 0, queue: VecDeque::new(), grants: 0, releases: 0 }
    }).collect();

    // Build process entities
    let process_entities: Vec<ProcessEntity> = processes.iter().enumerate().map(|(i, steps)| {
        ProcessEntity {
            steps: steps.clone(),
            instances: HashMap::new(),
            batch_buffers: HashMap::new(),
            combine_buffers: HashMap::new(),
            rng: Xoshiro256StarStar::seed_from_u64(seed + i as u64 * 1000),
            completed: 0,
            total_wait: 0.0,
            total_hold: 0.0,
        }
    }).collect();

    // Build sources
    let sources: Vec<Source> = arrival_means.iter().enumerate().map(|(i, &mean)| {
        Source {
            process_idx: i,
            interarrival: Distribution::Exponential(mean),
            batch_size,
            rng: Xoshiro256StarStar::seed_from_u64(seed + 99999 + i as u64),
            count: 0,
        }
    }).collect();

    // Build calendar with initial generate events
    let mut calendar = BinaryHeap::new();
    for i in 0..sources.len() {
        calendar.push(Reverse(Event {
            tick: 0, diasca: 0, seq: i as u64,
            target: Target::Source(i),
            payload: Payload::Generate,
        }));
    }

    let num_sources = sources.len();
    let mut engine = Engine {
        calendar,
        processes: process_entities,
        resources,
        sources,
        seq: num_sources as u64,
        tick: 0,
        diasca: 0,
        stop_tick,
        events_processed: 0,
    };

    engine.run();

    // Collect results
    let completions: Vec<u64> = engine.processes.iter().map(|p| p.completed).collect();
    let mean_waits: Vec<f64> = engine.processes.iter().map(|p| {
        if p.completed > 0 { p.total_wait / p.completed as f64 } else { 0.0 }
    }).collect();
    let mean_holds: Vec<f64> = engine.processes.iter().map(|p| {
        if p.completed > 0 { p.total_hold / p.completed as f64 } else { 0.0 }
    }).collect();
    let grants: Vec<u64> = engine.resources.iter().map(|r| r.grants).collect();
    let releases: Vec<u64> = engine.resources.iter().map(|r| r.releases).collect();

    Ok((atoms::ok(), engine.events_processed, completions, mean_waits, mean_holds, grants, releases))
}

rustler::init!("Elixir.Sim.Native");

const std = @import("std");

const cc = std.os.uefi.cc;
extern fn zigos_cpu_relax() callconv(cc) void;

pub const TicketLock = struct {
    next_ticket: u32,
    serving_ticket: u32,

    pub fn init() TicketLock {
        return .{
            .next_ticket = 0,
            .serving_ticket = 0,
        };
    }

    pub fn acquire(self: *TicketLock) u32 {
        const ticket = @atomicRmw(u32, &self.next_ticket, .Add, 1, .acq_rel);
        while (@atomicLoad(u32, &self.serving_ticket, .acquire) != ticket) {
            zigos_cpu_relax();
        }
        return ticket;
    }

    pub fn release(self: *TicketLock) void {
        _ = @atomicRmw(u32, &self.serving_ticket, .Add, 1, .release);
    }

    pub fn next(self: *const TicketLock) u32 {
        return @atomicLoad(u32, &self.next_ticket, .acquire);
    }

    pub fn serving(self: *const TicketLock) u32 {
        return @atomicLoad(u32, &self.serving_ticket, .acquire);
    }
};

pub const Barrier = struct {
    participants: u32,
    arrived: u32,
    generation: u32,

    pub fn init(participants: u32) ?Barrier {
        if (participants < 2) return null;
        return .{
            .participants = participants,
            .arrived = 0,
            .generation = 0,
        };
    }

    pub fn wait(self: *Barrier) u32 {
        const generation = @atomicLoad(u32, &self.generation, .acquire);
        const arrival = @atomicRmw(u32, &self.arrived, .Add, 1, .acq_rel) +% 1;
        if (arrival == self.participants) {
            @atomicStore(u32, &self.arrived, 0, .release);
            _ = @atomicRmw(u32, &self.generation, .Add, 1, .acq_rel);
            return generation +% 1;
        }
        while (@atomicLoad(u32, &self.generation, .acquire) == generation) {
            zigos_cpu_relax();
        }
        return @atomicLoad(u32, &self.generation, .acquire);
    }

    pub fn currentGeneration(self: *const Barrier) u32 {
        return @atomicLoad(u32, &self.generation, .acquire);
    }
};

pub const Experiment = struct {
    lock: TicketLock,
    barrier: Barrier,
    counter: u64,
    checksum: u64,

    pub fn init(participants: u32) ?Experiment {
        return .{
            .lock = TicketLock.init(),
            .barrier = Barrier.init(participants) orelse return null,
            .counter = 0,
            .checksum = 0,
        };
    }
};

pub const WorkerResult = struct {
    acquisitions: u32,
    final_barrier_generation: u32,
};

pub fn runWorker(
    experiment: *Experiment,
    worker_id: u32,
    iterations: u32,
) ?WorkerResult {
    if (iterations == 0) return null;
    var iteration: u32 = 0;
    while (iteration < iterations) : (iteration += 1) {
        _ = experiment.lock.acquire();
        experiment.counter +%= 1;
        experiment.checksum +%= contribution(worker_id, iteration);
        experiment.lock.release();
    }
    return .{
        .acquisitions = iterations,
        .final_barrier_generation = experiment.barrier.wait(),
    };
}

pub fn expectedChecksum(participants: u32, iterations: u32) u64 {
    var checksum: u64 = 0;
    var worker_id: u32 = 0;
    while (worker_id < participants) : (worker_id += 1) {
        var iteration: u32 = 0;
        while (iteration < iterations) : (iteration += 1) {
            checksum +%= contribution(worker_id, iteration);
        }
    }
    return checksum;
}

fn contribution(worker_id: u32, iteration: u32) u64 {
    var value = (@as(u64, worker_id) << 32) | iteration;
    value +%= 0x9E37_79B9_7F4A_7C15;
    value = std.math.rotl(u64, value, 21);
    value *%= 0xD6E8_FEB8_6659_FD93;
    value ^= value >> 29;
    return value;
}

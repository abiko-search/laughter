//! Internal lifecycle counters, not a general memory profiler. Capacity covers
//! only bounded output buffers, excluding LOL HTML, input, and BEAM allocations.
//! Snapshots are eventually consistent while resources are being created/dropped.

use std::sync::atomic::{AtomicUsize, Ordering};

static WORKERS: AtomicUsize = AtomicUsize::new(0);
static BUFFERS: AtomicUsize = AtomicUsize::new(0);
static CAPACITY: AtomicUsize = AtomicUsize::new(0);

pub(super) struct Allocation {
    workers: usize,
    buffers: usize,
    capacity: usize,
}

impl Allocation {
    pub(super) fn worker() -> Self {
        WORKERS.fetch_add(1, Ordering::Relaxed);
        Self {
            workers: 1,
            buffers: 0,
            capacity: 0,
        }
    }

    pub(super) fn buffer(capacity: usize) -> Self {
        BUFFERS.fetch_add(1, Ordering::Relaxed);
        CAPACITY.fetch_add(capacity, Ordering::Relaxed);
        Self {
            workers: 0,
            buffers: 1,
            capacity,
        }
    }
}

impl Drop for Allocation {
    fn drop(&mut self) {
        WORKERS.fetch_sub(self.workers, Ordering::Relaxed);
        BUFFERS.fetch_sub(self.buffers, Ordering::Relaxed);
        CAPACITY.fetch_sub(self.capacity, Ordering::Relaxed);
    }
}

pub fn rewrite_stats_impl() -> (usize, usize, usize) {
    (
        WORKERS.load(Ordering::Relaxed),
        BUFFERS.load(Ordering::Relaxed),
        CAPACITY.load(Ordering::Relaxed),
    )
}

//! Sizing the caches for the device. iOS ends an app that uses more memory than its share of the
//! RAM, so the engine's default budget (a quarter of the RAM, up to 1.5 GiB) is too much here.

/// Physical memory in bytes, where the platform says (Apple platforms).
#[cfg(target_vendor = "apple")]
fn physical_memory() -> Option<u64> {
    Some(objc2_foundation::NSProcessInfo::processInfo().physicalMemory())
}

#[cfg(not(target_vendor = "apple"))]
fn physical_memory() -> Option<u64> {
    None
}

/// An eighth of the RAM, between 192 and 768 MiB. Without a known RAM size the engine's own default
/// stays (a desktop run for development).
pub(crate) fn budget_for(ram: u64) -> usize {
    usize::try_from(ram / 8).unwrap_or(usize::MAX).clamp(192 << 20, 768 << 20)
}

pub(crate) fn configure() {
    if let Some(ram) = physical_memory() {
        let budget = budget_for(ram);
        lightcraft_engine::memory::set_budget(budget);
        log::info!("memory: {} MiB of RAM, caches limited to {} MiB", ram >> 20, budget >> 20);
    }
}

#[cfg(test)]
mod tests {
    use super::budget_for;

    #[test]
    fn budget_grows_with_ram_but_stays_within_bounds() {
        assert!(budget_for(8 << 30) > budget_for(3 << 30));
        assert!(budget_for(1 << 30) >= 192 << 20);
        assert!(budget_for(64 << 30) <= 768 << 20);
    }
}

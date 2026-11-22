//! A minimal logger: records go to standard error, which Xcode and Console.app show for an app on
//! a device. (The desktop app's file logger is not needed here; the app container is private.)

struct Stderr;

impl log::Log for Stderr {
    fn enabled(&self, metadata: &log::Metadata) -> bool {
        metadata.level() <= log::Level::Info
    }

    fn log(&self, record: &log::Record) {
        if self.enabled(record.metadata()) {
            eprintln!("[{} {}] {}", record.level(), record.target(), record.args());
        }
    }

    fn flush(&self) {}
}

pub(crate) fn install() {
    if log::set_logger(&Stderr).is_ok() {
        log::set_max_level(log::LevelFilter::Info);
    }
}

//! Windows platform tray and notification stubs.
//! Real implementations would use Shell_NotifyIcon, RegisterHotKey, and
//! IFileDialog. These are stubbed until the C/C++ host or direct Win32
//! bindings are implemented.

pub const Unsupported = error{UnsupportedService};

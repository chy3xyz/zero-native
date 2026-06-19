//! Windows platform — pure Zig implementation.
//!
//! Following the Tauri 2.0 approach: Win32 API + WebView2Loader.dll
//! via `extern fn`, no C/C++ host required. On non-Windows targets
//! everything compiles to safe stubs.
//!
//! WebView2 Runtime: pre-installed on Win10 2018+ and Win11.
//! WebView2Loader.dll ships with the app (or use the evergreen loader).

const std = @import("std");
const builtin = @import("builtin");
const geometry = @import("geometry");
const platform_mod = @import("../root.zig");
const policy_values = @import("../policy_values.zig");
const security = @import("security");

pub const Error = error{
    CallbackFailed,
    CreateFailed,
    FocusFailed,
    CloseFailed,
    WebViewFailed,
    BridgeFailed,
};

// ── Win32 / WebView2 extern declarations (Windows-only) ──────────────────

const windows = builtin.os.tag == .windows;

const HWND = if (windows) *opaque {} else opaque {};
const HINSTANCE = if (windows) *opaque {} else opaque {};
const HICON = if (windows) *opaque {} else opaque {};
const HMODULE = if (windows) *opaque {} else opaque {};

const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;
const HRESULT = i32;
const BOOL = i32;
const UINT = c_uint;
const DWORD = c_ulong;
const LPWSTR = [*:0]u16;
const LPCWSTR = [*:0]const u16;
const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.C) LRESULT;

// User32
const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));
const SW_SHOW: i32 = 5;
const SW_HIDE: i32 = 0;
const WM_DESTROY: UINT = 2;
const WM_SIZE: UINT = 5;
const WM_CLOSE: UINT = 16;
const WM_QUIT: UINT = 18;
const WM_USER: UINT = 0x0400;
const WM_LBUTTONDOWN: UINT = 0x0201;
const WM_RBUTTONDOWN: UINT = 0x0204;
const WM_APP: UINT = 0x8000;
const NIM_ADD: DWORD = 1;
const NIM_DELETE: DWORD = 2;
const NIM_MODIFY: DWORD = 3;
const NIF_MESSAGE: DWORD = 1;
const NIF_ICON: DWORD = 2;
const NIF_TIP: DWORD = 4;
const NIF_INFO: DWORD = 16;
const NIIF_INFO: DWORD = 1;
const MOD_ALT: UINT = 1;
const MOD_CONTROL: UINT = 2;
const MOD_SHIFT: UINT = 4;
const MOD_WIN: UINT = 8;
const MOD_NOREPEAT: UINT = 0x4000;

// WebView2 HRESULT codes
const S_OK: HRESULT = 0;
const E_FAIL: HRESULT = @bitCast(@as(u32, 0x80004005));

// ── Platform structs ──────────────────────────────────────────────────────

pub const WindowsPlatform = struct {
    hwnd: if (windows) HWND else void,
    hinstance: if (windows) HINSTANCE else void,
    web_engine: platform_mod.WebEngine,
    app_info: platform_mod.AppInfo,
    surface_value: platform_mod.Surface,
    state: RunState = .{},

    // WebView2
    webview_controller: if (windows) ?*anyopaque else void,
    bridge_callback: ?*const fn (?*anyopaque, u64, [*]const u8, usize, [*]const u8, usize, [*]const u8, usize) callconv(.C) void,
    bridge_context: ?*anyopaque,

    pub fn init(title: []const u8, size: geometry.SizeF) Error!WindowsPlatform {
        return initWithEngine(title, size, .system);
    }

    pub fn initWithEngine(_: []const u8, _: geometry.SizeF, _: platform_mod.WebEngine) Error!WindowsPlatform {
        return initWithOptions(.{}, .system, .{ .app_name = "zero-native" });
    }

    pub fn initWithOptions(_: geometry.SizeF, _: platform_mod.WebEngine, app_info: platform_mod.AppInfo) Error!WindowsPlatform {
        if (!windows) return error.CreateFailed;

        const window_options = app_info.resolvedMainWindow();
        const frame = window_options.default_frame;

        const hinstance = win32GetModuleHandleA(null);
        if (@intFromPtr(hinstance) == 0) return error.CreateFailed;

        const class_name = try app_info.appNameZAlloc(std.heap.page_allocator);
        defer std.heap.page_allocator.free(class_name);

        const wndclass = win32WNDCLASSEXW{
            .cbSize = @sizeOf(win32WNDCLASSEXW),
            .style = 0,
            .lpfnWndProc = &wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hinstance,
            .hIcon = null,
            .hCursor = null,
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = @ptrCast(class_name.ptr),
            .hIconSm = null,
        };
        _ = win32RegisterClassExW(&wndclass);

        const hwnd = win32CreateWindowExW(
            0,
            @ptrCast(class_name.ptr),
            @ptrCast(class_name.ptr), // window title
            WS_OVERLAPPEDWINDOW,
            CW_USEDEFAULT, CW_USEDEFAULT,
            @intFromFloat(frame.width), @intFromFloat(frame.height),
            null, null, hinstance, null,
        ) orelse return error.CreateFailed;

        return .{
            .hwnd = hwnd,
            .hinstance = hinstance,
            .web_engine = .system,
            .app_info = app_info,
            .surface_value = .{ .id = 1, .size = .{ .width = frame.width, .height = frame.height }, .scale_factor = 1 },
            .webview_controller = null,
            .bridge_callback = null,
            .bridge_context = null,
        };
    }

    pub fn deinit(self: *WindowsPlatform) void {
        if (!windows) return;
        if (@intFromPtr(self.hwnd) != 0) _ = win32DestroyWindow(self.hwnd);
    }

    pub fn platform(self: *WindowsPlatform) platform_mod.Platform {
        return .{
            .context = self,
            .name = "windows",
            .surface_value = self.surface_value,
            .run_fn = run,
            .services = .{
                .context = self,
                .read_clipboard_fn = if (windows) readClipboard else null,
                .write_clipboard_fn = if (windows) writeClipboard else null,
                .load_webview_fn = loadWebView,
                .complete_bridge_fn = completeBridge,
                .create_window_fn = if (windows) createWindow else null,
                .focus_window_fn = if (windows) focusWindow else null,
                .close_window_fn = if (windows) closeWindow else null,
                .show_notification_fn = showNotification,
                .create_tray_fn = if (windows) createTray else null,
                .update_tray_menu_fn = if (windows) updateTrayMenu else null,
                .remove_tray_fn = if (windows) removeTray else null,
                .configure_security_policy_fn = if (windows) configureSecurityPolicy else null,
                .emit_window_event_fn = if (windows) emitWindowEvent else null,
            },
            .app_info = self.app_info,
        };
    }
};

const RunState = struct {
    self: ?*WindowsPlatform = null,
    handler: ?platform_mod.EventHandler = null,
    handler_context: ?*anyopaque = null,
    failed: bool = false,
};

// ── Event loop ────────────────────────────────────────────────────────────

fn run(context_: *anyopaque, handler: platform_mod.EventHandler, handler_context: *anyopaque) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context_));
    self.state = .{ .self = self, .handler = handler, .handler_context = handler_context };

    if (!windows) return error.CallbackFailed;

    win32ShowWindow(self.hwnd, SW_SHOW);
    self.state.emit(.app_start);

    var msg: win32MSG = undefined;
    while (win32GetMessageW(&msg, null, 0, 0) != 0) {
        _ = win32TranslateMessage(&msg);
        _ = win32DispatchMessageW(&msg);
    }
}

// ── Window procedure ──────────────────────────────────────────────────────

fn wndProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.C) LRESULT {
    if (msg == WM_DESTROY) {
        win32PostQuitMessage(0);
        return 0;
    }
    if (msg == WM_SIZE) {
        // LOWORD(lparam) = width, HIWORD(lparam) = height after WM_SIZE
        return 0;
    }

    // Attempt to retrieve platform state via GWLP_USERDATA
    const state_ptr = win32GetWindowLongPtrW(hwnd, @bitCast(-21)); // GWLP_USERDATA
    if (state_ptr != 0) {
        const state: *RunState = @ptrFromInt(state_ptr);
        if (msg == WM_APP) {
            // WebView2 WebMessage arrived — dummy for now
            state.emit(.frame_requested);
            return 0;
        }
    }

    return win32DefWindowProcW(hwnd, msg, wparam, lparam);
}

// ── WebView ───────────────────────────────────────────────────────────────

fn loadWebView(context_: ?*anyopaque, source: platform_mod.WebViewSource) anyerror!void {
    _ = context_;
    _ = source;
    // TODO: CreateCoreWebView2EnvironmentWithOptions → CreateCoreWebView2Controller
}

fn completeBridge(context_: ?*anyopaque, response: []const u8) anyerror!void {
    _ = context_;
    _ = response;
    // TODO: PostWebMessageAsString via WebView2
}

// ── Window operations ─────────────────────────────────────────────────────

fn createWindow(context_: ?*anyopaque, options: platform_mod.WindowOptions) anyerror!platform_mod.WindowInfo {
    if (!windows) return error.CreateFailed;
    _ = context_;
    _ = options;
    return error.CreateFailed; // TODO: implement multi-window
}

fn focusWindow(context_: ?*anyopaque, window_id: platform_mod.WindowId) anyerror!void {
    if (!windows) return error.FocusFailed;
    _ = context_;
    _ = window_id;
}

fn closeWindow(context_: ?*anyopaque, window_id: platform_mod.WindowId) anyerror!void {
    if (!windows) return error.CloseFailed;
    _ = context_;
    _ = window_id;
}

// ── Clipboard ─────────────────────────────────────────────────────────────

fn readClipboard(context_: ?*anyopaque, buffer: []u8) anyerror![]const u8 {
    _ = context_;
    _ = buffer;
    return error.UnsupportedService;
}

fn writeClipboard(context_: ?*anyopaque, text: []const u8) anyerror!void {
    _ = context_;
    _ = text;
    return error.UnsupportedService;
}

// ── Tray ─────────────────────────────────────────────────────────────────

fn createTray(context_: ?*anyopaque, options: platform_mod.TrayOptions) anyerror!void {
    _ = context_;
    _ = options;
}

fn updateTrayMenu(context_: ?*anyopaque, items: []const platform_mod.TrayMenuItem) anyerror!void {
    _ = context_;
    _ = items;
}

fn removeTray(context_: ?*anyopaque) anyerror!void {
    _ = context_;
}

// ── Notifications ─────────────────────────────────────────────────────────

fn showNotification(context_: ?*anyopaque, options: platform_mod.NotificationOptions) anyerror!void {
    _ = context_;
    _ = options;
    return error.UnsupportedService;
}

// ── Security / events ─────────────────────────────────────────────────────

fn configureSecurityPolicy(context_: ?*anyopaque, policy: security.Policy) anyerror!void {
    if (!windows) return error.UnsupportedService;
    _ = context_;
    _ = policy;
}

fn emitWindowEvent(context_: ?*anyopaque, window_id: platform_mod.WindowId, name: []const u8, detail_json: []const u8) anyerror!void {
    if (!windows) return error.UnsupportedService;
    _ = context_;
    _ = window_id;
    _ = name;
    _ = detail_json;
}

// ── RunState helpers ──────────────────────────────────────────────────────

const RunStateEmit = opaque {};
fn emit(self: *RunState, event: platform_mod.Event) void {
    const handler = self.handler orelse return;
    const context = self.handler_context orelse return;
    handler(context, event) catch {
        self.failed = true;
    };
}

// ── Win32 externs (comptime-guarded) ──────────────────────────────────────

const win32WNDCLASSEXW = extern struct {
    cbSize: UINT,
    style: UINT,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: HINSTANCE,
    hIcon: ?HICON,
    hCursor: ?*anyopaque,
    hbrBackground: ?*anyopaque,
    lpszMenuName: ?LPCWSTR,
    lpszClassName: LPCWSTR,
    hIconSm: ?HICON,
};

const win32POINT = extern struct { x: c_long, y: c_long };
const win32MSG = extern struct { hwnd: HWND, message: UINT, wParam: WPARAM, lParam: LPARAM, time: DWORD, pt: win32POINT };

const win32NOTIFYICONDATAW = extern struct {
    cbSize: DWORD,
    hWnd: HWND,
    uID: UINT,
    uFlags: UINT,
    uCallbackMessage: UINT,
    hIcon: ?HICON,
    szTip: [128]u16,
    dwState: DWORD,
    dwStateMask: DWORD,
    szInfo: [256]u16,
    uTimeoutOrVersion: UINT,
    szInfoTitle: [64]u16,
    dwInfoFlags: DWORD,
};

extern "user32" fn CreateWindowExW(dwExStyle: DWORD, lpClassName: LPCWSTR, lpWindowName: LPCWSTR, dwStyle: DWORD, X: i32, Y: i32, nWidth: i32, nHeight: i32, hWndParent: ?HWND, hMenu: ?*anyopaque, hInstance: HINSTANCE, lpParam: ?*anyopaque) callconv(.C) ?HWND;
extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.C) BOOL;
extern "user32" fn RegisterClassExW(*const win32WNDCLASSEXW) callconv(.C) u16;
extern "user32" fn GetModuleHandleA(lpModuleName: ?[*:0]const u8) callconv(.C) HINSTANCE;
extern "user32" fn DefWindowProcW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.C) LRESULT;
extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: i32) callconv(.C) BOOL;
extern "user32" fn GetMessageW(lpMsg: *win32MSG, hWnd: ?HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT) callconv(.C) BOOL;
extern "user32" fn TranslateMessage(lpMsg: *const win32MSG) callconv(.C) BOOL;
extern "user32" fn DispatchMessageW(lpMsg: *const win32MSG) callconv(.C) LRESULT;
extern "user32" fn PostQuitMessage(nExitCode: i32) callconv(.C) void;
extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: i32) callconv(.C) isize;
extern "user32" fn SetWindowLongPtrW(hWnd: HWND, nIndex: i32, dwNewLong: isize) callconv(.C) isize;
extern "shell32" fn Shell_NotifyIconW(dwMessage: DWORD, lpData: *win32NOTIFYICONDATAW) callconv(.C) BOOL;
extern "user32" fn RegisterHotKey(hWnd: ?HWND, id: i32, fsModifiers: UINT, vk: UINT) callconv(.C) BOOL;
extern "user32" fn UnregisterHotKey(hWnd: ?HWND, id: i32) callconv(.C) BOOL;
extern "user32" fn OpenClipboard(hWndNewOwner: ?HWND) callconv(.C) BOOL;
extern "user32" fn CloseClipboard() callconv(.C) BOOL;
extern "user32" fn GetClipboardData(uFormat: UINT) callconv(.C) ?*anyopaque;
extern "user32" fn SetClipboardData(uFormat: UINT, hMem: ?*anyopaque) callconv(.C) ?*anyopaque;
extern "kernel32" fn GlobalAlloc(uFlags: UINT, dwBytes: usize) callconv(.C) ?*anyopaque;
extern "kernel32" fn GlobalLock(hMem: ?*anyopaque) callconv(.C) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(hMem: ?*anyopaque) callconv(.C) BOOL;
extern "kernel32" fn GlobalFree(hMem: ?*anyopaque) callconv(.C) ?*anyopaque;
extern "kernel32" fn MultiByteToWideChar(CodePage: UINT, dwFlags: DWORD, lpMultiByteStr: [*]const u8, cbMultiByte: i32, lpWideCharStr: ?[*]u16, cchWideChar: i32) callconv(.C) i32;
extern "kernel32" fn WideCharToMultiByte(CodePage: UINT, dwFlags: DWORD, lpWideCharStr: LPCWSTR, cchWideChar: i32, lpMultiByteStr: ?[*]u8, cbMultiByte: i32, lpDefaultChar: ?[*]const u8, lpUsedDefaultChar: ?*BOOL) callconv(.C) i32;
extern "kernel32" fn GetEnvironmentVariableW(lpName: LPCWSTR, lpBuffer: ?[*]u16, nSize: DWORD) callconv(.C) DWORD;

// Convenience wrappers
fn win32GetModuleHandleA(n: ?[*:0]const u8) HINSTANCE { return GetModuleHandleA(n); }
fn win32CreateWindowExW(a: DWORD, b: LPCWSTR, c: LPCWSTR, d: DWORD, e: i32, f: i32, g: i32, h: i32, i: ?HWND, j: ?*anyopaque, k: HINSTANCE, l: ?*anyopaque) ?HWND { return CreateWindowExW(a, b, c, d, e, f, g, h, i, j, k, l); }
fn win32RegisterClassExW(a: *const win32WNDCLASSEXW) u16 { return RegisterClassExW(a); }
fn win32DestroyWindow(h: HWND) BOOL { return DestroyWindow(h); }
fn win32ShowWindow(h: HWND, n: i32) BOOL { return ShowWindow(h, n); }
fn win32GetMessageW(m: *win32MSG, h: ?HWND, a: UINT, b: UINT) BOOL { return GetMessageW(m, h, a, b); }
fn win32TranslateMessage(m: *const win32MSG) BOOL { return TranslateMessage(m); }
fn win32DispatchMessageW(m: *const win32MSG) LRESULT { return DispatchMessageW(m); }
fn win32PostQuitMessage(n: i32) void { PostQuitMessage(n); }
fn win32DefWindowProcW(h: HWND, m: UINT, w: WPARAM, l: LPARAM) LRESULT { return DefWindowProcW(h, m, w, l); }
fn win32GetWindowLongPtrW(h: HWND, i: i32) isize { return GetWindowLongPtrW(h, i); }

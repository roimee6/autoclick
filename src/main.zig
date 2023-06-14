const std = @import("std");

const win = @cImport({
    @cInclude("windows.h");
});

const os = std.os;
const time = std.time;
const windows = os.windows;
const user32 = windows.user32;
const thread = std.Thread;

extern "user32" fn SendInput(c_uint, *INPUT, c_int) c_uint;
extern "user32" fn UnhookWindowsHook(nCode: c_int, pfnFilterProc: HOOKPROC) callconv(std.os.windows.WINAPI) windows.BOOL;
extern "user32" fn SetWindowsHookExW(idHook: c_int, lpfn: HOOKPROC, hmod: ?windows.HINSTANCE, dwThreadId: windows.DWORD) callconv(std.os.windows.WINAPI) windows.HANDLE;
extern "user32" fn CallNextHookEx(windows.HANDLE, c_int, windows.WPARAM, windows.LPARAM) windows.LRESULT;

const HOOKPROC = ?*const fn (c_int, windows.WPARAM, windows.LPARAM) callconv(.C) windows.LRESULT;

const MSLLHOOKSTRUCT = extern struct { pt: windows.POINT, mouseData: windows.DWORD, flags: windows.DWORD, time: windows.DWORD, dwExtraInfo: windows.ULONG_PTR };

const KBDLLHOOKSTRUCT = extern struct {
    vkCode: windows.DWORD,
    scanCode: windows.DWORD,
    flags: windows.DWORD,
    time: windows.DWORD,
    dwExtraInfo: windows.ULONG_PTR,
};

var mhook: windows.HANDLE = undefined;
var khook: windows.HANDLE = undefined;

fn mlistener(code: c_int, wParam: windows.WPARAM, lParam: windows.LPARAM) callconv(std.os.windows.WINAPI) windows.LRESULT {
    var pMouse: [*c]MSLLHOOKSTRUCT = @as([*c]MSLLHOOKSTRUCT, lParam);
    if (wParam != 0x0200 and pMouse.*.flags == 0) {
        if (wParam == 0x201) {
            _LISTENER.first_call = true;
            _LISTENER.mouse_down = true;
        } else if (wParam == 0x202) {
            _LISTENER.mouse_down = false;
        }
    }
    return CallNextHookEx(mhook, code, wParam, lParam);
}

fn klistener(code: c_int, wParam: windows.WPARAM, lParam: windows.LPARAM) callconv(std.os.windows.WINAPI) windows.LRESULT {
    var pKeyboard: [*c]KBDLLHOOKSTRUCT = @as([*c]KBDLLHOOKSTRUCT, lParam);
    if (wParam == 0x0101) {
        if (pKeyboard.*.vkCode == _LISTENER.toggle) {
            _LISTENER.toggled = !_LISTENER.toggled;
        } else if (pKeyboard.*.vkCode == _LISTENER.toggleDf) {
            _LISTENER.toggledDf = !_LISTENER.toggledDf;
        } else if (pKeyboard.*.vkCode == _LISTENER.close) {
            os.exit(0);
        }
    }
    return CallNextHookEx(khook, code, wParam, lParam);
}

const MOUSEINPUT = extern struct {
    dx: windows.LONG = 0,
    dy: windows.LONG = 0,
    mouseData: windows.DWORD = 0,
    dwFlags: windows.DWORD,
    time: windows.DWORD = 0,
    dwExtraInfo: windows.ULONG_PTR = 0,
};

const INPUT = extern struct {
    type: u32,
    DUMMYUNIONNAME: extern union {
        mi: MOUSEINPUT,
        //ki: KEYBDINPUT,
        //hi: HARDWAREINPUT,
    },
};

fn send_mouse_input(flags: u32) void {
    var input = INPUT{ .type = 0, .DUMMYUNIONNAME = .{ .mi = MOUSEINPUT{ .dwFlags = flags } } };
    _ = SendInput(1, &input, @sizeOf(INPUT));
}

const Listener = struct {
    min: u32 = 15,
    max: u32 = 20,
    last_call: time.Instant = .{ .timestamp = 0 },
    toggled: bool = false,
    toggledDf: bool = false,
    mouse_down: bool = false,
    first_call: bool = false,
    toggle: u32,
    toggleDf: u32,
    close: u32,
    running: bool = false,
    input_up: u32,
    input_down: u32,

    fn start_listener_thread(self: *Listener) void {
        if (self.running)
            return;

        self.running = true;

        while (self.running) {
            const wowo = focused(self.toggledDf);

            if (self.toggled and self.mouse_down and wowo) {
                if (self.first_call) {
                    self.first_call = false;
                    time.sleep(time.ns_per_ms * 30);
                } else {
                    var now = time.Instant.now() catch
                        return;

                    if (!(now.since(self.last_call) > ((1000 / randInt(self.min, self.max)) * time.ns_per_ms)))
                        continue;

                    send_mouse_input(self.input_up);
                    send_mouse_input(self.input_down);

                    self.last_call = time.Instant.now() catch
                        return;
                }
            }
            time.sleep(time.ns_per_ms);
        }
    }
};

fn randInt(minValue: u32, maxValue: u32) u32 {
    var prng = std.rand.DefaultPrng.init(getU64Time());
    const rand = prng.random();

    return rand.intRangeAtMost(u32, minValue, maxValue);
}

fn getU64Time() u64 {
    return @intCast(u64, time.timestamp());
}

var _LISTENER = Listener{
    .toggle = 0x2D,
    .toggleDf = 0x79,
    .close = 0x76,
    .input_up = 0x004,
    .input_down = 0x002,
};

fn listener() *Listener {
    return &_LISTENER;
}

fn start_listener() void {
    listener().start_listener_thread();
}

fn start_listen() void {
    _ = thread.spawn(.{}, start_listener, .{}) catch
        return;

    mhook = SetWindowsHookExW(14, mlistener, null, 0);
    khook = SetWindowsHookExW(13, klistener, null, 0);

    var msg: *user32.MSG = undefined;
    while (user32.GetMessageW(msg, null, 0, 0) == 1) {
        _ = user32.TranslateMessage(msg);
        _ = user32.DispatchMessageW(msg);
    }
}

pub fn main() !void {
    const argv = os.argv;

    var index: u32 = 0;
    var changed: u32 = 0;

    for (argv) |arg| {
        var arg_str = std.mem.span(arg);
        var arg_str_next = std.mem.span(argv[index + 1]);

        index += 1;

        if (std.mem.eql(u8, arg_str_next, "--min") or std.mem.eql(u8, arg_str_next, "--max")) {
            continue;
        }

        const val = try std.fmt.parseInt(u32, arg_str_next, 0);

        if (std.mem.eql(u8, arg_str, "--min")) {
            _LISTENER.min = val;
            changed += 1;
        } else if (std.mem.eql(u8, arg_str, "--max")) {
            _LISTENER.max = val;
            changed += 1;
        }

        if (index + 1 >= argv.len) {
            break;
        }
    }

    if (changed < 2) {
        return;
    }
    
    start_listen();
}

fn focused(toggled: bool) bool {
    if (toggled) {
        return true;
    }

    const minecraft = win.FindWindowA(null, "Minecraft");
    const window = win.GetForegroundWindow();

    return minecraft == window;
}

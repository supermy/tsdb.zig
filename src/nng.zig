const std = @import("std");

pub const nng_socket = extern struct {
    id: u32,
};

pub const nng_listener = extern struct {
    id: u32,
};

pub const nng_dialer = extern struct {
    id: u32,
};

pub const nng_pipe = extern struct {
    id: u32,
};

pub const NNG_FLAG_ALLOC = 0x01;
pub const NNG_FLAG_NONBLOCK = 0x02;

pub extern "c" fn nng_rep0_open(sock: *nng_socket) c_int;
pub extern "c" fn nng_req0_open(sock: *nng_socket) c_int;
pub extern "c" fn nng_listen(sock: nng_socket, addr: [*:0]const u8, lp: ?*nng_listener, flags: c_int) c_int;
pub extern "c" fn nng_dial(sock: nng_socket, addr: [*:0]const u8, dp: ?*nng_dialer, flags: c_int) c_int;
pub extern "c" fn nng_recv(sock: nng_socket, buf: ?*anyopaque, len: *usize, flags: c_int) c_int;
pub extern "c" fn nng_send(sock: nng_socket, buf: *const anyopaque, len: usize, flags: c_int) c_int;
pub extern "c" fn nng_close(sock: nng_socket) c_int;
pub extern "c" fn nng_strerror(err: c_int) [*:0]const u8;

pub fn check(err: c_int) !void {
    if (err != 0) {
        const msg = nng_strerror(err);
        const log = std.log.scoped(.nng);
        log.err("nng error {d}: {s}", .{ err, msg });
        return error.NngError;
    }
}

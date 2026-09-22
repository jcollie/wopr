// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Thin wrappers over the Linux syscalls this library needs.
//!
//! `std.posix` in Zig 0.16 no longer exposes sockets or shared memory, and this
//! library links no libc, so the calls go straight to `std.os.linux`.

const std = @import("std");
const linux = std.os.linux;

pub const E = linux.E;

pub const Error = error{
    Again,
    Interrupted,
    BrokenPipe,
    ConnectionReset,
    ConnectionRefused,
    AccessDenied,
    NotFound,
    OutOfMemory,
    ProtocolError,
    Unexpected,
};

/// Map a raw syscall return into an error, or the successful value.
fn check(rc: usize) Error!usize {
    return switch (linux.errno(rc)) {
        .SUCCESS => rc,
        .AGAIN => error.Again,
        .INTR => error.Interrupted,
        .PIPE => error.BrokenPipe,
        .CONNRESET => error.ConnectionReset,
        .CONNREFUSED, .HOSTDOWN => error.ConnectionRefused,
        .ACCES, .PERM => error.AccessDenied,
        .NOENT => error.NotFound,
        .NOMEM => error.OutOfMemory,
        .PROTO, .INVAL => error.ProtocolError,
        else => error.Unexpected,
    };
}

pub fn close(fd: i32) void {
    if (fd >= 0) _ = linux.close(fd);
}

pub fn read(fd: i32, buf: []u8) Error!usize {
    return check(linux.read(fd, buf.ptr, buf.len));
}

pub fn write(fd: i32, buf: []const u8) Error!usize {
    return check(linux.write(fd, buf.ptr, buf.len));
}

/// Connect a SOCK_STREAM Unix socket to `path`, which may be abstract if it
/// starts with '@'.
pub fn connectUnix(path: []const u8) Error!i32 {
    var addr: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = @splat(0) };
    if (path.len >= addr.path.len) return error.ProtocolError;
    @memcpy(addr.path[0..path.len], path);
    // An abstract socket name is a leading NUL followed by the rest of the name,
    // and its length excludes any trailing NUL.
    const abstract = path.len > 0 and path[0] == '@';
    if (abstract) addr.path[0] = 0;
    const path_len = if (abstract) path.len else path.len + 1;

    const fd: i32 = @intCast(try check(linux.socket(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        0,
    )));
    errdefer close(fd);

    const addr_len: linux.socklen_t = @intCast(@offsetOf(linux.sockaddr.un, "path") + path_len);
    _ = try check(linux.connect(fd, &addr, addr_len));
    return fd;
}

/// The most descriptors a single `sendmsg` will carry, matching PipeWire's own
/// `MAX_FDS_MSG`.
pub const max_fds_per_msg = 28;

const cmsg_align = @alignOf(usize);

fn cmsgAlign(n: usize) usize {
    return (n + cmsg_align - 1) & ~@as(usize, cmsg_align - 1);
}

fn cmsgLen(payload: usize) usize {
    return cmsgAlign(@sizeOf(linux.cmsghdr)) + payload;
}

fn cmsgSpace(payload: usize) usize {
    return cmsgAlign(@sizeOf(linux.cmsghdr)) + cmsgAlign(payload);
}

const cmsg_buf_len = cmsgSpace(max_fds_per_msg * @sizeOf(i32));

/// Send `data` with `fds` attached as SCM_RIGHTS ancillary data.
pub fn sendmsgFds(fd: i32, data: []const u8, fds: []const i32) Error!usize {
    std.debug.assert(fds.len <= max_fds_per_msg);

    var iov = [_]std.posix.iovec_const{.{ .base = data.ptr, .len = data.len }};
    var cbuf: [cmsg_buf_len]u8 align(cmsg_align) = undefined;

    var msg: linux.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };

    if (fds.len > 0) {
        const payload = fds.len * @sizeOf(i32);
        const hdr: linux.cmsghdr = .{
            .len = cmsgLen(payload),
            .level = linux.SOL.SOCKET,
            .type = linux.SCM.RIGHTS,
        };
        @memcpy(cbuf[0..@sizeOf(linux.cmsghdr)], std.mem.asBytes(&hdr));
        const data_off = cmsgAlign(@sizeOf(linux.cmsghdr));
        @memcpy(cbuf[data_off..][0..payload], std.mem.sliceAsBytes(fds));
        msg.control = &cbuf;
        msg.controllen = cmsgLen(payload);
    }

    return check(linux.sendmsg(fd, &msg, linux.MSG.NOSIGNAL));
}

pub const RecvResult = struct {
    len: usize,
    n_fds: usize,
};

/// Receive into `data`, collecting any SCM_RIGHTS descriptors into `fds_out`.
///
/// Received descriptors are already CLOEXEC. If the ancillary buffer overflows,
/// the descriptors that did arrive are closed and `ProtocolError` is returned,
/// rather than leaking them.
pub fn recvmsgFds(fd: i32, data: []u8, fds_out: []i32, nonblocking: bool) Error!RecvResult {
    var iov = [_]std.posix.iovec{.{ .base = data.ptr, .len = data.len }};
    var cbuf: [cmsg_buf_len]u8 align(cmsg_align) = undefined;

    var msg: linux.msghdr = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &cbuf,
        .controllen = cbuf.len,
        .flags = 0,
    };

    var flags: u32 = linux.MSG.CMSG_CLOEXEC;
    if (nonblocking) flags |= linux.MSG.DONTWAIT;

    const len = try check(linux.recvmsg(fd, &msg, flags));
    if (len == 0) return error.BrokenPipe;

    var n_fds: usize = 0;
    var off: usize = 0;
    while (off + @sizeOf(linux.cmsghdr) <= msg.controllen) {
        var hdr: linux.cmsghdr = undefined;
        @memcpy(std.mem.asBytes(&hdr), cbuf[off..][0..@sizeOf(linux.cmsghdr)]);
        if (hdr.len < @sizeOf(linux.cmsghdr) or off + hdr.len > msg.controllen) break;

        if (hdr.level == linux.SOL.SOCKET and hdr.type == linux.SCM.RIGHTS) {
            const data_off = off + cmsgAlign(@sizeOf(linux.cmsghdr));
            const payload = off + hdr.len - data_off;
            const count = payload / @sizeOf(i32);
            for (0..count) |i| {
                var got: i32 = undefined;
                @memcpy(std.mem.asBytes(&got), cbuf[data_off + i * @sizeOf(i32) ..][0..@sizeOf(i32)]);
                if (n_fds < fds_out.len) {
                    fds_out[n_fds] = got;
                    n_fds += 1;
                } else {
                    close(got);
                }
            }
        }
        off += cmsgAlign(hdr.len);
    }

    if (msg.flags & linux.MSG.CTRUNC != 0) {
        for (fds_out[0..n_fds]) |got| close(got);
        return error.ProtocolError;
    }

    return .{ .len = len, .n_fds = n_fds };
}

pub const Prot = struct {
    pub const read = linux.PROT.READ;
    pub const write = linux.PROT.WRITE;
};

/// Map `len` bytes of `fd` starting at `offset`, which need not be page aligned:
/// the mapping is widened to the enclosing pages and the returned slice points
/// at the requested bytes inside it.
pub const Mapping = struct {
    /// The whole page-aligned mapping, for `munmap`.
    base: []align(std.heap.page_size_min) u8,
    /// The bytes the caller asked for.
    slice: []u8,

    pub fn unmap(m: Mapping) void {
        _ = linux.munmap(m.base.ptr, m.base.len);
    }
};

pub fn mmapShared(fd: i32, offset: u64, len: usize) Error!Mapping {
    const page = std.heap.pageSize();
    const page_offset = offset % page;
    const map_offset = offset - page_offset;
    const map_len = page_offset + len;

    const rc = linux.mmap(
        null,
        map_len,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        @intCast(map_offset),
    );
    const addr = try check(rc);
    const base: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(addr);
    return .{
        .base = base[0..map_len],
        .slice = base[page_offset..][0..len],
    };
}

pub fn eventfd(initial: u32, flags: u32) Error!i32 {
    return @intCast(try check(linux.eventfd(initial, flags)));
}

/// Read the 8-byte counter from an eventfd, returning how many wakeups were
/// coalesced into this one.
pub fn eventfdRead(fd: i32) Error!u64 {
    var v: u64 = 0;
    const n = try read(fd, std.mem.asBytes(&v));
    if (n != 8) return error.ProtocolError;
    return v;
}

pub fn eventfdWrite(fd: i32, v: u64) Error!void {
    var x = v;
    const n = try write(fd, std.mem.asBytes(&x));
    if (n != 8) return error.ProtocolError;
}

pub const PollFd = linux.pollfd;
pub const POLL = linux.POLL;

pub fn poll(fds: []PollFd, timeout_ms: i32) Error!usize {
    return check(linux.poll(fds.ptr, fds.len, timeout_ms));
}

pub fn nowNsec() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub fn getuid() u32 {
    return linux.getuid();
}

/// Sleep for at least `ns`.
pub fn sleep(ns: u64) void {
    var req: linux.timespec = .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    var rem: linux.timespec = undefined;
    while (linux.errno(linux.nanosleep(&req, &rem)) == .INTR) req = rem;
}

/// A futex-backed mutex.
///
/// `std.Io.Mutex` in Zig 0.16 needs an `Io` to block on, which would drag the
/// whole `Io` interface into a library that otherwise only makes syscalls, so
/// this is the same three-state algorithm implemented directly. Uncontended
/// lock and unlock are a single atomic operation each and never enter the
/// kernel, which is what the audio thread needs.
pub const Mutex = struct {
    state: std.atomic.Value(u32) = .init(unlocked),

    const unlocked: u32 = 0;
    const locked: u32 = 1;
    const contended: u32 = 2;

    pub fn tryLock(m: *Mutex) bool {
        return m.state.cmpxchgStrong(unlocked, locked, .acquire, .monotonic) == null;
    }

    pub fn lock(m: *Mutex) void {
        if (m.state.cmpxchgStrong(unlocked, locked, .acquire, .monotonic) == null) return;
        // Mark the lock contended so the holder knows to wake us on release.
        while (m.state.swap(contended, .acquire) != unlocked) {
            _ = linux.futex_4arg(
                &m.state.raw,
                .{ .cmd = .WAIT, .private = true },
                contended,
                null,
            );
        }
    }

    pub fn unlock(m: *Mutex) void {
        if (m.state.swap(unlocked, .release) == contended) {
            _ = linux.futex_3arg(&m.state.raw, .{ .cmd = .WAKE, .private = true }, 1);
        }
    }
};

test "mutex serializes increments from several threads" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    const Shared = struct {
        m: Mutex = .{},
        counter: u64 = 0,

        fn bump(s: *@This()) void {
            for (0..10_000) |_| {
                s.m.lock();
                s.counter += 1;
                s.m.unlock();
            }
        }
    };

    var shared: Shared = .{};
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Shared.bump, .{&shared});
    for (threads) |t| t.join();
    try std.testing.expectEqual(@as(u64, 40_000), shared.counter);
}

// SPDX-License-Identifier: Unlicense
const std = @import("std");
const assert = std.debug.assert;
const Atomic = std.atomic.Value;

// TODO: real cache line size
const cache_line_size = 64;

// Based on the CppCon talk by Charles Frasch.
/// Single-producer, single-consumer queue, `1 << log2_len` elements of type `T` may be enqueued at
/// the same time.
pub fn Queue(comptime T: type, comptime log2_len: comptime_int) type {
    return struct {
        buf: [buf_len]T = undefined,

        push_cursor: Atomic(usize) align(cache_line_size) = .{ .raw = 0 },
        pop_cursor: Atomic(usize) align(cache_line_size) = .{ .raw = 0 },

        cached_push_cursor: usize align(cache_line_size) = 0,
        cached_pop_cursor: usize align(cache_line_size) = 0,

        const Self = @This();

        const buf_len = 1 << log2_len;
        const mask = buf_len - 1;

        const util = struct {
            fn isFull(push_cursor: usize, pop_cursor: usize) bool {
                assert(push_cursor >= pop_cursor);
                return push_cursor - pop_cursor >= buf_len;
            }

            fn isEmpty(push_cursor: usize, pop_cursor: usize) bool {
                assert(push_cursor >= pop_cursor);
                return push_cursor == pop_cursor;
            }
        };

        fn at(self: *Self, idx: usize) *T {
            return &self.buf[idx & mask];
        }

        /// Returns the number of elements in `self`.
        pub fn len(self: *const Self) usize {
            const push_cursor = self.push_cursor.load(.Monotonic);
            const pop_cursor = self.pop_cursor.load(.Monotonic);

            assert(push_cursor >= pop_cursor);

            return push_cursor - pop_cursor;
        }

        /// Returns whether `self` has no elements in it.
        pub fn isEmpty(self: *const Self) bool {
            const push_cursor = self.push_cursor.load(.Monotonic);
            const pop_cursor = self.pop_cursor.load(.Monotonic);

            return util.isEmpty(push_cursor, pop_cursor);
        }

        /// Returns whether `self` can hold no additional elements.
        pub fn isFull(self: *const Self) bool {
            const push_cursor = self.push_cursor.load(.Monotonic);
            const pop_cursor = self.pop_cursor.load(.Monotonic);

            return util.isFull(push_cursor, pop_cursor);
        }

        /// Wrapper for a push operation. The value must first be set with `set` or through `ptr`,
        /// then `perform` must be called. Holding two "un-performed" `Pusher`s at the same time is
        /// illegal, and attempting to `perform` both is safety-checked illegal behavior.
        pub const Pusher = struct {
            queue: *Self,
            cursor: usize,

            pub fn ptr(self: Pusher) *T {
                return self.queue.at(self.cursor);
            }

            pub inline fn set(self: Pusher, value: T) Pusher {
                self.ptr().* = value;
                return self;
            }

            pub fn perform(self: Pusher) void {
                assert(self.queue.push_cursor.load(.SeqCst) == self.cursor); // user error: initiated another push before the previous one was performed.
                self.queue.push_cursor.store(self.cursor +% 1, .Release);
            }
        };

        pub fn pusher(self: *Self) error{QueueFull}!Pusher {
            const push_cursor = self.push_cursor.load(.Monotonic);

            if (util.isFull(push_cursor, self.cached_pop_cursor)) {
                self.cached_pop_cursor = self.pop_cursor.load(.Acquire);

                if (util.isFull(push_cursor, self.cached_pop_cursor)) return error.QueueFull;
            }

            return .{ .queue = self, .cursor = push_cursor };
        }

        /// Wrapper for a pop operation. The value may be accessed with `get` or through `ptr`, then
        /// `perform` must be called. Holding two "un-performed" `Popper`s at the same time is
        /// illegal, and attempting to `perform` both is safety-checked illegal behavior.
        pub const Popper = struct {
            queue: *Self,
            cursor: usize,

            pub fn ptr(self: Popper) *T {
                return self.queue.at(self.cursor);
            }

            pub inline fn get(self: Popper) T {
                return self.ptr().*;
            }

            pub fn perform(self: Popper) void {
                assert(self.queue.pop_cursor.load(.SeqCst) == self.cursor); // user error: initiated another pop before the previous one was performed.
                self.queue.pop_cursor.store(self.cursor +% 1, .Release);
            }
        };

        pub fn popper(self: *Self) ?Popper {
            const pop_cursor = self.pop_cursor.load(.Monotonic);

            if (util.isEmpty(self.cached_push_cursor, pop_cursor)) {
                self.cached_push_cursor = self.push_cursor.load(.Acquire);
                if (util.isEmpty(self.cached_push_cursor, pop_cursor)) return null;
            }

            return .{ .queue = self, .cursor = pop_cursor };
        }

        pub fn push(self: *Self, value: T) error{QueueFull}!void {
            (try self.pusher()).set(value).perform();
        }

        pub fn pop(self: *Self) ?T {
            const p = self.popper() orelse return null;
            defer p.perform();
            return p.get();
        }
    };
}

test "simple pushing and popping" {
    var q = Queue(u8, 2){};
    try std.testing.expect(q.isEmpty());

    try std.testing.expect(q.len() == 0);

    try q.push(69);
    try std.testing.expect(q.len() == 1);

    try q.push(42);
    try std.testing.expect(q.len() == 2);

    try q.push(13);
    try std.testing.expect(q.len() == 3);

    try q.push(37);

    try std.testing.expect(q.isFull());

    try std.testing.expectError(error.QueueFull, q.push(0));
    try std.testing.expectError(error.QueueFull, q.push(0));

    try std.testing.expect(q.isFull());

    try std.testing.expect(q.pop() == 69);
    try std.testing.expect(q.len() == 3);

    try std.testing.expect(q.pop() == 42);
    try std.testing.expect(q.len() == 2);

    try std.testing.expect(q.pop() == 13);
    try std.testing.expect(q.len() == 1);

    try std.testing.expect(q.pop() == 37);
    try std.testing.expect(q.len() == 0);

    try std.testing.expect(q.pop() == null);
    try std.testing.expect(q.pop() == null);
}

test "threaded pushing and popping" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    const funcs = struct {
        fn pusher(queue: *Queue(u8, 2), err: *anyerror!void) void {
            err.* = pusherInternal(queue);
        }

        fn popper(queue: *Queue(u8, 2), err: *anyerror!void) void {
            err.* = popperInternal(queue);
        }

        fn popperInternal(queue: *Queue(u8, 2)) !void {
            // HACK-y
            while (!queue.isFull()) {
                std.Thread.yield() catch {};
            }

            try std.testing.expect(queue.pop() == 69);
            try std.testing.expect(queue.len() == 3);

            try std.testing.expect(queue.pop() == 42);
            try std.testing.expect(queue.len() == 2);

            try std.testing.expect(queue.pop() == 13);
            try std.testing.expect(queue.len() == 1);

            try std.testing.expect(queue.pop() == 37);
            try std.testing.expect(queue.len() == 0);

            try std.testing.expect(queue.pop() == null);
            try std.testing.expect(queue.pop() == null);

            try std.testing.expect(queue.isEmpty());
        }

        fn pusherInternal(queue: *Queue(u8, 2)) !void {
            try std.testing.expect(queue.isEmpty());
            try queue.push(69);
            try queue.push(42);
            try queue.push(13);
            try queue.push(37);
        }
    };

    var q = Queue(u8, 2){};

    var pusher_err: anyerror!void = {};
    var popper_err: anyerror!void = {};

    const popper_thr = try std.Thread.spawn(.{ .allocator = std.testing.allocator }, funcs.popper, .{ &q, &popper_err });
    const pusher_thr = try std.Thread.spawn(.{ .allocator = std.testing.allocator }, funcs.pusher, .{ &q, &pusher_err });

    pusher_thr.join();
    popper_thr.join();

    try pusher_err;
    try popper_err;
}

// TODO upstream: https://github.com/ziglang/zig/issues/1356
// test "only one push at a time" {
//     var q = Queue(u8, 2){};

//     const pusher_a = try q.pusher();
//     const pusher_b = try q.pusher();

//     pusher_a.perform();
//     pusher_b.perform();
// }
// test "only one pop at a time" {
//     var q = Queue(u8, 2){};

//     try q.push(0);
//     try q.push(0);

//     const popper_a = q.popper().?;
//     const popper_b = q.popper().?;

//     popper_a.perform();
//     popper_b.perform();
// }

const PieceTable = @This();

const std = @import("std");

const assert = std.debug.assert;
const mem = std.mem;
const testing = std.testing;

const log = std.log.scoped(.tokenizer);

const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;

original: []const u8 = undefined,
append: ArrayList(u8) = undefined,

allocator: Allocator,

root: ?*PieceTableNode = null,

pub const PieceTableNode = struct {
    use_original: bool,
    start: usize,
    len: usize,
    next: ?*PieceTableNode = null,

    pub fn create(allocator: Allocator, use_original: bool, start: usize, len: usize) !*PieceTableNode {
        // note: Can't populate the struct here because the Allocator interface
        // uses comptime T, i.e. all parts of the struct must be comptime known.
        var node = try allocator.create(PieceTableNode);
        node.* = PieceTableNode{
            .use_original = use_original,
            .start = start,
            .len = len,
        };
        return node;
    }
};

pub const PieceTableIterator = struct {
    node: ?*PieceTableNode,

    pub fn next(self: *PieceTableIterator) ?*PieceTableNode {
        const this_node = self.node;
        if (self.node) |_| {
            self.node = self.node.?.next;
        }
        return this_node;
    }
};

pub const CharIterator = struct {
    pt: *PieceTable,
    index: usize = 0,

    // todo: Optimize.

    pub fn next(self: *CharIterator) ?u8 {
        const buffer_len = self.pt.bufferLen();

        std.debug.print("{} {}\n", .{ buffer_len, self.index });

        if (self.index >= buffer_len) {
            return null;
        }

        const c = self.pt.getChar(self.index);
        self.index += 1;
        return c;
    }

    pub fn skip(self: *CharIterator) void {
        self.index += 1;
    }
};

pub fn init(allocator: Allocator) PieceTable {
    return .{
        .allocator = allocator,
    };
}

pub fn deinit(self: *PieceTable) void {
    // todo: Side-effect - uses self.root to determine if we have allocated
    // the array-list.
    if (self.root) |_| {
        self.append.deinit();
    }

    var it = PieceTableIterator{ .node = self.root };
    while (it.next()) |n| {
        self.allocator.destroy(n);
    }
}

pub fn setup(self: *PieceTable, original: []const u8) !void {
    self.original = original;
    self.root = try PieceTableNode.create(self.allocator, true, 0, original.len);
    self.append = ArrayList(u8).init(self.allocator);
}

pub fn insertTextAt(self: *PieceTable, text: []const u8, want_loc: usize) !usize {
    var total_len: usize = 0;

    var it = PieceTableIterator{ .node = self.root };
    while (it.next()) |n| {
        const start_loc = total_len;
        total_len += n.len;
        const next_loc = start_loc + n.len;
        if (want_loc == next_loc) {
            // Insert a new node.
            var m_node = try PieceTableNode.create(
                self.allocator,
                false,
                self.append.items.len,
                text.len,
            );
            try self.append.appendSlice(text);

            m_node.next = n.next;
            n.next = m_node;

            break;
        } else if (want_loc < next_loc) {
            // Split this node.
            var m_node = try PieceTableNode.create(
                self.allocator,
                false,
                self.append.items.len,
                text.len,
            );
            try self.append.appendSlice(text);

            const diff = want_loc - start_loc;

            var r_node = try PieceTableNode.create(
                self.allocator,
                n.use_original,
                n.start + diff,
                n.len - diff,
            );

            m_node.next = r_node;
            n.len = diff;
            n.next = m_node;

            break;
        }
    }

    return want_loc + text.len;
}

pub fn bufferLen(self: *PieceTable) usize {
    var len: usize = 0;
    var node = self.root;
    while (node) |n| {
        len += n.len;
        node = node.?.next;
    }

    return len;
}

pub fn getChar(self: *PieceTable, index: usize) u8 {
    var len: usize = 0;

    var it = PieceTableIterator{ .node = self.root };
    while (it.next()) |n| {
        if (index < len + n.len) {
            if (n.use_original) {
                return self.original[n.start + index - len];
            } else {
                return self.append.items[n.start + index - len];
            }
        }
        len += n.len;
    }

    // fixme: Error.
    return 0;
}

pub fn printBuffer(self: *PieceTable) void {
    var it = PieceTableIterator{ .node = self.root };
    while (it.next()) |n| {
        if (n.use_original) {
            std.debug.print("{s}", .{self.original[n.start .. n.start + n.len]});
        } else {
            std.debug.print("{s}", .{self.append.items[n.start .. n.start + n.len]});
        }
    }
    std.debug.print("\n", .{});
}

pub fn buildBuffer(self: *PieceTable, start: usize, end: usize) ![]const u8 {
    var buffer = ArrayList(u8).init(self.allocator);

    var index: usize = start;
    while (index <= end) : (index += 1) {
        try buffer.append(self.getChar(index));
    }

    return buffer.toOwnedSlice();
}

pub fn freeBuffer(self: *PieceTable, buffer: []const u8) void {
    self.allocator.free(buffer);
}

pub fn printStack(self: *PieceTable) void {
    var it = PieceTableIterator{ .node = self.root };
    while (it.next()) |n| {
        if (n.use_original) {
            std.debug.print("O start {d} len {d}\n", .{ n.start, n.len });
        } else {
            std.debug.print("A start {d} len {d}\n", .{ n.start, n.len });
        }
    }
}

// ---

test "init / deinit" {
    var pt = PieceTable.init(testing.allocator);
    defer pt.deinit();
}

test "add text - split node" {
    var pt = PieceTable.init(testing.allocator);
    defer pt.deinit();

    const original =
        \\# Header 1
        \\Row 1.
        \\Row 2.
        \\# Header 2
    ;

    const adjusted =
        \\# Header 1
        \\Row 1.
        \\Row 2.
        \\Row 3.
        \\# Header 2
    ;

    try pt.setup(original);
    _ = try pt.insertTextAt("\nRow 3.", 24);

    var index: usize = 0;
    for (adjusted) |c0| {
        const c1 = pt.getChar(index);
        index += 1;
        try testing.expectEqual(c0, c1);
    }
}

test "add text - push aside" {
    var pt = PieceTable.init(testing.allocator);
    defer pt.deinit();

    const original = "0123456789";
    const adjusted = "012AB3456789";

    try pt.setup(original);
    _ = try pt.insertTextAt("A", 3);
    _ = try pt.insertTextAt("B", 4);

    var index: usize = 0;
    for (adjusted) |c0| {
        const c1 = pt.getChar(index);
        index += 1;
        try testing.expectEqual(c0, c1);
    }
}

const Tokenizer = @This();

const std = @import("std");
const testing = std.testing;
const log = std.log.scoped(.tokenizer);

const PieceTable = @import("PieceTable.zig");

pt: *PieceTable = undefined,
index: usize = 0,

col: usize = 0,
row: usize = 0,

pub const Token = struct {
    id: Id,
    start: usize,
    end: usize,

    pub const Id = enum {
        // zig fmt: off
        eof,

        h1,
        h2,
        h3,
        h4,
        h5,

        li,

        line,
        // zig fmt: on
    };
};

pub fn next(self: *Tokenizer) Token {
    var result = Token{
        .id = .eof,
        .start = self.index,
        .end = undefined,
    };

    var state: enum {
        start_of_line,
        header,
        list_item,
        read_until_eol,
    } = .start_of_line;

    const buffer_len = self.pt.bufferLen();

    while (self.index < buffer_len) : (self.index += 1) {
        const c = self.pt.getChar(self.index);

        switch (state) {
            .start_of_line => switch (c) {
                '#' => {
                    result.id = .h1;
                    state = .header;
                },
                '+', '-', '*' => {
                    result.id = .li;
                    state = .list_item;
                },
                '\n' => {
                    result.id = .line;
                    self.index += 1;
                    break;
                },
                else => {
                    result.id = .line;
                    state = .read_until_eol;
                },
            },

            .header => switch (c) {
                '#' => {
                    switch (result.id) {
                        .h1 => result.id = .h2,
                        .h2 => result.id = .h3,
                        .h3 => result.id = .h4,
                        .h4 => result.id = .h5,
                        else => {
                            result.id = .line;
                            state = .read_until_eol;
                        },
                    }
                },
                ' ' => {
                    state = .read_until_eol;
                },
                '\n' => {
                    result.id = .line;
                    self.index += 1;
                    break;
                },
                else => {
                    result.id = .line;
                    state = .read_until_eol;
                },
            },

            .list_item => switch (c) {
                ' ' => {
                    state = .read_until_eol;
                },
                '\n' => {
                    result.id = .line;
                    self.index += 1;
                    break;
                },
                else => {
                    result.id = .line;
                    state = .read_until_eol;
                },
            },

            .read_until_eol => switch (c) {
                '\n' => {
                    self.index += 1;
                    break;
                },
                else => {},
            },
        }
    }

    result.end = self.index;

    return result;
}

fn testExpected(source: []const u8, expected: []const Token.Id) !void {
    var pt = PieceTable.init(testing.allocator);
    defer pt.deinit();

    try pt.setup(source);

    var tokenizer = Tokenizer{
        .pt = &pt,
    };

    var given = std.ArrayList(Token.Id).init(testing.allocator);
    defer given.deinit();

    while (true) {
        const token = tokenizer.next();
        try given.append(token.id);
        if (token.id == .eof) break;
    }

    try testing.expectEqualSlices(Token.Id, expected, given.items);
}

test "empty doc" {
    try testExpected("", &[_]Token.Id{.eof});
}

test "headers" {
    try testExpected(
        \\# header 1
        \\...
    , &[_]Token.Id{
        .h1, .line, .eof,
    });

    try testExpected(
        \\## header 2
        \\...
    , &[_]Token.Id{
        .h2, .line, .eof,
    });

    try testExpected(
        \\# header 1
        \\## header 2
        \\### header 3
        \\#### header 4
        \\##### header 5
        \\...
    , &[_]Token.Id{
        .h1, .h2, .h3, .h4, .h5, .line, .eof,
    });

    try testExpected(
        \\###### Not supported level 
        \\...
    , &[_]Token.Id{
        .line, .line, .eof,
    });
}

test "lists" {
    try testExpected(
        \\- list item 1
        \\- list item 2
        \\- list item 3
        \\- list item 4
        \\...
    , &[_]Token.Id{
        .li, .li, .li, .li, .line, .eof,
    });
}

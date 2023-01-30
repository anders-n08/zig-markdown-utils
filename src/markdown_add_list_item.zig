const std = @import("std");
const build_options = @import("build_options");
const io = std.io;
const mem = std.mem;

const Tokenizer = @import("Tokenizer.zig");
const PieceTable = @import("PieceTable.zig");
const Token = Tokenizer.Token;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

const usage =
    \\Usage: markdown_add_time_entry <path-to-md>
    \\
    \\--header                 Header to hold list
    \\--text [text]            Time entry text to be inserted at end of list
    \\--template [filename]    If <path-to-md> does not exists, create it using
    \\                         this template.
    \\-h, --help               Print help and exit
    \\
;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const all_args = try std.process.argsAlloc(allocator);
    const args = all_args[1..];

    // const stdout = io.getStdOut().writer();
    const stderr = io.getStdErr().writer();

    var file_path: ?[]const u8 = null;
    var template_path: ?[]const u8 = null;
    var insert_text: ?[]const u8 = null;
    var header: ?[]const u8 = null;
    var arg_index: usize = 0;

    while (arg_index < args.len) : (arg_index += 1) {
        if (mem.eql(u8, "-h", args[arg_index]) or mem.eql(u8, "--help", args[arg_index])) {
            return io.getStdOut().writeAll(usage);
        } else if (mem.eql(u8, "--header", args[arg_index])) {
            if (arg_index + 1 >= args.len) {
                return stderr.writeAll("fatal: expected [text] after --header\n\n");
            }
            arg_index += 1;
            header = args[arg_index];
        } else if (mem.eql(u8, "--text", args[arg_index])) {
            if (arg_index + 1 >= args.len) {
                return stderr.writeAll("fatal: expected [text] after --text\n\n");
            }
            arg_index += 1;
            insert_text = args[arg_index];
        } else if (mem.eql(u8, "--template", args[arg_index])) {
            if (arg_index + 1 >= args.len) {
                return stderr.writeAll("fatal: expected [file] after --template\n\n");
            }
            arg_index += 1;
            template_path = args[arg_index];
        } else {
            file_path = args[arg_index];
        }
    }

    if (file_path == null) {
        return stderr.writeAll("fatal: no input path to markdown file specified\n\n");
    }

    if (insert_text == null) {
        return stderr.writeAll("fatal: no insert text specified\n\n");
    }

    if (header == null) {
        return stderr.writeAll("fatal: no header specified\n\n");
    }

    var pt = PieceTable.init(allocator);
    defer pt.deinit();

    const file = blk: {
        if (std.fs.cwd().openFile(file_path.?, .{ .mode = .read_write })) |f| {
            const source = try f.readToEndAlloc(allocator, std.math.maxInt(u32));
            try pt.setup(source);
            break :blk f;
        } else |err| switch (err) {
            else => {
                if (template_path) |p| {
                    const template = std.fs.cwd().openFile(p, .{ .mode = .read_only }) catch {
                        return stderr.writeAll("fatal: file and template not found\n\n");
                    };
                    const source = try template.readToEndAlloc(allocator, std.math.maxInt(u32));
                    try pt.setup(source);

                    const new_file = std.fs.cwd().createFile(file_path.?, .{
                        .read = true,
                    }) catch {
                        return stderr.writeAll("fatal: failed to create file\n\n");
                    };
                    break :blk new_file;
                } else {
                    return stderr.writeAll("fatal: file not found\n\n");
                }
            },
        }
    };
    defer file.close();

    var tokenizer = Tokenizer{
        .pt = &pt,
    };

    var state: enum {
        find_header,
        find_first_list_item,
        find_last_list_item,
        wait_for_eof,
    } = .find_header;

    var prev_token: ?Token = null;

    while (true) {
        const token = tokenizer.next();

        switch (state) {
            .find_header => {
                switch (token.id) {
                    .h1, .h2, .h3, .h4, .h5 => {
                        const token_buffer = try pt.buildBuffer(token.start, token.end);
                        var trimmed = mem.trimLeft(u8, token_buffer, "# \t");
                        trimmed = mem.trimRight(u8, trimmed, " \t\n");
                        if (mem.eql(u8, trimmed, header.?)) {
                            state = .find_first_list_item;
                        }
                        pt.freeBuffer(token_buffer);
                    },
                    else => {},
                }
            },
            .find_first_list_item => {
                switch (token.id) {
                    .li => state = .find_last_list_item,
                    .h1, .h2, .h3, .h4, .h5, .eof => {
                        if (prev_token) |t| {
                            var next_loc = try pt.insertTextAt("- ", t.end);
                            next_loc = try pt.insertTextAt(insert_text.?, next_loc);
                            next_loc = try pt.insertTextAt("\n", next_loc);
                        }
                        state = .wait_for_eof;
                    },
                    else => {},
                }
            },
            .find_last_list_item => {
                if (token.id != .li) {
                    if (prev_token) |t| {
                        var next_loc = try pt.insertTextAt("- ", t.end);
                        next_loc = try pt.insertTextAt(insert_text.?, next_loc);
                        next_loc = try pt.insertTextAt("\n", next_loc);
                        state = .wait_for_eof;
                    }
                }
            },
            .wait_for_eof => {},
        }

        if (token.id == .eof) break;

        prev_token = token;
    }

    const buffer_len = pt.bufferLen();
    const buffer = try pt.buildBuffer(0, buffer_len);

    try file.seekTo(0);
    try file.writeAll(buffer);

    pt.freeBuffer(buffer);
}

test {
    std.testing.refAllDecls(@This());
}

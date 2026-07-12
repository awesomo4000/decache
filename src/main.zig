const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const mem = std.mem;
const sep = Io.Dir.path.sep;

const usage =
    \\usage: {s} [options]... <directory> <pattern>...
    \\
    \\Deletes files and directories in <directory> that match <pattern>.
    \\
    \\  -d, --dry-run    do not delete anything, only print what would be deleted and
    \\                   which pattern it matched
    \\  -v, --verbose    print files and directories being deleted, add more details
    \\                   to dry-run
    \\  -s, --summary    print amount of space freed
    \\  -h, --help       print this message and exit
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const ally = init.gpa;
    const arena = init.arena.allocator();

    var stdout_buf: [1024]u8 = undefined;
    const stdout_file = Io.File.stdout();
    var stdout_writer = stdout_file.writerStreaming(io, &stdout_buf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var stderr_buf: [1024]u8 = undefined;
    const stderr_file = Io.File.stderr();
    var stderr_writer = stderr_file.writerStreaming(io, &stderr_buf);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    var args = try init.minimal.args.toSlice(arena);

    if (args.len == 0) {
        stderr.writeAll("No program name somehow???\n") catch {};
        return 1;
    }
    const prog_name = args[0];
    args = args[1..];

    var dry_run = false;
    var verbose = false;
    var summary = false;
    while (args.len != 0) : (args = args[1..]) {
        var arg = args[0];
        // Probably never gonna happen, but no reason to crash over it
        if (arg.len == 0) continue;
        if (arg[0] == '-') {
            // Just skip '-'
            if (arg.len == 1) continue;
            if (arg[1] == '-') {
                arg = arg[2..];
                if (arg.len == 0) {
                    // '--' means options are done and all following strings
                    // are treated as directory/patterns
                    args = args[1..];
                    break;
                } else if (mem.eql(u8, arg, "dry-run")) {
                    dry_run = true;
                } else if (mem.eql(u8, arg, "verbose")) {
                    verbose = true;
                } else if (mem.eql(u8, arg, "summary")) {
                    summary = true;
                } else if (mem.eql(u8, arg, "help")) {
                    try stdout.print(usage, .{prog_name});
                    return 0;
                } else {
                    stderr.print("Unrecognised option: {s}\n", .{arg}) catch {};
                    stderr.print(usage, .{prog_name}) catch {};
                    return 1;
                }
            } else {
                for (arg[1..]) |char| {
                    switch (char) {
                        'd' => dry_run = true,
                        'v' => verbose = true,
                        's' => summary = true,
                        'h' => {
                            try stdout.print(usage, .{prog_name});
                            return 0;
                        },
                        else => {
                            stderr.print("Unrecognised option: -{c}\n", .{char}) catch {};
                            stderr.print(usage, .{prog_name}) catch {};
                            return 1;
                        },
                    }
                }
            }
        } else break;
    }

    if (args.len == 0) {
        try stdout.print(usage, .{prog_name});
        return 1;
    }
    const root_dir_path = args[0];
    args = args[1..];

    const patterns = blk: {
        var slice = try arena.alloc(Pattern, args.len);
        for (args, 0..) |arg, i| {
            slice[i] = .init(arg);
        }
        args = args[args.len..];
        break :blk slice;
    };
    if (patterns.len == 0) {
        try stdout.print(usage, .{prog_name});
        return 1;
    }

    const dir = Io.Dir.cwd().openDir(io, root_dir_path, .{ .iterate = true }) catch |err| {
        stderr.print("Failed to open '{s}': {t}\n", .{ root_dir_path, err }) catch {};
        return 1;
    };
    defer dir.close(io);
    var walker = try dir.walk(ally);
    defer walker.deinit();

    const needs_size = verbose and dry_run or summary;
    var total_size: u64 = 0;
    while (true) {
        const entry = walker.next(io) catch |err| switch (err) {
            error.OutOfMemory => break,
            else => {
                const filename = walker.inner.name_buffer.items[0 .. walker.inner.name_buffer.items.len - 1];
                stderr.print("Failed to read file or directory '{s}': {t}\n", .{ filename, err }) catch {};
                stderr.flush() catch {};
                continue;
            },
        } orelse break;

        const pattern = blk: for (patterns) |p| (if (p.matches(entry)) break :blk p) else null;
        if (pattern) |p| {
            var size: u64 = 0;
            if (needs_size) {
                size = getItemSize(io, ally, entry.dir, entry.path, entry.basename, stderr) catch 0;
                total_size +|= size;
            }
            if (dry_run) {
                if (verbose) {
                    try stdout.print("{s} ({Bi:.1}): {s}\n", .{ p.full_string, size, entry.path });
                } else {
                    try stdout.print("{s}: {s}\n", .{ p.full_string, entry.path });
                }
                try stdout.flush();
            } else {
                var print_verbose = true;
                entry.dir.deleteTree(io, entry.basename) catch |err| {
                    stderr.print("Failed to delete file or directory '{s}': {t}\n", .{ entry.path, err }) catch {};
                    print_verbose = false;
                    stderr.flush() catch {};
                };
                if (verbose and print_verbose) {
                    try stdout.print("Deleted '{s}'\n", .{entry.path});
                    try stdout.flush();
                }
            }

            if (entry.kind == .directory) {
                walker.leave(io);
            }
        }
    }

    if (summary) {
        if (dry_run) {
            try stdout.print("Total size: {Bi:.1}\n", .{total_size});
        } else {
            try stdout.print("Total freed: {Bi:.1}\n", .{total_size});
        }
    }

    return 0;
}

const Pattern = struct {
    full_string: []const u8,
    string: []const u8,
    from_root: bool,
    dir: bool,

    fn init(string: []const u8) Pattern {
        if (string.len == 0) {
            return .{
                .full_string = string,
                .string = string,
                .from_root = false,
                .dir = false,
            };
        }
        const from_root, const start: usize =
            if (string[0] == '/') .{ true, 1 } else .{ false, 0 };
        const dir, const end: usize =
            if (string[string.len - 1] == '/') .{ true, string.len - 1 } else .{ false, string.len };

        return .{
            .full_string = string,
            .string = string[start..end],
            .from_root = from_root,
            .dir = dir,
        };
    }

    fn matches(pattern: Pattern, entry: Io.Dir.Walker.Entry) bool {
        if (pattern.dir and entry.kind != .directory) return false;
        if (pattern.from_root) {
            return mem.startsWith(u8, entry.path, pattern.string);
        } else if (pattern.dir) {
            return mem.endsWith(u8, entry.path, pattern.string);
        } else {
            return mem.findLast(u8, entry.path, pattern.string) != null;
        }
    }
};

fn getItemSize(
    io: Io,
    ally: Allocator,
    parent: Io.Dir,
    dir_path: []const u8,
    sub_path: []const u8,
    stderr: *Io.Writer,
) !u64 {
    const dir = parent.openDir(io, sub_path, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => {
            const file = parent.openFile(io, sub_path, .{ .path_only = true }) catch |err2| {
                stderr.print("Failed to open file '{s}/{s}': {t}", .{ dir_path, sub_path, err2 }) catch {};
                stderr.flush() catch {};
                return 0;
            };
            const stat = file.stat(io) catch |err2| {
                stderr.print("Failed to stat file '{s}/{s}': {t}", .{ dir_path, sub_path, err2 }) catch {};
                stderr.flush() catch {};
                return 0;
            };
            return stat.size;
        },
        else => {
            stderr.print("Failed to open '{s}/{s}': {t}", .{ dir_path, sub_path, err }) catch {};
            stderr.flush() catch {};
            return 0;
        },
    };
    defer dir.close(io);

    var walker = try dir.walk(ally);
    defer walker.deinit();

    var size: u64 = 0;
    while (true) {
        const entry = walker.next(io) catch |err| switch (err) {
            error.OutOfMemory => break,
            else => {
                const filename = walker.inner.name_buffer.items[0 .. walker.inner.name_buffer.items.len - 1];
                stderr.print("Failed to read file or directory '{s}/{s}': {t}\n", .{ dir_path, filename, err }) catch {};
                stderr.flush() catch {};
                continue;
            },
        } orelse break;

        if (entry.kind == .file) {
            const file = entry.dir.openFile(io, entry.basename, .{ .path_only = true }) catch |err| {
                stderr.print("Failed to open file '{s}/{s}': {t}", .{ dir_path, sub_path, err }) catch {};
                stderr.flush() catch {};
                continue;
            };
            defer file.close(io);
            const stat = file.stat(io) catch |err| {
                stderr.print("Failed to stat file '{s}/{s}': {t}", .{ dir_path, sub_path, err }) catch {};
                stderr.flush() catch {};
                continue;
            };
            size +|= stat.size;
        }
    }

    return size;
}

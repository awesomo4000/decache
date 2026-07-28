const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const mem = std.mem;
const sep = Io.Dir.path.sep;

const ArgsIterator = @import("ArgsIterator.zig");

comptime {
    std.testing.refAllDecls(ArgsIterator);
}

const usage =
    \\usage: {s} [options]... <directory> <pattern>...
    \\
    \\Deletes files and directories in <directory> that match <pattern>.
    \\
    \\  -d, --dry-run    do not delete anything, only print what would be deleted and
    \\                   which pattern it matched
    \\  -v, --verbose    print items being deleted, add more details to dry-run
    \\  -a, --age <days> only delete items modified at least <days> ago
    \\  -S, --size <size>
    \\                   only delete items at least <size> large, <size> is an integer
    \\                   followed by an optional suffix [K|M|G|T]
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

    var args = try init.minimal.args.iterateAllocator(arena);

    const prog_name = args.next() orelse {
        stderr.writeAll("No program name somehow???\n") catch {};
        return 1;
    };

    var dry_run = false;
    var verbose = false;
    var summary = false;
    var min_age: Io.Duration = .zero;
    var min_size: u64 = 0;

    var maybe_root_dir_path: ?[]const u8 = null;
    var patterns_list: std.ArrayList(Pattern) = .empty;
    defer patterns_list.deinit(ally);

    var args_iterator: ArgsIterator = .init(args);
    while (args_iterator.next()) |arg_str| {
        const Arg = enum {
            dry_run,
            verbose,
            age,
            size,
            summary,
            help,

            unknown,
        };
        const arg: Arg = switch (arg_str) {
            .option_long => |value|
            // zig fmt: off
                if (value.len == 0) break // options are done on "--"
                else if (mem.eql(u8, value, "dry-run")) .dry_run
                else if (mem.eql(u8, value, "verbose")) .verbose
                else if (mem.eql(u8, value, "age"))     .age
                else if (mem.eql(u8, value, "size"))    .size
                else if (mem.eql(u8, value, "summary")) .summary
                else if (mem.eql(u8, value, "help"))    .help
                else .unknown,
            // zig fmt: on
            .option_short => |value| switch (value) {
                'd' => .dry_run,
                'v' => .verbose,
                'a' => .age,
                'S' => .size,
                's' => .summary,
                'h' => .help,
                else => .unknown,
            },
            .argument => |value| {
                if (maybe_root_dir_path == null) {
                    maybe_root_dir_path = value;
                } else {
                    try patterns_list.append(ally, .init(value));
                }
                continue;
            },
        };

        switch (arg) {
            .dry_run => dry_run = true,
            .verbose => verbose = true,
            .summary => summary = true,
            .age => {
                const maybe_argument = args_iterator.next();
                if (maybe_argument == null or maybe_argument.? != .argument) {
                    stderr.print("Option 'age' ({f}) requires an argument\n", .{arg_str}) catch {};
                    stderr.print(usage, .{prog_name}) catch {};
                    return 1;
                }

                const days_str = maybe_argument.?.argument;
                const days = std.fmt.parseInt(i32, days_str, 10) catch {
                    stderr.print("Invalid age: '{s}'\n", .{days_str}) catch {};
                    stderr.print(usage, .{prog_name}) catch {};
                    return 1;
                };

                min_age = .fromSeconds(@as(i64, -days) * std.time.s_per_day);
            },
            .size => {
                const maybe_argument = args_iterator.next();
                if (maybe_argument == null or maybe_argument.? != .argument) {
                    stderr.print("Option 'size' ({f}) requires an argument\n", .{arg_str}) catch {};
                    stderr.print(usage, .{prog_name}) catch {};
                    return 1;
                }

                var size_str = maybe_argument.?.argument;
                const multiplier: u64 = switch (size_str[size_str.len - 1]) {
                    'K', 'k' => 1024,
                    'M', 'm' => 1024 * 1024,
                    'G', 'g' => 1024 * 1024 * 1024,
                    'T', 't' => 1024 * 1024 * 1024 * 1024,
                    else => 1,
                };
                if (multiplier != 1) size_str = size_str[0 .. size_str.len - 1];

                const size = std.fmt.parseInt(u64, size_str, 10) catch {
                    stderr.print("Invalid size: '{s}'\n", .{size_str}) catch {};
                    stderr.print(usage, .{prog_name}) catch {};
                    return 1;
                };

                min_size = size *| multiplier;
            },
            .help => {
                try stdout.print(usage, .{prog_name});
                return 0;
            },
            .unknown => {
                stderr.print("Unrecognised option: '{f}'\n", .{arg_str}) catch {};
                stderr.print(usage, .{prog_name}) catch {};
                return 1;
            },
        }
    }

    // handle stuff after a potential "--"
    while (args_iterator.inner.next()) |arg| {
        if (maybe_root_dir_path == null) {
            maybe_root_dir_path = arg;
        } else {
            try patterns_list.append(ally, .init(arg));
        }
    }

    const root_dir_path = maybe_root_dir_path orelse {
        try stdout.print(usage, .{prog_name});
        return 1;
    };

    const patterns = try patterns_list.toOwnedSlice(ally);
    defer ally.free(patterns);
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

    const now = Io.Clock.real.now(io);
    const delete_cutoff = now.addDuration(min_age);
    const needs_size = verbose and dry_run or summary or min_size != 0;
    var total_size: u64 = 0;
    var skipped: u64 = 0;
    var deleted: u64 = 0;
    while (true) {
        const entry = walker.next(io) catch |err| {
            const filename = walker.inner.name_buffer.items[0 .. walker.inner.name_buffer.items.len - 1];
            stderr.print("Failed to read file or directory '{s}': {t}\n", .{ filename, err }) catch {};
            stderr.flush() catch {};
            continue;
        } orelse break;

        const pattern = blk: for (patterns) |p| (if (p.matches(entry)) break :blk p) else null;
        if (pattern) |p| {
            var skip: enum { dont, too_young, cant_get_age, too_small, cant_get_size } = .dont;
            if (min_age.nanoseconds != 0) blk: {
                const file = entry.dir.openFile(io, entry.basename, .{ .path_only = true }) catch |err| {
                    stderr.print("Failed to determine age of '{s}': {t}\n", .{ entry.path, err }) catch {};
                    stderr.flush() catch {};
                    skip = .cant_get_age;
                    break :blk;
                };
                const stat = file.stat(io) catch |err| {
                    stderr.print("Failed to determine age of '{s}': {t}\n", .{ entry.path, err }) catch {};
                    stderr.flush() catch {};
                    skip = .cant_get_age;
                    break :blk;
                };
                if (stat.mtime.nanoseconds > delete_cutoff.nanoseconds) {
                    skip = .too_young;
                }
            }

            var size: u64 = 0;
            if (needs_size) {
                size = getItemSize(io, ally, entry.dir, entry.path, entry.basename, stderr, min_size != 0) catch |err| blk: {
                    if (min_size != 0) {
                        stderr.print("Failed to get size of '{s}': {t}\n", .{ entry.path, err }) catch {};
                        stderr.flush() catch {};
                        skip = .cant_get_size;
                    }
                    break :blk 0;
                };

                if (skip == .dont and size < min_size) {
                    skip = .too_small;
                }

                if (skip == .dont) {
                    total_size +|= size;
                }
            }

            if (dry_run) {
                if (verbose) {
                    try stdout.print("{s} ({Bi:.1}){s}: {s}\n", .{
                        p.full_string,
                        size,
                        switch (skip) {
                            .dont => "",
                            .too_young => " (skipped, too young)",
                            .cant_get_age => " (skipped, failed to get age)",
                            .too_small => " (skipped, too small)",
                            .cant_get_size => " (skipped, failed get size)",
                        },
                        entry.path,
                    });
                } else {
                    try stdout.print("{s}{s}: {s}\n", .{
                        p.full_string,
                        if (skip != .dont) " (skipped)" else "",
                        entry.path,
                    });
                }
                if (skip == .dont) deleted += 1 else skipped += 1;
                try stdout.flush();
            } else {
                var print_verbose = true;
                if (skip == .dont) blk: {
                    entry.dir.deleteTree(io, entry.basename) catch |err| {
                        stderr.print("Failed to delete file or directory '{s}': {t}\n", .{ entry.path, err }) catch {};
                        print_verbose = false;
                        stderr.flush() catch {};
                        skipped += 1;
                        break :blk;
                    };
                    deleted += 1;
                } else {
                    skipped += 1;
                }
                if (verbose and print_verbose) {
                    try stdout.print("{s} '{s}'\n", .{
                        if (skip != .dont) "Skipped" else "Deleted",
                        entry.path,
                    });
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
            try stdout.print("{d} matched, {d} skipped\tTotal size: {Bi:.1}\n", .{ deleted, skipped, total_size });
        } else {
            try stdout.print("{d} deleted, {d} skipped\tTotal freed: {Bi:.1}\n", .{ deleted, skipped, total_size });
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
    important: bool,
) !u64 {
    const dir = parent.openDir(io, sub_path, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => {
            const file = parent.openFile(io, sub_path, .{ .path_only = true }) catch |err2| {
                stderr.print("Failed to open file '{s}/{s}': {t}", .{ dir_path, sub_path, err2 }) catch {};
                stderr.flush() catch {};
                return if (important) err2 else 0;
            };
            const stat = file.stat(io) catch |err2| {
                stderr.print("Failed to stat file '{s}/{s}': {t}", .{ dir_path, sub_path, err2 }) catch {};
                stderr.flush() catch {};
                return if (important) err2 else 0;
            };
            return stat.size;
        },
        else => {
            stderr.print("Failed to open '{s}/{s}': {t}", .{ dir_path, sub_path, err }) catch {};
            stderr.flush() catch {};
            return if (important) err else 0;
        },
    };
    defer dir.close(io);

    var walker = try dir.walk(ally);
    defer walker.deinit();

    var size: u64 = 0;
    while (true) {
        const entry = walker.next(io) catch |err| {
            const filename = walker.inner.name_buffer.items[0 .. walker.inner.name_buffer.items.len - 1];
            stderr.print("Failed to read file or directory '{s}/{s}': {t}\n", .{ dir_path, filename, err }) catch {};
            stderr.flush() catch {};
            if (important) return err else continue;
        } orelse break;

        if (entry.kind == .file) {
            const file = entry.dir.openFile(io, entry.basename, .{ .path_only = true }) catch |err| {
                stderr.print("Failed to open file '{s}/{s}': {t}", .{ dir_path, sub_path, err }) catch {};
                stderr.flush() catch {};
                if (important) return err else continue;
            };
            defer file.close(io);
            const stat = file.stat(io) catch |err| {
                stderr.print("Failed to stat file '{s}/{s}': {t}", .{ dir_path, sub_path, err }) catch {};
                stderr.flush() catch {};
                if (important) return err else continue;
            };
            size +|= stat.size;
        }
    }

    return size;
}

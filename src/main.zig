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
    \\A pattern is one or more path components separated by '/'. It matches an item
    \\whose path ends with exactly those components, so 'cache' matches 'cache' and
    \\'a/cache' but not 'mycache' or 'cache.txt'. A leading '/' anchors the pattern
    \\to <directory>, so '/build' matches only '<directory>/build'. A trailing '/'
    \\matches only directories. Matched directories are deleted as a whole.
    \\
    \\  -d, --dry-run    do not delete anything, only print what would be deleted and
    \\                   which pattern it matched
    \\  -v, --verbose    print items being deleted; with -d, list matches as a table of
    \\                   size and last change, biggest first
    \\  -a, --age <days> only delete items modified at least <days> ago; a directory
    \\                   is only deleted if everything inside it is that old too
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

    var options: Options = .{};
    var positionals: std.ArrayList([]const u8) = .empty;
    defer positionals.deinit(ally);

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
                try positionals.append(ally, value);
                continue;
            },
        };

        switch (arg) {
            .dry_run => options.dry_run = true,
            .verbose => options.verbose = true,
            .summary => options.summary = true,
            .age => {
                const maybe_argument = args_iterator.next();
                if (maybe_argument == null or maybe_argument.? != .argument) {
                    stderr.print("Option 'age' ({f}) requires an argument\n", .{arg_str}) catch {};
                    stderr.print(usage, .{prog_name}) catch {};
                    return 1;
                }

                const days_str = maybe_argument.?.argument;
                options.min_age_days = std.fmt.parseInt(u32, days_str, 10) catch {
                    stderr.print("Invalid age: '{s}'\n", .{days_str}) catch {};
                    stderr.print(usage, .{prog_name}) catch {};
                    return 1;
                };
            },
            .size => {
                const maybe_argument = args_iterator.next();
                if (maybe_argument == null or maybe_argument.? != .argument) {
                    stderr.print("Option 'size' ({f}) requires an argument\n", .{arg_str}) catch {};
                    stderr.print(usage, .{prog_name}) catch {};
                    return 1;
                }

                const size_str = maybe_argument.?.argument;
                options.min_size = parseSize(size_str) catch {
                    stderr.print("Invalid size: '{s}'\n", .{size_str}) catch {};
                    stderr.print(usage, .{prog_name}) catch {};
                    return 1;
                };
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
        try positionals.append(ally, arg);
    }

    if (positionals.items.len < 2) {
        try stdout.print(usage, .{prog_name});
        return 1;
    }
    const root_dir_path = positionals.items[0];

    const patterns = try ally.alloc(Pattern, positionals.items.len - 1);
    defer ally.free(patterns);
    for (patterns, positionals.items[1..]) |*pattern, string| {
        pattern.* = Pattern.init(string) catch |err| {
            stderr.print("Invalid pattern '{s}': {s}\n", .{ string, switch (err) {
                error.EmptyPattern => "it has no path components",
                error.EmptyComponent => "it contains an empty path component",
                error.DotComponent => "it contains a '.' or '..' component",
            } }) catch {};
            return 1;
        };
    }

    const dir = Io.Dir.cwd().openDir(io, root_dir_path, .{ .iterate = true }) catch |err| {
        stderr.print("Failed to open '{s}': {t}\n", .{ root_dir_path, err }) catch {};
        return 1;
    };
    defer dir.close(io);

    const stats = try clean(io, ally, dir, patterns, options, Io.Clock.real.now(io), stdout, stderr);

    if (options.summary) {
        if (options.dry_run and options.verbose) {
            // Lines up under the table's size column.
            var size_buf: [16]u8 = undefined;
            try stdout.print("{s:>9}  total, {d} matched, {d} skipped\n", .{
                mem.print(&size_buf, "{Bi:.1}", .{stats.total_size}) catch unreachable,
                stats.deleted,
                stats.skipped,
            });
        } else if (options.dry_run) {
            try stdout.print("{d} matched, {d} skipped\tTotal size: {Bi:.1}\n", .{ stats.deleted, stats.skipped, stats.total_size });
        } else {
            try stdout.print("{d} deleted, {d} skipped\tTotal freed: {Bi:.1}\n", .{ stats.deleted, stats.skipped, stats.total_size });
        }
    }

    return 0;
}

const Options = struct {
    dry_run: bool = false,
    verbose: bool = false,
    summary: bool = false,
    /// 0 disables the age filter.
    min_age_days: u32 = 0,
    /// 0 disables the size filter.
    min_size: u64 = 0,
};

const Stats = struct {
    /// Items deleted, or in a dry run, items that would be deleted.
    deleted: u64 = 0,
    skipped: u64 = 0,
    /// Size of the deleted items.
    total_size: u64 = 0,
};

/// Deletes everything under `root` matching one of `patterns`.
fn clean(
    io: Io,
    ally: Allocator,
    root: Io.Dir,
    patterns: []const Pattern,
    options: Options,
    now: Io.Timestamp,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) !Stats {
    var walker = try root.walk(ally);
    defer walker.deinit();

    const filtering = options.min_age_days != 0 or options.min_size != 0;
    const needs_info = filtering or options.summary or (options.verbose and options.dry_run);
    const delete_cutoff = now.subDuration(.fromSeconds(@as(i64, options.min_age_days) * std.time.s_per_day));

    // A verbose dry run collects its matches and prints them as one table at the end.
    const table = options.dry_run and options.verbose;
    var rows: std.ArrayList(Row) = .empty;
    defer {
        for (rows.items) |row| ally.free(row.path);
        rows.deinit(ally);
    }

    var stats: Stats = .{};
    while (true) {
        const entry = walker.next(io) catch |err| {
            stderr.print("Failed to read file or directory '{s}': {t}\n", .{ walkerPath(&walker), err }) catch {};
            stderr.flush() catch {};
            continue;
        } orelse break;

        const pattern = for (patterns) |p| {
            if (p.matches(entry.path, entry.kind)) break p;
        } else continue;

        // A matched directory is deleted or skipped as a whole, never descended into.
        defer if (entry.kind == .directory) walker.leave(io);

        var skip: Skip = .dont;
        var size: u64 = 0;
        var last_modified: ?Io.Timestamp = null;
        if (needs_info) {
            if (getItemInfo(io, ally, entry.dir, entry.basename, entry.path, stderr)) |info| {
                size = info.size;
                last_modified = info.newest_mtime;
                if (filtering and !info.complete) {
                    skip = .unreadable;
                } else if (options.min_age_days != 0 and info.newest_mtime.nanoseconds > delete_cutoff.nanoseconds) {
                    skip = .too_young;
                } else if (size < options.min_size) {
                    skip = .too_small;
                }
            } else |_| {
                if (filtering) skip = .unreadable;
            }
        }

        if (options.dry_run) {
            if (table) {
                try rows.ensureUnusedCapacity(ally, 1);
                rows.appendAssumeCapacity(.{
                    .path = try ally.dupe(u8, entry.path),
                    .pattern = pattern.full_string,
                    .size = size,
                    .last_modified = last_modified,
                    .skip = skip,
                });
            } else {
                try stdout.print("{s}{s}: {s}\n", .{
                    pattern.full_string,
                    if (skip != .dont) " (skipped)" else "",
                    entry.path,
                });
                try stdout.flush();
            }
            if (skip == .dont) {
                stats.deleted += 1;
                stats.total_size +|= size;
            } else {
                stats.skipped += 1;
            }
        } else {
            var print_verbose = true;
            if (skip == .dont) blk: {
                entry.dir.deleteTree(io, entry.basename) catch |err| {
                    stderr.print("Failed to delete file or directory '{s}': {t}\n", .{ entry.path, err }) catch {};
                    print_verbose = false;
                    stderr.flush() catch {};
                    stats.skipped += 1;
                    break :blk;
                };
                stats.deleted += 1;
                stats.total_size +|= size;
            } else {
                stats.skipped += 1;
            }
            if (options.verbose and print_verbose) {
                try stdout.print("{s} '{s}'\n", .{
                    if (skip != .dont) "Skipped" else "Deleted",
                    entry.path,
                });
                try stdout.flush();
            }
        }
    }

    if (table) try printTable(stdout, rows.items, now, patterns.len > 1);

    return stats;
}

const Skip = enum {
    dont,
    too_young,
    too_small,
    unreadable,

    fn reason(skip: Skip) []const u8 {
        return switch (skip) {
            .dont => "",
            .too_young => "too young",
            .too_small => "too small",
            .unreadable => "failed to read",
        };
    }
};

const Row = struct {
    path: []const u8,
    pattern: []const u8,
    size: u64,
    last_modified: ?Io.Timestamp,
    skip: Skip,

    fn biggerFirst(_: void, a: Row, b: Row) bool {
        if (a.size != b.size) return a.size > b.size;
        return mem.lessThan(u8, a.path, b.path);
    }
};

/// Prints `rows` biggest first, as aligned columns of size, date and age of
/// the last change, and path.
fn printTable(writer: *Io.Writer, rows: []Row, now: Io.Timestamp, show_pattern: bool) Io.Writer.Error!void {
    mem.sort(Row, rows, {}, Row.biggerFirst);

    try writer.print("{s:>9}  {s:<10}  {s:>5}  {s}\n", .{ "SIZE", "CHANGED", "AGE", "PATH" });
    for (rows) |row| {
        var size_buf: [16]u8 = undefined;
        var date_buf: [16]u8 = undefined;
        var age_buf: [16]u8 = undefined;
        try writer.print("{s:>9}  {s:<10}  {s:>5}  {s}", .{
            mem.print(&size_buf, "{Bi:.1}", .{row.size}) catch unreachable,
            mem.print(&date_buf, "{f}", .{Date{ .timestamp = row.last_modified }}) catch unreachable,
            mem.print(&age_buf, "{f}", .{Age{ .last_modified = row.last_modified, .now = now }}) catch unreachable,
            row.path,
        });
        if (show_pattern) try writer.print("  [{s}]", .{row.pattern});
        if (row.skip != .dont) try writer.print("  (skipped: {s})", .{row.skip.reason()});
        try writer.writeByte('\n');
    }
    try writer.flush();
}

/// Formats the time since a change compactly: "today", "12d", "5mo", "2y".
const Age = struct {
    last_modified: ?Io.Timestamp,
    now: Io.Timestamp,

    pub fn format(age: Age, writer: *Io.Writer) Io.Writer.Error!void {
        const last_modified = age.last_modified orelse return writer.writeAll("?");
        const days = @divFloor(age.now.nanoseconds - last_modified.nanoseconds, std.time.ns_per_day);
        if (days < 1) return writer.writeAll("today");
        if (days < 60) return writer.print("{d}d", .{days});
        if (days < 730) return writer.print("{d}mo", .{@divFloor(days, 30)});
        return writer.print("{d}y", .{@divFloor(days, 365)});
    }
};

/// Formats a timestamp as a UTC date, YYYY-MM-DD, or "unknown" if null.
const Date = struct {
    timestamp: ?Io.Timestamp,

    pub fn format(date: Date, writer: *Io.Writer) Io.Writer.Error!void {
        const timestamp = date.timestamp orelse return writer.writeAll("unknown");
        const secs = std.math.cast(u64, @divFloor(timestamp.nanoseconds, std.time.ns_per_s)) orelse 0;
        const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = secs };
        const year_day = epoch_seconds.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        try writer.print("{d}-{d:0>2}-{d:0>2}", .{ year_day.year, month_day.month.numeric(), month_day.day_index + 1 });
    }
};

/// The path of the entry the walker last worked on, for error messages.
fn walkerPath(walker: *const Io.Dir.Walker) []const u8 {
    return mem.sliceTo(walker.inner.name_buffer.items, 0);
}

const Pattern = struct {
    full_string: []const u8,
    /// The pattern without its leading and trailing '/'.
    string: []const u8,
    from_root: bool,
    dir: bool,

    const InitError = error{ EmptyPattern, EmptyComponent, DotComponent };

    fn init(full_string: []const u8) InitError!Pattern {
        var string = full_string;
        const from_root = mem.startsWith(u8, string, "/");
        if (from_root) string = string[1..];
        const dir = mem.endsWith(u8, string, "/");
        if (dir) string = string[0 .. string.len - 1];

        if (string.len == 0) return error.EmptyPattern;
        var components = mem.splitScalar(u8, string, '/');
        while (components.next()) |component| {
            if (component.len == 0) return error.EmptyComponent;
            if (mem.eql(u8, component, ".") or mem.eql(u8, component, "..")) return error.DotComponent;
        }

        return .{
            .full_string = full_string,
            .string = string,
            .from_root = from_root,
            .dir = dir,
        };
    }

    /// `path` is relative to the root directory and uses the native separator.
    fn matches(pattern: Pattern, path: []const u8, kind: Io.File.Kind) bool {
        if (pattern.dir and kind != .directory) return false;
        if (pattern.from_root) return pathEql(path, pattern.string);

        // The pattern must cover whole trailing components of the path.
        if (path.len < pattern.string.len) return false;
        const start = path.len - pattern.string.len;
        if (start != 0 and path[start - 1] != sep) return false;
        return pathEql(path[start..], pattern.string);
    }

    fn pathEql(path: []const u8, pattern: []const u8) bool {
        if (path.len != pattern.len) return false;
        for (path, pattern) |a, b| {
            if (a != b and !(b == '/' and a == sep)) return false;
        }
        return true;
    }
};

fn parseSize(string: []const u8) !u64 {
    if (string.len == 0) return error.InvalidSize;
    const multiplier: u64 = switch (string[string.len - 1]) {
        'K', 'k' => 1024,
        'M', 'm' => 1024 * 1024,
        'G', 'g' => 1024 * 1024 * 1024,
        'T', 't' => 1024 * 1024 * 1024 * 1024,
        else => 1,
    };
    const digits = if (multiplier != 1) string[0 .. string.len - 1] else string;
    return std.math.mul(u64, try std.fmt.parseInt(u64, digits, 10), multiplier);
}

const ItemInfo = struct {
    /// Total size of the regular files in the item.
    size: u64,
    /// Most recent modification time of the item or anything inside it.
    newest_mtime: Io.Timestamp,
    /// False if part of a directory could not be read, which makes `size` and
    /// `newest_mtime` lower bounds.
    complete: bool,
};

/// Symlinks are never followed.
fn getItemInfo(
    io: Io,
    ally: Allocator,
    parent: Io.Dir,
    basename: []const u8,
    path: []const u8,
    stderr: *Io.Writer,
) !ItemInfo {
    const stat = parent.statFile(io, basename, .{ .follow_symlinks = false }) catch |err| {
        stderr.print("Failed to stat '{s}': {t}\n", .{ path, err }) catch {};
        stderr.flush() catch {};
        return err;
    };
    var info: ItemInfo = .{
        .size = if (stat.kind == .file) stat.size else 0,
        .newest_mtime = stat.mtime,
        .complete = true,
    };
    if (stat.kind != .directory) return info;

    const dir = parent.openDir(io, basename, .{ .iterate = true, .follow_symlinks = false }) catch |err| {
        stderr.print("Failed to open '{s}': {t}\n", .{ path, err }) catch {};
        stderr.flush() catch {};
        info.complete = false;
        return info;
    };
    defer dir.close(io);

    var walker = try dir.walk(ally);
    defer walker.deinit();

    while (true) {
        const entry = walker.next(io) catch |err| {
            stderr.print("Failed to read '{s}{c}{s}': {t}\n", .{ path, sep, walkerPath(&walker), err }) catch {};
            stderr.flush() catch {};
            info.complete = false;
            continue;
        } orelse break;

        const entry_stat = entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false }) catch |err| {
            stderr.print("Failed to stat '{s}{c}{s}': {t}\n", .{ path, sep, entry.path, err }) catch {};
            stderr.flush() catch {};
            info.complete = false;
            continue;
        };
        if (entry_stat.kind == .file) info.size +|= entry_stat.size;
        if (entry_stat.mtime.nanoseconds > info.newest_mtime.nanoseconds) info.newest_mtime = entry_stat.mtime;
    }

    return info;
}

const testing = std.testing;

test "Pattern.init rejects patterns that could match too much" {
    const bad: []const []const u8 = &.{ "", "/", "//", "///", "a//b", "/a//", ".", "./", "..", "/../a", "a/./b", "a/.." };
    for (bad) |string| {
        if (Pattern.init(string)) |_| {
            std.debug.print("pattern '{s}' was accepted\n", .{string});
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "Pattern.matches whole trailing components" {
    const Case = struct { pattern: []const u8, path: []const u8, kind: Io.File.Kind, expected: bool };
    const p = sep_str;
    const cases: []const Case = &.{
        .{ .pattern = "cache", .path = "cache", .kind = .directory, .expected = true },
        .{ .pattern = "cache", .path = "cache", .kind = .file, .expected = true },
        .{ .pattern = "cache", .path = "a" ++ p ++ "cache", .kind = .file, .expected = true },
        .{ .pattern = "cache", .path = "cache" ++ p ++ "a", .kind = .file, .expected = false },
        .{ .pattern = "cache", .path = "cache" ++ p ++ "abcde", .kind = .file, .expected = false },
        .{ .pattern = "cache", .path = "mycache", .kind = .directory, .expected = false },
        .{ .pattern = "cache", .path = "cachedata", .kind = .directory, .expected = false },
        .{ .pattern = "cache", .path = "a" ++ p ++ "cache.txt", .kind = .file, .expected = false },
        .{ .pattern = "cache", .path = "notes_cache", .kind = .file, .expected = false },
        .{ .pattern = ".tmp", .path = "f.tmp", .kind = .file, .expected = false },

        .{ .pattern = "cache/", .path = "cache", .kind = .directory, .expected = true },
        .{ .pattern = "cache/", .path = "a" ++ p ++ "cache", .kind = .directory, .expected = true },
        .{ .pattern = "cache/", .path = "cache", .kind = .file, .expected = false },
        .{ .pattern = "cache/", .path = "cache", .kind = .sym_link, .expected = false },
        .{ .pattern = "cache/", .path = "mycache", .kind = .directory, .expected = false },

        .{ .pattern = "/build", .path = "build", .kind = .directory, .expected = true },
        .{ .pattern = "/build", .path = "build_scripts", .kind = .directory, .expected = false },
        .{ .pattern = "/build", .path = "buildinfo.txt", .kind = .file, .expected = false },
        .{ .pattern = "/build", .path = "a" ++ p ++ "build", .kind = .directory, .expected = false },
        .{ .pattern = "/build", .path = "build" ++ p ++ "a", .kind = .file, .expected = false },
        .{ .pattern = "/build/", .path = "build", .kind = .file, .expected = false },

        .{ .pattern = "a/b", .path = "a" ++ p ++ "b", .kind = .file, .expected = true },
        .{ .pattern = "a/b", .path = "x" ++ p ++ "a" ++ p ++ "b", .kind = .file, .expected = true },
        .{ .pattern = "a/b", .path = "xa" ++ p ++ "b", .kind = .file, .expected = false },
        .{ .pattern = "a/b", .path = "a" ++ p ++ "bc", .kind = .file, .expected = false },
        .{ .pattern = "a/b", .path = "b", .kind = .file, .expected = false },
        .{ .pattern = "/a/b", .path = "x" ++ p ++ "a" ++ p ++ "b", .kind = .file, .expected = false },
        .{ .pattern = "/a/b", .path = "a" ++ p ++ "b", .kind = .file, .expected = true },
    };
    for (cases) |case| {
        const pattern = try Pattern.init(case.pattern);
        if (pattern.matches(case.path, case.kind) != case.expected) {
            std.debug.print("pattern '{s}' on {t} '{s}': expected {}\n", .{ case.pattern, case.kind, case.path, case.expected });
            return error.TestUnexpectedResult;
        }
    }
}

const sep_str = Io.Dir.path.sep_str;

test Date {
    const Case = struct { seconds: i64, expected: []const u8 };
    const cases: []const Case = &.{
        .{ .seconds = 0, .expected = "1970-01-01" },
        .{ .seconds = 951782400, .expected = "2000-02-29" },
        .{ .seconds = 1798761599, .expected = "2026-12-31" },
        .{ .seconds = -86400, .expected = "1970-01-01" },
    };
    for (cases) |case| {
        const timestamp: Io.Timestamp = .fromNanoseconds(@as(i96, case.seconds) * std.time.ns_per_s);
        var buf: [32]u8 = undefined;
        var writer: Io.Writer = .fixed(&buf);
        try writer.print("{f}", .{Date{ .timestamp = timestamp }});
        try testing.expectEqualStrings(case.expected, writer.buffered());
    }
    var buf: [32]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    try writer.print("{f}", .{Date{ .timestamp = null }});
    try testing.expectEqualStrings("unknown", writer.buffered());
}

test parseSize {
    try testing.expectEqual(0, try parseSize("0"));
    try testing.expectEqual(10, try parseSize("10"));
    try testing.expectEqual(10 * 1024, try parseSize("10K"));
    try testing.expectEqual(3 * 1024 * 1024, try parseSize("3m"));
    try testing.expectEqual(1024 * 1024 * 1024 * 1024, try parseSize("1T"));
    for ([_][]const u8{ "", "K", "abc", "10KB", "1.5G", "99999999999T" }) |string| {
        if (parseSize(string)) |_| {
            std.debug.print("size '{s}' was accepted\n", .{string});
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

/// Every test that deletes works in a fresh `testing.tmpDir`: `root` is the
/// only directory handed to `clean`, and `outside` sits next to it holding a
/// sentinel that must always survive.
const Sandbox = struct {
    tmp: testing.TmpDir,
    root: Io.Dir,

    const io = testing.io;

    fn init() !Sandbox {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try writeFile(tmp.dir, "outside/sentinel", "keep");
        const root = try tmp.dir.createDirPathOpen(io, "root", .{ .open_options = .{ .iterate = true } });
        return .{ .tmp = tmp, .root = root };
    }

    fn deinit(sandbox: *Sandbox) void {
        sandbox.root.close(io);
        sandbox.tmp.cleanup();
    }

    fn writeFile(dir: Io.Dir, path: []const u8, data: []const u8) !void {
        if (Io.Dir.path.dirname(path)) |parent| try dir.createDirPath(io, parent);
        try dir.writeFile(io, .{ .sub_path = path, .data = data });
    }

    fn file(sandbox: Sandbox, path: []const u8, data: []const u8) !void {
        try writeFile(sandbox.root, path, data);
    }

    fn setMtime(sandbox: Sandbox, path: []const u8, mtime: Io.Timestamp) !void {
        try sandbox.root.setTimestamps(io, path, .{ .follow_symlinks = false, .modify_timestamp = .{ .new = mtime } });
    }

    fn exists(sandbox: Sandbox, path: []const u8) bool {
        _ = sandbox.root.statFile(io, path, .{ .follow_symlinks = false }) catch return false;
        return true;
    }

    fn expectExists(sandbox: Sandbox, paths: []const []const u8) !void {
        for (paths) |path| if (!sandbox.exists(path)) {
            std.debug.print("'{s}' was deleted\n", .{path});
            return error.TestUnexpectedResult;
        };
        _ = try sandbox.tmp.dir.statFile(io, "outside/sentinel", .{});
    }

    fn expectGone(sandbox: Sandbox, paths: []const []const u8) !void {
        for (paths) |path| if (sandbox.exists(path)) {
            std.debug.print("'{s}' was not deleted\n", .{path});
            return error.TestUnexpectedResult;
        };
    }

    fn clean(sandbox: Sandbox, pattern_strings: []const []const u8, options: Options) !Stats {
        var out: Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        return sandbox.cleanAt(pattern_strings, options, Io.Clock.real.now(io), &out.writer);
    }

    fn cleanAt(
        sandbox: Sandbox,
        pattern_strings: []const []const u8,
        options: Options,
        now: Io.Timestamp,
        out: *Io.Writer,
    ) !Stats {
        var patterns: [8]Pattern = undefined;
        for (patterns[0..pattern_strings.len], pattern_strings) |*pattern, string| pattern.* = try .init(string);
        var err: Io.Writer.Allocating = .init(testing.allocator);
        defer err.deinit();
        return main_file.clean(
            io,
            testing.allocator,
            sandbox.root,
            patterns[0..pattern_strings.len],
            options,
            now,
            out,
            &err.writer,
        );
    }

    /// Sets a mode without owner write permission on the directory at `path`,
    /// returning false if that has no effect (as when running as root), in
    /// which case the test cannot check anything.
    fn lock(sandbox: Sandbox, path: []const u8, mode: std.posix.mode_t) !bool {
        std.debug.assert(mode & 0o200 == 0);
        try sandbox.root.setFilePermissions(io, path, .fromMode(mode), .{});
        const probe = try Io.Dir.path.join(testing.allocator, &.{ path, "probe" });
        defer testing.allocator.free(probe);
        sandbox.root.writeFile(io, .{ .sub_path = probe, .data = "" }) catch return true;
        return false;
    }

    fn unlock(sandbox: Sandbox, path: []const u8) void {
        sandbox.root.setFilePermissions(io, path, .default_dir, .{}) catch {};
    }
};

const main_file = @This();

fn buildTree(sandbox: Sandbox) !void {
    try sandbox.file("cache/a.bin", "a");
    try sandbox.file("a/b/cache/c.bin", "c");
    try sandbox.file("src/cachedata/important.c", "important");
    try sandbox.file("mycache/keep", "keep");
    try sandbox.file("notes_cache.txt", "keep");
    try sandbox.file("cache.txt", "keep");
    try sandbox.file("build/out.o", "o");
    try sandbox.file("build_scripts/deploy.sh", "keep");
    try sandbox.file("sub/build/keep", "keep");
    try sandbox.file("x/cache", "file named cache");
    // A symlink named like a match, pointing out of the root.
    try sandbox.root.symLink(Sandbox.io, "../../outside", "sub/cache", .{ .is_directory = true });
}

const untouched_by_tree_patterns: []const []const u8 = &.{
    "a/b",
    "src/cachedata/important.c",
    "mycache/keep",
    "notes_cache.txt",
    "cache.txt",
    "build_scripts/deploy.sh",
    "sub/build/keep",
};

test "clean deletes only whole-component directory matches" {
    var sandbox: Sandbox = try .init();
    defer sandbox.deinit();
    try buildTree(sandbox);

    const stats = try sandbox.clean(&.{ "cache/", "/build/" }, .{});

    try sandbox.expectGone(&.{ "cache", "a/b/cache", "build" });
    try sandbox.expectExists(untouched_by_tree_patterns);
    try sandbox.expectExists(&.{ "sub/cache", "x/cache" });
    try testing.expectEqual(3, stats.deleted);
    try testing.expectEqual(0, stats.skipped);
}

test "clean removes a matching symlink but not its target" {
    var sandbox: Sandbox = try .init();
    defer sandbox.deinit();
    try buildTree(sandbox);

    const stats = try sandbox.clean(&.{"cache"}, .{});

    try sandbox.expectGone(&.{ "cache", "a/b/cache", "x/cache", "sub/cache" });
    try sandbox.expectExists(untouched_by_tree_patterns);
    try sandbox.expectExists(&.{ "build/out.o", "sub/build/keep" });
    try testing.expectEqual(4, stats.deleted);
}

test "clean in dry-run deletes nothing" {
    var sandbox: Sandbox = try .init();
    defer sandbox.deinit();
    try buildTree(sandbox);

    const stats = try sandbox.clean(&.{ "cache", "/build/", "keep" }, .{
        .dry_run = true,
        .verbose = true,
        .summary = true,
    });

    try sandbox.expectExists(untouched_by_tree_patterns);
    try sandbox.expectExists(&.{ "cache/a.bin", "a/b/cache/c.bin", "build/out.o", "x/cache", "sub/cache" });
    // cache, a/b/cache, x/cache, sub/cache, build, mycache/keep, sub/build/keep
    try testing.expectEqual(7, stats.deleted);
}

test "clean age filter checks everything inside a directory" {
    var sandbox: Sandbox = try .init();
    defer sandbox.deinit();

    const now = Io.Clock.real.now(Sandbox.io);
    const old = now.subDuration(.fromSeconds(10 * std.time.s_per_day));

    try sandbox.file("old_file/cache", "x");
    try sandbox.setMtime("old_file/cache", old);
    try sandbox.file("new_file/cache", "x");

    try sandbox.file("old_dir/cache/a", "x");
    try sandbox.setMtime("old_dir/cache/a", old);
    try sandbox.setMtime("old_dir/cache", old);

    // The directory itself looks old, but something deep inside it is in use.
    try sandbox.file("busy_dir/cache/deep/old", "x");
    try sandbox.setMtime("busy_dir/cache/deep/old", old);
    try sandbox.file("busy_dir/cache/deep/new", "x");
    try sandbox.setMtime("busy_dir/cache/deep", old);
    try sandbox.setMtime("busy_dir/cache", old);

    // An old symlink is judged by its own age, not by its fresh target.
    try sandbox.root.createDirPath(Sandbox.io, "link");
    try sandbox.root.symLink(Sandbox.io, "../../outside", "link/cache", .{ .is_directory = true });
    try sandbox.setMtime("link/cache", old);

    const stats = try sandbox.clean(&.{"cache"}, .{ .min_age_days = 5 });

    try sandbox.expectGone(&.{ "old_file/cache", "old_dir/cache", "link/cache" });
    try sandbox.expectExists(&.{ "new_file/cache", "busy_dir/cache/deep/new", "busy_dir/cache/deep/old" });
    try testing.expectEqual(3, stats.deleted);
    try testing.expectEqual(2, stats.skipped);
}

test "clean verbose dry run prints a table, biggest first" {
    var sandbox: Sandbox = try .init();
    defer sandbox.deinit();

    const day = std.time.s_per_day;
    const now: Io.Timestamp = .fromNanoseconds(1769817600 * std.time.ns_per_s); // 2026-01-31
    const Cache = struct { dir: []const u8, size: usize, days_ago: i64 };
    const caches: []const Cache = &.{
        .{ .dir = "tiny/.zig-cache", .size = 10, .days_ago = 30 },
        .{ .dir = "old/.zig-cache", .size = 100, .days_ago = 975 },
        .{ .dir = "big/.zig-cache", .size = 3000, .days_ago = 1 },
        .{ .dir = "new/.zig-cache", .size = 50, .days_ago = 0 },
        .{ .dir = "mid/.zig-cache", .size = 1500, .days_ago = 183 },
    };
    var data: [3000]u8 = @splat('x');
    for (caches) |cache| {
        const mtime = now.subDuration(.fromSeconds(cache.days_ago * day));
        const path = try Io.Dir.path.join(testing.allocator, &.{ cache.dir, "o", "obj" });
        defer testing.allocator.free(path);
        try sandbox.file(path, data[0..cache.size]);
        try sandbox.setMtime(path, mtime);
        try sandbox.setMtime(Io.Dir.path.dirname(path).?, mtime);
        try sandbox.setMtime(cache.dir, mtime);
    }

    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const stats = try sandbox.cleanAt(&.{".zig-cache/"}, .{ .dry_run = true, .verbose = true, .min_size = 50 }, now, &out.writer);

    try testing.expectEqualStrings(
        \\     SIZE  CHANGED       AGE  PATH
        \\   2.9KiB  2026-01-30     1d  big/.zig-cache
        \\   1.5KiB  2025-08-01    6mo  mid/.zig-cache
        \\     100B  2023-06-01     2y  old/.zig-cache
        \\      50B  2026-01-31  today  new/.zig-cache
        \\      10B  2026-01-01    30d  tiny/.zig-cache  (skipped: too small)
        \\
    , out.written());
    try testing.expectEqual(4, stats.deleted);
    try testing.expectEqual(1, stats.skipped);
    try sandbox.expectExists(&.{ "tiny/.zig-cache/o/obj", "big/.zig-cache/o/obj", "new/.zig-cache/o/obj" });
}

test "clean size filter and summary total" {
    var sandbox: Sandbox = try .init();
    defer sandbox.deinit();

    try sandbox.file("big/cache/a", &@as([1500]u8, @splat('a')));
    try sandbox.file("big/cache/sub/b", &@as([1500]u8, @splat('b')));
    try sandbox.file("small/cache", &@as([100]u8, @splat('c')));

    const stats = try sandbox.clean(&.{"cache"}, .{ .min_size = 2048, .summary = true });

    try sandbox.expectGone(&.{"big/cache"});
    try sandbox.expectExists(&.{"small/cache"});
    try testing.expectEqual(1, stats.deleted);
    try testing.expectEqual(1, stats.skipped);
    try testing.expectEqual(3000, stats.total_size);
}

test "clean skips a directory it cannot fully read when filtering" {
    var sandbox: Sandbox = try .init();
    defer sandbox.deinit();

    const now = Io.Clock.real.now(Sandbox.io);
    const old = now.subDuration(.fromSeconds(10 * std.time.s_per_day));
    // Everything is old, so only the unreadable directory can stop the delete.
    // An attempted delete stops at the first entry it cannot remove; with this
    // many siblings some come before 'locked' in any iteration order, and
    // those would be gone.
    var readable_buf: [16][]const u8 = undefined;
    for (&readable_buf, 0..) |*path, i| path.* = try testing.allocator.print("cache/f{d}", .{i});
    defer for (readable_buf) |path| testing.allocator.free(path);
    const readable: []const []const u8 = &readable_buf;
    for (readable) |path| {
        try sandbox.file(path, "x");
        try sandbox.setMtime(path, old);
    }
    try sandbox.file("cache/locked/old", "x");
    try sandbox.setMtime("cache/locked/old", old);
    try sandbox.setMtime("cache/locked", old);
    try sandbox.setMtime("cache", old);

    defer sandbox.unlock("cache/locked");
    if (!try sandbox.lock("cache/locked", 0o000)) return error.SkipZigTest;

    const stats = try sandbox.clean(&.{"cache/"}, .{ .min_age_days = 5 });

    sandbox.unlock("cache/locked");
    try sandbox.expectExists(readable);
    try sandbox.expectExists(&.{"cache/locked/old"});
    try testing.expectEqual(0, stats.deleted);
    try testing.expectEqual(1, stats.skipped);
}

test "clean counts a failed delete as skipped and not freed" {
    var sandbox: Sandbox = try .init();
    defer sandbox.deinit();

    try sandbox.file("ro/cache", "data");
    try sandbox.file("rw/cache", "data");

    defer sandbox.unlock("ro");
    if (!try sandbox.lock("ro", 0o555)) return error.SkipZigTest;

    const stats = try sandbox.clean(&.{"cache"}, .{ .summary = true });

    sandbox.unlock("ro");
    try sandbox.expectExists(&.{"ro/cache"});
    try sandbox.expectGone(&.{"rw/cache"});
    try testing.expectEqual(1, stats.deleted);
    try testing.expectEqual(1, stats.skipped);
    try testing.expectEqual(4, stats.total_size);
}

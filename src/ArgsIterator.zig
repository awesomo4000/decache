const std = @import("std");

const ArgsIterator = @This();

const Arg = union(enum) {
    option_long: []const u8,
    option_short: u8,
    argument: []const u8,

    pub fn format(self: Arg, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try switch (self) {
            .option_long => |value| writer.print("--{s}", .{value}),
            .option_short => |value| writer.print("-{c}", .{value}),
            .argument => |value| writer.print("{s}", .{value}),
        };
    }
};

inner: std.process.Args.Iterator,
current_arg: []const u8,

pub fn init(args: std.process.Args.Iterator) ArgsIterator {
    return .{
        .inner = args,
        .current_arg = "",
    };
}

pub fn next(self: *ArgsIterator) ?Arg {
    if (self.current_arg.len != 0) {
        const option = self.current_arg[0];
        self.current_arg = self.current_arg[1..];
        return .{ .option_short = option };
    }

    var arg = self.inner.next() orelse return null;

    while (true) {
        if (std.mem.startsWith(u8, arg, "--")) {
            const option = arg[2..];
            return .{ .option_long = option };
        } else if (std.mem.startsWith(u8, arg, "-")) {
            if (arg.len == 1) {
                arg = self.inner.next() orelse return null;
                continue;
            }
            const option = arg[1];
            self.current_arg = arg[2..];
            return .{ .option_short = option };
        } else {
            return .{ .argument = arg };
        }
    }
}

test "ArgsIterator" {
    const args: std.process.Args = .{
        .vector = &.{ "--asdf", "--qwerty", "--", "-abc", "waow", "woah", "hmmm" },
    };
    var iter: ArgsIterator = .init(args.iterate());

    const expected: []const ?Arg = &.{
        .{ .option_long = "asdf" },
        .{ .option_long = "qwerty" },
        .{ .option_long = "" },
        .{ .option_short = 'a' },
        .{ .option_short = 'b' },
        .{ .option_short = 'c' },
        .{ .argument = "waow" },
        .{ .argument = "woah" },
        .{ .argument = "hmmm" },
        null,
    };

    for (expected) |e| {
        try std.testing.expectEqualDeep(e, iter.next());
    }
}

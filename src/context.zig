const std = @import("std");
const Allocator = std.mem.Allocator;
const TypeInfo = std.builtin.TypeInfo;
const trait = std.meta.trait;

pub const Escape = enum {
    Escaped,
    Unescaped,
};

pub fn getContext(allocator: Allocator, out_writer: anytype, data: anytype) Allocator.Error!Context(@TypeOf(out_writer)) {
    const Impl = ContextImpl(@TypeOf(out_writer), @TypeOf(data));
    return try Impl.init(allocator, out_writer, data);
}

pub fn Context(comptime Writer: type) type {
    return struct {
        const Self = @This();

        ptr: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            get: fn (ctx: *anyopaque, allocator: Allocator, path: []const u8, index: ?usize) Allocator.Error!?Self,
            write: fn (ctx: *anyopaque, path: []const u8, escape: Escape) Writer.Error!bool,
            deinit: fn (ctx: *anyopaque, allocator: Allocator) void,
        };

        pub const Iterator = struct {
            context: *Self,
            path: []const u8,
            current: usize,

            pub fn next(self: *Iterator, allocator: Allocator) Allocator.Error!?Self {
                defer self.current += 1;
                return try self.context.vtable.get(self.context.ptr, allocator, self.path, self.current);
            }
        };

        pub inline fn get(self: Self, allocator: Allocator, path: []const u8) Allocator.Error!?Self {
            return try self.vtable.get(self.ptr, allocator, path, null);
        }

        pub fn iterator(self: *Self, path: []const u8) Iterator {
            return .{
                .context = self,
                .path = path,
                .current = 0,
            };
        }

        pub inline fn write(self: Self, path: []const u8, escape: Escape) Writer.Error!bool {
            return try self.vtable.write(self.ptr, path, escape);
        }

        pub inline fn deinit(self: Self, allocator: Allocator) void {
            return self.vtable.deinit(self.ptr, allocator);
        }
    };
}

fn ContextImpl(comptime Writer: type, comptime Data: type) type {
    return struct {
        const ContextInterface = Context(Writer);

        const vtable = ContextInterface.VTable{
            .get = get,
            .write = write,
            .deinit = deinit,
        };

        const PATH_SEPARATOR = ".";
        const Self = @This();

        writer: Writer,
        data: Data,

        pub fn init(allocator: Allocator, writer: Writer, data: Data) Allocator.Error!ContextInterface {
            var self = try allocator.create(Self);
            self.* = .{
                .writer = writer,
                .data = data,
            };

            return ContextInterface{
                .ptr = self,
                .vtable = &vtable,
            };
        }

        fn get(ctx: *anyopaque, allocator: Allocator, path: []const u8, index: ?usize) Allocator.Error!?ContextInterface {
            var self = getSelf(ctx);

            var path_iterator = std.mem.tokenize(u8, path, PATH_SEPARATOR);
            return try Comptime.get(allocator, self.writer, self.data, &path_iterator, index);
        }

        fn write(ctx: *anyopaque, path: []const u8, escape: Escape) Writer.Error!bool {
            var self = getSelf(ctx);

            var path_iterator = std.mem.tokenize(u8, path, PATH_SEPARATOR);
            return if (try Comptime.write(self.writer, self.data, &path_iterator, escape)) |_| true else false;
        }

        fn deinit(ctx: *anyopaque, allocator: Allocator) void {
            var self = getSelf(ctx);
            allocator.destroy(self);
        }

        inline fn getSelf(ctx: *anyopaque) *Self {
            return @ptrCast(*Self, @alignCast(@alignOf(Self), ctx));
        }
    };
}

const Comptime = struct {
    pub inline fn get(
        allocator: Allocator,
        out_writer: anytype,
        data: anytype,
        path_iterator: *std.mem.TokenIterator(u8),
        index: ?usize,
    ) Allocator.Error!?Context(@TypeOf(out_writer)) {

        // TODO: Should we set a new branch quota here??
        // Let's wait for some real use case
        //@setEvalBranchQuota(std.math.maxInt(u32));

        const TReturn = Allocator.Error!?Context(@TypeOf(out_writer));
        return try seek(
            TReturn,
            getContext,
            allocator,
            out_writer,
            data,
            path_iterator,
            index,
        );
    }

    pub inline fn write(
        out_writer: anytype,
        data: anytype,
        path_iterator: *std.mem.TokenIterator(u8),
        escape: Escape,
    ) @TypeOf(out_writer).Error!?void {

        // TODO: Should we set a new branch quota here??
        // Let's wait for some real use case
        //@setEvalBranchQuota(std.math.maxInt(u32));

        const TReturn = @TypeOf(out_writer).Error!?void;
        return try seek(TReturn, stringify, escape, out_writer, data, path_iterator, null);
    }

    inline fn seek(
        comptime TReturn: type,
        action: anytype,
        param: anytype,
        out_writer: anytype,
        data: anytype,
        path_iterator: *std.mem.TokenIterator(u8),
        index: ?usize,
    ) TReturn {
        if (path_iterator.next()) |token| {
            return try recursiveSeek(TReturn, @TypeOf(data), action, param, out_writer, data, token, path_iterator, index);
        } else {
            const Data = @TypeOf(data);
            if (Data == comptime_int) {
                const RuntimeInt = if (data > 0) std.math.IntFittingRange(0, data) else std.math.IntFittingRange(data, 0);
                var runtime_value: RuntimeInt = data;
                return try seek(TReturn, action, param, out_writer, runtime_value, path_iterator, index);
            } else if (Data == comptime_float) {
                var runtime_value: f64 = data;
                return try seek(TReturn, action, param, out_writer, runtime_value, path_iterator, index);
            } else if (Data == void or Data == @TypeOf(null)) {
                return null;
            } else {
                if (index) |current_index| {
                    if (iterateAt(data, current_index)) |data_at| {
                        return try action(param, out_writer, data_at);
                    } else {
                        return null;
                    }
                } else {
                    return try action(param, out_writer, data);
                }
            }
        }
    }

    inline fn recursiveSeek(
        comptime TReturn: type,
        comptime TValue: type,
        action: anytype,
        param: anytype,
        out_writer: anytype,
        data: anytype,
        path: []const u8,
        path_iterator: *std.mem.TokenIterator(u8),
        index: ?usize,
    ) TReturn {
        const typeInfo = @typeInfo(TValue);

        switch (typeInfo) {
            .Struct => return try seekField(TReturn, TValue, action, param, out_writer, data, path, path_iterator, index),
            .Pointer => |info| switch (info.size) {
                .One => return try recursiveSeek(TReturn, info.child, action, param, out_writer, data, path, path_iterator, index),
                .Slice => {

                    //Slice supports the "len" field,
                    if (std.mem.eql(u8, "len", path)) {
                        try return seek(TReturn, action, param, out_writer, data.len, path_iterator, index);
                    }
                },

                .Many => @compileError("[*] pointers not supported"),
                .C => @compileError("[*c] pointers not supported"),
            },
            .Optional => |info| {
                if (data) |value| {
                    return try return recursiveSeek(TReturn, info.child, action, param, out_writer, value, path, path_iterator, index);
                }
            },
            else => {},
        }

        return null;
    }

    inline fn seekField(
        comptime TReturn: type,
        comptime TValue: type,
        action: anytype,
        param: anytype,
        out_writer: anytype,
        data: anytype,
        path: []const u8,
        path_iterator: *std.mem.TokenIterator(u8),
        index: ?usize,
    ) TReturn {
        const fields = std.meta.fields(TValue);
        inline for (fields) |field| {
            if (std.mem.eql(u8, field.name, path)) {
                return try seek(TReturn, action, param, out_writer, @field(data, field.name), path_iterator, index);
            }
        }

        return null;
    }

    inline fn stringify(
        escape: Escape,
        out_writer: anytype,
        value: anytype,
    ) @TypeOf(out_writer).Error!void {
        const typeInfo = @typeInfo(@TypeOf(value));

        switch (typeInfo) {
            .Void, .Null => {},

            // what should we print?
            .Struct, .Opaque => {},

            .Bool => try escape_write(out_writer, if (value) "true" else "false", escape),
            .Int, .ComptimeInt => try std.fmt.formatInt(value, 10, .lower, .{}, out_writer),
            .Float, .ComptimeFloat => try std.fmt.formatFloatDecimal(value, .{}, out_writer),
            .Enum => try escape_write(out_writer, @tagName(value), escape),

            .Pointer => |info| switch (info.size) {
                TypeInfo.Pointer.Size.One => try stringify(escape, out_writer, value.*),
                TypeInfo.Pointer.Size.Slice => {
                    if (info.child == u8) {
                        try escape_write(out_writer, value, escape);
                    }
                },
                TypeInfo.Pointer.Size.Many => @compileError("[*] pointers not supported"),
                TypeInfo.Pointer.Size.C => @compileError("[*c] pointers not supported"),
            },
            .Array => |info| {
                if (info.child == u8) {
                    try escape_write(out_writer, &value, escape);
                }
            },
            .Optional => {
                if (value) |not_null| {
                    try stringify(escape, out_writer, not_null);
                }
            },
            else => @compileError("Not supported"),
        }
    }

    fn escape_write(
        out_writer: anytype,
        value: []const u8,
        escape: Escape,
    ) @TypeOf(out_writer).Error!void {
        switch (escape) {
            .Unescaped => {
                try out_writer.writeAll(value);
            },

            .Escaped => {
                const html_quot: []const u8 = "&quot;";
                const quot = '"';

                const html_apos: []const u8 = "&#39;";
                const apos = '\'';

                const html_amp: []const u8 = "&amp;";
                const amp = '&';

                const html_lt: []const u8 = "&lt;";
                const lt = '<';

                const html_gt: []const u8 = "&gt;";
                const gt = '>';

                const html_null: []const u8 = "\u{fffd}";
                const @"null" = '\x00';

                if (std.mem.indexOfAny(u8, value, &[_]u8{ quot, apos, amp, lt, gt, @"null" })) |index| {
                    if (index > 0) {
                        try out_writer.writeAll(value[0..index]);
                    }

                    for (value[index..]) |char| {
                        try switch (char) {
                            @"null" => out_writer.writeAll(html_null),
                            quot => out_writer.writeAll(html_quot),
                            apos => out_writer.writeAll(html_apos),
                            amp => out_writer.writeAll(html_amp),
                            lt => out_writer.writeAll(html_lt),
                            gt => out_writer.writeAll(html_gt),
                            else => out_writer.writeByte(char),
                        };
                    }
                } else {
                    try out_writer.writeAll(value);
                }
            },
        }
    }

    inline fn iterateAt(data: anytype, index: usize) ?IteratorType(@TypeOf(data)) {
        switch (@typeInfo(@TypeOf(data))) {

            // Booleans are evaluated on the iterator
            .Bool => return if (data == true and index == 0) data else null,

            .Pointer => |info| switch (info.size) {
                .Slice => {

                    //Slice of u8 is always string
                    if (info.child != u8) {
                        return if (index < data.len) data[index] else null;
                    }
                },
                else => {},
            },

            .Optional => return if (data) |value| iterateAt(value, index) else null,

            else => {},
        }

        return if (index == 0) data else null;
    }

    fn IteratorType(comptime T: type) type {
        switch (@typeInfo(T)) {
            .Pointer => |info| switch (info.size) {
                .Slice => {

                    //Slice of u8 is always string
                    if (info.child != u8) {
                        return info.child;
                    }
                },
                else => {},
            },
            .Optional => |info| return IteratorType(info.child),
            else => {},
        }

        return T;
    }
};

test {
    _ = struct_tests;
}
const testing = std.testing;

const struct_tests = struct {

    // Test model

    const Item = struct {
        name: []const u8,
        value: f32,
    };

    const Person = struct {
        id: u32,
        name: []const u8,
        address: struct {
            street: []const u8,
            region: enum { EU, US, RoW },
            zip: u64,
            contacts: struct {
                phone: []const u8,
                email: []const u8,
            },
            coordinates: struct {
                lon: f64,
                lat: f64,
            },
        },
        items: []const Item,
        salary: f32,
        indication: ?*Person,
        active: bool,
        additional_information: ?[]const u8,
    };

    var person_1 = Person{
        .id = 1,
        .name = "John Doe",
        .address = .{
            .street = "far away street",
            .region = .EU,
            .zip = 99450,
            .contacts = .{
                .phone = "555-9090",
                .email = "jdoe@none.com",
            },
            .coordinates = .{
                .lon = 41.40338,
                .lat = 2.17403,
            },
        },
        .items = &[_]Item{
            .{ .name = "just one item", .value = 0.01 },
        },
        .salary = 75.00,
        .indication = null,
        .active = false,
        .additional_information = null,
    };

    var person_2 = Person{
        .id = 2,
        .name = "Someone Jr",
        .address = .{
            .street = "nearby",
            .region = .RoW,
            .zip = 333900,
            .contacts = .{
                .phone = "555-9191",
                .email = "smjr@herewego.com",
            },
            .coordinates = .{
                .lon = 38.71471,
                .lat = -9.13872,
            },
        },
        .items = &[_]Item{
            .{ .name = "item 1", .value = 100 },
            .{ .name = "item 2", .value = 200 },
        },
        .salary = 140.00,
        .indication = &person_1,
        .active = true,
        .additional_information = "someone was here",
    };

    fn write(out_writer: anytype, data: anytype, path: []const u8) anyerror!void {
        const allocator = testing.allocator;

        var ctx = try getContext(allocator, out_writer, data);
        defer ctx.deinit(allocator);

        _ = try ctx.write(path, .Unescaped);
    }

    test "Write Int" {
        const allocator = testing.allocator;
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        var writer = list.writer();

        // Direct access
        try write(writer, person_2, "id");
        try testing.expectEqualStrings("2", list.items);

        list.clearAndFree();

        // Ref access
        try write(writer, &person_2, "id");
        try testing.expectEqualStrings("2", list.items);

        list.clearAndFree();

        // Nested access
        try write(writer, person_2, "address.zip");
        try testing.expectEqualStrings("333900", list.items);

        list.clearAndFree();

        // Nested pointer access
        try write(writer, person_2, "indication.address.zip");
        try testing.expectEqualStrings("99450", list.items);

        list.clearAndFree();

        // Nested Ref access
        try write(writer, &person_2, "address.zip");
        try testing.expectEqualStrings("333900", list.items);

        list.clearAndFree();

        // Nested Ref pointer access
        try write(writer, &person_2, "indication.address.zip");
        try testing.expectEqualStrings("99450", list.items);
    }

    test "Write Float" {
        const allocator = testing.allocator;
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        var writer = list.writer();

        // Direct access
        try write(writer, person_2, "salary");
        try testing.expectEqualStrings("140", list.items);

        list.clearAndFree();

        // Ref access
        try write(writer, &person_2, "salary");
        try testing.expectEqualStrings("140", list.items);

        list.clearAndFree();

        // Nested access
        try write(writer, person_2, "address.coordinates.lon");
        try testing.expectEqualStrings("38.71471", list.items);

        list.clearAndFree();

        // Negative values
        try write(writer, person_2, "address.coordinates.lat");
        try testing.expectEqualStrings("-9.13872", list.items);

        list.clearAndFree();

        // Nested pointer access
        try write(writer, person_2, "indication.address.coordinates.lon");
        try testing.expectEqualStrings("41.40338", list.items);

        list.clearAndFree();

        // Nested Ref access
        try write(writer, &person_2, "address.coordinates.lon");
        try testing.expectEqualStrings("38.71471", list.items);

        list.clearAndFree();

        // Negative Ref values
        try write(writer, &person_2, "address.coordinates.lat");
        try testing.expectEqualStrings("-9.13872", list.items);

        list.clearAndFree();

        // Nested Ref pointer access
        try write(writer, &person_2, "indication.address.coordinates.lon");
        try testing.expectEqualStrings("41.40338", list.items);
    }

    test "Write String" {
        const allocator = testing.allocator;
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        var writer = list.writer();

        // Direct access
        try write(writer, person_2, "name");
        try testing.expectEqualStrings("Someone Jr", list.items);

        list.clearAndFree();

        // Ref access
        try write(writer, &person_2, "name");
        try testing.expectEqualStrings("Someone Jr", list.items);

        list.clearAndFree();

        // Direct Len access
        try write(writer, person_2, "name.len");
        try testing.expectEqualStrings("10", list.items);

        list.clearAndFree();

        // Direct Ref Len access
        try write(writer, &person_2, "name.len");
        try testing.expectEqualStrings("10", list.items);

        list.clearAndFree();

        // Nested access
        try write(writer, person_2, "address.street");
        try testing.expectEqualStrings("nearby", list.items);

        list.clearAndFree();

        // Nested pointer access
        try write(writer, person_2, "indication.address.street");
        try testing.expectEqualStrings("far away street", list.items);

        list.clearAndFree();

        // Nested Ref access
        try write(writer, &person_2, "address.street");
        try testing.expectEqualStrings("nearby", list.items);

        list.clearAndFree();

        // Nested pointer access
        try write(writer, &person_2, "indication.address.street");
        try testing.expectEqualStrings("far away street", list.items);
    }

    test "Write Enum" {
        const allocator = testing.allocator;
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        var writer = list.writer();

        // Direct access
        try write(writer, person_2, "address.region");
        try testing.expectEqualStrings("RoW", list.items);

        list.clearAndFree();

        // Ref access
        try write(writer, &person_2, "address.region");
        try testing.expectEqualStrings("RoW", list.items);

        list.clearAndFree();

        // Nested pointer access
        try write(writer, person_2, "indication.address.region");
        try testing.expectEqualStrings("EU", list.items);

        list.clearAndFree();

        // Nested Ref pointer access
        try write(writer, &person_2, "indication.address.region");
        try testing.expectEqualStrings("EU", list.items);
    }

    test "Write Bool" {
        const allocator = testing.allocator;
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        var writer = list.writer();

        // Direct access
        try write(writer, person_2, "active");
        try testing.expectEqualStrings("true", list.items);

        list.clearAndFree();

        // Ref access
        try write(writer, &person_2, "active");
        try testing.expectEqualStrings("true", list.items);

        list.clearAndFree();

        // Nested pointer access
        try write(writer, person_2, "indication.active");
        try testing.expectEqualStrings("false", list.items);

        list.clearAndFree();

        // Nested Ref pointer access
        try write(writer, &person_2, "indication.active");
        try testing.expectEqualStrings("false", list.items);
    }

    test "Write Nullable" {
        const allocator = testing.allocator;
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        var writer = list.writer();

        // Direct access
        try write(writer, person_2, "additional_information");
        try testing.expectEqualStrings("someone was here", list.items);

        list.clearAndFree();

        // Ref access
        try write(writer, &person_2, "additional_information");
        try testing.expectEqualStrings("someone was here", list.items);

        list.clearAndFree();

        // Null Accress
        try write(writer, person_1, "additional_information");
        try testing.expectEqualStrings("", list.items);

        list.clearAndFree();

        // Null Ref Accress
        try write(writer, &person_1, "additional_information");
        try testing.expectEqualStrings("", list.items);

        list.clearAndFree();

        // Nested pointer access
        try write(writer, person_2, "indication.additional_information");
        try testing.expectEqualStrings("", list.items);

        list.clearAndFree();

        // Nested Ref pointer access
        try write(writer, &person_2, "indication.additional_information");
        try testing.expectEqualStrings("", list.items);
    }

    test "Write Not found" {
        const allocator = testing.allocator;
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        var writer = list.writer();

        // Direct access
        try write(writer, person_1, "wrong_name");
        try testing.expectEqualStrings("", list.items);

        // Nested access
        try write(writer, person_1, "name.wrong_name");
        try testing.expectEqualStrings("", list.items);

        // Direct Ref access
        try write(writer, &person_1, "wrong_name");
        try testing.expectEqualStrings("", list.items);

        // Nested Ref access
        try write(writer, &person_1, "name.wrong_name");
        try testing.expectEqualStrings("", list.items);
    }

    test "Navigation" {
        const allocator = testing.allocator;
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        var writer = list.writer();

        // Person

        var person_ctx = try getContext(allocator, writer, person_2);
        defer person_ctx.deinit(allocator);

        list.clearAndFree();

        _ = try person_ctx.write("address.street", .Unescaped);
        try testing.expectEqualStrings("nearby", list.items);

        // Address

        var address_ctx = (try person_ctx.get(allocator, "address")) orelse {
            try testing.expect(false);
            return;
        };
        defer address_ctx.deinit(allocator);

        list.clearAndFree();
        _ = try address_ctx.write("street", .Unescaped);
        try testing.expectEqualStrings("nearby", list.items);

        // Street

        var street_ctx = (try address_ctx.get(allocator, "street")) orelse {
            try testing.expect(false);
            return;
        };
        defer street_ctx.deinit(allocator);

        list.clearAndFree();

        _ = try street_ctx.write("", .Unescaped);
        try testing.expectEqualStrings("nearby", list.items);

        list.clearAndFree();

        _ = try street_ctx.write(".", .Unescaped);
        try testing.expectEqualStrings("nearby", list.items);
    }

    test "Navigation Pointers" {
        const allocator = testing.allocator;
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        var writer = list.writer();

        // Person

        var person_ctx = try getContext(allocator, writer, &person_2);
        defer person_ctx.deinit(allocator);

        list.clearAndFree();

        _ = try person_ctx.write("indication.address.street", .Unescaped);
        try testing.expectEqualStrings("far away street", list.items);

        // Indication

        var indication_ctx = (try person_ctx.get(allocator, "indication")) orelse {
            try testing.expect(false);
            return;
        };
        defer indication_ctx.deinit(allocator);

        list.clearAndFree();
        _ = try indication_ctx.write("address.street", .Unescaped);
        try testing.expectEqualStrings("far away street", list.items);

        // Address

        var address_ctx = (try indication_ctx.get(allocator, "address")) orelse {
            try testing.expect(false);
            return;
        };
        defer address_ctx.deinit(allocator);

        list.clearAndFree();
        _ = try address_ctx.write("street", .Unescaped);
        try testing.expectEqualStrings("far away street", list.items);

        // Street

        var street_ctx = (try address_ctx.get(allocator, "street")) orelse {
            try testing.expect(false);
            return;
        };
        defer street_ctx.deinit(allocator);

        list.clearAndFree();

        _ = try street_ctx.write("", .Unescaped);
        try testing.expectEqualStrings("far away street", list.items);

        list.clearAndFree();

        _ = try street_ctx.write(".", .Unescaped);
        try testing.expectEqualStrings("far away street", list.items);
    }

    test "Navigation NotFound" {
        const allocator = testing.allocator;

        // Person
        var person_ctx = try getContext(allocator, std.io.null_writer, person_2);
        defer person_ctx.deinit(allocator);

        // Person.address
        var address_ctx = (try person_ctx.get(allocator, "address")) orelse {
            try testing.expect(false);
            return;
        };
        defer address_ctx.deinit(allocator);

        var wrong_address = try person_ctx.get(allocator, "wrong_address");
        try testing.expect(wrong_address == null);

        // Person.address.street
        var street_ctx = (try address_ctx.get(allocator, "street")) orelse {
            try testing.expect(false);
            return;
        };
        defer street_ctx.deinit(allocator);

        var wrong_street = try address_ctx.get(allocator, "wrong_street");
        try testing.expect(wrong_street == null);

        // Person.address.street.len
        var street_len_ctx = (try street_ctx.get(allocator, "len")) orelse {
            try testing.expect(false);
            return;
        };
        defer street_len_ctx.deinit(allocator);

        var wrong_len = try street_ctx.get(allocator, "wrong_len");
        try testing.expect(wrong_len == null);
    }

    test "Iterator over slice" {
        const allocator = testing.allocator;
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        var writer = list.writer();

        // Person
        var ctx = try getContext(allocator, writer, person_2);
        defer ctx.deinit(allocator);

        var iterator = ctx.iterator("items");

        var item_1 = (try iterator.next(allocator)) orelse {
            try testing.expect(false);
            return;
        };
        defer item_1.deinit(allocator);

        list.clearAndFree();

        _ = try item_1.write("name", .Unescaped);
        try testing.expectEqualStrings("item 1", list.items);

        var item_2 = (try iterator.next(allocator)) orelse {
            try testing.expect(false);
            return;
        };
        defer item_2.deinit(allocator);

        list.clearAndFree();

        _ = try item_2.write("name", .Unescaped);
        try testing.expectEqualStrings("item 2", list.items);

        var no_more = try iterator.next(allocator);
        try testing.expect(no_more == null);
    }

    test "Iterator over bool" {
        const allocator = testing.allocator;

        // Person
        var ctx = try getContext(allocator, std.io.null_writer, person_2);
        defer ctx.deinit(allocator);

        {
            // iterator over true
            var iterator = ctx.iterator("active");

            var item_1 = (try iterator.next(allocator)) orelse {
                try testing.expect(false);
                return;
            };
            defer item_1.deinit(allocator);

            var no_more = try iterator.next(allocator);
            try testing.expect(no_more == null);
        }

        {
            // iterator over false
            var iterator = ctx.iterator("indication.active");

            var no_more = try iterator.next(allocator);
            try testing.expect(no_more == null);
        }
    }

    test "Iterator over null" {
        const allocator = testing.allocator;

        // Person
        var ctx = try getContext(allocator, std.io.null_writer, person_2);
        defer ctx.deinit(allocator);

        {
            // iterator over true
            var iterator = ctx.iterator("additional_information");

            var item_1 = (try iterator.next(allocator)) orelse {
                try testing.expect(false);
                return;
            };
            defer item_1.deinit(allocator);

            var no_more = try iterator.next(allocator);
            try testing.expect(no_more == null);
        }

        {
            // iterator over false
            var iterator = ctx.iterator("indication.additional_information");

            var no_more = try iterator.next(allocator);
            try testing.expect(no_more == null);
        }
    }
};

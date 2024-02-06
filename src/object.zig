const std = @import("std");
const values = @import("value.zig");
const VM = @import("vm.zig");
const mem = @import("memory.zig");
const chunks = @import("chunk.zig");

const Value = values.Value;

const stdout = std.io.getStdOut().writer();
const allocator = @import("memory.zig").allocator;
// var vm = VM.vm;

pub const ObjType = enum {
    String,
    Function,
    Native,
    Closure,
    Upvalue,
    Class,
    Instance,
    BoundMethod,
    List,
};

pub const Obj = struct {
    type: ObjType,
    next: ?*Obj,
    is_marked: bool,
};

pub const ObjString = struct {
    obj: Obj,
    length: usize,
    chars: []u8,

    pub fn allocate(chars: []u8, length: usize) !*ObjString {
        var string = try mem.allocateObject(ObjString, ObjType.String);
        string.obj.type = ObjType.String;
        string.length = length;
        string.chars = chars;
        VM.push(Value.makeObj(@alignCast(@ptrCast(string))));
        try VM.vm.strings.put(chars, string);
        _ = VM.pop();
        return string;
    }

    pub fn copy(chars: [*]const u8, length: usize) !*ObjString {
        var heapChars = try allocator.alloc(u8, length + 1);
        heapChars[length] = 0;
        std.mem.copyForwards(u8, heapChars, chars[0..length]);
        const interned = VM.vm.strings.get(heapChars);

        if (interned) |string| {
            defer allocator.free(heapChars);
            return string;
        }
        return (try ObjString.allocate(heapChars, length));
    }

    pub fn take(chars: []u8, length: usize) !*ObjString {
        var heapChars = try allocator.alloc(u8, length + 1);
        heapChars[length] = 0;
        std.mem.copyForwards(u8, heapChars, chars[0..length]);
        const interned = VM.vm.strings.get(heapChars);
        if (interned) |string| {
            defer allocator.free(heapChars);
            return string;
        }
        return (try ObjString.allocate(chars, length));
    }
};

pub const ObjUpvalue = struct {
    obj: Obj,
    closed: Value,
    location: *Value,
    next: ?*ObjUpvalue,

    pub fn init(slot: *Value) !*ObjUpvalue {
        const upvalue = try mem.allocateObject(ObjUpvalue, ObjType.Upvalue);
        upvalue.closed = Value.makeNull();
        upvalue.location = slot;
        upvalue.next = null;
        return upvalue;
    }
};

pub const ObjFunction = struct {
    obj: Obj,
    arity: u32,
    upvalue_count: u8,
    chunk: chunks.Chunk,
    name: ?*ObjString,

    pub fn init() !*ObjFunction {
        var function: *ObjFunction = try mem.allocateObject(ObjFunction, ObjType.Function);
        function.arity = 0;
        function.name = null;
        function.upvalue_count = 0;
        chunks.initChunk(&function.chunk) catch {};
        return function;
    }

    fn print(self: ObjFunction) void {
        if (self.name) |name| {
            stdout.print("<fn {s}>", .{name.chars}) catch {};
        } else {
            stdout.print("<script>", .{}) catch {};
        }
    }

    fn toString(self: ObjFunction) ![]u8 {
        if (self.name) |name| {
            return try std.fmt.allocPrint(mem.allocator, "<fn {s}>", .{name.chars});
        } else {
            return try std.fmt.allocPrint(mem.allocator, "<script>", .{});
        }
    }
};

pub const ObjClosure = struct {
    obj: Obj,
    function: *ObjFunction,
    upvalues: [*]?*ObjUpvalue,
    upvalue_count: u8,

    pub fn init(function: *ObjFunction) !*ObjClosure {
        const vals = try mem.allocator.alloc(?*ObjUpvalue, function.upvalue_count);
        const upvalues = vals.ptr;
        var i: usize = 0;
        while (i < function.upvalue_count) : (i += 1) {
            upvalues[i] = null;
        }
        const closure: *ObjClosure = try mem.allocateObject(ObjClosure, ObjType.Closure);
        closure.function = function;
        closure.upvalues = upvalues;
        closure.upvalue_count = function.upvalue_count;
        return closure;
    }
};

pub const ObjNative = struct {
    obj: Obj,
    function: NativeFn,

    pub fn init(function: NativeFn) !*ObjNative {
        const native: *ObjNative = try mem.allocateObject(ObjNative, ObjType.Native);
        native.function = function;
        return native;
    }
};

pub const ObjClass = struct {
    obj: Obj,
    name: *ObjString,
    methods: std.AutoHashMap(*ObjString, Value),

    pub fn init(name: *ObjString) !*ObjClass {
        const class: *ObjClass = try mem.allocateObject(ObjClass, ObjType.Class);
        class.name = name;
        class.methods = std.AutoHashMap(*ObjString, Value).init(allocator);
        return class;
    }
};

pub const ObjInstance = struct {
    obj: Obj,
    class: *ObjClass,
    fields: std.AutoHashMap(*ObjString, Value),

    pub fn init(class: *ObjClass) !*ObjInstance {
        const instance = try mem.allocateObject(ObjInstance, ObjType.Instance);
        instance.class = class;
        instance.fields = std.AutoHashMap(*ObjString, Value).init(allocator);
        return instance;
    }
};

pub const ObjBoundMethod = struct {
    obj: Obj,
    reciever: Value,
    method: *ObjClosure,

    pub fn init(reciever: Value, method: *ObjClosure) !*ObjBoundMethod {
        const bound = try mem.allocateObject(ObjBoundMethod, ObjType.BoundMethod);
        bound.reciever = reciever;
        bound.method = method;
        return bound;
    }
};

pub const ObjList = struct {
    obj: Obj,
    items: *std.ArrayList(Value),

    pub fn init() !*ObjList {
        const list = try mem.allocateObject(ObjList, ObjType.List);
        list.items = try mem.allocator.create(std.ArrayList(Value));
        list.items.* = std.ArrayList(Value).init(allocator);
        return list;
    }

    pub fn append(self: ObjList, value: Value) void {
        if (self.items.capacity < self.items.items.len + 1) {
            const old_cap = self.items.capacity;
            const new_cap = mem.growCapacity(old_cap);
            mem.growArray(Value, self.items, old_cap, new_cap);
        }
        self.items.appendAssumeCapacity(value);
    }

    pub fn store(self: ObjList, index: usize, value: Value) void {
        self.items.items[index] = value;
    }

    pub fn getByIndex(self: ObjList, index: usize) Value {
        return self.items.items[index];
    }

    pub fn remove(self: ObjList, index: usize) void {
        self.items.orderedRemove(index);
    }

    pub fn isValidIndex(self: ObjList, index: usize) bool {
        if (index < 0 or index > self.items.items.len - 1) return false;
        return true;
    }
};

pub const NativeFn = *const fn (arg_count: u8, args: [*]Value) Value;

pub inline fn isObjType(value: Value, object_type: ObjType) bool {
    return value.isObj() and value.as.obj.type == object_type;
}

pub fn printObject(value: Value) void {
    switch (value.as.obj.type) {
        ObjType.String => {
            const string: *ObjString = @alignCast(@ptrCast(value.as.obj));
            stdout.print("{s}", .{string.chars}) catch {};
        },
        ObjType.Upvalue => {
            stdout.print("upvalue", .{}) catch {};
        },
        ObjType.Function => value.asFunction().print(),
        ObjType.Closure => {
            printFunction(value.asClosure().function);
        },
        ObjType.Native => stdout.print("<native fn>", .{}) catch {},
        ObjType.BoundMethod => value.asBoundMethod().method.function.print(),
        ObjType.Class => {
            stdout.print("{s}", .{value.asClass().name.chars}) catch {};
        },
        ObjType.Instance => {
            stdout.print("{s} instance", .{value.asInstance().class.name.chars}) catch {};
        },
        ObjType.List => {
            stdout.print("<List>", .{}) catch {};
        },
    }
}

pub fn objectToString(value: Value) ![]u8 {
    switch (value.as.obj.type) {
        ObjType.String => {
            const string: *ObjString = @alignCast(@ptrCast(value.as.obj));
            return try std.fmt.allocPrint(mem.allocator, "{s}", .{string.chars});
        },
        ObjType.Upvalue => {
            return try std.fmt.allocPrint(mem.allocator, "upvalue", .{});
        },
        ObjType.Function => return try value.asFunction().toString(),
        ObjType.Closure => {
            return try value.asClosure().function.toString();
        },
        ObjType.Native => return try std.fmt.allocPrint(mem.allocator, "<native fn>", .{}),
        ObjType.BoundMethod => return try value.asBoundMethod().method.function.toString(),
        ObjType.Class => {
            return try std.fmt.allocPrint(mem.allocator, "<Class {s}>", .{value.asClass().name.chars});
        },
        ObjType.Instance => {
            return try std.fmt.allocPrint(mem.allocator, "<{s} instance>", .{value.asInstance().class.name.chars});
        },
        ObjType.List => return try std.fmt.allocPrint(mem.allocator, "<List>", .{}),
    }
}

fn printFunction(function: *ObjFunction) void {
    if (function.name) |name| {
        stdout.print("<fn {s}>", .{name.chars}) catch {};
    } else {
        stdout.print("<script>", .{}) catch {};
    }
}

pub fn objectsEqual(a: Value, b: Value) bool {
    if (a.as.obj.type != b.as.obj.type) return false;
    switch (a.as.obj.type) {
        ObjType.String => {
            const obj_string_a: *ObjString = @alignCast(@ptrCast(a.as.obj));
            const obj_string_b: *ObjString = @alignCast(@ptrCast(b.as.obj));
            return std.mem.eql(u8, obj_string_a.chars, obj_string_b.chars);
        },
        else => return false,
    }
}

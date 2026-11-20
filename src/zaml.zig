//! zaml: a CPython extension module that parses YAML with yaml-zig.
//!
//! The parse runs without the GIL into an arena; the resulting value tree is
//! then converted into Python objects and the arena is freed.

const std = @import("std");
const py = @import("py");
const yaml = @import("yaml");

const gpa = std.heap.c_allocator;

/// Raised by a helper when a Python exception has already been set.
const PyError = error{PythonError};

/// `zaml.YAMLError`, a subclass of `ValueError`.
var yaml_error: ?*py.PyObject = null;

// Python exports None and the built-in exceptions as data. On Windows, data
// from a DLL must be read through its `__imp_` pointer, which translate-c does
// not emit, so referencing `_Py_NoneStruct` or `PyExc_*` directly reads garbage.
// Look these objects up through function calls at module load instead.
var none_obj: ?*py.PyObject = null;
var value_error: ?*py.PyObject = null;
var type_error: ?*py.PyObject = null;
var runtime_error: ?*py.PyObject = null;
var true_obj: ?*py.PyObject = null;
var false_obj: ?*py.PyObject = null;
var float_type: ?*py.PyObject = null;

// ---------------------------------------------------------------------------
// Python entry points

fn load(_: [*c]py.PyObject, args: [*c]py.PyObject, kwargs: [*c]py.PyObject) callconv(.c) [*c]py.PyObject {
    return loadDocuments(args, kwargs, .first) catch null;
}

fn loadAll(_: [*c]py.PyObject, args: [*c]py.PyObject, kwargs: [*c]py.PyObject) callconv(.c) [*c]py.PyObject {
    return loadDocuments(args, kwargs, .all) catch null;
}

const Mode = enum { first, all };

fn loadDocuments(args: *py.PyObject, kwargs: ?*py.PyObject, mode: Mode) PyError!*py.PyObject {
    var stream: ?*py.PyObject = null;
    var schema_name: [*c]const u8 = "core";
    var keywords = [_:null]?[*:0]const u8{ "", "schema" };
    if (py.PyArg_ParseTupleAndKeywords(args, kwargs, "O|$s", @ptrCast(&keywords), &stream, &schema_name) == 0) {
        return error.PythonError;
    }
    const schema = try parseSchema(std.mem.span(schema_name));

    const source = try Source.get(stream.?);
    defer source.release();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostics: std.ArrayList(yaml.Diagnostic) = .empty;

    // Parsing touches no Python objects, so let other threads run meanwhile.
    const thread_state = py.PyEval_SaveThread();
    const result = yaml.parseStream(arena, source.bytes, .{ .errors = &diagnostics, .schema = schema });
    py.PyEval_RestoreThread(thread_state);

    const docs = result catch |err| return raiseLoadError(err, diagnostics.items, source.bytes);

    var loader: Loader = .{};
    defer loader.deinit();
    switch (mode) {
        .first => {
            if (docs.len == 0) return none();
            return loader.convert(docs[0]);
        },
        .all => {
            const list = try check(py.PyList_New(@intCast(docs.len)));
            errdefer py.Py_DecRef(list);
            for (docs, 0..) |doc, i| {
                // PyList_SetItem steals the reference, even on failure.
                if (py.PyList_SetItem(list, @intCast(i), try loader.convert(doc)) < 0) return error.PythonError;
            }
            return list;
        },
    }
}

fn parseSchema(name: []const u8) PyError!yaml.Schema {
    inline for (.{ "core", "yaml11", "json", "failsafe" }) |option| {
        if (std.mem.eql(u8, name, option)) return @field(yaml.Schema, option);
    }
    py.PyErr_SetString(value_error, "schema must be 'core', 'yaml11', 'json' or 'failsafe'");
    return error.PythonError;
}

/// The UTF-8 input, borrowed from a `str`/`bytes` argument or from the
/// result of calling `.read()` on a file-like argument.
const Source = struct {
    bytes: []const u8,
    /// A new reference that keeps `bytes` alive, when we created one.
    owner: ?*py.PyObject = null,

    fn get(arg: *py.PyObject) PyError!Source {
        if (try borrowBytes(arg)) |bytes| return .{ .bytes = bytes };

        const read = py.PyObject_GetAttrString(arg, "read") orelse {
            py.PyErr_Clear();
            py.PyErr_SetString(type_error, "expected str, bytes or a file object with read()");
            return error.PythonError;
        };
        defer py.Py_DecRef(read);
        const data = try check(py.PyObject_CallNoArgs(read));
        errdefer py.Py_DecRef(data);
        const bytes = try borrowBytes(data) orelse {
            py.PyErr_SetString(type_error, "read() must return str or bytes");
            return error.PythonError;
        };
        return .{ .bytes = bytes, .owner = data };
    }

    fn release(self: Source) void {
        if (self.owner) |owner| py.Py_DecRef(owner);
    }

    fn borrowBytes(obj: *py.PyObject) PyError!?[]const u8 {
        var len: py.Py_ssize_t = 0;
        if (py.PyUnicode_Check(obj) != 0) {
            const ptr = py.PyUnicode_AsUTF8AndSize(obj, &len) orelse return error.PythonError;
            return ptr[0..@intCast(len)];
        }
        if (py.PyBytes_Check(obj) != 0) {
            var ptr: [*c]u8 = null;
            if (py.PyBytes_AsStringAndSize(obj, &ptr, &len) < 0) return error.PythonError;
            return ptr[0..@intCast(len)];
        }
        return null;
    }
};

fn raiseLoadError(err: yaml.Error, diagnostics: []const yaml.Diagnostic, source: []const u8) PyError {
    var buf: [1024]u8 = undefined;
    const msg: [:0]const u8 = switch (err) {
        error.OutOfMemory => {
            _ = py.PyErr_NoMemory();
            return error.PythonError;
        },
        error.NestingTooDeep => "document is nested too deeply",
        error.AliasBudgetExceeded => "aliases expand to too many nodes",
        error.YamlParseError => msg: {
            if (diagnostics.len == 0) break :msg "invalid YAML";
            const first = diagnostics[0];
            const at = first.span.lineCol(source);
            if (first.suggestion) |suggestion| {
                break :msg std.mem.printSentinel(&buf, "{s} (line {d}, column {d}); {s}", .{ first.message, at.line, at.col, suggestion }, 0) catch "invalid YAML";
            }
            break :msg std.mem.printSentinel(&buf, "{s} (line {d}, column {d})", .{ first.message, at.line, at.col }, 0) catch "invalid YAML";
        },
    };
    py.PyErr_SetString(yaml_error, msg.ptr);
    return error.PythonError;
}

// ---------------------------------------------------------------------------
// yaml.Value -> Python objects

/// Converts yaml.Values to Python objects.
///
/// Mapping keys repeat a lot in real documents (every record has an "id", a
/// "name"...). The loader creates one Python string per distinct short key and
/// reuses it, which also lets Python reuse the string's cached hash when the
/// key goes into a dict. The cache lives for one load call.
const Loader = struct {
    keys: std.StringHashMapUnmanaged(*py.PyObject) = .empty,
    hits: usize = 0,
    /// Set when the cache filled up without paying off (mostly unique keys).
    disabled: bool = false,

    const max_key_len = 64;
    const max_keys = 4096;

    fn deinit(self: *Loader) void {
        var it = self.keys.valueIterator();
        while (it.next()) |obj| py.Py_DecRef(obj.*);
        self.keys.deinit(gpa);
    }

    fn convert(self: *Loader, value: yaml.Value) PyError!*py.PyObject {
        return switch (value) {
            .null => none(),
            .bool => |b| check(py.PyBool_FromLong(@intFromBool(b))),
            .int => |i| newInt(i),
            .float => |f| check(py.PyFloat_FromDouble(f)),
            .string => |s| newString(s),
            .seq => |items| {
                const list = try check(py.PyList_New(@intCast(items.len)));
                errdefer py.Py_DecRef(list);
                for (items, 0..) |item, i| {
                    if (py.PyList_SetItem(list, @intCast(i), try self.convert(item)) < 0) return error.PythonError;
                }
                return list;
            },
            .map => |entries| {
                const dict = try check(py.PyDict_New());
                errdefer py.Py_DecRef(dict);
                for (entries) |entry| try self.setEntry(dict, entry);
                return dict;
            },
        };
    }

    /// A new reference to the Python object for a mapping key.
    fn key(self: *Loader, value: yaml.Value) PyError!*py.PyObject {
        const text = switch (value) {
            .string => |s| s,
            else => return self.convert(value),
        };
        if (self.disabled or text.len > max_key_len) return newString(text);

        if (self.keys.get(text)) |cached| {
            self.hits += 1;
            py.Py_IncRef(cached);
            return cached;
        }
        const obj = try newString(text);
        if (self.keys.count() < max_keys) {
            self.keys.put(gpa, text, obj) catch return obj; // caching is optional
            py.Py_IncRef(obj); // the cache's own reference
        } else if (self.hits < max_keys / 4) {
            // Full, and keys rarely repeat: stop paying for lookups.
            self.disabled = true;
        }
        return obj;
    }

    fn setEntry(self: *Loader, dict: *py.PyObject, entry: yaml.Entry) PyError!void {
        switch (entry.key) {
            .seq, .map => {
                py.PyErr_SetString(yaml_error, "mapping keys that are lists or mappings are not supported");
                return error.PythonError;
            },
            else => {},
        }
        const k = try self.key(entry.key);
        defer py.Py_DecRef(k);
        const val = try self.convert(entry.value);
        defer py.Py_DecRef(val);

        const size_before = py.PyDict_Size(dict);
        if (py.PyDict_SetItem(dict, k, val) < 0) return error.PythonError;
        if (py.PyDict_Size(dict) == size_before) {
            // Distinct YAML keys can still be equal in Python (e.g. 1 and true).
            const repr = try check(py.PyObject_Repr(k));
            defer py.Py_DecRef(repr);
            const text = py.PyUnicode_AsUTF8AndSize(repr, null) orelse return error.PythonError;
            var buf: [256]u8 = undefined;
            const msg = std.mem.printSentinel(&buf, "duplicate mapping key: {s}", .{std.mem.span(text)}, 0) catch "duplicate mapping key";
            py.PyErr_SetString(yaml_error, msg.ptr);
            return error.PythonError;
        }
    }
};

fn newInt(value: i128) PyError!*py.PyObject {
    if (std.math.cast(i64, value)) |small| return check(py.PyLong_FromLongLong(small));
    var buf: [48]u8 = undefined;
    const digits = std.mem.printSentinel(&buf, "{d}", .{value}, 0) catch unreachable;
    return check(py.PyLong_FromString(digits.ptr, null, 10));
}

// ---------------------------------------------------------------------------
// Dumping: Python objects -> yaml.Value -> YAML text

fn dump(_: [*c]py.PyObject, args: [*c]py.PyObject, kwargs: [*c]py.PyObject) callconv(.c) [*c]py.PyObject {
    return dumpDocuments(args, kwargs, .first) catch null;
}

fn dumpAll(_: [*c]py.PyObject, args: [*c]py.PyObject, kwargs: [*c]py.PyObject) callconv(.c) [*c]py.PyObject {
    return dumpDocuments(args, kwargs, .all) catch null;
}

fn dumpDocuments(args: *py.PyObject, kwargs: ?*py.PyObject, mode: Mode) PyError!*py.PyObject {
    var data: ?*py.PyObject = null;
    var stream: ?*py.PyObject = null;
    var indent: py.Py_ssize_t = 2;
    var sort_keys: c_int = 0;
    var default: ?*py.PyObject = null;
    var keywords = [_:null]?[*:0]const u8{ "", "stream", "indent", "sort_keys", "default" };
    if (py.PyArg_ParseTupleAndKeywords(args, kwargs, "O|O$npO", @ptrCast(&keywords), &data, &stream, &indent, &sort_keys, &default) == 0) {
        return error.PythonError;
    }
    if (default == none_obj) default = null;
    if (default) |d| if (py.PyCallable_Check(d) == 0) {
        py.PyErr_SetString(type_error, "default must be callable");
        return error.PythonError;
    };
    if (indent < 1 or indent > 16) {
        py.PyErr_SetString(value_error, "indent must be between 1 and 16");
        return error.PythonError;
    }
    if (stream == none_obj) stream = null;

    // The GIL stays held until the text is emitted (see Dumper).
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const dumper: Dumper = .{ .arena = arena_state.allocator(), .default = default };

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const options: yaml.EmitOptions = .{ .indent = @intCast(indent), .sort_keys = sort_keys != 0 };

    const result = switch (mode) {
        .first => yaml.emit(&out.writer, try dumper.value(data.?, 0), options),
        .all => yaml.emitStream(&out.writer, try dumper.values(data.?), options),
    };
    result catch |err| return raiseDumpError(err);

    const text = try newString(out.written());
    if (stream) |s| {
        defer py.Py_DecRef(text);
        try writeTo(s, text);
        return none();
    }
    return text;
}

/// Matches the emitter's own limit; also stops data that contains itself.
const max_dump_depth = 128;

/// Converts Python objects to yaml.Values for the emitter.
///
/// Without `default`, no Python code runs during conversion, so the value tree
/// can borrow string data from the Python objects (the GIL stays held until
/// the text is emitted). `default` is arbitrary Python code that could change
/// or free the objects being converted, so with it, strings are copied into
/// the arena and every container being walked is kept alive.
const Dumper = struct {
    arena: std.mem.Allocator,
    default: ?*py.PyObject,

    fn values(self: Dumper, documents: *py.PyObject) PyError![]yaml.Value {
        const iter = py.PyObject_GetIter(documents) orelse return error.PythonError;
        defer py.Py_DecRef(iter);
        var list: std.ArrayList(yaml.Value) = .empty;
        while (py.PyIter_Next(iter)) |doc| {
            defer py.Py_DecRef(doc);
            list.append(self.arena, try self.value(doc, 0)) catch return noMemory();
        }
        if (py.PyErr_Occurred() != null) return error.PythonError;
        return list.items;
    }

    fn value(self: Dumper, obj: *py.PyObject, depth: usize) PyError!yaml.Value {
        if (depth > max_dump_depth) {
            py.PyErr_SetString(value_error, "data is nested more than 128 levels deep, or contains itself");
            return error.PythonError;
        }
        if (obj == none_obj) return .null;
        if (obj == true_obj) return .{ .bool = true };
        if (obj == false_obj) return .{ .bool = false };
        if (py.PyUnicode_Check(obj) != 0) return .{ .string = try self.string(obj) };
        if (py.PyLong_Check(obj) != 0) return .{ .int = try toInt(obj) };
        if (py.PyObject_IsInstance(obj, float_type) == 1) return .{ .float = py.PyFloat_AsDouble(obj) };
        if (py.PyDict_Check(obj) != 0) return self.map(obj, depth);
        if (py.PyList_Check(obj) != 0 or py.PyTuple_Check(obj) != 0) return self.seq(obj, depth);

        const default = self.default orelse return typeError("cannot dump objects of type", obj);
        const call_args = try check(py.PyTuple_Pack(1, obj));
        defer py.Py_DecRef(call_args);
        const replacement = try check(py.PyObject_CallObject(default, call_args));
        defer py.Py_DecRef(replacement);
        // A default that returns another unsupported object is called again
        // on it; the depth limit stops one that never settles.
        return self.value(replacement, depth + 1);
    }

    fn map(self: Dumper, obj: *py.PyObject, depth: usize) PyError!yaml.Value {
        self.hold(obj);
        defer self.release(obj);
        const entries = self.arena.alloc(yaml.Entry, @intCast(py.PyDict_Size(obj))) catch return noMemory();
        var pos: py.Py_ssize_t = 0;
        var key: [*c]py.PyObject = null;
        var val: [*c]py.PyObject = null;
        var i: usize = 0;
        while (py.PyDict_Next(obj, &pos, &key, &val) != 0) : (i += 1) {
            if (i == entries.len) return changedDuringDump();
            self.hold(key);
            defer self.release(key);
            self.hold(val);
            defer self.release(val);
            const k = try self.value(key, depth + 1);
            switch (k) {
                .seq, .map => return typeError("mapping keys must be str, int, float, bool or None, not", key),
                else => {},
            }
            entries[i] = .{ .key = k, .value = try self.value(val, depth + 1) };
        }
        if (i != entries.len) return changedDuringDump();
        return .{ .map = entries };
    }

    fn seq(self: Dumper, obj: *py.PyObject, depth: usize) PyError!yaml.Value {
        self.hold(obj);
        defer self.release(obj);
        const is_list = py.PyList_Check(obj) != 0;
        const len: usize = @intCast(if (is_list) py.PyList_Size(obj) else py.PyTuple_Size(obj));
        const items = self.arena.alloc(yaml.Value, len) catch return noMemory();
        for (items, 0..) |*item, i| {
            // A list that shrinks under `default` makes GetItem raise IndexError.
            const elem = (if (is_list) py.PyList_GetItem(obj, @intCast(i)) else py.PyTuple_GetItem(obj, @intCast(i))) orelse return error.PythonError;
            self.hold(elem);
            defer self.release(elem);
            item.* = try self.value(elem, depth + 1);
        }
        return .{ .seq = items };
    }

    fn string(self: Dumper, obj: *py.PyObject) PyError![]const u8 {
        const text = try utf8(obj);
        if (self.default == null) return text;
        return self.arena.dupe(u8, text) catch noMemory();
    }

    /// Keeps a borrowed object alive while `default` may run.
    fn hold(self: Dumper, obj: *py.PyObject) void {
        if (self.default != null) py.Py_IncRef(obj);
    }

    fn release(self: Dumper, obj: *py.PyObject) void {
        if (self.default != null) py.Py_DecRef(obj);
    }
};

fn changedDuringDump() PyError {
    py.PyErr_SetString(runtime_error, "dictionary changed size during dump");
    return error.PythonError;
}

fn utf8(obj: *py.PyObject) PyError![]const u8 {
    var len: py.Py_ssize_t = 0;
    const ptr = py.PyUnicode_AsUTF8AndSize(obj, &len) orelse return error.PythonError;
    return ptr[0..@intCast(len)];
}

fn toInt(obj: *py.PyObject) PyError!i128 {
    var overflow: c_int = 0;
    const small = py.PyLong_AsLongLongAndOverflow(obj, &overflow);
    if (overflow == 0) {
        if (small == -1 and py.PyErr_Occurred() != null) return error.PythonError;
        return small;
    }
    // Wider than 64 bits: go through the decimal digits.
    const digits = try check(py.PyNumber_ToBase(obj, 10));
    defer py.Py_DecRef(digits);
    return std.fmt.parseInt(i128, try utf8(digits), 10) catch {
        py.PyErr_SetString(value_error, "integers wider than 128 bits cannot be dumped");
        return error.PythonError;
    };
}

fn writeTo(stream: *py.PyObject, text: *py.PyObject) PyError!void {
    const write = py.PyObject_GetAttrString(stream, "write") orelse return error.PythonError;
    defer py.Py_DecRef(write);
    const call_args = try check(py.PyTuple_Pack(1, text));
    defer py.Py_DecRef(call_args);
    const result = try check(py.PyObject_CallObject(write, call_args));
    py.Py_DecRef(result);
}

fn raiseDumpError(err: yaml.EmitError) PyError {
    switch (err) {
        error.OutOfMemory, error.WriteFailed => return noMemory(),
        error.NestingTooDeep => py.PyErr_SetString(value_error, "data is nested more than 128 levels deep"),
        error.InvalidUtf8 => py.PyErr_SetString(value_error, "string is not valid UTF-8"),
        error.UnrepresentableInt => py.PyErr_SetString(value_error, "integers wider than 128 bits cannot be dumped"),
        error.UnrepresentableScalar => py.PyErr_SetString(value_error, "value cannot be represented in YAML"),
    }
    return error.PythonError;
}

fn typeError(comptime prefix: [:0]const u8, obj: *py.PyObject) PyError {
    const type_obj = py.PyObject_Type(obj) orelse return error.PythonError;
    defer py.Py_DecRef(type_obj);
    const name = py.PyObject_GetAttrString(type_obj, "__name__") orelse return error.PythonError;
    defer py.Py_DecRef(name);
    const text = utf8(name) catch return error.PythonError;
    var buf: [256]u8 = undefined;
    const msg = std.mem.printSentinel(&buf, prefix ++ " {s}", .{text}, 0) catch prefix;
    py.PyErr_SetString(type_error, msg.ptr);
    return error.PythonError;
}

fn noMemory() PyError {
    _ = py.PyErr_NoMemory();
    return error.PythonError;
}

// ---------------------------------------------------------------------------
// Small Python helpers

fn check(obj: ?*py.PyObject) PyError!*py.PyObject {
    return obj orelse error.PythonError;
}

fn none() *py.PyObject {
    py.Py_IncRef(none_obj);
    return none_obj.?;
}

fn newString(s: []const u8) PyError!*py.PyObject {
    return check(py.PyUnicode_FromStringAndSize(s.ptr, @intCast(s.len)));
}

// ---------------------------------------------------------------------------
// Module definition (multi-phase initialisation, PEP 489)

/// A new reference to a built-in object, e.g. `ValueError`.
fn builtin(name: [*:0]const u8) ?*py.PyObject {
    const builtins = py.PyImport_ImportModule("builtins") orelse return null;
    defer py.Py_DecRef(builtins);
    return py.PyObject_GetAttrString(builtins, name);
}

fn moduleExec(module: [*c]py.PyObject) callconv(.c) c_int {
    // These references are kept for the life of the process.
    if (none_obj == null) none_obj = py.Py_BuildValue("") orelse return -1;
    if (value_error == null) value_error = builtin("ValueError") orelse return -1;
    if (type_error == null) type_error = builtin("TypeError") orelse return -1;
    if (runtime_error == null) runtime_error = builtin("RuntimeError") orelse return -1;
    if (true_obj == null) true_obj = py.PyBool_FromLong(1) orelse return -1;
    if (false_obj == null) false_obj = py.PyBool_FromLong(0) orelse return -1;
    if (float_type == null) float_type = builtin("float") orelse return -1;
    if (yaml_error == null) {
        yaml_error = py.PyErr_NewException("zaml.YAMLError", value_error, null);
        if (yaml_error == null) return -1;
    }
    py.Py_IncRef(yaml_error);
    if (py.PyModule_AddObject(module, "YAMLError", yaml_error) < 0) {
        py.Py_DecRef(yaml_error);
        return -1;
    }
    return 0;
}

var methods = [_]py.PyMethodDef{
    .{
        .ml_name = "load",
        .ml_meth = @ptrCast(&load),
        .ml_flags = py.METH_VARARGS | py.METH_KEYWORDS,
        .ml_doc = "load(stream, /, *, schema='core')\n--\n\n" ++
            "Parse the first YAML document in a str, bytes or file object.",
    },
    .{
        .ml_name = "load_all",
        .ml_meth = @ptrCast(&loadAll),
        .ml_flags = py.METH_VARARGS | py.METH_KEYWORDS,
        .ml_doc = "load_all(stream, /, *, schema='core')\n--\n\n" ++
            "Parse every YAML document in a str, bytes or file object into a list.",
    },
    .{
        .ml_name = "dump",
        .ml_meth = @ptrCast(&dump),
        .ml_flags = py.METH_VARARGS | py.METH_KEYWORDS,
        .ml_doc = "dump(data, /, stream=None, *, indent=2, sort_keys=False, default=None)\n--\n\n" ++
            "Serialize data as a YAML document. Return it as a str, or write it to stream.\n" ++
            "default(obj) is called for objects of unsupported types and returns a replacement.",
    },
    .{
        .ml_name = "dump_all",
        .ml_meth = @ptrCast(&dumpAll),
        .ml_flags = py.METH_VARARGS | py.METH_KEYWORDS,
        .ml_doc = "dump_all(documents, /, stream=None, *, indent=2, sort_keys=False, default=None)\n--\n\n" ++
            "Serialize an iterable of documents as a YAML stream separated by ---.",
    },
    std.mem.zeroes(py.PyMethodDef),
};

var slots = [_]py.PyModuleDef_Slot{
    .{ .slot = py.Py_mod_exec, .value = @ptrCast(@constCast(&moduleExec)) },
    std.mem.zeroes(py.PyModuleDef_Slot),
};

var module_def: py.PyModuleDef = .{
    .m_base = std.mem.zeroes(py.PyModuleDef_Base),
    .m_name = "zaml",
    .m_doc = "Fast YAML 1.2 parsing and dumping for Python, written in Zig.",
    .m_size = 0,
    .m_methods = &methods,
    .m_slots = &slots,
    .m_traverse = null,
    .m_clear = null,
    .m_free = null,
};

pub export fn PyInit_zaml() callconv(.c) ?*py.PyObject {
    // Equivalent of PyModuleDef_HEAD_INIT: the definition starts with one reference.
    const def_obj: *py.PyObject = @ptrCast(&module_def);
    if (module_def.m_base.m_index == 0) py.Py_IncRef(def_obj);
    return py.PyModuleDef_Init(&module_def);
}

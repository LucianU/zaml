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

    switch (mode) {
        .first => {
            if (docs.len == 0) return none();
            return convert(docs[0]);
        },
        .all => {
            const list = try check(py.PyList_New(@intCast(docs.len)));
            errdefer py.Py_DecRef(list);
            for (docs, 0..) |doc, i| {
                // PyList_SetItem steals the reference, even on failure.
                if (py.PyList_SetItem(list, @intCast(i), try convert(doc)) < 0) return error.PythonError;
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

fn convert(value: yaml.Value) PyError!*py.PyObject {
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
                if (py.PyList_SetItem(list, @intCast(i), try convert(item)) < 0) return error.PythonError;
            }
            return list;
        },
        .map => |entries| {
            const dict = try check(py.PyDict_New());
            errdefer py.Py_DecRef(dict);
            for (entries) |entry| try setEntry(dict, entry);
            return dict;
        },
    };
}

fn setEntry(dict: *py.PyObject, entry: yaml.Entry) PyError!void {
    switch (entry.key) {
        .seq, .map => {
            py.PyErr_SetString(yaml_error, "mapping keys that are lists or mappings are not supported");
            return error.PythonError;
        },
        else => {},
    }
    const key = try convert(entry.key);
    defer py.Py_DecRef(key);
    const val = try convert(entry.value);
    defer py.Py_DecRef(val);

    const size_before = py.PyDict_Size(dict);
    if (py.PyDict_SetItem(dict, key, val) < 0) return error.PythonError;
    if (py.PyDict_Size(dict) == size_before) {
        // Distinct YAML keys can still be equal in Python (e.g. 1 and true).
        const repr = try check(py.PyObject_Repr(key));
        defer py.Py_DecRef(repr);
        const text = py.PyUnicode_AsUTF8AndSize(repr, null) orelse return error.PythonError;
        var buf: [256]u8 = undefined;
        const msg = std.mem.printSentinel(&buf, "duplicate mapping key: {s}", .{std.mem.span(text)}, 0) catch "duplicate mapping key";
        py.PyErr_SetString(yaml_error, msg.ptr);
        return error.PythonError;
    }
}

fn newInt(value: i128) PyError!*py.PyObject {
    if (std.math.cast(i64, value)) |small| return check(py.PyLong_FromLongLong(small));
    var buf: [48]u8 = undefined;
    const digits = std.mem.printSentinel(&buf, "{d}", .{value}, 0) catch unreachable;
    return check(py.PyLong_FromString(digits.ptr, null, 10));
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
    std.mem.zeroes(py.PyMethodDef),
};

var slots = [_]py.PyModuleDef_Slot{
    .{ .slot = py.Py_mod_exec, .value = @ptrCast(@constCast(&moduleExec)) },
    std.mem.zeroes(py.PyModuleDef_Slot),
};

var module_def: py.PyModuleDef = .{
    .m_base = std.mem.zeroes(py.PyModuleDef_Base),
    .m_name = "zaml",
    .m_doc = "Fast YAML 1.2 parsing for Python, written in Zig.",
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

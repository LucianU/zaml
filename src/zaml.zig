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

/// Per-module state. Every interpreter that imports zaml gets its own module
/// object with its own copy, so no Python object is shared between
/// interpreters (PEP 630, PEP 684); zaml keeps no Python objects in globals.
///
/// It also holds the built-in objects zaml needs. Python exports None and the
/// built-in exceptions as data, and on Windows data from a DLL must be read
/// through its `__imp_` pointer, which translate-c does not emit; so instead
/// of referencing `_Py_NoneStruct` or `PyExc_*`, zaml looks them up at import.
const State = extern struct {
    /// `zaml.YAMLError`, a subclass of `ValueError`.
    yaml_error: ?*py.PyObject,
    none_obj: ?*py.PyObject,
    true_obj: ?*py.PyObject,
    false_obj: ?*py.PyObject,
    value_error: ?*py.PyObject,
    type_error: ?*py.PyObject,
    runtime_error: ?*py.PyObject,
    float_type: ?*py.PyObject,

    const fields = @typeInfo(State).@"struct".field_names;

    /// The state of a fully initialized module. Fails with RuntimeError when
    /// the module was created but not executed (importlib's module_from_spec
    /// without exec_module) or has already been cleared: its methods exist,
    /// but the objects they need do not.
    fn of(module: *py.PyObject) PyError!*const State {
        if (py.PyModule_GetState(module)) |raw| {
            const st: *const State = @ptrCast(@alignCast(raw));
            if (st.yaml_error != null) return st; // moduleExec sets it last
        }
        if (builtin("RuntimeError")) |runtime_error| {
            defer py.Py_DecRef(runtime_error);
            py.PyErr_SetString(runtime_error, "zaml._zaml is not initialized");
        }
        return error.PythonError;
    }

    /// A new reference to None.
    fn none(st: *const State) *py.PyObject {
        py.Py_IncRef(st.none_obj);
        return st.none_obj.?;
    }
};

// ---------------------------------------------------------------------------
// Python entry points

fn load(module: [*c]py.PyObject, args: [*c]py.PyObject, kwargs: [*c]py.PyObject) callconv(.c) [*c]py.PyObject {
    const st = State.of(module) catch return null;
    return loadDocuments(st, args, kwargs, .first) catch null;
}

fn loadAll(module: [*c]py.PyObject, args: [*c]py.PyObject, kwargs: [*c]py.PyObject) callconv(.c) [*c]py.PyObject {
    const st = State.of(module) catch return null;
    return loadDocuments(st, args, kwargs, .all) catch null;
}

const Mode = enum { first, all };

fn loadDocuments(st: *const State, args: *py.PyObject, kwargs: ?*py.PyObject, mode: Mode) PyError!*py.PyObject {
    var stream: ?*py.PyObject = null;
    var schema_name: [*c]const u8 = "core";
    var keywords = [_:null]?[*:0]const u8{ "", "schema" };
    if (py.PyArg_ParseTupleAndKeywords(args, kwargs, "O|$s", @ptrCast(&keywords), &stream, &schema_name) == 0) {
        return error.PythonError;
    }
    const schema = try parseSchema(st, std.mem.span(schema_name));

    const source = try Source.get(st, stream.?);
    defer source.release();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostics: std.ArrayList(yaml.Diagnostic) = .empty;

    // Parsing touches no Python objects, so let other threads run meanwhile.
    const thread_state = py.PyEval_SaveThread();
    const result = yaml.parseStream(arena, source.bytes, .{ .errors = &diagnostics, .schema = schema });
    py.PyEval_RestoreThread(thread_state);

    const docs = result catch |err| return raiseLoadError(st, err, diagnostics.items, source.bytes);

    var loader: Loader = .{ .st = st };
    defer loader.deinit();
    switch (mode) {
        .first => {
            if (docs.len == 0) return st.none();
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

fn parseSchema(st: *const State, name: []const u8) PyError!yaml.Schema {
    inline for (.{ "core", "yaml11", "json", "failsafe" }) |option| {
        if (std.mem.eql(u8, name, option)) return @field(yaml.Schema, option);
    }
    py.PyErr_SetString(st.value_error, "schema must be 'core', 'yaml11', 'json' or 'failsafe'");
    return error.PythonError;
}

/// The UTF-8 input, borrowed from a `str`/`bytes` argument or from the
/// result of calling `.read()` on a file-like argument.
const Source = struct {
    bytes: []const u8,
    /// A new reference that keeps `bytes` alive, when we created one.
    owner: ?*py.PyObject = null,

    fn get(st: *const State, arg: *py.PyObject) PyError!Source {
        if (try borrowBytes(arg)) |bytes| return .{ .bytes = bytes };

        const read = py.PyObject_GetAttrString(arg, "read") orelse {
            py.PyErr_Clear();
            py.PyErr_SetString(st.type_error, "expected str, bytes or a file object with read()");
            return error.PythonError;
        };
        defer py.Py_DecRef(read);
        const data = try check(py.PyObject_CallNoArgs(read));
        errdefer py.Py_DecRef(data);
        const bytes = try borrowBytes(data) orelse {
            py.PyErr_SetString(st.type_error, "read() must return str or bytes");
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

fn raiseLoadError(st: *const State, err: yaml.Error, diagnostics: []const yaml.Diagnostic, source: []const u8) PyError {
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
    py.PyErr_SetString(st.yaml_error, msg.ptr);
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
    st: *const State,
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
            .null => self.st.none(),
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
                py.PyErr_SetString(self.st.yaml_error, "mapping keys that are lists or mappings are not supported");
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
            py.PyErr_SetString(self.st.yaml_error, msg.ptr);
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

fn dump(module: [*c]py.PyObject, args: [*c]py.PyObject, kwargs: [*c]py.PyObject) callconv(.c) [*c]py.PyObject {
    const st = State.of(module) catch return null;
    return dumpDocuments(st, args, kwargs, .first) catch null;
}

fn dumpAll(module: [*c]py.PyObject, args: [*c]py.PyObject, kwargs: [*c]py.PyObject) callconv(.c) [*c]py.PyObject {
    const st = State.of(module) catch return null;
    return dumpDocuments(st, args, kwargs, .all) catch null;
}

fn dumpDocuments(st: *const State, args: *py.PyObject, kwargs: ?*py.PyObject, mode: Mode) PyError!*py.PyObject {
    var data: ?*py.PyObject = null;
    var stream: ?*py.PyObject = null;
    var indent: py.Py_ssize_t = 2;
    var sort_keys: c_int = 0;
    var default: ?*py.PyObject = null;
    var keywords = [_:null]?[*:0]const u8{ "", "stream", "indent", "sort_keys", "default" };
    if (py.PyArg_ParseTupleAndKeywords(args, kwargs, "O|O$npO", @ptrCast(&keywords), &data, &stream, &indent, &sort_keys, &default) == 0) {
        return error.PythonError;
    }
    if (default == st.none_obj) default = null;
    if (default) |d| if (py.PyCallable_Check(d) == 0) {
        py.PyErr_SetString(st.type_error, "default must be callable");
        return error.PythonError;
    };
    if (indent < 1 or indent > 16) {
        py.PyErr_SetString(st.value_error, "indent must be between 1 and 16");
        return error.PythonError;
    }
    if (stream == st.none_obj) stream = null;

    // The GIL stays held until the text is emitted (see Dumper).
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const dumper: Dumper = .{
        .st = st,
        .arena = arena_state.allocator(),
        .default = default,
        // dump_all runs the caller's iterator between documents, which may
        // change or free a document already converted (a generator often
        // reuses one dict), so its strings are copied, like with default.
        .copy_strings = default != null or mode == .all,
    };

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const options: yaml.EmitOptions = .{ .indent = @intCast(indent), .sort_keys = sort_keys != 0 };

    const result = switch (mode) {
        .first => yaml.emit(&out.writer, try dumper.value(data.?, 0), options),
        .all => yaml.emitStream(&out.writer, try dumper.values(data.?), options),
    };
    result catch |err| return raiseDumpError(st, err);

    const text = try newString(out.written());
    if (stream) |s| {
        defer py.Py_DecRef(text);
        try writeTo(s, text);
        return st.none();
    }
    return text;
}

/// Matches the emitter's own limit; also stops data that contains itself.
const max_dump_depth = 128;

/// Converts Python objects to yaml.Values for the emitter.
///
/// Without `default`, no Python code runs while a document is converted, so
/// for dump() the value tree can borrow string data from the Python objects
/// (the GIL stays held until the text is emitted). `default` is arbitrary
/// Python code that could change or free the objects being converted, so with
/// it every container being walked is kept alive, and strings are copied into
/// the arena; dump_all() copies strings too (see dumpDocuments).
const Dumper = struct {
    st: *const State,
    arena: std.mem.Allocator,
    default: ?*py.PyObject,
    copy_strings: bool,

    /// Converts each document as the iterable yields it, like PyYAML: a
    /// document changed after being yielded is written as it was then.
    fn values(self: Dumper, documents: *py.PyObject) PyError![]yaml.Value {
        std.debug.assert(self.copy_strings); // the iterator runs between documents
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
            py.PyErr_SetString(self.st.value_error, "data is nested more than 128 levels deep, or contains itself");
            return error.PythonError;
        }
        if (obj == self.st.none_obj) return .null;
        if (obj == self.st.true_obj) return .{ .bool = true };
        if (obj == self.st.false_obj) return .{ .bool = false };
        if (py.PyUnicode_Check(obj) != 0) return .{ .string = try self.string(obj) };
        if (py.PyLong_Check(obj) != 0) return .{ .int = try toInt(self.st, obj) };
        if (py.PyDict_Check(obj) != 0) return self.map(obj, depth);
        if (py.PyList_Check(obj) != 0 or py.PyTuple_Check(obj) != 0) return self.seq(obj, depth);
        if (isFloat(self.st, obj)) return .{ .float = py.PyFloat_AsDouble(obj) };

        const default = self.default orelse return typeError(self.st, "cannot dump objects of type", obj);
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
            if (i == entries.len) return changedDuringDump(self.st);
            self.hold(key);
            defer self.release(key);
            self.hold(val);
            defer self.release(val);
            const k = try self.value(key, depth + 1);
            switch (k) {
                .seq, .map => return typeError(self.st, "mapping keys must be str, int, float, bool or None, not", key),
                else => {},
            }
            entries[i] = .{ .key = k, .value = try self.value(val, depth + 1) };
        }
        if (i != entries.len) return changedDuringDump(self.st);
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
        if (!self.copy_strings) return text;
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

fn changedDuringDump(st: *const State) PyError {
    py.PyErr_SetString(st.runtime_error, "dictionary changed size during dump");
    return error.PythonError;
}

/// Whether obj's real type is float or a subclass. Unlike isinstance(), this
/// never consults obj.__class__, which can run Python code and fail.
fn isFloat(st: *const State, obj: *py.PyObject) bool {
    const obj_type = py.PyObject_Type(obj) orelse return false; // cannot fail for a live object
    defer py.Py_DecRef(obj_type);
    return py.PyType_IsSubtype(@ptrCast(obj_type), @ptrCast(st.float_type)) != 0;
}

fn utf8(obj: *py.PyObject) PyError![]const u8 {
    var len: py.Py_ssize_t = 0;
    const ptr = py.PyUnicode_AsUTF8AndSize(obj, &len) orelse return error.PythonError;
    return ptr[0..@intCast(len)];
}

fn toInt(st: *const State, obj: *py.PyObject) PyError!i128 {
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
        py.PyErr_SetString(st.value_error, "integers wider than 128 bits cannot be dumped");
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

fn raiseDumpError(st: *const State, err: yaml.EmitError) PyError {
    switch (err) {
        error.OutOfMemory, error.WriteFailed => return noMemory(),
        error.NestingTooDeep => py.PyErr_SetString(st.value_error, "data is nested more than 128 levels deep"),
        error.InvalidUtf8 => py.PyErr_SetString(st.value_error, "string is not valid UTF-8"),
        error.UnrepresentableInt => py.PyErr_SetString(st.value_error, "integers wider than 128 bits cannot be dumped"),
        error.UnrepresentableScalar => py.PyErr_SetString(st.value_error, "value cannot be represented in YAML"),
    }
    return error.PythonError;
}

fn typeError(st: *const State, comptime prefix: [:0]const u8, obj: *py.PyObject) PyError {
    const type_obj = py.PyObject_Type(obj) orelse return error.PythonError;
    defer py.Py_DecRef(type_obj);
    const name = py.PyObject_GetAttrString(type_obj, "__name__") orelse return error.PythonError;
    defer py.Py_DecRef(name);
    const text = utf8(name) catch return error.PythonError;
    var buf: [256]u8 = undefined;
    const msg = std.mem.printSentinel(&buf, prefix ++ " {s}", .{text}, 0) catch prefix;
    py.PyErr_SetString(st.type_error, msg.ptr);
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
    const st: *State = @ptrCast(@alignCast(py.PyModule_GetState(module) orelse return -1));
    st.none_obj = py.Py_BuildValue("") orelse return -1;
    st.true_obj = py.PyBool_FromLong(1) orelse return -1;
    st.false_obj = py.PyBool_FromLong(0) orelse return -1;
    st.value_error = builtin("ValueError") orelse return -1;
    st.type_error = builtin("TypeError") orelse return -1;
    st.runtime_error = builtin("RuntimeError") orelse return -1;
    st.float_type = builtin("float") orelse return -1;
    // Set last: State.of() treats a non-null yaml_error as "fully initialized".
    st.yaml_error = py.PyErr_NewException("zaml.YAMLError", st.value_error, null) orelse return -1;
    return py.PyModule_AddObjectRef(module, "YAMLError", st.yaml_error);
}

/// Lets the garbage collector see the references the state holds.
fn moduleTraverse(module: [*c]py.PyObject, visit: py.visitproc, arg: ?*anyopaque) callconv(.c) c_int {
    const raw = py.PyModule_GetState(module) orelse return 0;
    const st: *State = @ptrCast(@alignCast(raw));
    inline for (State.fields) |name| {
        if (@field(st, name)) |obj| {
            const result = visit.?(obj, arg);
            if (result != 0) return result;
        }
    }
    return 0;
}

fn moduleClear(module: [*c]py.PyObject) callconv(.c) c_int {
    const raw = py.PyModule_GetState(module) orelse return 0;
    const st: *State = @ptrCast(@alignCast(raw));
    inline for (State.fields) |name| {
        if (@field(st, name)) |obj| {
            @field(st, name) = null;
            py.Py_DecRef(obj);
        }
    }
    return 0;
}

fn moduleFree(module: ?*anyopaque) callconv(.c) void {
    _ = moduleClear(@ptrCast(@alignCast(module)));
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

// Python 3.12 added the slot that declares support for interpreters with
// their own GIL; 3.10 and 3.11 reject it as unknown. zaml targets the 3.10
// stable ABI, so it carries two definitions and picks one at import.
const mod_multiple_interpreters = 3; // Py_mod_multiple_interpreters
const per_interpreter_gil_supported: ?*anyopaque = @ptrFromInt(2); // Py_MOD_PER_INTERPRETER_GIL_SUPPORTED

var slots_310 = [_]py.PyModuleDef_Slot{
    .{ .slot = py.Py_mod_exec, .value = @ptrCast(@constCast(&moduleExec)) },
    std.mem.zeroes(py.PyModuleDef_Slot),
};

var slots_312 = [_]py.PyModuleDef_Slot{
    .{ .slot = py.Py_mod_exec, .value = @ptrCast(@constCast(&moduleExec)) },
    .{ .slot = mod_multiple_interpreters, .value = per_interpreter_gil_supported },
    std.mem.zeroes(py.PyModuleDef_Slot),
};

fn moduleDef(slots: [*c]py.PyModuleDef_Slot) py.PyModuleDef {
    return .{
        .m_base = std.mem.zeroes(py.PyModuleDef_Base),
        .m_name = "zaml._zaml",
        .m_doc = "Fast YAML 1.2 parsing and dumping for Python, written in Zig.",
        .m_size = @sizeOf(State),
        .m_methods = &methods,
        .m_slots = slots,
        .m_traverse = moduleTraverse,
        .m_clear = moduleClear,
        .m_free = moduleFree,
    };
}

var module_def_310 = moduleDef(&slots_310);
var module_def_312 = moduleDef(&slots_312);
/// One-time setup of the chosen definition: 0 = not started, 1 = running, 2 = done.
var def_setup = std.atomic.Value(u8).init(0);

/// The running interpreter's minor version, from Py_GetVersion() ("3.12.5 ...").
fn runtimeMinorVersion() u32 {
    const version = std.mem.span(py.Py_GetVersion());
    var parts = std.mem.splitScalar(u8, version, '.');
    _ = parts.next(); // major
    const minor = parts.next() orelse return 0;
    var digits: usize = 0;
    while (digits < minor.len and std.ascii.isDigit(minor[digits])) digits += 1;
    return std.fmt.parseInt(u32, minor[0..digits], 10) catch 0;
}

pub export fn PyInit__zaml() callconv(.c) ?*py.PyObject {
    const def = if (runtimeMinorVersion() >= 12) &module_def_312 else &module_def_310;
    // The first import sets the shared definition up: one reference (the
    // equivalent of PyModuleDef_HEAD_INIT) and PyModuleDef_Init's writes of its
    // type and index. Interpreters with their own GIL can import concurrently,
    // so exactly one does this while any others wait; afterwards
    // PyModuleDef_Init only returns the definition.
    if (def_setup.load(.acquire) != 2) {
        if (def_setup.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
            py.Py_IncRef(@ptrCast(def));
            _ = py.PyModuleDef_Init(def);
            def_setup.store(2, .release);
        } else {
            while (def_setup.load(.acquire) != 2) std.atomic.spinLoopHint();
        }
    }
    return py.PyModuleDef_Init(def);
}

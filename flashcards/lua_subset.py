"""A small Lua subset interpreter for Omarchy Hyprland binding files.

The binding files are real Lua, but they only need a narrow slice of the
language: calls, tables, numeric for-loops, ifs, functions, and string
concatenation. This module evaluates that slice so the generator can expand
loops and apply o.rebind / hl.unbind without a Hyprland runtime.

Unsupported syntax raises LuaError with a file and line. That is deliberate:
after an `omarchy update`, a silent skip would drop bindings.
"""

from __future__ import annotations

import re
from typing import Any, Callable


class LuaError(Exception):
    def __init__(self, message: str, line: int | None = None, filename: str | None = None, source: str | None = None):
        self.line = line
        self.filename = filename
        loc = ""
        if filename or line:
            loc = f"{filename or '?'}:{line or '?'}: "
        extra = ""
        if source and line:
            lines = source.splitlines()
            if 1 <= line <= len(lines):
                extra = "\n  " + lines[line - 1]
        super().__init__(loc + message + extra)


class Multi:
    """Several Lua return values."""

    def __init__(self, values: list[Any]):
        self.values = values


class Table:
    def __init__(self) -> None:
        self.items: list[tuple[Any, Any]] = []
        self.map: dict[Any, Any] = {}

    def set(self, key: Any, value: Any) -> None:
        key = _intish(key)
        if key in self.map:
            self.map[key] = value
            for i, (existing, _) in enumerate(self.items):
                if existing == key:
                    self.items[i] = (key, value)
                    return
        self.map[key] = value
        self.items.append((key, value))

    def get(self, key: Any) -> Any:
        return self.map.get(_intish(key), None)

    def as_dict(self) -> dict[Any, Any]:
        return dict(self.items)


class LuaObject:
    """Host object. Known fields are stored; everything else is a Proxy."""

    def __init__(self, name: str):
        self.name = name
        self.fields: dict[str, Any] = {}

    def set(self, key: str, value: Any) -> None:
        self.fields[key] = value

    def get(self, key: Any) -> Any:
        if isinstance(key, str) and key in self.fields:
            return self.fields[key]
        if isinstance(key, str) and key.isidentifier():
            path = f"{self.name}.{key}" if self.name else key
        else:
            path = f"{self.name}[{key!r}]"
        return Proxy(path)


class Proxy:
    def __init__(self, path: str):
        self.path = path
        self.args: list[Any] | None = None
        self.callee: str | None = None

    def child(self, key: Any) -> Proxy:
        if isinstance(key, str) and key.isidentifier():
            return Proxy(f"{self.path}.{key}")
        return Proxy(f"{self.path}[{key!r}]")

    def call(self, args: list[Any]) -> Proxy:
        result = Proxy(self.path + "()")
        result.args = list(args)
        result.callee = self.path
        return result

    def __repr__(self) -> str:
        return f"Proxy({self.path})"


class LuaFunc:
    def __init__(self, params: list[str], body: list[Any], closure: Env, interp: Interpreter):
        self.params = params
        self.body = body
        self.closure = closure
        self.interp = interp

    def invoke(self, args: list[Any]) -> Any:
        child = Env(self.closure)
        for i, name in enumerate(self.params):
            child.set_local(name, args[i] if i < len(args) else None)
        prev = self.interp.env
        self.interp.env = child
        try:
            for stmt in self.body:
                self.interp.exec(stmt)
        except ReturnSignal as sig:
            return sig.value
        finally:
            self.interp.env = prev
        return None


class ReturnSignal(Exception):
    def __init__(self, value: Any):
        self.value = value


class Env:
    def __init__(self, parent: Env | None = None):
        self.parent = parent
        self.vars: dict[str, Any] = {}

    def get(self, name: str) -> Any:
        if name in self.vars:
            return self.vars[name]
        if self.parent is not None:
            return self.parent.get(name)
        raise LuaError(f"undefined global '{name}'")

    def contains(self, name: str) -> bool:
        if name in self.vars:
            return True
        if self.parent is not None:
            return self.parent.contains(name)
        return False

    def set(self, name: str, value: Any) -> None:
        if name in self.vars:
            self.vars[name] = value
            return
        if self.parent is not None and self.parent.contains(name):
            self.parent.set(name, value)
            return
        self._root().vars[name] = value

    def set_local(self, name: str, value: Any) -> None:
        self.vars[name] = value

    def _root(self) -> Env:
        env = self
        while env.parent is not None:
            env = env.parent
        return env


def _intish(key: Any) -> Any:
    if isinstance(key, float) and key.is_integer():
        return int(key)
    return key


# --- lexer -----------------------------------------------------------------

_KEYWORDS = {
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function",
    "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then",
    "true", "until", "while",
}
_TWO = {"..", "==", "~=", "<=", ">=", "//"}


class Tok:
    def __init__(self, kind: str, value: Any, line: int):
        self.kind = kind
        self.value = value
        self.line = line

    def __repr__(self) -> str:
        return f"Tok({self.kind}, {self.value!r}, {self.line})"


def tokenize(source: str, filename: str) -> tuple[list[Tok], dict[int, str]]:
    tokens: list[Tok] = []
    comments: list[tuple[int, str]] = []
    i = 0
    line = 1
    n = len(source)
    line_has_code = False

    def err(msg: str) -> LuaError:
        return LuaError(msg, line, filename, source)

    while i < n:
        c = source[i]
        if c == "\n":
            line += 1
            i += 1
            line_has_code = False
            continue
        if c in " \t\r":
            i += 1
            continue
        if c == "-" and i + 1 < n and source[i + 1] == "-":
            full_line = not line_has_code
            i += 2
            if i < n and source[i] == "[":
                long = _read_long_bracket(source, i)
                if long is not None:
                    text, i, newlines = long
                    if full_line and "\n" not in text:
                        comments.append((line, text.strip()))
                    line += newlines
                    continue
            start = i
            while i < n and source[i] != "\n":
                i += 1
            if full_line:
                comments.append((line, source[start:i].strip()))
            continue
        line_has_code = True
        if c == "[":
            long = _read_long_bracket(source, i)
            if long is not None:
                text, i, newlines = long
                tokens.append(Tok("string", text, line))
                line += newlines
                continue
        if c in ("'", '"'):
            quote = c
            i += 1
            chars: list[str] = []
            while i < n and source[i] != quote:
                if source[i] == "\n":
                    raise err("unterminated string")
                if source[i] == "\\":
                    i += 1
                    if i >= n:
                        raise err("unterminated string escape")
                    esc = source[i]
                    mapping = {"n": "\n", "r": "\r", "t": "\t", "\\": "\\", "'": "'", '"': '"', "a": "\a", "b": "\b", "f": "\f", "v": "\v"}
                    if esc in mapping:
                        chars.append(mapping[esc])
                        i += 1
                    elif esc.isdigit():
                        digits = esc
                        i += 1
                        for _ in range(2):
                            if i < n and source[i].isdigit():
                                digits += source[i]
                                i += 1
                        chars.append(chr(int(digits)))
                    else:
                        chars.append(esc)
                        i += 1
                    continue
                chars.append(source[i])
                i += 1
            if i >= n or source[i] != quote:
                raise err("unterminated string")
            i += 1
            tokens.append(Tok("string", "".join(chars), line))
            continue
        if c.isdigit():
            j = i + 1
            while j < n and source[j].isdigit():
                j += 1
            if j < n and source[j] == "." and not (j + 1 < n and source[j + 1] == ".") and j + 1 < n and source[j + 1].isdigit():
                j += 1
                while j < n and source[j].isdigit():
                    j += 1
                tokens.append(Tok("number", float(source[i:j]), line))
            else:
                tokens.append(Tok("number", int(source[i:j]), line))
            i = j
            continue
        if c.isalpha() or c == "_":
            j = i + 1
            while j < n and (source[j].isalnum() or source[j] == "_"):
                j += 1
            word = source[i:j]
            if word in _KEYWORDS:
                tokens.append(Tok(word, word, line))
            else:
                tokens.append(Tok("name", word, line))
            i = j
            continue
        two = source[i:i + 2]
        if two in _TWO:
            tokens.append(Tok(two, two, line))
            i += 2
            continue
        tokens.append(Tok(c, c, line))
        i += 1
    tokens.append(Tok("eof", None, line))
    return tokens, _single_line_comments(comments)


def _read_long_bracket(source: str, i: int) -> tuple[str, int, int] | None:
    if i >= len(source) or source[i] != "[":
        return None
    j = i + 1
    eqs = 0
    while j < len(source) and source[j] == "=":
        eqs += 1
        j += 1
    if j >= len(source) or source[j] != "[":
        return None
    j += 1
    close = "]" + ("=" * eqs) + "]"
    k = source.find(close, j)
    if k < 0:
        raise LuaError("unterminated long bracket")
    text = source[j:k]
    return text, k + len(close), text.count("\n")


def _single_line_comments(comments: list[tuple[int, str]]) -> dict[int, str]:
    """Comments that stand alone, immediately usable as section headers."""
    singles: dict[int, str] = {}
    for idx, (ln, text) in enumerate(comments):
        prev_line = comments[idx - 1][0] if idx else None
        next_line = comments[idx + 1][0] if idx + 1 < len(comments) else None
        if prev_line == ln - 1 or next_line == ln + 1:
            continue
        singles[ln] = text
    return singles


# --- parser ----------------------------------------------------------------

class Node:
    def __init__(self, line: int):
        self.line = line
        self.leading_comment: str | None = None


class Lit(Node):
    def __init__(self, value: Any, line: int):
        super().__init__(line)
        self.value = value


class Name(Node):
    def __init__(self, name: str, line: int):
        super().__init__(line)
        self.name = name


class UnOp(Node):
    def __init__(self, op: str, operand: Node, line: int):
        super().__init__(line)
        self.op = op
        self.operand = operand


class BinOp(Node):
    def __init__(self, op: str, left: Node, right: Node, line: int):
        super().__init__(line)
        self.op = op
        self.left = left
        self.right = right


class Dot(Node):
    def __init__(self, obj: Node, field: str, line: int):
        super().__init__(line)
        self.obj = obj
        self.field = field


class Index(Node):
    def __init__(self, obj: Node, key: Node, line: int):
        super().__init__(line)
        self.obj = obj
        self.key = key


class Call(Node):
    def __init__(self, func: Node, args: list[Node], line: int):
        super().__init__(line)
        self.func = func
        self.args = args


class MethodCall(Node):
    def __init__(self, obj: Node, method: str, args: list[Node], line: int):
        super().__init__(line)
        self.obj = obj
        self.method = method
        self.args = args


class FuncExpr(Node):
    def __init__(self, params: list[str], body: list[Node], line: int):
        super().__init__(line)
        self.params = params
        self.body = body


class TableExpr(Node):
    def __init__(self, fields: list[tuple[Node | None, Node]], line: int):
        super().__init__(line)
        self.fields = fields


class Assign(Node):
    def __init__(self, targets: list[Node], values: list[Node], line: int):
        super().__init__(line)
        self.targets = targets
        self.values = values


class LocalAssign(Node):
    def __init__(self, names: list[str], values: list[Node], line: int):
        super().__init__(line)
        self.names = names
        self.values = values


class CallStmt(Node):
    def __init__(self, expr: Node, line: int):
        super().__init__(line)
        self.expr = expr


class If(Node):
    def __init__(self, clauses: list[tuple[Node | None, list[Node]]], line: int):
        super().__init__(line)
        self.clauses = clauses


class ForNum(Node):
    def __init__(self, name: str, start: Node, stop: Node, step: Node | None, body: list[Node], line: int):
        super().__init__(line)
        self.name = name
        self.start = start
        self.stop = stop
        self.step = step
        self.body = body


class ForIn(Node):
    def __init__(self, names: list[str], iters: list[Node], body: list[Node], line: int):
        super().__init__(line)
        self.names = names
        self.iters = iters
        self.body = body


class LocalFunc(Node):
    def __init__(self, name: str, params: list[str], body: list[Node], line: int):
        super().__init__(line)
        self.name = name
        self.params = params
        self.body = body


class FuncAssign(Node):
    def __init__(self, target: Node, params: list[str], body: list[Node], line: int):
        super().__init__(line)
        self.target = target
        self.params = params
        self.body = body


class Return(Node):
    def __init__(self, values: list[Node], line: int):
        super().__init__(line)
        self.values = values


class Do(Node):
    def __init__(self, body: list[Node], line: int):
        super().__init__(line)
        self.body = body


_PREC = {
    "or": 1,
    "and": 2,
    "==": 3, "~=": 3, "<": 3, ">": 3, "<=": 3, ">=": 3,
    "..": 4,
    "+": 5, "-": 5,
    "*": 6, "/": 6, "//": 6, "%": 6,
    "^": 8,
}
_UNARY_PREC = 7


class Parser:
    def __init__(self, tokens: list[Tok], comments: dict[int, str], filename: str, source: str):
        self.toks = tokens
        self.i = 0
        self.comments = comments
        self.filename = filename
        self.source = source

    def peek(self) -> Tok:
        return self.toks[self.i]

    def at(self, *kinds: str) -> bool:
        return self.peek().kind in kinds

    def accept(self, kind: str) -> Tok | None:
        if self.at(kind):
            tok = self.peek()
            self.i += 1
            return tok
        return None

    def expect(self, kind: str) -> Tok:
        tok = self.accept(kind)
        if tok is None:
            got = self.peek()
            raise LuaError(f"expected {kind}, got {got.kind}", got.line, self.filename, self.source)
        return tok

    def parse_chunk(self) -> list[Node]:
        body = self.parse_block()
        if not self.at("eof"):
            got = self.peek()
            raise LuaError(f"unexpected {got.kind} after chunk", got.line, self.filename, self.source)
        return body

    def parse_block(self) -> list[Node]:
        stmts: list[Node] = []
        while not self.at("end", "elseif", "else", "until", "eof"):
            if self.at("return"):
                stmts.append(self.parse_return())
                self.accept(";")
                break
            stmts.append(self.parse_stat())
            self.accept(";")
        return stmts

    def _attach(self, node: Node, line: int) -> Node:
        node.leading_comment = self.comments.get(line - 1)
        return node

    def parse_stat(self) -> Node:
        line = self.peek().line
        if self.accept("local"):
            if self.accept("function"):
                node = self._parse_func_name(local=True, line=line)
            else:
                node = self._parse_local_assign(line)
        elif self.accept("function"):
            node = self._parse_func_name(local=False, line=line)
        elif self.accept("if"):
            node = self._parse_if(line)
        elif self.accept("for"):
            node = self._parse_for(line)
        elif self.accept("do"):
            body = self.parse_block()
            self.expect("end")
            node = Do(body, line)
        elif self.at("while", "repeat", "goto", "break"):
            kind = self.peek().kind
            raise LuaError(f"{kind} is not supported in binding files", line, self.filename, self.source)
        else:
            expr = self.parse_exp()
            if self.at(",", "="):
                targets = [expr]
                while self.accept(","):
                    targets.append(self.parse_prefix())
                self.expect("=")
                node = Assign(targets, self.parse_explist(), line)
            else:
                node = CallStmt(expr, line)
        return self._attach(node, line)

    def _parse_local_assign(self, line: int) -> LocalAssign:
        names = [self.expect("name").value]
        while self.accept(","):
            names.append(self.expect("name").value)
        values: list[Node] = []
        if self.accept("="):
            values = self.parse_explist()
        return LocalAssign(names, values, line)

    def _parse_func_name(self, local: bool, line: int) -> Node:
        name_tok = self.expect("name")
        if local:
            params, body = self._parse_funcbody()
            return LocalFunc(name_tok.value, params, body, line)
        target: Node = Name(name_tok.value, name_tok.line)
        while self.accept("."):
            field = self.expect("name")
            target = Dot(target, field.value, field.line)
        params, body = self._parse_funcbody()
        return FuncAssign(target, params, body, line)

    def _parse_funcbody(self) -> tuple[list[str], list[Node]]:
        self.expect("(")
        params: list[str] = []
        if not self.at(")"):
            while True:
                if self.at("..."):
                    raise LuaError("varargs are not supported", self.peek().line, self.filename, self.source)
                params.append(self.expect("name").value)
                if not self.accept(","):
                    break
        self.expect(")")
        body = self.parse_block()
        self.expect("end")
        return params, body

    def _parse_if(self, line: int) -> If:
        clauses: list[tuple[Node | None, list[Node]]] = []
        cond = self.parse_exp()
        self.expect("then")
        clauses.append((cond, self.parse_block()))
        while self.accept("elseif"):
            cond = self.parse_exp()
            self.expect("then")
            clauses.append((cond, self.parse_block()))
        if self.accept("else"):
            clauses.append((None, self.parse_block()))
        self.expect("end")
        return If(clauses, line)

    def _parse_for(self, line: int) -> Node:
        name = self.expect("name").value
        if self.accept("="):
            start = self.parse_exp()
            self.expect(",")
            stop = self.parse_exp()
            step = self.parse_exp() if self.accept(",") else None
            self.expect("do")
            body = self.parse_block()
            self.expect("end")
            return ForNum(name, start, stop, step, body, line)
        names = [name]
        while self.accept(","):
            names.append(self.expect("name").value)
        self.expect("in")
        iters = self.parse_explist()
        self.expect("do")
        body = self.parse_block()
        self.expect("end")
        return ForIn(names, iters, body, line)

    def parse_return(self) -> Return:
        line = self.peek().line
        self.expect("return")
        if self.at("end", "elseif", "else", "until", "eof", ";"):
            values: list[Node] = []
        else:
            values = self.parse_explist()
        return self._attach(Return(values, line), line)

    def parse_explist(self) -> list[Node]:
        exprs = [self.parse_exp()]
        while self.accept(","):
            exprs.append(self.parse_exp())
        return exprs

    def parse_exp(self, min_prec: int = 0) -> Node:
        left = self._parse_unary()
        while True:
            op = self.peek().kind
            prec = _PREC.get(op)
            if prec is None or prec < min_prec:
                break
            self.i += 1
            next_min = prec if op in ("..", "^") else prec + 1
            right = self.parse_exp(next_min)
            left = BinOp(op, left, right, left.line)
        return left

    def _parse_unary(self) -> Node:
        if self.at("not", "-", "#"):
            tok = self.peek()
            self.i += 1
            operand = self.parse_exp(_UNARY_PREC)
            return UnOp(tok.kind, operand, tok.line)
        return self.parse_prefix()

    def parse_prefix(self) -> Node:
        return self._parse_postfix(self._parse_atom())

    def _parse_atom(self) -> Node:
        tok = self.peek()
        if self.accept("nil"):
            return Lit(None, tok.line)
        if self.accept("true"):
            return Lit(True, tok.line)
        if self.accept("false"):
            return Lit(False, tok.line)
        if self.at("number"):
            self.i += 1
            return Lit(tok.value, tok.line)
        if self.at("string"):
            self.i += 1
            return Lit(tok.value, tok.line)
        if self.accept("function"):
            params, body = self._parse_funcbody()
            return FuncExpr(params, body, tok.line)
        if self.accept("{"):
            return self._parse_table(tok.line)
        if self.accept("("):
            expr = self.parse_exp()
            self.expect(")")
            return expr
        if self.at("name"):
            self.i += 1
            return Name(tok.value, tok.line)
        raise LuaError(f"unexpected {tok.kind}", tok.line, self.filename, self.source)

    def _parse_postfix(self, expr: Node) -> Node:
        while True:
            if self.accept("."):
                field = self.expect("name")
                expr = Dot(expr, field.value, field.line)
            elif self.accept("["):
                key = self.parse_exp()
                self.expect("]")
                expr = Index(expr, key, expr.line)
            elif self.accept(":"):
                method = self.expect("name")
                args = self._parse_args()
                expr = MethodCall(expr, method.value, args, expr.line)
            elif self.at("(", "{", "string"):
                args = self._parse_args()
                expr = Call(expr, args, expr.line)
            else:
                break
        return expr

    def _parse_args(self) -> list[Node]:
        if self.accept("("):
            if self.accept(")"):
                return []
            args = self.parse_explist()
            self.expect(")")
            return args
        if self.at("{", "string"):
            return [self._parse_atom()]
        got = self.peek()
        raise LuaError("expected arguments", got.line, self.filename, self.source)

    def _parse_table(self, line: int) -> TableExpr:
        fields: list[tuple[Node | None, Node]] = []
        if self.accept("}"):
            return TableExpr(fields, line)
        while True:
            if self.accept("["):
                key = self.parse_exp()
                self.expect("]")
                self.expect("=")
                fields.append((key, self.parse_exp()))
            elif self.at("name") and self.i + 1 < len(self.toks) and self.toks[self.i + 1].kind == "=":
                key_tok = self.expect("name")
                self.expect("=")
                fields.append((Lit(key_tok.value, key_tok.line), self.parse_exp()))
            else:
                fields.append((None, self.parse_exp()))
            if self.accept(",") or self.accept(";"):
                if self.accept("}"):
                    break
                continue
            self.expect("}")
            break
        return TableExpr(fields, line)


def parse(source: str, filename: str) -> list[Node]:
    tokens, comments = tokenize(source, filename)
    return Parser(tokens, comments, filename, source).parse_chunk()


# --- evaluator -------------------------------------------------------------

class Interpreter:
    def __init__(self, filename: str, source: str, globals_dict: dict[str, Any]):
        self.filename = filename
        self.source = source
        self.line = 1
        self.global_env = Env()
        for key, value in globals_dict.items():
            self.global_env.set_local(key, value)
        self.env = Env(self.global_env)
        self.on_comment: Callable[[str], None] | None = None
        self.on_condition: Callable[[Node, bool], None] | None = None

    def run(self, stmts: list[Node]) -> None:
        try:
            self.exec_block(stmts)
        except ReturnSignal:
            return
        except LuaError:
            raise
        except Exception as exc:
            raise LuaError(str(exc), self.line, self.filename, self.source) from exc

    def exec_block(self, stmts: list[Node], env: Env | None = None) -> None:
        if env is None:
            for stmt in stmts:
                self.exec(stmt)
            return
        prev = self.env
        self.env = env
        try:
            for stmt in stmts:
                self.exec(stmt)
        finally:
            self.env = prev

    def exec(self, stmt: Node) -> None:
        self.line = stmt.line
        if stmt.leading_comment and self.on_comment:
            self.on_comment(stmt.leading_comment)
        if isinstance(stmt, LocalAssign):
            vals = self.eval_explist(stmt.values)
            for i, name in enumerate(stmt.names):
                self.env.set_local(name, vals[i] if i < len(vals) else None)
        elif isinstance(stmt, Assign):
            vals = self.eval_explist(stmt.values)
            for i, target in enumerate(stmt.targets):
                self.assign(target, vals[i] if i < len(vals) else None)
        elif isinstance(stmt, CallStmt):
            self.eval_expr(stmt.expr)
        elif isinstance(stmt, If):
            for cond, body in stmt.clauses:
                if cond is not None and not self.truthy(self.eval_expr(cond)):
                    continue
                if cond is not None and self.on_condition:
                    self.on_condition(cond, True)
                try:
                    self.exec_block(body)
                finally:
                    if cond is not None and self.on_condition:
                        self.on_condition(cond, False)
                break
        elif isinstance(stmt, ForNum):
            start = int(self.num(self.eval_expr(stmt.start)))
            stop = int(self.num(self.eval_expr(stmt.stop)))
            step = int(self.num(self.eval_expr(stmt.step))) if stmt.step is not None else 1
            if step == 0:
                raise LuaError("for-loop step is zero", stmt.line, self.filename, self.source)
            i = start
            while i <= stop if step > 0 else i >= stop:
                child = Env(self.env)
                child.set_local(stmt.name, i)
                self.exec_block(stmt.body, child)
                i += step
        elif isinstance(stmt, ForIn):
            iter_vals = self.eval_explist(stmt.iters)
            iterator = iter_vals[0] if iter_vals else None
            state = iter_vals[1] if len(iter_vals) > 1 else None
            control = iter_vals[2] if len(iter_vals) > 2 else None
            while True:
                result = self.call(iterator, [state, control])
                vals = self.as_list(result)
                if not vals or vals[0] is None:
                    break
                control = vals[0]
                child = Env(self.env)
                for i, name in enumerate(stmt.names):
                    child.set_local(name, vals[i] if i < len(vals) else None)
                self.exec_block(stmt.body, child)
        elif isinstance(stmt, LocalFunc):
            self.env.set_local(stmt.name, None)
            fn = LuaFunc(stmt.params, stmt.body, self.env, self)
            self.env.set_local(stmt.name, fn)
        elif isinstance(stmt, FuncAssign):
            fn = LuaFunc(stmt.params, stmt.body, self.env, self)
            self.assign(stmt.target, fn)
        elif isinstance(stmt, Return):
            vals = self.eval_explist(stmt.values)
            if len(vals) == 1:
                raise ReturnSignal(vals[0])
            raise ReturnSignal(Multi(vals))
        elif isinstance(stmt, Do):
            self.exec_block(stmt.body, Env(self.env))
        else:
            raise LuaError(f"cannot execute {type(stmt).__name__}", stmt.line, self.filename, self.source)

    def assign(self, target: Node, value: Any) -> None:
        if isinstance(value, Multi):
            value = value.values[0] if value.values else None
        if isinstance(target, Name):
            self.env.set(target.name, value)
        elif isinstance(target, Dot):
            self.set_index(self.eval_expr(target.obj), target.field, value)
        elif isinstance(target, Index):
            self.set_index(self.eval_expr(target.obj), self.eval_expr(target.key), value)
        else:
            raise LuaError("invalid assignment target", target.line, self.filename, self.source)

    def eval_explist(self, exprs: list[Node]) -> list[Any]:
        out: list[Any] = []
        for i, expr in enumerate(exprs):
            value = self.eval_expr(expr)
            if i == len(exprs) - 1 and isinstance(value, Multi):
                out.extend(value.values)
            elif isinstance(value, Multi):
                out.append(value.values[0] if value.values else None)
            else:
                out.append(value)
        return out

    def eval_expr(self, expr: Node) -> Any:
        self.line = expr.line
        if isinstance(expr, Lit):
            return expr.value
        if isinstance(expr, Name):
            try:
                return self.env.get(expr.name)
            except LuaError as exc:
                raise LuaError(str(exc), expr.line, self.filename, self.source) from exc
        if isinstance(expr, UnOp):
            value = self.eval_expr(expr.operand)
            if expr.op == "not":
                return not self.truthy(value)
            if expr.op == "-":
                return -self.num(value)
            if expr.op == "#":
                if isinstance(value, str):
                    return len(value)
                if isinstance(value, Table):
                    n = 0
                    while value.get(n + 1) is not None:
                        n += 1
                    return n
            raise LuaError(f"bad unary {expr.op}", expr.line, self.filename, self.source)
        if isinstance(expr, BinOp):
            if expr.op == "and":
                left = self.eval_expr(expr.left)
                return self.eval_expr(expr.right) if self.truthy(left) else left
            if expr.op == "or":
                left = self.eval_expr(expr.left)
                return left if self.truthy(left) else self.eval_expr(expr.right)
            return self.apply_bin(expr.op, self.eval_expr(expr.left), self.eval_expr(expr.right), expr.line)
        if isinstance(expr, Dot):
            return self.get_index(self.eval_expr(expr.obj), expr.field)
        if isinstance(expr, Index):
            return self.get_index(self.eval_expr(expr.obj), self.eval_expr(expr.key))
        if isinstance(expr, Call):
            return self.call(self.eval_expr(expr.func), self.eval_explist(expr.args))
        if isinstance(expr, MethodCall):
            return self.method(self.eval_expr(expr.obj), expr.method, self.eval_explist(expr.args))
        if isinstance(expr, FuncExpr):
            return LuaFunc(expr.params, expr.body, self.env, self)
        if isinstance(expr, TableExpr):
            table = Table()
            array_index = 1
            for key_expr, val_expr in expr.fields:
                value = self.eval_expr(val_expr)
                if isinstance(value, Multi):
                    value = value.values[0] if value.values else None
                if key_expr is None:
                    table.set(array_index, value)
                    array_index += 1
                else:
                    table.set(self.eval_expr(key_expr), value)
            return table
        raise LuaError(f"bad expression {type(expr).__name__}", getattr(expr, "line", self.line), self.filename, self.source)

    def call(self, fn: Any, args: list[Any]) -> Any:
        if isinstance(fn, LuaFunc):
            return fn.invoke(args)
        if isinstance(fn, Proxy):
            return fn.call(args)
        if callable(fn):
            return fn(*args)
        raise LuaError(f"attempt to call a {type(fn).__name__} value", self.line, self.filename, self.source)

    def method(self, obj: Any, name: str, args: list[Any]) -> Any:
        if obj is None:
            raise LuaError(f"attempt to index a nil value ('{name}')", self.line, self.filename, self.source)
        if isinstance(obj, str):
            return self.string_method(obj, name, args)
        if isinstance(obj, Proxy):
            called = obj.child(name).call(args)
            called.path = f"{obj.path}:{name}()"
            return called
        if isinstance(obj, (Table, LuaObject)):
            fn = obj.get(name)
            if isinstance(fn, LuaFunc):
                return self.call(fn, [obj, *args])
            if isinstance(fn, Proxy):
                return fn.call(args)
            if callable(fn):
                return self.call(fn, args)
        attr = getattr(obj, name, None)
        if callable(attr):
            return attr(*args)
        raise LuaError(f"attempt to call method '{name}'", self.line, self.filename, self.source)

    def string_method(self, text: str, name: str, args: list[Any]) -> Any:
        if name == "lower":
            return text.lower()
        if name == "upper":
            return text.upper()
        if name == "gsub":
            return lua_gsub(text, str(args[0]), str(args[1]))
        if name == "match":
            return lua_match(text, str(args[0]))
        if name == "find":
            init = args[1] if len(args) > 1 and args[1] is not None else 1
            plain = len(args) > 2 and args[2] is True
            return lua_find(text, str(args[0]), int(init), plain)
        raise LuaError(f"string has no method '{name}'", self.line, self.filename, self.source)

    def get_index(self, obj: Any, key: Any) -> Any:
        if obj is None:
            raise LuaError("attempt to index a nil value", self.line, self.filename, self.source)
        if isinstance(obj, (Table, LuaObject)):
            return obj.get(key)
        if isinstance(obj, Proxy):
            return obj.child(key)
        raise LuaError(f"attempt to index a {type(obj).__name__} value", self.line, self.filename, self.source)

    def set_index(self, obj: Any, key: Any, value: Any) -> None:
        if isinstance(obj, (Table, LuaObject)):
            obj.set(key, value)
            return
        raise LuaError(f"attempt to index a {type(obj).__name__} value for assignment", self.line, self.filename, self.source)

    def apply_bin(self, op: str, left: Any, right: Any, line: int) -> Any:
        if op == "..":
            return lua_tostring(left) + lua_tostring(right)
        if op in {"+", "-", "*", "/", "//", "%", "^"}:
            ln = self.num(left)
            rn = self.num(right)
            if op == "+":
                result = ln + rn
            elif op == "-":
                result = ln - rn
            elif op == "*":
                result = ln * rn
            elif op == "/":
                result = ln / rn
            elif op == "//":
                result = ln // rn
            elif op == "%":
                result = ln % rn
            else:
                result = ln ** rn
            if isinstance(result, float) and result.is_integer():
                return int(result)
            return result
        if op == "==":
            return left == right
        if op == "~=":
            return left != right
        if op in {"<", ">", "<=", ">="}:
            if isinstance(left, (int, float)) and isinstance(right, (int, float)) and not isinstance(left, bool) and not isinstance(right, bool):
                return { "<": left < right, ">": left > right, "<=": left <= right, ">=": left >= right }[op]
            if isinstance(left, str) and isinstance(right, str):
                return { "<": left < right, ">": left > right, "<=": left <= right, ">=": left >= right }[op]
        raise LuaError(f"bad operands for '{op}'", line, self.filename, self.source)

    def num(self, value: Any) -> int | float:
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise LuaError(f"number expected, got {value!r}", self.line, self.filename, self.source)
        return value

    def truthy(self, value: Any) -> bool:
        return value is not None and value is not False

    def as_list(self, value: Any) -> list[Any]:
        if value is None:
            return []
        if isinstance(value, Multi):
            return value.values
        return [value]


def lua_tostring(value: Any) -> str:
    if value is None:
        return "nil"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    if isinstance(value, float):
        return repr(value)
    return str(value)


def lua_pairs(table: Table) -> Multi:
    if not isinstance(table, Table):
        raise LuaError("pairs expects a table")
    keys = [key for key, value in table.items if value is not None]

    def nxt(_state: Any, key: Any) -> Any:
        if key is None:
            if not keys:
                return None
            found = keys[0]
            return Multi([found, table.get(found)])
        try:
            index = keys.index(key)
        except ValueError:
            return None
        if index + 1 >= len(keys):
            return None
        found = keys[index + 1]
        return Multi([found, table.get(found)])

    return Multi([nxt, table, None])


def lua_ipairs(table: Table) -> Multi:
    if not isinstance(table, Table):
        raise LuaError("ipairs expects a table")

    def nxt(state: Table, index: Any) -> Any:
        i = int(index or 0) + 1
        value = state.get(i)
        if value is None:
            return None
        return Multi([i, value])

    return Multi([nxt, table, 0])


_LUA_CLASS = {
    "a": "A-Za-z",
    "d": "0-9",
    "l": "a-z",
    "u": "A-Z",
    "w": "A-Za-z0-9_",
    "x": "0-9A-Fa-f",
    "s": r"\s",
}


def lua_pattern_to_re(pattern: str) -> str:
    out: list[str] = []
    i = 0
    while i < len(pattern):
        c = pattern[i]
        if c == "%":
            i += 1
            if i >= len(pattern):
                raise LuaError("malformed Lua pattern")
            n = pattern[i]
            if n == "s":
                out.append(r"\s")
            elif n in _LUA_CLASS and n != "s":
                out.append("[" + _LUA_CLASS[n] + "]")
            else:
                out.append(re.escape(n))
            i += 1
            continue
        if c == "[":
            j = i + 1
            if j < len(pattern) and pattern[j] == "^":
                j += 1
            while j < len(pattern) and pattern[j] != "]":
                if pattern[j] == "%":
                    j += 2
                else:
                    j += 1
            out.append(_convert_class(pattern[i:j + 1]))
            i = j + 1
            continue
        if c in "^$":
            out.append(c)
        elif c == ".":
            out.append(".")
        elif c in "+*?":
            out.append(c)
        else:
            out.append(re.escape(c))
        i += 1
    return "".join(out)


def _convert_class(cls: str) -> str:
    inner = cls[1:-1]
    neg = inner.startswith("^")
    if neg:
        inner = inner[1:]
    chars: list[str] = []
    i = 0
    while i < len(inner):
        if inner[i] == "%" and i + 1 < len(inner):
            n = inner[i + 1]
            if n in _LUA_CLASS and n != "s":
                chars.append(_LUA_CLASS[n])
            elif n == "s":
                chars.append(r"\s")
            else:
                chars.append(re.escape(n))
            i += 2
            continue
        chars.append(re.escape(inner[i]) if inner[i] in r"\]" else inner[i])
        i += 1
    return ("[^" if neg else "[") + "".join(chars) + "]"


def lua_match(text: str, pattern: str) -> str | None:
    matched = re.search(lua_pattern_to_re(pattern), text)
    if not matched:
        return None
    if matched.groups():
        return matched.group(1)
    return matched.group(0)


def lua_gsub(text: str, pattern: str, repl: str) -> str:
    return re.sub(lua_pattern_to_re(pattern), repl, text)


def lua_find(text: str, pattern: str, init: int, plain: bool) -> int | None:
    start = max(init - 1, 0)
    if plain:
        idx = text.find(pattern, start)
        return None if idx < 0 else idx + 1
    matched = re.search(lua_pattern_to_re(pattern), text[start:])
    if not matched:
        return None
    return start + matched.start() + 1


def execute(source: str, filename: str, globals_dict: dict[str, Any], on_comment: Callable[[str], None] | None = None, on_condition: Callable[[Node, bool], None] | None = None) -> Interpreter:
    interp = Interpreter(filename, source, globals_dict)
    interp.on_comment = on_comment
    interp.on_condition = on_condition
    interp.run(parse(source, filename))
    return interp

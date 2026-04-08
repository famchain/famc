# famc

A self-hosted compiler for a systems language targeting bare-metal RISC-V (RV32I). Part of a fully bootstrappable toolchain that builds from a small seed binary with no external dependencies.

## Bootstrap Chain

```
fam0.seed (hand-verified binary, 188 bytes)
  -> fam0 (minimal assembler, verifies itself)
    -> fam1
      -> fam2
        -> fam3 (full assembler with macros, relaxation)
          -> famc (this compiler, self-hosted)
```

Each stage compiles the next from source. The compiler compiles itself. The only external tool is QEMU (or any RV32I hardware).

## Building

```sh
bash build.sh
```

This runs the full bootstrap chain and produces `bin/famc`.

## Usage

```sh
famc source.fam          # compiles to source.bin
q32 source.bin           # runs on QEMU rv32i virt machine
```

## Language Overview

Everything is an expression. All values are 32-bit words. No type system -- structs provide named field access and stride information, but every variable is just a word.

### Variables

```
x = 42;          // immutable
y := 0;          // mutable (can be reassigned)
y = 10;          // ok
y += 5;          // compound assignment: += -= *= /= %= &= |= ^= <<= >>=
```

### Arithmetic & Bitwise

```
a + b    a - b    a * b    a / b    a % b
a & b    a | b    a ^ b    ~a       a << n    a >> n
```

Comparisons are signed by default:
```
a < b    a > b    a <= b    a >= b    a == b    a != b
```

Unsigned variants:
```
a <u b   a >u b   a <=u b   a >=u b
```

Bitwise operators bind tighter than comparisons (unlike C):
```
flags & MASK == 0    // parsed as (flags & MASK) == 0, not flags & (MASK == 0)
```

### Logical Operators (Short-Circuit)

```
a && b    // if a is 0, result is 0 (b not evaluated)
a || b    // if a is non-0, result is 1 (b not evaluated)
```

### Control Flow

```
// Ternary (with optional else)
x > 0 ? x : 0 - x
flag ? do_something()

// Blocks (last expression is the value)
result = { a = 10; b = 20; a + b };

// Loops
loop { ... break value; ... continue; }

// For loops (exclusive and inclusive ranges)
for i in 0..10 { ... }      // 0 to 9
for i in 0..=10 { ... }     // 0 to 10
```

### Closures

```
add = |a, b| a + b;
greet = |name| { putstr("hello "); putstr(name); putchar('\n') };

// Captures by reference
counter := 0;
inc = || { counter = counter + 1 };

// Early return
clamp = |x, lo, hi| {
    x < lo ? return lo;
    x > hi ? return hi;
    x
};

// Recursion via self
fact = |n| { n <= 1 ? return 1; n * self(n - 1) };
fib = |n| n <= 1 ? n : self(n-1) + self(n-2);
```

### Structs

```
struct Point { x; y }
struct Rect { origin; size }

p = Point(10, 20);
p.x                    // 10
p.y = 30;              // field write

r = Rect(Point(0, 0), Point(100, 200));
r.origin.x             // chained access

sizeof(Point)           // 8 (2 fields * 4 bytes)
```

### Arrays

```
arr = alloc(40);        // 10 words
arr[0] = 42;            // word access (stride 4)
arr[i]                  // read

@arr[0] = 65;           // byte access (stride 1)
#arr[0] = 1000;         // halfword access (stride 2)
```

### Typed Placement (Contiguous Struct Arrays)

```
struct Vec2 { x; y }
buf = alloc(sizeof(Vec2) * 100);

Vec2@buf[0] = Vec2(1, 2);       // copy struct data to buf[0]
Vec2@buf[i].x                   // read field with struct stride
Vec2@buf[i].y = 99;             // write field at typed offset
```

### Pointer Operations

```
*addr = value;          // word store
*addr                   // word load
@addr = byte;           // byte store
@addr                   // byte load (unsigned)
#addr = half;           // halfword store
#addr                   // halfword load (unsigned)
```

### Macros

Hygienic parametric macros. Arguments evaluated once (no double-evaluation). No code emitted if unused.

```
macro MAX(a, b) a > b ? a : b;
macro CLAMP(x, lo, hi) MIN(MAX(x, lo), hi);
macro SWAP(a, b) { t := a; a = b; b = t };

MAX(expensive(), 0)     // expensive() called only once
```

### Inline Assembly

```
asm putchar {
    lui t0, 0x10000
    sb a0, 0(t0)
    ret
};

asm double { add a0, a0, a0; ret };

putchar(65);            // prints 'A'
double(21)              // returns 42
```

Standard RISC-V calling convention: arguments in a0-a7, return in a0.

## Safety Properties

- **Stack guard**: every stack growth checks `sp >= tp`. Set `tp` to control stack limits per hart.
- **No heap in generated code**: `gp` is never touched by compiler output. User controls heap via stdlib `alloc`.
- **Immutability**: `=` creates immutable bindings. Reassignment is a compile error.
- **Typed field validation**: accessing a field not in the variable's struct type is a compile error.
- **Placement type check**: `A@arr[0] = B(1,2)` errors if A and B are different structs.
- **Scope checks**: `return` outside closure, `break`/`continue` outside loop -> compile error.
- **Arg limits**: max 8 arguments per call (a0-a7), checked at compile time.
- **Table overflow checks**: all compiler tables are bounds-checked or dynamically grown.
- **Branch safety**: asm B-type branches use trampoline pattern (unlimited range).

## Error Messages

```
error:3:5 undefined name
error:7:1 immutable variable
error:12:0 return outside closure
error:5:15 type mismatch
```

Format: `error:line:col message`. One error, then exit.

## Target

- **ISA**: RV32I base only (no M/A/F/C extensions)
- **Platform**: QEMU virt (UART at 0x10000000, RAM at 0x80000000)
- **Multiply/divide**: inline shift-and-add / long division
- **Position independent**: all jumps PC-relative, data s0-relative
- **Multi-hart ready**: no global state, per-hart sp/tp/gp

## Standard Library

`lib/stdlib.fam` provides: `putchar`, `putstr`, `putnum`, `puthex`, `alloc`, `exit`. These are asm blocks prepended to every program by the `famc` wrapper script.

## Tools

- `famc` -- compiler wrapper (prepends stdlib, compiles, checks output)
- `q32` -- QEMU runner (checks binary magic before execution)
- `tools/fmt_fam.py` -- source formatter (tab indentation, blank line collapsing)
- `tools/fmt_asm.py` -- assembly formatter (for .fam3 files)
- `.ci/runtests` -- test suite (177 tests)

## Tests

```sh
.ci/runtests              # run all tests
.ci/runtests --verbose    # show individual results
```

## License

See [LICENSE](LICENSE).

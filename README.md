# famc

A self-hosted compiler for a small expression-oriented language targeting
bare-metal RISC-V (RV32I). Part of a fully bootstrappable toolchain that
builds from a 168-byte seed binary with no external dependencies beyond
QEMU (or any RV32I hardware that can execute the seed and stream bytes
over a UART).

## Bootstrap Chain

```
fam0.seed             168 B   hand-auditable hex-to-binary converter (the trust root)
  → bin/fam0          168 B   self-hosts: recompiles itself from src/fam0.fam0
    → bin/fam1        576 B   hex + labels + branch fixups
      → bin/fam2     5744 B   RV32I mnemonic assembler
        → bin/fam3  13256 B   pseudos, macros, branch relaxation
          → bin/famc ~55 KB   expression-language compiler, self-hosted
```

Each stage is compiled by the previous stage. The top of the chain (famc)
is self-hosting: it can recompile itself from `src/famc.fam3`. The only
external tool in the build is QEMU, and it's used only as an execution
environment — fam0 itself is pure RV32I with no ELF wrapping, no syscalls,
and no runtime library.

## Building

```sh
bash build.sh
```

This runs the full bootstrap chain from the committed seed all the way to
`bin/famc`. The build also verifies self-hosting by re-running `bin/fam0`
on `src/fam0.fam0` and comparing the result to the committed `fam0.seed`.

## Running a program

```sh
tools/famc source.fam          # compile → source.bin
tools/q32 source.bin           # execute on QEMU rv32i virt
```

## Language Overview

Everything is an expression. All values are 32-bit words. No type system —
structs provide named field access and stride information, but every
variable is still just a word.

### Variables

```
x = 42;          // first binding → immutable
y := 0;          // first binding → mutable
y = 10;          // reassignment allowed (y was declared mutable)
y += 5;          // compound: += -= *= /= %= &= |= ^= <<= >>=
y++;             // postfix increment / decrement
++y;             // prefix increment / decrement
```

The rule: **the operator at the first binding determines mutability**
(`=` → immutable, `:=` → mutable). Subsequent assignments to a mutable
variable can use either operator. Reassigning an immutable variable is a
compile error.

### Arithmetic and Bitwise

```
a + b    a - b    a * b    a / b    a % b
a & b    a | b    a ^ b    ~a       a << n    a >> n    a >>u n
```

`>>` is arithmetic right shift (sign-extends); `>>u` is logical right
shift (zero-extends).

Signed comparisons:
```
a < b    a > b    a <= b    a >= b    a == b    a != b
```

Unsigned variants:
```
a <u b   a >u b   a <=u b   a >=u b
```

Bitwise operators bind tighter than comparisons (unlike C):
```
flags & MASK == 0    // parses as (flags & MASK) == 0
```

### Short-circuit Logical Operators

```
a && b    // if a is 0, result is 0; b not evaluated
a || b    // if a is non-zero, result is 1; b not evaluated
```

### Control Flow

```
// Ternary (full and one-armed forms)
x > 0 ? x : 0 - x
flag ? do_something();

// Blocks — last expression is the value
result = { a := 10; b := 20; a + b };

// Infinite loop with break / continue
loop {
    cond ? break value;
    cond2 ? continue;
    ...
}

// For loops (exclusive and inclusive ranges)
for i in 0..10  { ... }     // 0 .. 9
for i in 0..=10 { ... }     // 0 .. 10
```

### Functions

```
fn add(a, b) { a + b }
fn greet() { @0x10000000 = 'A'; }

// Up to 8 parameters (RISC-V a0..a7 calling convention)
fn sum8(a, b, c, d, e, f, g, h) { a+b+c+d+e+f+g+h }

// Explicit return
fn abs(x) { x < 0 ? return 0 - x; x }

// Recursion is name-based
fn fact(n) { n < 2 ? return 1; n * fact(n - 1) }
fn fib(n) { n < 2 ? return n; fib(n-1) + fib(n-2) }
```

### Structs

```
struct Point { x, y }
p := Point { 10, 20 };              // positional init
q := Point { x: 5, y: 7 };          // named init

Point@p.x                           // 10  (type-tagged field read)
Point@p.y = 30;                     // field write
Point@p.x += 5;                     // compound ops on fields too

sizeof(Point)                       // 8  (2 fields × 4 bytes)
```

Field access uses the `Type@var.field` form — the type is explicit at
every access, which is how the compiler knows the field offsets and
strides. Nested struct reads multi-step through intermediate variables:

```
struct Inner { v, w }
struct Outer { a, b, c }
x = Outer { a: 1, b: Inner { 20, 30 }, c: 4 };
inner = Outer@x.b;                  // inner now refers to the inner struct
val  = Inner@inner.v;               // 20
```

### Arrays (Stack-Allocated)

Arrays are declared in-place on the local frame with an element-stride
prefix:

```
@arr[10];                       // 10 bytes
*arr[10];                       // 10 words (40 bytes)
#arr[10];                       // 10 halfwords (20 bytes)
```

Access uses the same prefix for read / write:

```
@arr[0] = 65;                   // byte store
@arr[i]                         // byte load

*arr[0] = 0x41424344;           // word store
*arr[i]                         // word load
```

### Typed Placement (Struct Arrays)

```
struct Vec2 { x, y }
Vec2@buf[100];                  // declare 100 × sizeof(Vec2) bytes

Vec2@buf[i].x                   // field read with struct stride
Vec2@buf[i].y = 99;              // field write at typed offset
```

Field access through `Type@expr.field` also works on single struct
variables:

```
struct Point { x, y }
p := Point { 10, 20 };
Point@p.x                       // 10
Point@p.y = 99;                 // field write
```

### Pointer Operations

```
*addr = value;       // word store  (4 bytes)
*addr                // word load
@addr = byte;        // byte store  (1 byte)
@addr                // byte load (unsigned)
#addr = half;        // halfword store (2 bytes)
#addr                // halfword load (unsigned)
```

### Macros

Text-substitution macros with GAS-style `\name` argument references.
Definitions use a `{ ... }` body. Parens around the parameter list are
optional. No code is emitted if a macro is unused.

```
macro PUTC(c)         { @0x10000000 = \c; }
macro STORE(addr, val) { @\addr = \val; }
macro AB               { @0x10000000 = 65; @0x10000000 = 66; }

PUTC('A');
STORE(0x10000000, 'B');
AB();
```

Substitution is textual, so if a macro body references `\c` twice, the
argument's text appears twice in the expansion. Pass a temporary
variable when you need single-evaluation:

```
macro TWICE(c)  { @0x10000000 = \c; @0x10000000 = \c; }
t := expensive();
TWICE(t);                    // expensive() called once; t referenced twice
```

### Inline Assembly

```
// Named asm blocks — called like a function
asm double { add a0, a0, a0 }
@0x10000000 = double(32) + 1;

// Inline asm with variable bindings
x := 0;
asm {
    li t0, 42
    (x=t0)          // store register into variable
};

asm {
    (t0=x)          // load variable into register
    addi t0, t0, 5
    (x=t0)
};
```

Standard RISC-V calling convention. Arguments in `a0..a7`, return in `a0`.

### Numeric Local Labels

Numeric labels (`0:`–`99:`) can be reused across macro expansions.
Reference with `Nb` (backward) or `Nf` (forward):

```
asm {
    li t0, 10
1:  addi t0, t0, -1
    bnez t0, 1b
}
```

## Safety Properties

- **Stack guard**: every stack growth in generated code checks `sp >= s1`.
  `s1` holds the stack-low marker set at program entry.
- **No heap in generated code**: stack-allocated arrays are the only
  allocation mechanism exposed to user programs. The compiler itself uses
  a bump-allocated heap at build time, but nothing in the output binary
  touches that region.
- **Immutability is enforced**: attempts to reassign an immutable binding
  are a compile error.
- **Typed struct accesses are checked**: reading a field not in the
  variable's declared struct type is a compile error. Writing via
  `A@buf[i] = B(...)` with mismatched structs is a compile error.
- **Scope checks**: `return` outside a function, `break` / `continue`
  outside a loop — all compile errors.
- **Argument count**: max 8 arguments per call (a0..a7), checked at
  compile time.
- **Bounds on compiler tables**: all symbol / macro / fixup tables are
  either bounds-checked or dynamically grown with checks.
- **Branch reach**: the compiler never emits a branch that could overflow
  its offset field. Long branches are expanded to trampolines.
- **No `jalr`**: generated code is strictly direct-jump only (RV32I minus
  `jalr`), so the entire binary is statically reachable from the entry
  point. `.ci/runtests` includes a `no-jalr` verifier.

## Error Messages

```
Error:3:5 undefined variable
Error:7:1 cannot reassign immutable
Error:12:0 return outside function
Error:5:15 expected ';'
```

Format: `Error:<line>:<col> <message>`. First error terminates
compilation.

## Target and Memory Layout

- **ISA**: RV32I base only. No M / A / F / D / C extensions. No `jalr`
  in generated code.
- **Platform**: QEMU `virt` machine by default
  - UART at `0x10000000` (16550-compatible)
  - SiFive test finisher at `0x00100000` (for clean poweroff)
  - Code loaded at `0x80000000`
- **Multiply and divide**: inlined shift-and-add / long-division templates.
- **Position independent**: all intra-program jumps are PC-relative.
  Data accesses are `fp`-relative. The load address can be changed without
  re-linking.

## Porting to Different Hardware

The bootstrap chain assumes four platform-specific constants. To retarget
to different RV32I hardware, edit these where they appear and rebuild:

| Constant | Current value | Meaning | Files that need editing |
|---|---|---|---|
| UART base | `0x10000000` | MMIO base of a 16550-compatible UART | `src/fam0.S`, `src/fam1.S`, `src/fam2.S`, `src/fam3.S`, `src/famc.fam3` |
| Buffer base | `0x80100000` | Where fam0 parks its hex-decode output buffer | `src/fam0.S` |
| Shutdown address | `0x00100000` | MMIO base of the SiFive test finisher device | `src/fam0.S`, `src/fam1.S`, `src/fam2.S`, `src/fam3.S`, `src/famc.fam3` |
| Shutdown value | `0x5555` | Value written to the finisher to signal "pass + halt" | `src/fam0.S`, `src/fam1.S`, `src/fam2.S`, `src/fam3.S`, `src/famc.fam3` |

In each `.S` file, the constants appear as literals in `li`, `lui`, or
`addi` operands near the top (`_start` block) and near the bottom
(poweroff sequence). In `src/famc.fam3` they appear twice: once in the
compiler's own UART setup (`lui s6, 0x10000`), and once inside the panic
handler that famc emits into every program it produces (`lui a0, 0x10000`
and the poweroff sequence).

The `.famN` hex-encoded sources under `src/` are generated from the
corresponding `.S` files via `tools/s2fam0`, `tools/s2fam1`, and
`tools/s2fam2`. After editing the `.S` files, regenerate the hex sources
before running `build.sh`:

```sh
tools/s2fam0 src/fam0.S  > src/fam0.fam0
tools/s2fam1 src/fam1.S  > src/fam1.fam0
tools/s2fam2 src/fam2.S  > src/fam2.fam1
tools/s2fam2 src/fam3.S  > src/fam3.fam2
```

`src/famc.fam3` is hand-maintained in fam3 syntax and is read directly by
`bin/fam3` — no intermediate file to regenerate.

**Caveats**: This constant-swapping procedure assumes the target UART is
16550-compatible (RX data at offset 0, LSR at offset 5, data-ready at bit
0, THRE at bit 5) and that the platform exposes a SiFive-style test
finisher. Real hardware with a non-16550 UART (e.g., SiFive FE310) or no
test finisher requires rewriting the UART polling code and the poweroff
sequence — a deeper port than just changing constants.

## Tools

- `tools/famc` — compiler wrapper (feeds `.fam` source to `bin/famc` under QEMU)
- `tools/fam3` — fam3 wrapper (feeds `.fam3` source to `bin/fam3` under QEMU)
- `tools/q32` — QEMU runner for compiled RV32I binaries (checks magic byte)
- `tools/no-jalr` — verifier that a binary contains no `jalr` instructions
- `tools/s2fam0`, `tools/s2fam1`, `tools/s2fam2` — regenerate hex-format
  bootstrap sources from `.S` reference files (GNU `as` required)
- `tools/fmt_fam.py` — source formatter for `.fam` files
- `tools/fmt_asm.py` — source formatter for `.fam3` files
- `.ci/runtests` — test suite (592 tests)

## Tests

```sh
.ci/runtests              # run all tests
.ci/runtests --verbose    # show individual pass / fail output
```

Covers: variables, arithmetic, bitwise, comparisons, short-circuit,
ternary, blocks, loops, for-loops, break/continue, functions, recursion,
structs, struct arrays, sizeof, pointer ops, macros (including hygiene
and edge cases), inline assembly, compile-time errors, and a handful of
semantic-invariant tests that pin down behavior any future codegen
refactor must preserve.

## License

MIT. See [LICENSE](LICENSE).

# The binary program image

`src/core/program_image.zig` (plan P10.4, P10.5) writes a `Program` as a binary image and
loads it back without parsing. A Program holds only indices into its own arrays, never
pointers, so its arrays are the whole program. Writing one writes the arrays, and loading
copies and checks them. Only the string table's hash index is rebuilt.

```text
program_image.write(&program, writer)      // the image, deterministic
program_image.load(gpa, bytes) !Program    // checked; the bytes are copied
program_image.image_bytes(&program)        // the size write produces
```

A typical use: compile ink, or load inklecate's JSON, at build time, and write the image.
At run time, load the image instead of the JSON.

| Story | JSON | Image | `ink_json.load` | `program_image.load` |
|---|---:|---:|---:|---:|
| crime_scene | 26,635 B | 39,536 B | 389 µs | 63 µs |
| generated (1000 knots) | 378,714 B | 505,080 B | 5,605 µs | 764 µs |

Both load times include `Story.init` with fitted limits. They come from `zig build bench`
in ReleaseSafe, where the image loads 6–7× faster than the JSON. Images are larger than the
JSON: arrays of 4-byte indices, against short decimal text with shared names.

## Format, version 1

All integers are little-endian. A big-endian host gets `error.UnsupportedEndianness`.

**Header** (40 bytes):

| Offset | Field | Value |
|---:|---|---|
| 0 | magic | the 8 bytes `INKZPROG` |
| 8 | format version | 1 |
| 12 | endianness word | `0x01020304` |
| 16 | ink version | `Program.ink_version` |
| 20 | global declaration | a container index, or `0xFFFFFFFF` for none |
| 24 | count slots | `Program.count_slots_count` |
| 28 | newline | the string id of `"\n"` |
| 32 | sections count | 22 |
| 36 | reserved | 0 |

**Section table**: for each section, in the order below, two u32 values: the element size in
bytes and the element count. A reader rejects a size that differs from its own
(`error.SectionLayoutMismatch`).

**Sections**, each padded with zeros to a multiple of 8 bytes:

| # | Section | Element |
|---:|---|---|
| 0 | string bytes | u8 |
| 1 | string ends: one past each string's last byte; string 0 is `""` | u32 |
| 2 | instruction opcodes | u8 |
| 3 | instruction operands | u32 |
| 4 | extra words (operands too large for one word) | u32 |
| 5–16 | container columns: `instruction_first`, `instruction_count`, `parent`, `index_in_parent`, `depth` (u16), `flags` (u8), `name`, `path`, `path_hash`, `named_first`, `named_count`, `count_slot` | u32 unless noted |
| 17 | named entries: name, child | 8 B |
| 18 | globals: name | 4 B |
| 19 | list origins: name, items_first, items_count | 12 B |
| 20 | list items: origin, name, full name, value | 16 B |
| 21 | externals: name, fallback | 8 B |

The image must end exactly after the last section's padding.

## Loading untrusted images

`load` never trusts its input. An image that is not one returns a named error:
`NotAProgramImage`, `UnsupportedFormatVersion`, `UnsupportedEndianness`,
`SectionLayoutMismatch`, `ImageTruncated` or `InvalidImage`. It never crashes. It checks, in
order:

1. The header, the section table and every section's bounds.
2. The raw sections:
   - every opcode byte names an opcode;
   - container flags use only their three bits;
   - the instruction columns and the container columns each have one length;
   - there is at least one container.
3. The string ends: string 0 is empty, ends never decrease, and the last end is the byte
   count. When the hash index is rebuilt, no two strings may be equal.
4. Every string id and index range, in 64-bit arithmetic. Indices that must exist must not
   be `none`.
5. `Program.check`: the container tree, the instruction partition, every operand and the list
   and external tables. Extra words must also decode: bools are 0 or 1, and closed enums
   name a value.

A test truncates an image at every length and sets every byte to 0x00, to 0xff and to
itself plus one; each load gives a valid program or a named error.

`zig build fuzz` has two loader targets. One takes raw bytes; random bytes rarely pass the
magic, so its 200,000-input run (`zig build fuzz --fuzz=200K`) reached only 28 coverage
points. The other (P10.7) starts from a valid image of a story with every kind of section
and lets the fuzzer overwrite aligned words, set bytes, flip bits and truncate. Its inputs
pass the header and reach the section, string, reference and `Program.check` validation:
318,000 inputs reached 1,173 points (of 16,905 in the whole test binary), with no crash.

## Changing the format

Change the format only together with `format_version`. A reader accepts only its own version.
An image is a cache of the JSON or the source, so a mismatch means rebuilding the image, not
converting it.

# Minipedia creates highly compressed enwiki dumps

These dumps are in a bespoke file format

Integer values are big endian

### Prelude
1. Magic Bytes = "MINIPEDIA"
2. File Format Version = u64
3. HeaderStart = u64 (From the start of the file)

### Header
1. Block Offset Array size `u32`
2. Block ID Map size `u32`
3. Block Offset Array (`[]const u64`). The start of block `i` is at index `i` of this array
4. Block ID Map (`[]const u16`).

Estimated Header Overhead: `15MB`

There will not be more than 65536 blocks, so the offset array can be at most `65536 * 8 == 524288` bytes.
65536 is a safe limit and also allows indexing with `u16`

There will not be more than 7,000,000 articles, to the Block ID Map can be at most `14_000_000` bytes.

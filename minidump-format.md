# Minidump File Format

Minipedia creates highly compressed enwiki dumps

These dumps are in a bespoke file format

*Integer values are big endian*


### Prelude
1. Magic Bytes = "MINIDUMP"
2. File Format Version = u64
3. HeaderStart = u64 (From the start of the file)


### Header
1. Block Offset Array size `u64`
2. Block ID Map size `u64`
3. Block Offset Array (`[]const u64`). The start of block `i` is at index `i` of this array
4. Block ID Map (`[]const u16`).

Estimated Header Overhead: `15MB`

There will not be more than 65536 blocks, so the offset array can be at most `65_536 * @sizeOf(u64) == 524_288` bytes.
65536 is a safe limit and also allows indexing with `u16`

There will not be more than 7,000,000 articles, to the Block ID Map can be at most `7_000_000 * @sizeOf(u16) = 14_000_000` bytes.


### Block Format
- Limited to known size, 1MB
1. article_id: `u64`
2. article_content: `[]const u8`
3. null byte: `\0`


### Lookup an Article with it's ID
1. Get the block_id where the article is located from block_id_map
2. Get the start of that block from the block offset array
3. Scan that block for `\0[article_id_bytes_big_endian]`. The article content follows that series of bytes until the next `\0`.


package zlib

import "core:fmt"
import "core:mem"
import "core:os"
import "core:hash"

@private
_zlib_err :: proc(test: bool, message: string, loc := #caller_location) -> bool
{
    if test {
        fmt.eprintf("%#v: ERROR: %s\n", loc, message);
        os.exit(1);
    }
    
    return test;
}

Huffman :: struct
{
    codes: []u32,
    lengths: []u8,
}

Buffer :: struct
{
    cmf: byte,
    extra_flags: byte,
    check_value: u16,

    data: []byte,
    DEBUG: bool,
    bit_buffer: u32,
    bits_remaining: u32,
    
    huff_lit: Huffman,
    huff_dist: Huffman,
    out: [dynamic]byte,
}

@private
_read_sized :: proc (file: ^[]byte, $T: typeid, loc := #caller_location) -> T
{
    if len(file^) < size_of(T)
    {
        fmt.eprintf("%#v: Expected %v, got EOF\n", loc, typeid_of(T));
        return T(0);
    }
    
    ret := ((^T)(&file[0]))^;
    file^ = file[size_of(T):];

    return ret;
}

read_block :: proc(data: []byte) -> Buffer
{
    data := data;
    
    z_buff := Buffer{};
    z_buff.cmf = _read_sized(&data, byte);
    z_buff.extra_flags = _read_sized(&data, byte);
 
    z_buff.data = make([]byte, len(data)-4);
    copy(z_buff.data, data);
    
    z_buff.check_value = u16(_read_sized(&data, u16be));

    z_buff.bit_buffer = 0;
    z_buff.bits_remaining = 0;

    return z_buff;
}

 
load_bits :: proc(using z_buff: ^Buffer, req: u32, loc := #caller_location)
{
    bits_to_read := req - bits_remaining;
    bytes_to_read := bits_to_read/8;
    if bits_to_read%8 != 0 do
        bytes_to_read += 1;
 
    for i in 0..<(bytes_to_read)
    {
        new_byte := u32(_read_sized(&data, byte, loc));
        bit_buffer |= new_byte << (i*8 + bits_remaining);
    }
 
    bits_remaining += bytes_to_read * 8;
}

read_bits :: proc(using z_buff: ^Buffer, size: u32) -> u32
{
    res := u32(0);
 
    if size > bits_remaining do
        load_bits(z_buff, size);
 
    for i in 0..<(size)
    {
        bit := u32(bit_buffer & (1 << i));
        res |= bit;
    }
 
    bit_buffer >>= size;
    bits_remaining -= size;

    return res;
}
 
_get_max_bit_length :: proc(lengths: []byte) -> byte
{
    max_length := byte(0);
    for l in lengths do
        max_length = max(max_length, l);
    return max_length;
}
 
_get_bit_length_count :: proc(counts: []u32, lengths: []byte, max_length: byte)
{
    for l in lengths do
        counts[l] += 1;
    counts[0] = 0;

    for i in 1..<(max_length)
    {
        if _zlib_err(counts[i] > (1 << i), "Bad Sizes")
        do return;
    }
}
 
_first_code_for_bitlen :: proc(first_codes: []u32, counts: []u32, max_length: byte)
{
    code := u32(0);
    counts[0] = 0;
    for bits in 1 ..(max_length)
    {
        code = (code + counts[bits-1]) << 1;
        first_codes[bits] = code;
    }
}
 
_assign_huffman_codes :: proc(assigned_codes: []u32, first_codes: []u32, lengths: []byte)
{
    for _, i in assigned_codes
    {
        if lengths[i] > 0
        {
            assigned_codes[i] = first_codes[lengths[i]];
            first_codes[lengths[i]] += 1;
        }
    }
}

_build_huffman_code :: proc(lengths: []byte) -> Huffman
{

    huff := Huffman{};
    huff.lengths = lengths;
    
    max_length := _get_max_bit_length(lengths);
 
    counts         := make([]u32, max_length+1);
    first_codes    := make([]u32, max_length+1);
    assigned_codes := make([]u32, len(lengths));
 
    _get_bit_length_count(counts, lengths, max_length);
    _first_code_for_bitlen(first_codes, counts, max_length);
    _assign_huffman_codes(assigned_codes, first_codes, lengths);

    delete(counts);
    delete(first_codes);
    
    huff.codes = assigned_codes;
    
    return huff;
}
 
_peek_bits_reverse :: proc(using z_buff: ^Buffer, size: u32, loc := #caller_location) -> u32
{
    if size > bits_remaining do
        load_bits(z_buff, size, loc);
    res := u32(0);
    for i in 0..<(size)
    {
        res <<= 1;
        bit := u32(bit_buffer & (1 << i));
        res |= (bit > 0) ? 1 : 0;
    }

    return res;
}
 
_decode_huffman :: proc(using z_buff: ^Buffer, using huff: Huffman, loc := #caller_location) -> u32
{
    for _, i in codes
    {
        if lengths[i] == 0 do continue;
        if u32(lengths[i]) > bits_remaining + u32(len(data)*8) do continue; // Not enough bits
        code := _peek_bits_reverse(z_buff, u32(lengths[i]), loc);
        if codes[i] == code
        {
            bit_buffer >>= lengths[i];
            bits_remaining -= u32(lengths[i]);
            return u32(i);
        }
    }
    return 0;
}
 
@static HUFFMAN_ALPHABET :=
    [?]u32{16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15};
 
@static length_extra_bits := [?]u8{
    0, 0, 0, 0, 0, 0, 0, 0, //257 - 264
    1, 1, 1, 1, //265 - 268
    2, 2, 2, 2, //269 - 273
    3, 3, 3, 3, //274 - 276
    4, 4, 4, 4, //278 - 280
    5, 5, 5, 5, //281 - 284
    0,          //285
};
 
@static base_lengths := [?]u32{
    3, 4, 5, 6, 7, 8, 9, 10, //257 - 264
    11, 13, 15, 17,          //265 - 268
    19, 23, 27, 31,          //269 - 273
    35, 43, 51, 59,          //274 - 276
    67, 83, 99, 115,         //278 - 280
    131, 163, 195, 227,      //281 - 284
    258                      //285
};
 
@static base_dists := [?]u32{
    /*0*/  1,     2, 3, 4, //0-3
    /*1*/  5,     7,       //4-5
    /*2*/  9,     13,      //6-7
    /*3*/  17,    25,      //8-9
    /*4*/  33,    49,      //10-11
    /*5*/  65,    97,      //12-13
    /*6*/  129,   193,     //14-15
    /*7*/  257,   385,     //16-17
    /*8*/  513,   769,     //18-19
    /*9*/  1025,  1537,    //20-21
    /*10*/ 2049,  3073,    //22-23
    /*11*/ 4097,  6145,    //24-25
    /*12*/ 8193,  12289,   //26-27
    /*13*/ 16385, 24577,   //28-29
           0,     0        //30-31, error, shouldn't occur
};
 
@static dist_extra_bits := [?]u32{
    /*0*/  0, 0, 0, 0, //0-3
    /*1*/  1, 1,       //4-5
    /*2*/  2, 2,       //6-7
    /*3*/  3, 3,       //8-9
    /*4*/  4, 4,       //10-11
    /*5*/  5, 5,       //12-13
    /*6*/  6, 6,       //14-15
    /*7*/  7, 7,       //16-17
    /*8*/  8, 8,       //18-19
    /*9*/  9, 9,       //20-21
    /*10*/ 10, 10,     //22-23
    /*11*/ 11, 11,     //24-25
    /*12*/ 12, 12,     //26-27
    /*13*/ 13, 13,     //28-29
           0,  0       //30-31 error, they shouldn't occur
};

@static default_huff_len := [?]byte
{
    0  ..<144 = 8,
    144..<256 = 9,
    256..<280 = 7,
    280..<288 = 8,
};

@static default_huff_dist := [?]byte
{
    0..<32 = 5,
};

deflate :: proc(using z_buff: ^Buffer)
{
    // decompressed_data := make([dynamic]byte, 0, 1024*1024); // 1MiB
    for
    {
        decoded_value := _decode_huffman(z_buff, huff_lit);
        if decoded_value == 256 do break;
        if decoded_value < 256
        {
            append(&out, byte(decoded_value));
            continue;
        }
 
        if 256 < decoded_value && decoded_value < 286
        {
            base_index := decoded_value - 257;
            duplicate_length := u32(base_lengths[base_index]) + read_bits(z_buff, u32(length_extra_bits[base_index]));
 
            distance_index := _decode_huffman(z_buff, huff_dist);
            distance_length := base_dists[distance_index] + read_bits(z_buff, dist_extra_bits[distance_index]);

            back_pointer_index := u32(len(out)) - distance_length;
            for duplicate_length > 0
            {
                /* if DEBUG do */
                /*     fmt.printf("Decoded Value: %d\nDistance Length: %d\nBack Pointer: %d\n\n", */
                /*                decoded_value, distance_length, back_pointer_index); */
                append(&out, out[back_pointer_index]);
                back_pointer_index += 1;
                duplicate_length   -= 1;
            }
        }
    }
 
    // append(&out, ..decompressed_data[:]);
    // delete(decompressed_data);
}

compute_huffman :: proc(using z_buff: ^Buffer)
{
    hlit  := u32(read_bits(z_buff, 5)) + 257;
    hdist := u32(read_bits(z_buff, 5)) + 1;
    hclen := u32(read_bits(z_buff, 4)) + 4;
    
    huff_clen_lens := [19]byte{};
    
    for i in 0..<(hclen) do
        huff_clen_lens[HUFFMAN_ALPHABET[i]] = byte(read_bits(z_buff, 3));
    
    huff_clen := _build_huffman_code(huff_clen_lens[:]);
    huff_lit_dist_lens := make([]byte, hlit+hdist);

    code_index := u32(0);
    for code_index < u32(len(huff_lit_dist_lens))
    {
        decoded_value := _decode_huffman(z_buff, huff_clen);
        if _zlib_err(decoded_value < 0 || decoded_value > 18, "Bad codelengths")
        do return;
        if decoded_value < 16
        {
            huff_lit_dist_lens[code_index] = byte(decoded_value);
            code_index += 1;
            continue;
        }
        
        repeat_count := u32(0);
        code_length_to_repeat := byte(0);
        
        switch decoded_value
        {
        case 16:
            repeat_count = read_bits(z_buff, 2) + 3;
            if _zlib_err(code_index == 0, "Bad codelengths") do return;
            code_length_to_repeat = huff_lit_dist_lens[code_index - 1];
        case 17:
            repeat_count = read_bits(z_buff, 3) + 3;
        case 18:
            repeat_count = read_bits(z_buff, 7) + 11;
        }

        if _zlib_err(hlit+hdist - code_index < repeat_count, "Bad codelengths")
        do return;
        
        mem.set(&huff_lit_dist_lens[code_index], code_length_to_repeat, int(repeat_count));
        code_index += repeat_count;
    }

    if _zlib_err(code_index != hlit+hdist, "Bad codelengths")
    do return;

    huff_lit  = _build_huffman_code(huff_lit_dist_lens[:hlit]);
    huff_dist = _build_huffman_code(huff_lit_dist_lens[hlit:]);
}

decompress :: proc(using z_buff: ^Buffer)
{
    final := false;
    type: u32;
    out = make([dynamic]byte);

    for !final
    {
        load_bits(z_buff, 8);
        final = bool(read_bits(z_buff, 1));
        type  = read_bits(z_buff, 2);
        /* if DEBUG do */
        /*     fmt.printf("TYPE: %d\n", type); */

        if type == 0
        {
            uncompressed(z_buff);
        }
        else
        {
            if type == 1 // Fixed Huffman
            {
                z_buff.huff_lit  = _build_huffman_code(default_huff_len[:]);
                z_buff.huff_dist = _build_huffman_code(default_huff_dist[:]);
            }
            else // Computed Huffman
            {
                compute_huffman(z_buff);
            }
            deflate(z_buff);
        }
    }
}

@private
uncompressed :: proc(using z_buff: ^Buffer)
{
    header := [4]byte{};
    if bits_remaining & 7 > 0 do
        read_bits(z_buff, bits_remaining & 7); // Discard

    for _, i in header do
        header[i] = u8(read_bits(z_buff, 8));
    assert(bits_remaining == 0);

    length  := u32(header[1]) * 256 + u32(header[0]);
    nlength := u32(header[3]) * 256 + u32(header[2]);
    if _zlib_err(nlength != (length ~ 0xffff), "Corrupt Zlib") ||
        _zlib_err(length > u32(len(data)), "Read past buffer")
    do return;

    append(&out, ..data[:length]);
    data = data[length:];
}

@private
count_matching :: proc(data, datb: []byte) -> u32
{
    i := u32(0);
    for i < u32(min(len(data), len(datb))) && i < 257
    {
        if data[i] != datb[i] do
            break;
        i += 1;
    }
    return i;
}

@private
Ring_Buffer :: struct(Value: typeid)
{
    buff:  []Value,
    idx:   u32,
    count: u32,
}

@private
ring_push :: proc(using ring: ^Ring_Buffer($T), val: T)
{
    buff[idx] = val;
    idx += 1;
    
    if count < u32(len(buff)) do
        count += 1;
    if idx >= u32(len(buff)) do
        idx = 0;
}

@private
make_ring :: proc($Value: typeid, size: u32) -> (ring: Ring_Buffer(Value))
{
    ring.buff = make([]Value, size);
    return ring;
}

@private
delete_ring :: proc(using ring: ^Ring_Buffer($T))
{
    delete(buff);
    idx = 0;
    count = 0;
}

@private
push_huffman_code :: proc(buffer: ^Bit_String, length, dist: u32, huff_lit, huff_dist: Huffman)
{
    length_code, dist_code: u32;
    for length > base_lengths[length_code+1]-1 do
        length_code += 1;
    for dist > base_dists[dist_code+1]-1 do
        dist_code += 1;

    length_eb := u32(length_extra_bits[length_code]);
    dist_eb := u32(dist_extra_bits[dist_code]);

    encode_huffman(buffer, length_code+257, huff_lit);
    if length_eb > 0 do
        bits_append(buffer, length - base_lengths[length_code], length_eb);

    encode_huffman(buffer, dist_code, huff_dist);
    if dist_eb > 0 do
        bits_append(buffer, dist - base_dists[dist_code], dist_eb);
    
}

@private
encode_huffman :: proc(buffer: ^Bit_String, val: u32, using huff: Huffman)
{
    bits_append_reverse(buffer, codes[val], u32(lengths[val]));
}

compress :: proc(data: []byte, level: u32) -> []byte
{
    buffer := Bit_String{};
    buffer.buffer = make([dynamic]byte);
    
    hashtable: map[u32]Ring_Buffer([]byte);

    bits_append(&buffer, u8(0x78));
    bits_append(&buffer, u8(0x5e));
    bits_append(&buffer, 1, 1);
    bits_append(&buffer, 1, 2);

    huff_lit := _build_huffman_code(default_huff_len[:]);
    huff_dist := _build_huffman_code(default_huff_dist[:]);
    
    i := u32(0);
    best_repeat: u32;
    jump_to: []byte;
    for i < u32(len(data)) - 3
    {
        best_repeat = 3;
        jump_to = nil;
        
        key := (^u32)(&data[i])^ & 0x00ff_ffff;
        matches := hashtable[key];
        if hashtable[key].buff == nil do
            hashtable[key] = make_ring([]byte, level*2);

        // Find best jump location
        for _, j in 0..<(hashtable[key].count)
        {
            match := hashtable[key].buff[j];
            if mem.ptr_sub(&data[i], &match[0]) < 32768
            {
                repeat := count_matching(match, data[i:]);
                if repeat >= best_repeat
                {
                    best_repeat = repeat;
                    jump_to = match;
                }
            }
        }

        // Push new match to ring buffer
        ring := hashtable[key];
        ring_push(&ring, data[i:]);
        hashtable[key] = ring;

        if jump_to != nil // If we found a match, encode it
        {
            distance := mem.ptr_sub(&data[i], &jump_to[0]);
            push_huffman_code(&buffer, best_repeat, u32(distance), huff_lit, huff_dist);
            i += best_repeat;
        }
        else // else, push the current byte
        {
            encode_huffman(&buffer, u32(data[i]), huff_lit);
            i += 1;
        }
    }

    // encode the remainder
    for i < u32(len(data))
    {
        encode_huffman(&buffer, u32(data[i]), huff_lit);
        i += 1;
    }

    // End of block
    encode_huffman(&buffer, 256, huff_lit);
    bits_next_byte(&buffer);

    for _, ring in hashtable
    {
        if ring.buff != nil
        {
            r := ring;
            delete_ring(&r);
        }
    }

    checksum := adler32(data[:]);
    bits_append(&buffer, u32(checksum));

    out := make([]byte, len(buffer.buffer));
    copy(out, buffer.buffer[:]);
    delete(buffer.buffer);
    
    return out;
}

@private
adler32 :: proc(data: []byte) -> u32
{
    A, B: u32;
    A = 1;

    for D in data
    {
        A = (A + u32(D)) % 65521;
        B = (B + A)      % 65521;
    }
    
    return (B << 16) + A;
}

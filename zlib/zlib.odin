package zlib

import "core:fmt"
import "core:mem"

@private
_zlib_err :: proc(test: bool, message: string, loc := #caller_location) -> bool
{
    if test do
        fmt.eprintf("%#v: ERROR: %s\n", loc, message);

    return test;
}

Buffer :: struct
{
    cmf: byte,
    extra_flags: byte,
    check_value: u16,

    data: []byte,
    bit_buffer: u32,
    bits_remaining: u32,
    
    huff_lit: []u32,
    huff_dist: []u32,
    huff_lit_lens: []u8,
    huff_dist_lens: []u8,
    out: [dynamic]byte,
}

@private
_read_sized :: proc (file: ^[]byte, $T: typeid) -> T
{
    if len(file^) < size_of(T)
    {
        fmt.eprintf("Expected %T, got EOF\n", typeid_of(T));
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

 
load_bits :: proc(using z_buff: ^Buffer, req: u32)
{
    bits_to_read := req - bits_remaining;
    bytes_to_read := bits_to_read/8;
    if bits_to_read%8 != 0 do
        bytes_to_read += 1;
 
    for i in 0..<(bytes_to_read)
    {
        new_byte := u32(_read_sized(&data, byte));
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

_build_huffman_code :: proc(lengths: []byte) -> []u32
{
    max_length := _get_max_bit_length(lengths);
 
    counts         := make([]u32, max_length+1);
    first_codes    := make([]u32, max_length+1);
    assigned_codes := make([]u32, len(lengths));
 
    _get_bit_length_count(counts, lengths, max_length);
    _first_code_for_bitlen(first_codes, counts, max_length);
    _assign_huffman_codes(assigned_codes, first_codes, lengths);

    return assigned_codes;
}
 
_peek_bits_reverse :: proc(using z_buff: ^Buffer, size: u32) -> u32
{
    if size > bits_remaining do
        load_bits(z_buff, size);
    res := u32(0);
    for i in 0..<(size)
    {
        res <<= 1;
        bit := u32(bit_buffer & (1 << i));
        res |= (bit > 0) ? 1 : 0;
    }

    return res;
}
 
_decode_huffman :: proc(using z_buff: ^Buffer, codes: []u32, lengths: []byte) -> u32
{
    for _, i in codes
    {
        if lengths[i] == 0 do continue;
        code := _peek_bits_reverse(z_buff, u32(lengths[i]));
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
 
@static base_length_extra_bit := [?]u8{
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
 
@static dist_bases := [?]u32{
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
   8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8, 8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,
   8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8, 8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,
   8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8, 8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,
   8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8, 8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,
   8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8, 9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,
   9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9, 9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,
   9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9, 9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,
   9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9, 9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,
   7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7, 7,7,7,7,7,7,7,7,8,8,8,8,8,8,8,8
};

@static default_huff_dist := [?]byte
{
   5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5
};

deflate :: proc(using z_buff: ^Buffer)
{
    decompressed_data := make([]byte, 1024*1024); // 1MiB
    data_index := u32(0);
    for
    {
        decoded_value := _decode_huffman(z_buff, huff_lit, huff_lit_lens);

        if decoded_value == 256 do break;
        if decoded_value < 256
        {
            decompressed_data[data_index] = byte(decoded_value);
            data_index += 1;
            continue;
        }
 
        if 256 < decoded_value && decoded_value < 286
        {
            base_index := decoded_value - 257;
            duplicate_length := u32(base_lengths[base_index]) + read_bits(z_buff, u32(base_length_extra_bit[base_index]));
 
            distance_index := _decode_huffman(z_buff, huff_dist, huff_dist_lens);
            distance_length := dist_bases[distance_index] + read_bits(z_buff, dist_extra_bits[distance_index]);

            back_pointer_index := data_index - distance_length;
            for duplicate_length > 0
            {
                decompressed_data[data_index] = decompressed_data[back_pointer_index];
                data_index         += 1;
                back_pointer_index += 1;
                duplicate_length   -= 1;
            }
        }
    }
 
    bytes_read := data_index;
 
    append(&out, ..decompressed_data[:bytes_read]);
    delete(decompressed_data);
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
        decoded_value := _decode_huffman(z_buff, huff_clen, huff_clen_lens[:]);
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

    huff_lit_lens = huff_lit_dist_lens[:hlit];
    huff_dist_lens = huff_lit_dist_lens[hlit:];
    
    huff_lit  = _build_huffman_code(huff_lit_lens);
    huff_dist = _build_huffman_code(huff_dist_lens);
}

decompress :: proc(using z_buff: ^Buffer)
{
    final := false;
    type: u32;
    out = make([dynamic]byte);

    for !final
    {
        final = bool(read_bits(z_buff, 1));
        type  = read_bits(z_buff, 2);

        if type == 0
        {
            uncompressed(z_buff);
        }
        else
        {
            if type == 1 // Fixed Huffman
            {
                z_buff.huff_lit_lens  = default_huff_len[:];
                z_buff.huff_dist_lens = default_huff_dist[:];
                z_buff.huff_lit = _build_huffman_code(z_buff.huff_lit_lens);
                z_buff.huff_dist = _build_huffman_code(z_buff.huff_dist_lens);
            }
            else // Computed Huffman
            {
                compute_huffman(z_buff);
            }
            deflate(z_buff);
        }
    }
}

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

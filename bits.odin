package image

import "core:intrinsics"
import "core:fmt"
import "core:os"

Bit_String :: struct
{
    buffer: [dynamic]byte,
    bytei: u32,
    biti:  u32,
}

bit_slice :: proc(val: $T, shift, size: u32) -> T where intrinsics.type_is_integer(T)
{
    assert(size_of(T)*8 > shift && size_of(T)*8 >= size);
    size_mask := T((1 << size) - 1);
    return T((val >> shift) & size_mask);
}

bits_append_bits :: proc(using str: ^Bit_String, val: $T, bitn: u32, loc := #caller_location) where intrinsics.type_is_integer(T)
{
    to_write := bitn;
    for to_write > 0
    {
        size := min(8-biti, to_write);
        if biti > 0 
        {
            buffer[bytei] |= byte(bit_slice(val, bitn-to_write, size) << biti);
        }
        else 
        {
            append(&buffer, byte(bit_slice(val, bitn-to_write, size)));
        }

        biti += size;
        if biti > 7
        {
            bytei += 1;
            biti = 0;
        }

        to_write -= size;
    }
    assert(to_write == 0);
}

bits_append_bytes :: proc(using str: ^Bit_String, val: $T, loc := #caller_location) where intrinsics.type_is_integer(T)
{
    for i in 0..<size_of(T) 
    {
        bits_append_bits(str, byte(val >> (u32(size_of(T)-i-1)*8)), 8, loc);
    }
}

bits_append_slice :: proc(using str: ^Bit_String, bytes: []byte, loc := #caller_location)
{
    for b in bytes 
    {
        bits_append_bits(str, b, 8, loc);
    }
}

bits_append :: proc{bits_append_bits, bits_append_bytes, bits_append_slice};

bits_append_byte :: proc(using str: ^Bit_String, val: byte)
{
    bits_next_byte(str);
    append(&buffer, val);
}

bits_next_byte :: proc(using str: ^Bit_String)
{
    if biti > 0 
    {
        bits_append(str, 0, 8-biti);
    }
}

bit_slice_reverse :: proc(val: $T, offset, size: u32) -> T where intrinsics.type_is_integer(T)
{
    res := T(0);

    sshift := offset + size-1;
    dshift := u32(0);
    for sshift >= offset
    {
        res |= (val >> sshift & 1) << dshift;
        if sshift == 0 do break;
        sshift -= 1;
        dshift += 1;
    }

    return res;
}

bits_append_reverse :: proc(using str: ^Bit_String, val: $T, bitn: u32, loc := #caller_location) where intrinsics.type_is_integer(T)
{
    reversed := bit_slice_reverse(val, 0, bitn);
    bits_append(str, reversed, bitn, loc);
}

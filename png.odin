package image

import "core:fmt"
import "core:mem"
import "core:os"

import "zlib"

@private
png_err :: proc(test: bool, file, message: string, loc := #caller_location) -> bool
{
    if test do
        fmt.eprintf("%#v: ERROR: %s: %s\n", loc, file, message);
    
    return test;
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

IHDR :: 0x49484452;
PLTE :: 0x504c5445;
IDAT :: 0x49444154;
IEND :: 0x49454e44;

cHRM :: 0x6348524d;
gAMA :: 0x67414d41;
sBIT :: 0x73424954;
sRGB :: 0x73524742;
bKGD :: 0x624b4744;
hIST :: 0x68495354;
tRNS :: 0x74524e53;
pHYs :: 0x70485973;
sPLT :: 0x73504c54;
tIME :: 0x74494d45;
iTXt :: 0x69545874;
tEXt :: 0x74455874;
zTXt :: 0x7a545874;

PNG :: struct
{
    filepath      : string,
    width, height : u32,
    depth         : byte,
    color         : byte,
    palette       : [256][4]byte,
    pal_len       : u32,
    has_trans     : bool,
    comp, filter  : byte,
    components    : u32,
    out_components: u32,
    pal_components: u32,
    interlace     : byte,
    data          : [dynamic]byte,
    out           : []byte,
}

Chunk :: struct
{
    size:  u32,
    type:  u32,
    data:  []byte,
    crc32: u32,
}
 
Filter :: enum
{
    None,
    Sub,
    Up,
    Avg,
    Paeth,
}

test_png :: proc(filepath: string) -> bool
{
    file, ok := os.read_entire_file(filepath);
    if !ok
    {
        fmt.eprintf("Could not open file %s\n", filepath);
        return false;
    }
    signature := _read_sized(&file, u64);

    if len(file) < 8 || signature != 0xa1a0a0d474e5089 do
        return false;

    return true;
}

load_png :: proc(filepath: string) -> (image: Image)
{
    image = Image{};
    
    file, ok := os.read_entire_file(filepath);
    if png_err(!ok, filepath, "Could not open file") ||
        png_err(len(file) < 8, filepath, "Invalid PNG file")
    do return;

    signature := _read_sized(&file, u64);

    if png_err(signature != 0xa1a0a0d474e5089, filepath, "Invalid PNG signature")
    do return;
    
    trns   := [3]byte{};
    trns16 := [3]u16{};

    p := PNG{};
    p.filepath = filepath;
    first := true;
    loop: for
    {
        chunk := read_chunk(&file);
        chars := transmute([4]byte)chunk.type;
        data_save := chunk.data;
        
        switch chunk.type
        {
        case IHDR:
            if png_err(!first, filepath, "Multiple IHDR") ||
               png_err(chunk.size != 13, filepath, "Invalid IHDR length")
            do return;

            p.width     = u32(_read_sized(&chunk.data, u32be));
            p.height    = u32(_read_sized(&chunk.data, u32be));
            p.depth     = _read_sized(&chunk.data, byte);
            p.color     = _read_sized(&chunk.data, byte);
            p.comp      = _read_sized(&chunk.data, byte);
            p.filter    = _read_sized(&chunk.data, byte);
            p.interlace = _read_sized(&chunk.data, byte);

            if png_err(p.color > 6, filepath, "Invalid color type") ||
               png_err(p.color == 1 || p.color == 5, filepath, "Invalid color type") ||
               png_err(p.color == 3 && p.depth == 16, filepath, "Invalid color type")
            do return;

            if p.color == 3 do p.pal_components = 3;

            switch p.color
            {
            case 0: p.components = 1;
            case 2: p.components = 3;
            case 4: p.components = 2;
            case 6: p.components = 4;
            }
            
            if p.pal_components == 0
            {
                p.components = (p.color & 2 != 0 ? 3 : 1) + (p.color & 4 != 0 ? 1 : 0);
            }
            else
            {
                p.components = 1; // palette index
                
                if png_err((1<<30) / p.width / 4 < p.height, filepath, "too large")
                do return;
            }

        case PLTE:
            if png_err(first, filepath, "First chunk not IHDR") ||
               png_err(chunk.size > 256*3, filepath, "Invalid PLTE")
            do return;

            p.pal_len = chunk.size / 3;
            if png_err(p.pal_len * 3 != chunk.size, filepath, "Invalid PLTE")
            do return;
            for i in 0..<(p.pal_len)
            {
                p.palette[i][0] = _read_sized(&chunk.data, byte);
                p.palette[i][1] = _read_sized(&chunk.data, byte);
                p.palette[i][2] = _read_sized(&chunk.data, byte);
                p.palette[i][3] = 255;
            }

        case tRNS:
            
            if png_err(first, filepath, "First chunk not IHDR") ||
               png_err(len(p.data) > 0, filepath, "tRNS after IDAT")
            do return;
            p.has_trans = true;
            if p.pal_components != 0
            {
                if png_err(p.pal_len == 0, filepath, "tRNS before PLTE") ||
                   png_err(chunk.size > p.pal_len, filepath, "Invalid tRNS")
                do return;

                p.pal_components = 4;
                for i in 0..<(chunk.size) do
                    p.palette[i][3] = _read_sized(&chunk.data, byte);
            }
            else
            {
                if png_err(~p.components & 1 != 0, filepath, "tRNS with alpha channel") ||
                   png_err(chunk.size != u32(p.components*2), filepath, "Invalid tRNS")
                do return;

                if p.depth == 16 do
                    for i in 0..<(p.components) do
                        trns16[i] = u16(_read_sized(&chunk.data, u16be));
                else do
                    for i in 0..<(p.components) do
                        trns[i] = byte(_read_sized(&chunk.data, u16be) & 255);
            }
            
        case IDAT:
            if png_err(first, filepath, "First chunk not IHDR") do
                return;

            if p.data == nil do
                p.data = make([dynamic]byte);

            append(&p.data, ..chunk.data);
        

        case IEND:
            if png_err(first, filepath, "First chunk not IHDR") ||
               png_err(len(p.data) == 0, filepath, "No IDAT")
            do return;

            z_buff := zlib.read_block(p.data[:]);
            zlib.decompress(&z_buff);
            if png_err(len(z_buff.out) == 0, filepath, "Error decompressing PNG")
            do return;
            
            delete(p.data);

            p.out_components = p.components;
            if p.has_trans do
                p.out_components += 1;
            
            p.out = create_png(&p, z_buff.out[:], u32(len(z_buff.out)));
            delete(z_buff.out);

            if p.has_trans
            {
                if p.depth == 16 do
                    compute_transparency16(&p, trns16);
                else do
                    compute_transparency8(&p, trns);
            }

            if p.pal_components > 0 do
                expand_palette(&p);

            break loop;

        case:
            if png_err(first, filepath, "first not IHDR")
            do return;
        }

        if first do first = false;
        
        delete(data_save);
    }

    image.format = .RGBA;
    switch p.out_components
    {
    case 1:
        image.format = .GRAY;
    case 2:
        image.format = .GRAYA;
    case 3:
        image.format = .RGB;
    case 4:
        image.format = .RGBA;
    }

    image.width  = p.width;
    image.height = p.height;
    image.depth  = u32(p.depth);

    image.data = make([]byte, len(p.out));
    copy(image.data, p.out);
    delete(p.out);

    image.flipped.y = true;
    
    return image;
}

@private
read_chunk :: proc(file: ^[]u8) -> Chunk
{
    chunk := Chunk{};

    chunk.size = u32(_read_sized(file, u32be));
    chunk.type = u32(_read_sized(file, u32be));
    
    chunk.data = make([]byte, chunk.size);
    copy(chunk.data, file^);
    file^ = file[chunk.size:];

    chunk.crc32 = u32(_read_sized(file, u32be));

    return chunk;
}

@private
create_png :: proc(p: ^PNG, data: []byte, raw_len: u32) -> []byte
{
    image: []byte;
    if p.interlace != 0 do
        image = deinterlace(p, data, raw_len);
    else do
        image = defilter(p, data, p.width, p.height);

    return image;
}

@private
paeth_predict :: proc(a, b, c: i32) -> i32
{
    p := a + b - c;
    pa := abs(p-a);
    pb := abs(p-b);
    pc := abs(p-c);

    if pa <= pb && pa <= pc do return a;
    if pb <= pc do return b;
    return c;
}


@private
deinterlace :: proc(p: ^PNG, data: []byte, size: u32) -> []byte
{
    data := data;
    
    bytes := u32(p.depth == 16 ? 2 : 1);
    out_bytes := p.out_components * bytes;
    deinterlaced := make([]byte, p.width*p.height*out_bytes);
    
    origin := [7][2]u32{
        {0, 0},
        {4, 0},
        {0, 4},
        {2, 0},
        {0, 2},
        {1, 0},
        {0, 1},
    };

    spacing := [7][2]u32{
        {8, 8},
        {8, 8},
        {4, 8},
        {4, 4},
        {2, 4},
        {2, 2},
        {1, 2},
    };
    
    for pass in 0..<(7)
    {
        // Number of pixels per-axis in this pass
        count_x := (p.width  - origin[pass].x + spacing[pass].x-1) / spacing[pass].x;
        count_y := (p.height - origin[pass].y + spacing[pass].y-1) / spacing[pass].y;

        if count_x != 0 && count_y != 0
        {
            sub_image_len := ((((u32(p.components) * count_x * u32(p.depth)) + 7) >> 3) + 1) * count_y;
            sub_image := defilter(p, data, count_x, count_y);
            
            for y in 0..<(count_y)
            {
                for x in 0..<(count_x)
                {
                    out_y := y * spacing[pass].y + origin[pass].y;
                    out_x := x * spacing[pass].x + origin[pass].x;
                    mem.copy(&deinterlaced[out_y*p.width*out_bytes + out_x*out_bytes],
                             &sub_image[(y*count_x + x)*out_bytes], int(out_bytes));
                }
            }
            
            data = data[sub_image_len:];
        }
    }

    return deinterlaced;
}

@private
defilter :: proc(p: ^PNG, data: []byte, x, y: u32) -> []byte
{
    x := x;
    y := y;
    
    bytes := u32(p.depth == 16 ? 2 : 1);
    bit_depth := u32(p.depth);
    pixel_depth := (bit_depth+7) >> 3;
    
    img_width_bytes := ((u32(p.components) * x * bit_depth) + 7) >> 3;
    img_len := (img_width_bytes + 1) * y;
    
    output_bytes := u32(p.out_components) * bytes;
    filter_bytes := p.components * bytes;

    prev_row: []byte;
    row := data;
    stride := x * filter_bytes;
    
    image := make([]byte, x*y*u32(output_bytes));
    working := image;
    for i in 0..<(y)
    {
        filter := Filter(row[0]);
        row = row[1:];
        off := i*x*output_bytes;
        
        if png_err(filter > .Paeth, p.filepath, "Invalid filter")
        {
            delete(image);
            return nil;
        }

        /* if bit_depth < 8 */
        /* { */
        /*     assert(img_width_bytes <= p.width); */
        /*     off += p.width * p.out_components - img_width_bytes; */
        /*     filter_bytes = 1; */
        /*     x = img_width_bytes; */
        /* } */
        working = image[off:];

        switch filter
        {
        case .None:
            for j in 0..<(x) do
                for k in 0..<(filter_bytes)
                {
                    ri := j*filter_bytes+k;
                    oi := j*output_bytes+k;
                    
                    working[oi] = row[ri];
                }    
            
        case .Sub:
            for j in 0..<(x)
            {
                for k in 0..<(filter_bytes)
                {
                    ri := j*filter_bytes+k;
                    oi := j*output_bytes+k;
                    
                    a := u16(0);
                    if j != 0 do
                        a = u16(working[oi - output_bytes]);
                    working[oi] = byte(u16(row[ri]) + a);
                }
            }

        case .Up:
            for j in 0..<(x)
            {
                for k in 0..<(filter_bytes)
                {
                    ri := j*filter_bytes+k;
                    oi := j*output_bytes+k;
                    
                    b := u16(0);
                    if y != 0 do
                        b = u16(prev_row[oi]);
                    working[oi] = byte(u16(row[ri]) + b);
                }
            }

        case .Avg:
            for j in 0..<(x)
            {
                for k in 0..<(filter_bytes)
                {
                    ri := j*filter_bytes+k;
                    oi := j*output_bytes+k;
                    
                    a := u16(0);
                    b := u16(0);
                    if j != 0 do
                        a = u16(working[oi - output_bytes]);
                    if y != 0 do
                        b = u16(prev_row[oi]);

                    working[oi] = byte(u16(row[ri]) + (a+b)/2);
                }
            }

        case .Paeth:
            for j in 0..<(x)
            {
                for k in 0..<(filter_bytes)
               {
                    ri := j*filter_bytes+k;
                    oi := j*output_bytes+k;
                    
                    a := u16(0);
                    b := u16(0);
                    c := u16(0);

                    if j != 0
                    {
                        a = u16(working[oi - output_bytes]);
                        if y != 0 do
                            c = u16(prev_row[oi - output_bytes]);
                    }

                    if y != 0 do
                        b = u16(prev_row[oi]);
                    
                   paeth := paeth_predict(i32(a), i32(b), i32(c));
                   working[oi] = byte(u16(row[ri]) + u16(paeth));
                }
            }
        }

        if p.components != p.out_components
        {
            for j in 0..<(x)
            {
                working[j*output_bytes+filter_bytes] = 255;
                if p.depth == 16 do
                    working[j*output_bytes+filter_bytes+1] = 255;
            }
        }
        
        prev_row = working;
        row = row[x*filter_bytes:];
    }

    // @TODO(Tyler): Support for 1/2/4 bit color depth

    // @NOTE(Tyler): Swap endianness to platform native
    if p.depth == 16
    {
        working = image;
        working_be := mem.slice_data_cast([]u16be, working);
        working_16 := mem.slice_data_cast([]u16,   working);

        for _, i in working_16 do
            working_16[i] = u16(working_be[i]);
    }

    return image;
}

@private
compute_transparency8 :: proc(p: ^PNG, trans: [3]u8)
{
    assert(p.out_components == 2 || p.out_components == 4);

    if p.out_components == 2
    {
        data := mem.slice_data_cast([][2]u8, p.out);
        for _, i in data
        {
            pixel := &data[i];
            pixel[1] = pixel[0] == trans[0] ? 0 : 255;
        }
    }
    else
    {
        data := mem.slice_data_cast([][4]u8, p.out);
        for _, i in data
        {
            pixel := &data[i];
            if pixel[0] == trans[0]
            && pixel[1] == trans[1]
            && pixel[2] == trans[2] do
            pixel[3] = 0;
        }
    }
}

@private
compute_transparency16 :: proc(p: ^PNG, trans: [3]u16)
{
    assert(p.out_components == 2 || p.out_components == 4);

    if p.out_components == 2
    {
        data := mem.slice_data_cast([][2]u16, p.out);
        for _, i in data
        {
            pixel := data[i];
            pixel[1] = pixel[0] == trans[0] ? 0 : 255;
        }
    }
    else
    {
        data := mem.slice_data_cast([][4]u16, p.out);
        for _, i in data
        {
            pixel := data[i];
            if pixel[0] == trans[0]
            && pixel[1] == trans[1]
            && pixel[2] == trans[2] do
                pixel[3] = 0;
        }
    }
}

@private
expand_palette :: proc(p: ^PNG)
{
    p.components = p.pal_components;
    p.out_components = p.pal_components;

    expanded := make([]byte, p.width*p.height*p.pal_components);
    for i in 0..<(p.width*p.height) do
        mem.copy(&expanded[i*p.pal_components], &p.palette[u32(p.out[i])][0], int(p.pal_components));
    delete(p.out);
    p.out = expanded;
}
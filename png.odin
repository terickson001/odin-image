package image

import "core:fmt"
import "core:mem"
import "core:os"
import m "core:math"
import "core:hash"
import "shared:compress/zlib"
import "shared:compress/bits"
import "shared:profile"

@private
png_err :: proc(test: bool, file, message: string, loc := #caller_location) -> bool
{
    if test 
    {
        fmt.eprintf("%#v: ERROR: %s: %s\n", loc, file, message);
    }
    
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

write_png_to_mem :: proc(image: Image, format: Image_Format, depth: u32) -> []byte
{
    image := image;
    
    p := PNG{};
    p.width = image.width;
    p.height = image.height;
    p.components = u32(format) & 7;
    p.depth = u8(depth);
    
    switch p.components
    {
        case 1: p.color = 0;
        case 2: p.color = 4;
        case 3: p.color = 2;
        case 4: p.color = 6;
    }
    
    image.data = convert_format_png(image, format, depth);
    /* image.depth = depth; */
    /* image.format = format; */
    
    filtered   := filter_image(image, p);
    compressed := zlib.compress(filtered, 8);
    delete(filtered);
    
    buffer := bits.String{};
    buffer.buffer = make([dynamic]byte, 0, 8 + 12+13 + 12+len(compressed) + 12);
    
    bits.append(&buffer, u64(0x8950_4e47_0d0a_1a0a));
    bits.append(&buffer, u32(13));
    bits.append(&buffer, u32(IHDR));
    bits.append(&buffer, u32(p.width));
    bits.append(&buffer, u32(p.height));
    bits.append(&buffer, u8(p.depth));
    bits.append(&buffer, u8(p.color));
    bits.append(&buffer, u8(0));
    bits.append(&buffer, u8(0));
    bits.append(&buffer, u8(0));
    bits.append(&buffer, hash.crc32(buffer.buffer[len(buffer.buffer)-17:]));
    
    bits.append(&buffer, u32(len(compressed)));
    bits.append(&buffer, u32(IDAT));
    bits.append(&buffer, compressed);
    bits.append(&buffer, hash.crc32(buffer.buffer[len(buffer.buffer)-len(compressed)-4:]));
    
    bits.append(&buffer, u32(0));
    bits.append(&buffer, u32(IEND));
    bits.append(&buffer, u32(0xae42_6082)); // Hard-coded IEND crc
    
    out := make([]byte, len(buffer.buffer));
    copy(out, buffer.buffer[:]);
    delete(buffer.buffer);
    
    return out;
}

write_png :: proc(image: Image, filepath: string, format: Image_Format, depth: u32)
{
    encoded := write_png_to_mem(image, format, depth);
    defer delete(encoded);
    
    os.write_entire_file(filepath, encoded);
}

@private
convert_format_png :: proc(image: Image, to_format: Image_Format, to_depth: u32) -> []byte
{
    src_comp := u32(image.format) & 7;
    out_comp := u32(to_format) & 7;
    
    Change :: enum {
        Remove = -1,
        None   =  0,
        Add    =  1,
    };
    
    src_pixel_depth := u32(image.depth+7) >> 3;
    out_pixel_depth := (to_depth+7) >> 3;
    
    change_depth := Change(int(out_pixel_depth) - int(src_pixel_depth));
    change_alpha := Change(int((src_comp % 2))  - int((out_comp % 2)));
    change_color := Change(int((out_comp+1)/2)  - int((src_comp+1)/2));
    
    converted := make([]byte, image.width*image.height*out_pixel_depth*out_comp);
    
    pixel := [8]u8{};
    for p in 0..<(image.width*image.height)
    {
        si := p*src_comp*src_pixel_depth;
        oi := p*out_comp*out_pixel_depth;
        
        /* Convert Depth, and store in intermediate value, `pixel` */
        switch change_depth
        {
            case .Remove:
            for p in 0..<(src_comp) 
            {
                (^u16)(&pixel[p*out_pixel_depth])^ = (^u16)(&image.data[si+p*2])^/257;
            }
            
            case .Add:
            for p in 0..<(src_comp) 
            {
                (^u16)(&pixel[p*out_pixel_depth])^ = u16(image.data[si+p])*257;
            }
            
            case .None:
            if src_pixel_depth == 1 
            {
                for p in 0..<(src_comp)
                {
                    (^u16)(&pixel[p*out_pixel_depth])^ = u16(image.data[si+p]);
                }
            }
            else 
            {
                for p in 0..<(src_comp)
                {
                    (^u16)(&pixel[p*out_pixel_depth])^ = (^u16)(&image.data[si+p*2])^;
                }
            }
        }
        
        
        /* Convert color, RGB <-> Grayscale, and store in output */
        switch change_color
        {
            case .Remove:
            for b in 0..<(out_pixel_depth) 
            {
                converted[oi+b] = byte(
                                       (u32(pixel[out_pixel_depth*0+b]) +
                                        u32(pixel[out_pixel_depth*1+b]) +
                                        u32(pixel[out_pixel_depth*2+b])) / 3,
                                       );
            }
            
            
            case .Add:
            for i in 0..<(3*out_pixel_depth) 
            {
                converted[oi+u32(i)] = pixel[i%out_pixel_depth]+byte(i%out_pixel_depth);
            }
            
            case .None:
            for i in 0..<((out_comp + (out_comp%2)-1) * out_pixel_depth) 
            {
                converted[oi+i] = pixel[i];
            }
        }
        
        /* Add or copy alpha channel to output */
        switch change_alpha
        {
            case .Remove: break; // Ignore
            
            case .Add:
            for b in 0..<(out_pixel_depth) 
            {
                converted[oi+(out_comp-1)*out_pixel_depth+b] = 255;
            }
            
            case .None:
            if src_comp % 2 == 0 
            {
                for b in 0..<(out_pixel_depth)
                {
                    converted[oi+(out_comp-1)*out_pixel_depth+b] = pixel[(src_comp-1)*out_pixel_depth+b];
                }
            }
        }
    }
    
    return converted;
}

@private
filter_image :: proc(image: Image, png: PNG) -> []byte
{
    pixel_depth := u32(png.depth+7) >> 3;
    stride := image.width * png.components * pixel_depth + 1;
    filtered := make([]byte, stride*image.height);
    
    buf := make([]byte, stride-1);
    defer delete(buf);
    for row in 0..<(image.height)
    {
        best_filter := Filter.None;
        best_entropy := ~u64(0);
        for filter in Filter.None..<(Filter.Paeth)
        {
            filter_row(image, png, row, filter, buf);
            
            entropy := u64(0);
            for p in buf 
            {
                entropy += u64(abs(transmute(i8)p));
            }
            
            if entropy < best_entropy
            {
                best_entropy = entropy;
                best_filter = filter;
            }
        }
        if best_filter != .Paeth 
        {
            filter_row(image, png, row, best_filter, buf);
        }
        
        filtered[stride*row] = u8(best_filter);
        copy(filtered[stride*row+1:], buf);
    }
    
    return filtered;
}

@private
filter_row :: proc(image: Image, png: PNG, row_num: u32, filter: Filter, buf: []byte)
{
    src_comp := u32(image.format) & 7;
    
    src_depth := (image.depth + 7) >> 3;
    out_depth := u32(png.depth + 7) >> 3;
    
    src_bytes := src_comp * src_depth;
    out_bytes := png.components * out_depth;
    
    prev_row: []byte = nil;
    if row_num != 0 
    {
        prev_row = image.data[(row_num-1)*image.width*src_bytes:row_num*image.width*src_bytes];
    }
    row := image.data[row_num*image.width*src_bytes:(row_num+1)*image.width*src_bytes];
    
    switch filter
    {
        case .None:  
        do_filter_none(false, image.width, row_num, src_bytes, out_bytes, buf, row, prev_row);
        case .Sub:
        do_filter_sub(false, image.width, row_num, src_bytes, out_bytes, buf, row, prev_row);
        case .Up:
        do_filter_up(false, image.width, row_num, src_bytes, out_bytes, buf, row, prev_row);
        case .Avg:
        do_filter_avg(false, image.width, row_num, src_bytes, out_bytes, buf, row, prev_row);
        case .Paeth:
        do_filter_paeth(false, image.width, row_num, src_bytes, out_bytes, buf, row, prev_row);
    }
}

test_png :: proc{test_png_mem, test_png_file};
test_png_mem :: proc(file: []byte) -> bool
{
    file := file;
    signature := _read_sized(&file, u64);
    
    if len(file) < 8 || signature != 0xa1a0a0d474e5089 
    {
        return false;
    }
    
    return true;
}

test_png_file :: proc(filepath: string) -> bool
{
    file, ok := os.read_entire_file(filepath);
    if !ok
    {
        fmt.eprintf("Could not open file %s\n", filepath);
        return false;
    }
    defer delete(file);
    
    return test_png_mem(file);
}

load_png_from_mem :: proc(file: []byte, desired_format: Image_Format = nil, name := "<MEM>") -> (image: Image)
{
    file := file;
    signature := _read_sized(&file, u64);
    
    if png_err(signature != 0xa1a0a0d474e5089, name, "Invalid PNG signature")
    {
        return;
    }
    
    trns   := [3]byte{};
    trns16 := [3]u16{};
    
    p := PNG{};
    p.filepath = name;
    first := true;
    loop: for
    {
        chunk := read_chunk(&file);
        chars := transmute([4]byte)chunk.type;
        data_save := chunk.data;
        
        switch chunk.type
        {
            case IHDR:
            if png_err(!first, name, "Multiple IHDR") ||
                png_err(chunk.size != 13, name, "Invalid IHDR length")
            {
                return;
            }
            
            p.width     = u32(_read_sized(&chunk.data, u32be));
            p.height    = u32(_read_sized(&chunk.data, u32be));
            p.depth     = _read_sized(&chunk.data, byte);
            p.color     = _read_sized(&chunk.data, byte);
            p.comp      = _read_sized(&chunk.data, byte);
            p.filter    = _read_sized(&chunk.data, byte);
            p.interlace = _read_sized(&chunk.data, byte);
            
            if png_err(p.color > 6, name, "Invalid color type") ||
                png_err(p.color == 1 || p.color == 5, name, "Invalid color type") ||
                png_err(p.color == 3 && p.depth == 16, name, "Invalid color type")
            {
                return;
            }
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
                
                if png_err((1<<30) / p.width / 4 < p.height, name, "too large")
                {
                    return;
                }
            }
            
            case PLTE:
            if png_err(first, name, "First chunk not IHDR") ||
                png_err(chunk.size > 256*3, name, "Invalid PLTE")
            {
                return;
            }
            
            p.pal_len = chunk.size / 3;
            if png_err(p.pal_len * 3 != chunk.size, name, "Invalid PLTE")
            {
                return;
            }
            
            for i in 0..<(p.pal_len)
            {
                p.palette[i][0] = _read_sized(&chunk.data, byte);
                p.palette[i][1] = _read_sized(&chunk.data, byte);
                p.palette[i][2] = _read_sized(&chunk.data, byte);
                p.palette[i][3] = 255;
            }
            
            case tRNS:
            
            if png_err(first, name, "First chunk not IHDR") ||
                png_err(len(p.data) > 0, name, "tRNS after IDAT")
            {
                return;
            }
            
            p.has_trans = true;
            if p.pal_components != 0
            {
                if png_err(p.pal_len == 0, name, "tRNS before PLTE") ||
                    png_err(chunk.size > p.pal_len, name, "Invalid tRNS")
                {
                    return;
                }
                
                p.pal_components = 4;
                for i in 0..<(chunk.size) 
                {
                    p.palette[i][3] = _read_sized(&chunk.data, byte);
                }
            }
            else
            {
                if png_err(~p.components & 1 != 0, name, "tRNS with alpha channel") ||
                    png_err(chunk.size != u32(p.components*2), name, "Invalid tRNS")
                {
                    return;
                }
                
                if p.depth == 16 
                {
                    for i in 0..<(p.components)
                    {
                        trns16[i] = u16(_read_sized(&chunk.data, u16be));
                    }
                }
                else 
                {
                    for i in 0..<(p.components)
                    {
                        trns[i] = byte(_read_sized(&chunk.data, u16be) & 255);
                    }
                }
            }
            
            case IDAT:
            if png_err(first, name, "First chunk not IHDR") 
            {
                return;
            }
            
            if p.data == nil 
            {
                p.data = make([dynamic]byte);
            }
            
            append(&p.data, ..chunk.data);
            
            
            case IEND:
            if png_err(first, name, "First chunk not IHDR") ||
                png_err(len(p.data) == 0, name, "No IDAT")
            {
                return;
            }
            
            z_buff := zlib.read_block(p.data[:]);
            zlib.decompress(&z_buff);
            if png_err(len(z_buff.out) == 0, name, "Error decompressing PNG")
            {
                return;
            }
            
            delete(p.data);
            
            p.out_components = p.components;
            if p.has_trans 
            {
                p.out_components += 1;
            }
            
            p.out = create_png(&p, z_buff.out[:], u32(len(z_buff.out)));
            delete(z_buff.out);
            
            if p.has_trans
            {
                if p.depth == 16 
                {
                    compute_transparency16(&p, trns16);
                }
                else 
                {
                    compute_transparency8(&p, trns);
                }
            }
            
            if p.pal_components > 0 
            {
                expand_palette(&p);
            }
            
            break loop;
            
            case:
            if png_err(first, name, "first not IHDR")
            {
                return;
            }
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
    
    image.data = p.out[:];
    
    flip_y(&image);
    if desired_format != nil
    {
        del := image.data;
        defer delete(del);
        
        image.data = convert_format_png(image, desired_format, image.depth);
        image.format = desired_format;
    }
    
    return image;
}

load_png :: proc(filepath: string, desired_format: Image_Format = nil) -> (image: Image)
{
    image = Image{};
    
    file, ok := os.read_entire_file(filepath);
    if png_err(!ok, filepath, "Could not open file") ||
        png_err(len(file) < 8, filepath, "Invalid PNG file")
    {
        return;
    }
    
    return load_png_from_mem(file, desired_format);
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
    if p.interlace != 0 
    {
        image = deinterlace(p, data, raw_len);
    }
    else 
    {
        image = defilter(p, data, p.width, p.height);
    }
    
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

do_filter_none :: #force_inline proc(reverse: bool,
                                     w, rowi, src_bytes, out_bytes: u32,
                                     out, src, prev: []byte)
{
    si, oi: u32;
    if src_bytes == out_bytes
    {
        copy(out, src[:w*src_bytes]);
        return;
    }
    for j in 0..<(w)
    {
        for k in 0..<(src_bytes)
        {
            si = j*src_bytes+k;
            oi = j*out_bytes+k;
            
            out[oi] = byte(u16(src[si]));
        }
    }
}

do_filter_sub :: #force_inline proc(reverse: bool,
                                    w, rowi, src_bytes, out_bytes: u32,
                                    out, src, prev: []byte)
{
    si, oi: u32;
    a: u16;
    for j in 0..<(w)
    {
        for k in 0..<(src_bytes)
        {
            si = j*src_bytes+k;
            oi = j*out_bytes+k;
            
            if j != 0 
            {
                a = u16(out[oi - out_bytes]);
            }
            
            if reverse 
            {
                out[oi] = byte(u16(src[si]) + a);
            }
            else 
            {
                out[oi] = byte(u16(src[si]) - a);
            }
        }
    }
}

do_filter_up :: #force_inline proc(reverse: bool,
                                   w, rowi, src_bytes, out_bytes: u32,
                                   out, src, prev: []byte)
{
    si, oi: u32;
    b: u16;
    for j in 0..<(w)
    {
        for k in 0..<(src_bytes)
        {
            si = j*src_bytes+k;
            oi = j*out_bytes+k;
            
            if rowi != 0 
            {
                b = u16(prev[oi]);
            }
            
            if reverse 
            {
                out[oi] = byte(u16(src[si]) + b);
            }
            else 
            {
                out[oi] = byte(u16(src[si]) - b);
            }
        }
    }
}

do_filter_avg :: #force_inline proc(reverse: bool,
                                    w, rowi, src_bytes, out_bytes: u32,
                                    out, src, prev: []byte)
{
    si, oi: u32;
    a, b: u16;
    for j in 0..<(w)
    {
        for k in 0..<(src_bytes)
        {
            si = j*src_bytes+k;
            oi = j*out_bytes+k;
            
            if j != 0 
            {
                a = u16(out[oi - out_bytes]);
            }
            
            if rowi != 0 
            {
                b = u16(prev[oi]);
            }
            
            if reverse 
            {
                out[oi] = byte(u16(src[si]) + (a+b)/2);
            }
            else 
            {
                out[oi] = byte(u16(src[si]) - (a+b)/2);
            }
        }
    }
}

do_filter_paeth :: #force_inline proc(reverse: bool,
                                      w, rowi, src_bytes, out_bytes: u32,
                                      out, src, prev: []byte)
{
    si, oi: u32;
    a, b, c: u16;
    for j in 0..<(w)
    {
        for k in 0..<(src_bytes)
        {
            si = j*src_bytes+k;
            oi = j*out_bytes+k;
            
            if j != 0
            {
                a = u16(out[oi - out_bytes]);
                if rowi != 0 
                {
                    c = u16(prev[oi - out_bytes]);
                }
            }
            
            if rowi != 0 
            {
                b = u16(prev[oi]);
            }
            
            if reverse 
            {
                out[oi] = byte(u16(src[si]) + u16(paeth_predict(i32(a), i32(b), i32(c))));
            }
            else 
            {
                out[oi] = byte(u16(src[si]) - u16(paeth_predict(i32(a), i32(b), i32(c))));
            }
        }
    }
}

@private
expand_row :: #force_inline proc(image: []byte, row: u32, depth: byte, grayscale: bool, src_stride, out_stride: u32)
{
    scale := byte(1);
    mask := (u32(1) << depth) - 1;
    if grayscale
    {
        scale = byte(0xff/mask);
    }
    
    eidx := 0;
    expanded := image[(row)  *out_stride:][:src_stride];
    bits     := image[(row+1)*out_stride - src_stride:][:src_stride];
    for b in bits
    {
        mask <<= 8;
        for bidx := 0; bidx < min(len(expanded[eidx:]), int(depth)); bidx += 1
        {
            mask >>= depth;
            expanded[eidx] = (b & byte(mask)) * scale;
            eidx += 1;
        }
    }
}

@private
defilter :: proc(p: ^PNG, data: []byte, x, y: u32) -> []byte
{
    profile.scoped_zone();
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
    
    width := p.depth >= 8 ? x : img_width_bytes;
    
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
        
        if p.depth < 8 
        {
            off += x*output_bytes - img_width_bytes;
        }
        
        working = image[off:];
        
        switch filter
        {
            case .None:
            do_filter_none(true, width, i, filter_bytes, output_bytes, working, row, prev_row);
            case .Sub:
            do_filter_sub(true, width, i, filter_bytes, output_bytes, working, row, prev_row);
            case .Up:    
            do_filter_up(true, width, i, filter_bytes, output_bytes, working, row, prev_row);
            case .Avg:   
            do_filter_avg(true, width, i, filter_bytes, output_bytes, working, row, prev_row);
            case .Paeth: 
            do_filter_paeth(true, width, i, filter_bytes, output_bytes, working, row, prev_row);
        }
        // do_filter(filter_proc, true, width, i, filter_bytes, output_bytes, working, row, prev_row);
        
        if p.components != p.out_components && p.depth >= 8
        {
            for j in 0..<(x)
            {
                working[j*output_bytes+filter_bytes] = 255;
                if p.depth == 16 
                {
                    working[j*output_bytes+filter_bytes+1] = 255;
                }
            }
        }
        
        prev_row = working;
        row = row[width*filter_bytes:];
        
        if p.depth < 8 && i >= 2 
        {
            expand_row(image, i-2, p.depth, p.color == 0, img_width_bytes, x*output_bytes);
        }
    }
    
    if p.depth < 8 
    {
        for i in (y-2)..<(y)
        {
            expand_row(image, i, p.depth, p.color == 0, img_width_bytes, x*output_bytes);
        }
    }
    
    // @TODO(Tyler): Support for 1/2/4 bit color depth
    
    // @NOTE(Tyler): Swap endianness to platform native
    if p.depth == 16
    {
        working = image;
        working_be := mem.slice_data_cast([]u16be, working);
        working_16 := mem.slice_data_cast([]u16,   working);
        
        for _, i in working_16 
        {
            working_16[i] = u16(working_be[i]);
        }
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
            if pixel[0] == trans[0] &&
                pixel[1] == trans[1] &&
                pixel[2] == trans[2] 
            {
                pixel[3] = 0;
            }
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
            if pixel[0] == trans[0] &&
                pixel[1] == trans[1] &&
                pixel[2] == trans[2] 
            {
                pixel[3] = 0;
            }
        }
    }
}

@private
expand_palette :: proc(p: ^PNG)
{
    p.components = p.pal_components;
    p.out_components = p.pal_components;
    
    expanded := make([]byte, p.width*p.height*p.pal_components);
    for i in 0..<(p.width*p.height) 
    {
        mem.copy(&expanded[i*p.pal_components], &p.palette[u32(p.out[i])][0], int(p.pal_components));
    }
    delete(p.out);
    p.out = expanded;
}

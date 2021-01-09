package image

import "core:fmt"
import "core:os"
import "core:mem"
import "core:runtime"
import "core:intrinsics"
import "core:sort"
import "core:strings"

import "shared:compress/zlib"

@private
read_type :: proc(file: ^[]byte, $T: typeid) -> T
{
    if len(file^) < size_of(T)
    {
        fmt.eprintf("Expected %v, got EOF\n", typeid_of(T));
        return T(0);
    }
    
    ret := ((^T)(&file[0]))^;
    file^ = file[size_of(T):];
    
    return ret;
}

@private
read_typeid :: proc(file: ^[]byte, store: uintptr, id: typeid, loc := #caller_location)
{
    ti := type_info_of(id);
    
    #partial switch sub_type in ti.variant
    {
        case runtime.Type_Info_String:
        read_slice(file, store, type_info_of(typeid_of(byte)), 0);
        case runtime.Type_Info_Slice:
        read_slice(file, store, sub_type.elem, 0);
        case runtime.Type_Info_Struct:
        read_packed_struct(file, store, sub_type);
        case:
        if len(file^) < ti.size
        {
            fmt.eprintf("%#v: Expected %v, got EOF\n", loc, id);
            return;
        }
        
        mem.copy(rawptr(store), &file[0], ti.size);
        file^ = file[ti.size:];
    }
}

Box :: struct(T: typeid)
{
    min: [2]T,
    max: [2]T,
}

Pixel_Type :: enum i32
{
    Uint  = 0,
    Half  = 1,
    Float = 2,
}

Channel :: struct
{
    name       : string,
    pixel_type : Pixel_Type,
    linear     : u8,
    reserved   : [3]u8,
    sampling   : [2]i32,
}

Chromaticities :: struct
{
    red   : [2]f32,
    green : [2]f32,
    blue  : [2]f32,
    white : [2]f32,
}

Compression :: enum u8
{
    None  = 0,
    RLE   = 1,
    ZIPS  = 2,
    ZIP   = 3,
    PIZ   = 4,
    PXR24 = 5,
    B44   = 6,
    B44A  = 7,
}

Line_Order :: enum u8
{
    Increasing = 0,
    Decreasing = 1,
    Random     = 2,
}

Header_Type :: enum u8
{
    Scanline      = 0,
    Tiled         = 1,
    Deep_Scanline = 2,
    Deep_Tiled    = 3,
}

Tile_Desc :: struct
{
    size: [2]u32,
    mode: u8,
}

Part :: struct
{
    using header : Header,
    offsets      : []u64,
    data_size    : i32,
    chunks       : [dynamic]Chunk,
    data         : []byte,
}

Scanline_Chunk :: struct
{
    y_coord   : i32,
    data_size : i32,
    data      : []byte,
}

Tile_Chunk :: struct
{
    tile      : [2]i32,
    level     : [2]i32,
    data_size : i32,
    data      : []byte,
}

Deep_Scanline_Chunk :: struct
{
    y_coord          : i32,
    offset_size      : u64,
    packed_data_size : u64,
    data_size        : u64,
    offsets          : []i32,
    data             : []byte,
}

Deep_Tile_Chunk :: struct
{
    tile             : [2]i32,
    level            : [2]i32,
    offset_size      : u64,
    packed_data_size : u64,
    data_size        : u64,
    offsets          : []i32,
    data             : []byte,
}

@(private="file")
Chunk :: struct
{
    data: []byte,
    variant: union
    {
        Scanline_Chunk,
        Tile_Chunk,
        Deep_Scanline_Chunk,
        Deep_Tile_Chunk,
    }
}

@(private="file")
Header :: struct
{
    /* Required for all Files */
    channels           : []Channel,
    compression        : Compression,
    dataWindow         : Box(i32),
    displayWindow      : Box(i32),
    lineOrder          : Line_Order,
    pixelAspectRatio   : f32,
    screenWindowCenter : [2]f32,
    screenWindowWidth  : f32,
    
    /* Optional for all Files */
    comments           : string,
    
    /* Required for tiled image */
    tiles              : Tile_Desc,
    
    /* Required for multi-part and deep data files */
    name               : string,
    type               : Header_Type,
    version            : i32,
    chunkCount         : i32,
    
    /* Required for deep data images */
    maxSamplesPerPixel : i32,
    
    /* Optional for multi-part files */
    view               : string,
    
    /* Unknown requirements */
    chromaticities     : Chromaticities,
    taWindow           : Box(i32),
    ilut               : string,
    latitude           : f32,
    longitude          : f32,
    multiView          : []string,
    xDensity           : f32,
}

Header_Field :: struct
{
    field: uintptr,
    type: ^runtime.Type_Info,
}

@private
header_map :: proc(using header: ^Header) -> map[string]Header_Field
{
    @static field_names:   []string;
    @static field_offsets: []uintptr;
    @static field_types:   []^runtime.Type_Info;
    
    if field_names == nil
    {
        ti := runtime.type_info_base(type_info_of(Header));
        s, _ := ti.variant.(runtime.Type_Info_Struct);
        field_names   = s.names;
        field_offsets = s.offsets;
        field_types   = s.types;
    }
    
    hmap := make(map[string]Header_Field, len(field_names));
    
    for _, i in field_names 
    {
        hmap[field_names[i]] = {uintptr(header) + field_offsets[i], field_types[i]};
    }
    
    return hmap;
}

@private
read_cstring :: proc(file: ^[]byte) -> string
{
    idx := 0;
    for file[idx] != 0 
    {
        idx += 1;
    }
    
    str := transmute(string)file[:idx];
    file^ = file[idx+1:];
    return str;
}

@private
read_packed_struct :: proc(file: ^[]byte, store: uintptr, using ti: runtime.Type_Info_Struct)
{
    for _, i in types 
    {
        read_typeid(file, store+offsets[i], types[i].id);
    }
}

@private
read_slice :: proc(file: ^[]byte, store: uintptr, elem_ti: ^runtime.Type_Info, size: i32)
{
    size := size;
    data: []byte;
    if size == 0 // Null-Terminated
    {
        for file[size] != 0 
        {
            size += 1;
        }
        data = file[:size];
        file^ = file[size+1:];
    }
    else
    {
        data = file[:size];
        file^ = file[size:];
    }
    
    
    slice_data_count := int(size) / elem_ti.size;
    slice_data := mem.alloc(slice_data_count*elem_ti.size);
    
    if sub_type, ok := elem_ti.variant.(runtime.Type_Info_Struct); ok
    {
        idx := 0;
        for len(data) > 0
        {
            for slice_data_count <= idx
            {
                // @Note(Tyler): This allocation assumes the estimate was fairly close
                slice_data = mem.resize(slice_data,
                                        slice_data_count     * elem_ti.size,
                                        (slice_data_count+1) * elem_ti.size);
                slice_data_count += 1;
            }
            
            read_packed_struct(&data, uintptr(slice_data)+uintptr(elem_ti.size*idx), sub_type);
            idx += 1;
        }
    }
    else
    {
        idx := 0;
        for len(data) > 0
        {
            read_typeid(&data, uintptr(slice_data)+uintptr(elem_ti.size*idx), elem_ti.id);
            idx += 1;
        }
    }
    
    slice := cast(^mem.Raw_Slice)store;
    slice.data = slice_data;
    slice.len  = slice_data_count;
}

@private
read_string_vector :: proc(file : ^[]byte, store: uintptr, size: i32)
{
    
    data := file[:size];
    file^ = file[size:];
    
    strs := make([dynamic]string);
    
    for len(data) > 0
    {
        size := read_type(&data, i32);
        str: string;
        read_slice(&data, uintptr(&str), type_info_of(typeid_of(u8)), size);
        append(&strs, str);
    }
    
    out := cast(^[]string)store;
    out^ = make([]string, len(strs));
    copy(out^, strs[:]);
    delete(strs);
}

@private
read_header :: proc(file: ^[]byte, header: ^Header)
{
    hmap := header_map(header);
    
    for file[0] != 0
    {
        attr := read_cstring(file);
        type_str := read_cstring(file);
        size := read_type(file, i32);
        
        if attr == "channels" 
        {
            size -= 1;
        }
        field, ok := hmap[attr];
        if !ok
        {
            fmt.eprintf("ERROR: Unknown attribute (%s: %s) in header\n", attr, type_str);
            os.exit(1);
        }
        
        type := field.type;
        #partial switch sub_type in type.variant
        {
            case runtime.Type_Info_String:
            read_slice(file, field.field, type_info_of(typeid_of(u8)), size);
            
            case runtime.Type_Info_Slice:
            #partial switch elem_type in sub_type.elem.variant
            {
                case runtime.Type_Info_String:
                read_string_vector(file, field.field, size);
                
                case:
                read_slice(file, field.field, runtime.type_info_base(sub_type.elem), size);
                if attr == "channels" 
                {
                    file^ = file[1:]; // skip null byte
                }
            }
            
            case runtime.Type_Info_Struct:
            read_packed_struct(file, field.field, sub_type);
            
            case:
            read_typeid(file, field.field, type.id);
        }
        
    }
    
    file^ = file[1:]; // Skip null byte
    
    // fmt.printf("HEADER:\n%#v\n", header^);
}

@static SCANLINES_PER_BLOCK := [8]i32{1, 1, 1, 16, 32, 16, 32, 32};
load_exr :: proc(filepath: string) -> (image: Image)
{
    image = Image{};
    
    file, ok := os.read_entire_file(filepath);
    if !ok
    {
        fmt.eprintf("ERROR: Could not open file %q\n", filepath);
        return;
    }
    
    signature := read_type(&file, u32be);
    
    if signature != 0x762f3101
    {
        fmt.eprintf("ERROR: File %q is not a valid EXR\n", filepath);
        return;
    }
    
    version := read_type(&file, u32);
    tiled      := bool(version & 0x0200);
    long_names := bool(version & 0x0400);
    non_image  := bool(version & 0x0800);
    multipart  := bool(version & 0x1000);
    
    fmt.printf("tiled: %v\nlong_names: %v\nnon_image: %v\nmultipart: %v\n",
               tiled, long_names, non_image, multipart);
    if tiled && (non_image || multipart)
    {
        fmt.eprintf("%s: ERROR: Tiled image cannot be multipart, or contain deep data\n", filepath);
        return;
    }
    
    scanline := false;
    if !(tiled || non_image || multipart) 
    {
        scanline = true;
    }
    fmt.printf("tiled: %v\nlong_names: %v\nnon_image: %v\nmultipart: %v\nscanline: %v\n",
               tiled, long_names, non_image, multipart, scanline);
    
    /* Read Headers */
    parts := make([dynamic]Part, 0, 1);
    if !multipart
    {
        part := Part{};
        read_header(&file, &part.header);
        append(&parts, part);
        fmt.printf("HEADER: %#v\n", part.header);
    }
    else
    {
        for file[0] != 0
        {
            part := Part{};
            read_header(&file, &part.header);
            append(&parts, part);
        }
        fmt.printf("PART COUNT: %d\n", len(parts));
    }
    
    /* Read Offset Tables */
    for part, i in parts
    {
        table_size := part.chunkCount;
        if table_size == 0
        {
            assert(!multipart, "MultiPart image must have chunkCount");
            if scanline
            {
                slpb := SCANLINES_PER_BLOCK[part.compression];
                scanlines := part.dataWindow.max.y - part.dataWindow.min.y;
                table_size = (scanlines + slpb-1) / slpb;
            }
            else // Tiled
            {
                // @todo(Tyler): Understand how this works
            }
        }
        
        parts[i].offsets = make([]u64, table_size);
        for _, o in parts[i].offsets 
        {
            parts[i].offsets[o] = read_type(&file, u64);
        }
    }
    
    /* Read Chunks */
    for len(file) > 0
    {
        parti := u64(0);
        if multipart 
        {
            parti = read_type(&file, u64);
        }
        part := &parts[parti];
        chunk := Chunk{};
        switch part.type
        {
            case .Scanline:
            using sc_chunk := Scanline_Chunk{};
            
            y_coord = read_type(&file, i32);
            fmt.println("y_coord:", y_coord);
            data_size = read_type(&file, i32);
            read_slice(&file, uintptr(&chunk.data), type_info_of(typeid_of(u8)), data_size);
            
            chunk.variant = sc_chunk;
            
            case .Tiled:
            // @todo(Tyler) Implement
            case .Deep_Scanline:
            // @todo(Tyler) Implement
            case .Deep_Tiled:
            // @todo(Tyler) Implement
        }
        
        
        fmt.printf("CHUNK #%d\n", len(part.chunks));
        switch part.compression
        {
            case .None:
            
            case .RLE:
            
            case .ZIPS:
            
            case .ZIP:
            decompress_zip(&chunk);
            case .PIZ:
            
            case .PXR24:
            decompress_pxr24(&chunk);
            case .B44:
            
            case .B44A:
            
        }
        
        append(&part.chunks, chunk);
        part.data_size += i32(len(chunk.data));
    }
    
    // Re-order pixel-data
    for _, i in parts
    {
        using part := &parts[i];
        
        _channel_sort :: proc(a, b: Channel) -> int { return strings.compare(a.name, b.name); }
        sort.quick_sort_proc(channels, _channel_sort);
        fmt.printf("Channels: %#v\n", channels);
        
        channel_sizes := [32]int{};
        pixel_width := int(0);
        for _, j in channels
        {
            channel_sizes[j] = channels[j].pixel_type == .Half ? 2 : 4;
            pixel_width += channel_sizes[j];
        }
        
        dims := dataWindow.max-dataWindow.min+1;
        data = make([]byte, data_size);
        assert(int(data_size) == int(dims.x*dims.y)*pixel_width);
        working := data;
        for chunk, c in chunks 
        {
            reorder_channels(&working, chunk.data, pixel_width, channels, channel_sizes[:], dims);
        }
    }
    
    image.data = parts[0].data;
    image.width = cast(u32)(parts[0].displayWindow.max.x - parts[0].displayWindow.min.x+1);
    image.height = cast(u32)(parts[0].displayWindow.max.y - parts[0].displayWindow.min.y+1);
    fmt.printf("w: %d\nh: %d\n", image.width, image.height);
    // flip_y(&image);
    
    return image;
}

@private
reorder_channels :: proc(out: ^[]byte, data: []byte, pixel_width: int, channels: []Channel, channel_sizes: []int, dims: [2]i32)
{
    data := data;
    
    assert(len(data)%(int(dims.x)*pixel_width) == 0);
    channel_offsets := [32]u32{};
    pixel_offsets   := [32]u32{};
    for i in 1..(len(channels))
    {
        channel_offsets[i] = channel_offsets[i-1] + u32(int(dims.x) * channel_sizes[i-1]);
        pixel_offsets[i]   = pixel_offsets[i-1]   + u32(channel_sizes[i-1]);
    }
    
    scanlines := len(data)/(int(dims.x)*pixel_width);
    assert(scanlines == 16);
    track := make([]b8, dims.x);
    for _ in 0..<(scanlines)
    {
        for _, c in channels
        {
            
            src := channel_offsets[c];
            dest := int(pixel_offsets[c]);
            fmt.printf("Sorting all %q components:\n  First: %d\n  Interval: %d\n", 
                       channels[c].name, dest, pixel_width);
            for x in 0..<(int(dims.x))
            {
                /*
                                switch channels[c].pixel_type
                                {
                                    case .Uint:  (^u32)(&out[dest])^ = read_type(&data, u32);
                                    case .Half:  (^u16)(&out[dest])^ = read_type(&data, u16);
                                    case .Float: (^u32)(&out[dest])^ = read_type(&data, u32);
                                }
                */
                
                switch channels[c].pixel_type
                {
                    case .Half:  mem.copy(&out[dest], &data[src], 2);
                    case .Uint:  mem.copy(&out[dest], &data[src], 4);
                    case .Float: mem.copy(&out[dest], &data[src], 4); if (^f32)(&data[src])^ != 0.0 do track[x] = true;
                }
                
                
                src += u32(channel_sizes[c]);
                dest += pixel_width;
            }
            fmt.printf("  Last:%d\n", dest-pixel_width);
        }
        for x in track 
        {
            assert(bool(x));
        }
        data = data[int(dims.x)*pixel_width:];
        
        /*
                for i in 0..<(int(dims.x)*len(channels))
                {
                    p := i % int(dims.x);
                    c := i / int(dims.x);
                    
                    dest := u32(pixel_width*p) + pixel_offsets[c];
                    switch channels[c].pixel_type
                    {
                        case .Uint:  (^u32)(&out[dest])^ = read_type(&data, u32);
                        case .Half:  (^u16)(&out[dest])^ = read_type(&data, u16);
                        case .Float: (^u32)(&out[dest])^ = read_type(&data, u32);
                    }
                }
*/
        
        
        out^ = out[int(dims.x)*pixel_width:];
        
        
    }
}

@private
decompress_zip :: proc(chunk: ^Chunk)
{
    buff := zlib.read_block(chunk.data);
    zlib.decompress(&buff);
    delete(chunk.data);
    chunk.data = make([]byte, len(buff.out));
    copy(chunk.data, buff.out[:]);
    delete(buff.out[:]);
}

@private
decompress_pxr24 :: proc(chunk: ^Chunk)
{
    decompress_zip(chunk);
    // @Todo(Tyler): Expand f32 image data
}

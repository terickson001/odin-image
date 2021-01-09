package image

import "core:fmt"

// Format: Lower 3 bits represent the number
//         of components for the format
Image_Format :: enum u8
{
    RGB   = 0b_000_011,
    RGBA  = 0b_000_100,
    GRAY  = 0b_000_001,
    GRAYA = 0b_000_010,
}

Compression_Type :: enum u8
{
    None,
    DXT1,
    DXT2,
    DXT3,
    DXT4,
    DXT5,
    BC4,
    BC5,
    BC6H,
    BC7,
}

Image :: struct
{
    data          : []byte,
    width, height : u32,
    depth         : u32,
    format        : Image_Format,
    compression   : Compression_Type,
    mipmap        : u8,
}

when ODIN_OS == "windows"
{
    import "core:sys/win32"
        file_exists :: proc(path: string) -> bool
    {
        c_path  := win32.utf8_to_wstring(path, context.temp_allocator);
        attribs := win32.get_file_attributes_w(c_path);
        
        return (i32(attribs) != win32.INVALID_FILE_ATTRIBUTES)
            && ((attribs & win32.FILE_ATTRIBUTE_DIRECTORY) != win32.FILE_ATTRIBUTE_DIRECTORY);
    }
}
else
{
    import "core:os"
        file_exists :: proc(path: string) -> bool
    {
        if stat, err := os.stat(path); err == os.ERROR_NONE 
        {
            return os.S_ISREG(stat.mode);
        }
        return false;
    }
}

Image_Type :: enum
{
    Invalid,
    BMP,
    PNG,
    TGA,
    DDS,
}

Error :: enum u8
{
    Ok,
    No_File,
    Unsupported,
}

get_type :: proc{get_type_file, get_type_mem};
get_type_file :: proc(filepath: string) -> Image_Type
{
    switch
    {
        case test_bmp(filepath): return .BMP;
        case test_png(filepath): return .PNG;
        case test_tga(filepath): return .TGA;
        case test_dds(filepath): return .DDS;
        case: return .Invalid;
    }
}

get_type_mem :: proc(data: []byte) -> Image_Type
{
    switch
    {
        case test_bmp(data): return .BMP;
        case test_png(data): return .PNG;
        case test_tga(data): return .TGA;
        case test_dds(data): return .DDS;
        case: return .Invalid;
    }
}

try_load :: proc{try_load_from_file, try_load_from_mem};
try_load_from_file :: proc(filepath: string, desired_format: Image_Format = nil) -> (Image, Error)
{
    if !file_exists(filepath) 
    {
        return Image{}, .No_File;
    }
    
    switch get_type(filepath)
    {
        case .BMP:     return load_bmp(filepath, desired_format), .Ok;
        case .PNG:     return load_png(filepath, desired_format), .Ok;
        case .TGA:     return load_tga(filepath, desired_format), .Ok;
        case .DDS:     return load_dds(filepath, desired_format), .Ok;
        case .Invalid: return Image{}, .Unsupported;
        case:          return Image{}, .Unsupported;
    }
}

try_load_from_mem :: proc(data: []byte, desired_format: Image_Format = nil, name := "<MEM>") -> (Image, Error)
{
    switch get_type(data)
    {
        case .BMP:     return load_bmp_from_mem(data, desired_format, name), .Ok;
        case .PNG:     return load_png_from_mem(data, desired_format, name), .Ok;
        case .TGA:     return load_tga_from_mem(data, desired_format, name), .Ok;
        case .DDS:     return load_dds_from_mem(data, desired_format, name), .Ok;
        case .Invalid: return Image{}, .Unsupported;
        case:          return Image{}, .Unsupported;
    }
}

load :: proc{load_from_file, load_from_mem};
load_from_file :: proc(filepath: string, desired_format: Image_Format = nil) -> Image
{
    image, err := try_load_from_file(filepath, desired_format);
    switch err
    {
        case .No_File:     panic(fmt.tprint("Could not open image ", filepath));
        case .Unsupported: panic(fmt.tprint("The image format of ", filepath, " is unsupported"));
        case .Ok:          return image;
    }
    
    return Image{};
}

load_from_mem :: proc(data: []byte, desired_format: Image_Format = nil, name := "<MEM>") -> Image
{
    image, err := try_load_from_mem(data, desired_format, name);
    switch err
    {
        case .Unsupported: panic(fmt.tprint("Image format is unsupported"));
        case .Ok:          return image;
        case .No_File:     unreachable();
    }
    
    return Image{};
}

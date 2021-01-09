package image

import "core:os"
import "core:fmt"
import "core:strings"

test_dds :: proc{test_dds_mem, test_dds_file};
test_dds_mem :: proc(file: []byte) -> bool
{
    filecode := file[:4];
    if strings.string_from_ptr(&filecode[0], 4) != "DDS\x20" 
    {
        return false;
    }
    return true;
}

test_dds_file :: proc(filepath: string) -> bool
{
    file, ok := os.read_entire_file(filepath);
    if !ok
    {
        fmt.eprintf("Image %q could not be opened\n", filepath);
        return false;
    }
    
    return test_dds_mem(file);
}

load_dds :: proc{load_dds_from_mem, load_dds_from_file};
load_dds_from_mem :: proc(file: []byte, desired_format: Image_Format = nil, name := "<MEM>") -> (image: Image)
{
    header := file[4:128];
    
    height       := (^u32)(&header[0x08])^;
    width        := (^u32)(&header[0x0C])^;
    linear_size  := (^u32)(&header[0x10])^;
    mipmap_count := (^u32)(&header[0x18])^;
    four_cc      := (^u32)(&header[0x50])^;
    
    FOURCC_DXT1 :: 0x31545844;
    FOURCC_DXT2 :: 0x32545844;
    FOURCC_DXT3 :: 0x33545844;
    FOURCC_DXT4 :: 0x34545844;
    FOURCC_DXT5 :: 0x35545844;
    
    compression: Compression_Type;
    switch four_cc
    {
        case FOURCC_DXT1: compression = .DXT1;
        case FOURCC_DXT2: compression = .DXT2;
        case FOURCC_DXT3: compression = .DXT3;
        case FOURCC_DXT4: compression = .DXT4;
        case FOURCC_DXT5: compression = .DXT5;
        case: return;
    }
    
    image.data = file[128:];
    image.width = width;
    image.height = height;
    
    image.depth = 8;
    assert(compression != .None);
    image.compression = compression;
    image.mipmap = u8(mipmap_count);
    image.format = .RGBA;
    
    return image;
}

load_dds_from_file :: proc(filepath: string, desired_format: Image_Format = nil) -> Image
{
    file, ok := os.read_entire_file(filepath);
    if !ok
    {
        fmt.eprintf("Image %q could not be opened\n", filepath);
        return Image{};
    }
    
    return load_dds_from_mem(file, desired_format, filepath);
}
package image

import "core:fmt"

// Format: Lower 3 bits represent the number
//         of components for the format
Image_Format :: enum
{
    RGB   = 0b_000_011,
    RGBA  = 0b_000_100,
    GRAY  = 0b_000_001,
    GRAYA = 0b_000_010,
}

Image :: struct
{
    data: []byte,
    width, height: u32,
    depth: u32,
    format: Image_Format,
    flipped: [2]bool,
}

load :: proc(filepath: string) -> Image
{
    if test_bmp(filepath) do
        return load_bmp(filepath);
    else if test_png(filepath) do
        return load_png(filepath);
    else if test_tga(filepath) do
        return load_tga(filepath);
    else do
        fmt.eprintf("Unsupported filetype: %s\n", filepath);
    
   return Image{};
}

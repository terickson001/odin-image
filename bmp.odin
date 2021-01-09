package image

import "core:fmt"
import "core:os"
import "core:mem"

test_bmp :: proc{test_bmp_mem, test_bmp_file};
test_bmp_mem :: proc(file: []byte) -> bool
{
    if len(file) < 54 
    {
        return false;
    }
    if file[0] != 'B' || file[1] != 'M' 
    {
        return false;
    }

    return true;
}

test_bmp_file :: proc(filepath: string) -> bool
{
    file, ok := os.read_entire_file(filepath);
    if !ok
    {
        fmt.eprintf("Image %q could not be opened\n", filepath);
        return false;
    }
    
    return test_bmp_mem(file);
}

load_bmp ::  proc{load_bmp_from_file, load_bmp_from_mem};
load_bmp_from_file :: proc(filepath: string, desired_format: Image_Format = nil) -> Image
{
    file, ok := os.read_entire_file(filepath);
    if !ok
    {
        fmt.eprintf("Image %q could not be opened\n", filepath);
        return {};
    }
    
    return load_bmp_from_mem(file, desired_format, filepath);
}

load_bmp_from_mem :: proc(file: []byte, desired_format: Image_Format = nil, name := "<MEM>") -> (image: Image)
{
    image = Image{};
    
    if len(file) < 54 ||
        file[0] != 'B' || file[1] != 'M'
    {
        fmt.eprintf("Image %q is not a valid BMP\n", name);
        return;
    }

    data_pos   := (^u32)(&(file[0x0A]))^;
    image_size := (^u32)(&(file[0x22]))^;
    width      := (^u32)(&(file[0x12]))^;
    height     := (^u32)(&(file[0x16]))^;

    if image_size == 0 do image_size = width*height*3;
    if data_pos == 0   do data_pos = 54;

    image.data = make([]byte, image_size);
    copy(image.data, file[data_pos:]);
    delete(file);
    
    image.width  = width;
    image.height = height;
    image.depth  = 8;
    image.format = .RGB;

    pixels := mem.slice_data_cast([][3]byte, image.data);
    for _, i in pixels 
    {
        pixels[i][0], pixels[i][2] = pixels[i][2], pixels[i][0];
    }
    
    return image;
}

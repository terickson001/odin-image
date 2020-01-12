package image

import "core:fmt"
import "core:os"

test_bmp :: proc(filepath: string) -> bool
{
    file, err := os.open(filepath);
    if err != 0
    {
        fmt.eprintf("Image %q could not be opened\n", filepath);
        return false;
    }
    
    header: [54]byte;
    n_read, _ := os.read(file, header[:]);
    if n_read != 54 ||
        header[0] != 'B' || header[1] != 'M'
    {
        return false;
    }

    return true;
}

load_bmp :: proc(filepath: string) -> (image: Image)
{
    image = Image{};
    
    file, ok := os.read_entire_file(filepath);
    if !ok
    {
        fmt.eprintf("Image %q could not be opened\n", filepath);
        return;
    }
    
    if len(file) < 54 ||
        file[0] != 'B' || file[1] != 'M'
    {
        fmt.eprintf("Image %q is not a valid BMP\n", filepath);
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
    image.format = .BGR;
    
    return image;
}

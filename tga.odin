package image

import "core:fmt"
import "core:os"
import "core:mem"
import m "core:math"
import "core:builtin"

test_tga :: proc(filepath: string) -> bool
{
    file, err := os.open(filepath);
    if err != 0
    {
        fmt.eprintf("Image %q could not be opened\n", filepath);
        return false;
    }

    header : [18]byte;

    n_read, _ := os.read(file, header[:]);
    if n_read != 18 do return false;

    cmap_type        := header[0x01];
    image_type       := header[0x02];
    cmap_start       := (^u16)(&header[0x03])^;
    cmap_len         := (^u16)(&header[0x05])^;
    cmap_depth       := header[0x07];
    width            := (^u16)(&header[0x0C])^;
    height           := (^u16)(&header[0x0E])^;
    pixel_depth      := header[0x10];
    image_descriptor := header[0x11];

    if cmap_type > 1 do return false;
    if cmap_type == 1
    {
        if image_type != 1 && image_type != 9 do return false;
        switch cmap_depth
        {
        case 8,15,16,24,32:
        case: return false;
        }
    }
    else
    {
        switch image_type
        {
        case 2,3,10,11:
        case: return false;
        }
    }

    if width < 1 || height < 1 do return false;
    if cmap_type == 1 && pixel_depth != 8 && pixel_depth != 16 do return false;
    switch pixel_depth
    {
    case 8,15,16,24,32:
    case: return false;
    }

    return true;
}

load_tga :: proc(filepath: string) -> (image: Image)
{
    image = Image{};
    
    header: [18]byte;

    file, err := os.open(filepath);
    if err != 0
    {
        fmt.eprintf("Image %q could not be opened\n", filepath);
        return;
    }

    n_read, _ := os.read(file, header[:]);
    if n_read != 18
    {
        fmt.eprintf("Image %q is not a valid TGA\n", filepath);
        return;
    }

    id_length        := header[0x00];
    cmap_type        := header[0x01];
    image_type       := header[0x02];
    cmap_start       := (^u16)(&header[0x03])^;
    cmap_len         := (^u16)(&header[0x05])^;
    cmap_depth       := header[0x07];
    width            := (^u16)(&header[0x0C])^;
    height           := (^u16)(&header[0x0E])^;
    pixel_depth      := header[0x10];
    image_descriptor := header[0x11];

    RLE := bool(image_type & 0b1000);
    
    fmt.printf("======= Load TGA (%s) =======\n", filepath);
    fmt.printf("cmap_type: %d\n", cmap_type);
    fmt.printf("cmap_start: %d\n", cmap_start);
    fmt.printf("cmap_len: %d\n", cmap_len);
    fmt.printf("cmap_depth: %d\n", cmap_depth);

    fmt.printf("id_length: %d\n", id_length);
    fmt.printf("image_type: %d\n", image_type);
    fmt.printf("  RLE?: %s\n", RLE?"Yes":"No");
    fmt.printf("width: %d\n", width);
    fmt.printf("height: %d\n", height);
    fmt.printf("pixel_depth: %d\n", pixel_depth);
    fmt.printf("image_descriptor: %d\n", image_descriptor);
    fmt.printf("========================\n");
    
    pixel_depth_bytes := int(m.ceil(f32(pixel_depth)/8));
    cmap_depth_bytes  := int(m.ceil(f32(cmap_depth) /8));

    image_id := make([]byte, id_length);
    defer delete(image_id);
    if id_length > 0
    {
        n_read, _ = os.read(file, image_id);
        if n_read != int(id_length)
        {
            fmt.eprintf("Could not read image ID in TGA %q\n", filepath);
            return;
        }
    }

    cmap_data := make([]byte, int(cmap_len)*cmap_depth_bytes);
    defer delete(cmap_data);
    if cmap_type != 0
    {
        n_read, _ = os.read(file, cmap_data);
        if  n_read != len(cmap_data)
        {
            fmt.eprintf("Could not read colormap in TGA %q", filepath);
            return;
        }
    }

    raw_image_data := make([]byte, int(width*height)*pixel_depth_bytes);
    image_size, _ := os.read(file, raw_image_data);
    if image_size == 0
    {
        fmt.eprintf("Could not read image data in TGA %q", filepath);
        return;
    }

    image_data := raw_image_data[:];
    defer delete(image_data);
    
    decoded_data_size := int(width*height)*pixel_depth_bytes;
    image_data_size: int;

    if cmap_type != 0 do
        image_data_size = int(width*height)*cmap_depth_bytes;
    else do
        image_data_size = int(decoded_data_size);

    decoded_image_data: []byte;
    if RLE
    {
        decoded_image_data = make([]byte, decoded_data_size);
        pixel_count := 0;
        i := 0;
        decoded_index := 0;
        for pixel_count < int(width*height)
        {
            count := int(image_data[i]);
            i += 1;
            encoded := bool(count & 0x80);
            count &= 0x7F;
            if encoded
            {
                for j := 0; j < count + 1; j += 1
                {
                    mem.copy(&decoded_image_data[decoded_index], &image_data[i], int(pixel_depth_bytes));
                    decoded_index += int(pixel_depth_bytes);
                    pixel_count += 1;
                }
                i += int(pixel_depth_bytes);
            }
            else
            {
                for j in 0..count
                {
                    mem.copy(&decoded_image_data[decoded_index], &image_data[i], pixel_depth_bytes);
                    i += pixel_depth_bytes;
                    decoded_index += pixel_depth_bytes;
                    pixel_count += 1;
                }
            }
        }
        delete(image_data);
        image_data = decoded_image_data;
    }

    colormapped_image_data := make([]byte, image_data_size);
    result_depth := pixel_depth;
    if cmap_type != 0
    {
        colormapped_index := 0;
        for i in 0..<int(width*height)
        {
            mem.copy(&colormapped_image_data[colormapped_index],
                     &cmap_data[int(image_data[i*pixel_depth_bytes])*cmap_depth_bytes],
                     cmap_depth_bytes);
            colormapped_index += cmap_depth_bytes;
        }
        delete(image_data);
        image_data = colormapped_image_data;
        result_depth = cmap_depth;
    }

    switch result_depth
    {
    case 15: image.format = .RGB;
    case 16: image.format = .RGB;
    case 24: image.format = .RGB;
    case 32: image.format = .RGBA;
    case:
        fmt.eprintf("Invalid color depth '%d' in TGA %q\n", result_depth, filepath);
        return;
    }

    image.data = make([]byte, len(image_data));
    copy(image.data, image_data);
    image.width = u32(width);
    image.height = u32(height);
    
    convert_format(&image, u32(result_depth));
    image.depth = 8;

    return image;
}

@private
convert_format :: proc(img: ^Image, from_depth: u32)
{
    components := u32(img.format) & 7;

    if (from_depth == 24 || from_depth == 32)
    {
        swap: byte;
        for i in 0..<(img.width*img.height)
        {
            blue := &img.data[i*components+0];
            red  := &img.data[i*components+2];
            blue^, red^ = red^, blue^;
        }
    }
    else
    {
        expanded := make([]byte, img.width*img.height * 3);

        for i in 0..<(img.width*img.height)
        {
            pixel := (^u16)(&img.data[i*2])^;
            r := i32(pixel >> 10 & 0x1f);
            g := i32(pixel >> 5  & 0x1f);
            b := i32(pixel >> 0  & 0x1f);
            
            expanded[i*3+0] = byte((r * 255)/31);
            expanded[i*3+1] = byte((g * 255)/31);
            expanded[i*3+2] = byte((b * 255)/31);
        }

        delete(img.data);
        img.data = expanded;
    }
}

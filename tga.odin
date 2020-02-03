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
        case 8,15,16,24,32: break;
        case: return false;
        }
    }
    else
    {
        switch image_type
        {
        case 2,3,10,11: break;
        case: return false;
        }
    }

    if width < 1 || height < 1 do return false;
    if cmap_type == 1 && pixel_depth != 8 && pixel_depth != 16 do return false;
    switch pixel_depth
    {
    case 8,15,16,24,32: break;
    case: return false;
    }

    return true;
}

load_tga :: proc(filepath: string, desired_format: Image_Format = nil) -> (image: Image)
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

    // Read Header
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
    
    /* fmt.printf("======= Load TGA (%s) =======\n", filepath); */
    /* fmt.printf("cmap_type: %d\n", cmap_type); */
    /* fmt.printf("cmap_start: %d\n", cmap_start); */
    /* fmt.printf("cmap_len: %d\n", cmap_len); */
    /* fmt.printf("cmap_depth: %d\n", cmap_depth); */

    /* fmt.printf("id_length: %d\n", id_length); */
    /* fmt.printf("image_type: %d\n", image_type); */
    /* fmt.printf("  RLE?: %s\n", RLE?"Yes":"No"); */
    /* fmt.printf("width: %d\n", width); */
    /* fmt.printf("height: %d\n", height); */
    /* fmt.printf("pixel_depth: %d\n", pixel_depth); */
    /* fmt.printf("image_descriptor: %d\n", image_descriptor); */
    /* fmt.printf("========================\n"); */
    
    pixel_depth_bytes := (pixel_depth + 7) >> 3;
    cmap_depth_bytes  := (cmap_depth  + 7) >> 3;

    // Read image ID
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

    // Read color map, if it exists
    cmap_data := make([]byte, cmap_len*u16(cmap_depth_bytes));
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

    // Read raw image data
    raw_image_data := make([]byte, width*height * u16(pixel_depth_bytes));
    image_size, _ := os.read(file, raw_image_data);
    if image_size == 0
    {
        fmt.eprintf("Could not read image data in TGA %q", filepath);
        return;
    }

    image_data := raw_image_data;
    
    decoded_data_size := width*height * u16(pixel_depth_bytes);
    image_data_size: int;

    if cmap_type != 0 do
        image_data_size = int(width*height * u16(cmap_depth_bytes));
    else do
        image_data_size = int(decoded_data_size);

    // Read Run Length Encoded data
    if RLE
    {
        decoded_image_data := make([]byte, decoded_data_size);
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
                bytes_to_copy := int(pixel_depth_bytes)*(count+1);
                mem.copy(&decoded_image_data[decoded_index], &image_data[i], bytes_to_copy);
                i += bytes_to_copy;
                decoded_index += bytes_to_copy;
                pixel_count += count+1;
            }
        }
        delete(image_data);
        image_data = decoded_image_data;
    }

    // Expand color map indices to color data
    result_depth := pixel_depth;
    if cmap_type != 0
    {
        colormapped_image_data := make([]byte, image_data_size);
        colormapped_index := 0;
        for i in 0..<(int(width*height))
        {
            mem.copy(&colormapped_image_data[colormapped_index],
                     &cmap_data[int(image_data[i*int(pixel_depth_bytes)])*int(cmap_depth_bytes)],
                     int(cmap_depth_bytes));
            colormapped_index += int(cmap_depth_bytes);
        }
        delete(image_data);
        image_data = colormapped_image_data;
        result_depth = cmap_depth;
    }

    // Determine final image format
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

    image.data = image_data;
    image.width = u32(width);
    image.height = u32(height);

    image.depth = result_depth <= 16 ? 5 : 8;
    converted := convert_format_tga(image, image.format, 8);
    delete(image.data);
    
    image.data = converted;
    image.depth = 8;

    return image;
}

write_tga_to_mem :: proc(img: Image, format: Image_Format, depth: u32) -> []byte
{
    if format == .GRAY || format == .GRAYA 
    {
        fmt.eprintf("ERROR: Cannot not encoded TGA image as grayscale\n");
        return nil;
    }

    if depth != 5 && depth != 8
    {
        fmt.eprintf("ERROR: Invalid bitdepth '%d'\n", depth);
        return nil;
    }
    
    img := img;
    // Convert Format
    img.data = convert_format_tga(img, format, depth);
    img.format = format;
    img.depth = depth;
    
    // Run Length Encode
    encoded := run_length_encode(img);
    delete(img.data);

    // Write Header
    out := make([dynamic]byte);
    
    img_desc := byte(0);
    img_desc &= (img.depth * (u32(img.format)&7) == 32 ? 8 : 0);

    append(&out, 0); // ID Length
    append(&out, 0); // CMap Type
    append(&out, 10); // Image Type
    append(&out, 0, 0); // CMap Origin
    append(&out, 0, 0); // CMap Length
    append(&out, 0);    // CMap Depth
    append(&out, 0, 0); // X-Origin
    append(&out, 0, 0); // Y-Origin
    append(&out, byte(img.width&0x00ff),  byte((img.width&0xff00)>>8));
    append(&out, byte(img.height&0x00ff), byte((img.height&0xff00)>>8));
    append(&out, img.depth == 5 ? 16 : (byte(img.format)&7)*8);
    append(&out, img_desc);
    append(&out, ..encoded);

    ret := make([]byte, len(out));
    copy(ret, out[:]);
    delete(out);
    
    return ret;
}

run_length_encode :: proc(img: Image) -> []byte
{
    encoded := make([dynamic]byte);

    pixel_bytes := img.depth == 5 ? 2 : u32(img.format) & 7;
    watch := img.data[:pixel_bytes];
    count := u8(1);
    lcount := u8(0);
    i, ii: u32;
    for p in 1..<(int(img.width*img.height))
    {
        i  = u32(p)  *pixel_bytes;
        ii = u32(p+1)*pixel_bytes;

        cur := img.data[i:ii];
        
        if mem.compare(watch, cur) == 0
        {
            if lcount > 0
            {
                append(&encoded, 0x7F & (lcount-1));
                append(&encoded, ..img.data[i-(u32(lcount+1)*pixel_bytes):i-pixel_bytes]);
                lcount = 0;
            }
            count += 1;
            if count == 128
            {
                append(&encoded, 0x80 | (count-1));
                append(&encoded, ..watch);
                count = 0;
            }
        }
        else
        {
            if count > 1
            {
                append(&encoded, 0x80 | (count-1));
                append(&encoded, ..watch);
                watch = cur;
                count = 1;
            }
            else
            {
                lcount += 1;
                watch = cur;
                if lcount == 128
                {
                    append(&encoded, (lcount-1));
                    append(&encoded, ..img.data[i-(u32(lcount+1)*pixel_bytes):i-pixel_bytes]);
                    lcount = 1;
                }
            }
            watch = cur;
        }
    }

    if count > 0
    {
        append(&encoded, 0x80 | (count-1));
        append(&encoded, ..watch);
        count = 0;
    }
    else if lcount > 0
    {
        append(&encoded, 0x7F & (lcount-1));
        append(&encoded, ..img.data[i-(u32(lcount+1)*pixel_bytes):i-pixel_bytes]);
        lcount = 0;
    }
    else
    {
        fmt.eprintf("RLE ERROR\n");
        os.exit(1);
    }

    out := make([]byte, len(encoded));
    copy(out, encoded[:]);
    delete(encoded);

    return out;
}

write_tga :: proc(img: Image, filepath: string, format: Image_Format, depth: u32)
{
    encoded := write_tga_to_mem(img, format, depth);
    defer delete(encoded);

    os.write_entire_file(filepath, encoded);
}

@private
convert_format_tga :: proc(img: Image, to_format: Image_Format, to_depth: u32) -> []byte
{
    Change :: enum
    {
        Remove = -1,
        None   =  0,
        Add    =  1,
    };

    src_comp := u32(img.format) & 7;
    out_comp := u32(to_format) & 7;
    
    change_depth := Change(int(to_depth>>3) - int(img.depth>>3));
    change_alpha := Change(int(src_comp % 2) - int(out_comp % 2));
    
    src_pixel_bytes := img.depth == 5 ? 2 : src_comp;
    out_pixel_bytes := to_depth  == 5 ? 2 : out_comp;
    
    converted := make([]byte, img.width*img.height*out_pixel_bytes);
    for p in 0..<(img.width*img.height)
    {

        // Change depth, and swap RGB <-> BGR
        switch change_depth
        {
        case .Remove:
            dest := (^u16)(&converted[p*2]);
            dest^ |= u16(img.data[p*src_comp+0] & 0xf8) << 7;
            dest^ |= u16(img.data[p*src_comp+1] & 0xf8) << 2;
            dest^ |= u16(img.data[p*src_comp+2] & 0xf8) >> 3;
            
        case .Add:
            pixel := (^u16)(&img.data[p*2])^;
            r := u16(pixel >> 10 & 0x1f);
            g := u16(pixel >> 5  & 0x1f);
            b := u16(pixel >> 0  & 0x1f);
            
            converted[p*out_comp+0] = byte((r * 255)/31);
            converted[p*out_comp+1] = byte((g * 255)/31);
            converted[p*out_comp+2] = byte((b * 255)/31);
            
        case .None:
            if to_depth == 8
            {
                converted[p*out_comp+0] = img.data[p*src_comp+2];
                converted[p*out_comp+1] = img.data[p*src_comp+1];
                converted[p*out_comp+2] = img.data[p*src_comp+0];
            }
            else
            {
                pixel := (^u16)(&img.data[p*2])^;
                r := u16(pixel >> 10 & 0x1f);
                g := u16(pixel >> 5  & 0x1f);
                b := u16(pixel >> 0  & 0x1f);

                dest := (^u16)(&converted[p*2]);
                dest^ |= b << 10;
                dest^ |= g << 5;
                dest^ |= r << 0;
            }
        }

        switch change_alpha
        {
        case .Remove: break; // Ignore
            
        case .Add:
            if to_depth == 5 do
                converted[p*2+1] |= 0x80;
            else do
                converted[p*4+3] = 255;
            
        case .None:
            if src_comp % 2 != 0 do break;
            switch change_depth
            {
            case .Remove:
                converted[p*2+1] |= img.data[p*4+3] & 0x80;
            case .Add:
                converted[p*4+3]  = ((img.data[p*2+1] & 0x80) >> 7) * 255;
            case .None:
                if to_depth == 5 do
                    converted[p*2+1] |= img.data[p*2+1] & 0x80;
                else do
                    converted[p*4+3]  = img.data[p*4+3];
            }
        }
    }

    return converted;
}

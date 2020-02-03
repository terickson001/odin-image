package image

flip_y :: proc(img: ^Image)
{
    pixel_depth := img.depth == 16 ? 2 : 1;
    
    row_size := u32(img.width) * (u32(img.format) & 7) * u32(pixel_depth);
    end := row_size * img.height;
    swap := make([]byte, row_size);
    for row in 0..<(img.height/2)
    {
        a := img.data[row*row_size:(row+1)*row_size];
        b := img.data[end-(row+1)*row_size:end-row*row_size];
        copy(swap, a);
        copy(a, b);
        copy(b, swap);
    }
    delete(swap);
}

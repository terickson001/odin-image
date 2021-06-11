package util

import "core:fmt"
import "core:strings"
import "core:strconv"
import "core:os"

char_is_alpha :: proc(c: u8) -> bool
{
    return ('a' <= c && c <= 'z') || ('A' <= c && c <= 'Z');
}

char_is_num :: proc(c: u8) -> bool
{
    return '0' <= c && c <= '9';
}

char_is_alphanum :: proc(c: u8) -> bool
{
    return char_is_alpha(c) || char_is_num(c);
}

char_is_ident :: proc(c: u8) -> bool
{
    return char_is_alphanum(c) || c == '_';
}

read_char :: proc(str: ^string, ret: ^byte) -> bool
{
    c := byte(0);
    defer if ret != nil do ret^ = c;
    
    if len(str^) == 0 do return false;
    
    c = str[0];
    str^ = str[1:];
    
    return true;
}

read_line :: proc(str: ^string, ret: ^string) -> bool
{
    line := string{};
    defer if ret != nil do ret^ = line;
    
    idx := 0;
    for idx < len(str) && str[idx] != '\n' do idx += 1;
    
    line = str[:idx];
    if idx == len(str)
    {
        str^ = string{};
        return true;
    }
    else if str[idx] == '\n'
    {
        str^ = str[idx+1:];
        return true;
    }
    else
    {
        str^ = string{};
        return false;
    }
}

read_ident :: proc(str: ^string, ret: ^string) -> bool
{
    ret^ = string{};
    idx := 0;
    
    if !char_is_ident(str[idx]) 
    {
        return false;
    }
    
    for char_is_ident(str[idx]) || str[idx] == '-' do idx += 1;
    
    if idx == 0 do return false;
    
    ret^ = str[:idx];
    str^ = str[idx:];
    return true;
}

read_string :: proc(str: ^string, ret: ^string) -> bool
{
    ret^ = string{};
    idx := 0;
    
    if str[idx] != '"' && str[idx] != '\'' do return false;
    
    quote := str[idx];
    idx += 1;
    
    for str[idx] != quote
    {
        if str[idx] == '\\' do idx += 1;
        idx += 1;
    }
    
    ret^ = str[1:idx];
    str^ = str[idx+1:];
    
    return true;
}

read_filepath :: proc(str: ^string, ret: ^string) -> bool
{
    ret^ = string{};
    idx := 0;
    
    char_is_path :: proc(c: u8) -> bool
    {
        return char_is_ident(c) || os.is_path_separator(rune(c)) || c == '.';
    }
    if !char_is_path(str[idx]) do return false;
    
    for char_is_path(str[idx])
    {
        if str[idx] == '\\' do idx += 1;
        idx += 1;
    }
    
    ret^ = str[:idx];
    str^ = str[idx:];
    
    return true;
}

read_whitespace :: proc(str: ^string, newline := false) -> bool
{
    idx := 0;
    
    loop: for idx+1 < len(str)
    {
        switch str[idx]
        {
            case '\t', '\v', '\f', ' ': break;
            case '\n', '\r': if !newline do break loop;
            case: break loop;
        }
        idx += 1;
    }
    
    if idx > 0 do str^ = str[idx:];
    
    return true;
}

read_non_whitespace :: proc(str: ^string, ret: ^string) -> bool
{
    ret^ = string{};
    idx := 0;
    
    loop: for idx+1 < len(str)
    {
        switch str[idx]
        {
            case '\t', '\v', '\f', ' ', '\n', '\r': break loop;
            case: idx += 1;
        }
    }
    
    if idx == 0 do return false;
    
    ret^ = str[:idx];
    str^ = str[idx:];
    
    return true;
}

read_custom_bool :: proc(str: ^string, true_str: string, false_str: string, ret: ^bool) -> bool
{
    ret^ = false;
    
    if strings.has_prefix(str^, true_str)
    {
        ret^ = true;
        str^ = str[len(true_str):];
    }
    else if strings.has_prefix(str^, false_str)
    {
        ret^ = false;
        str^ = str[len(false_str):];
    }
    else
    {
        return false;
    }
    
    return true;
}

read_surround :: proc(str: ^string, open, close: byte, ret: ^string) -> bool
{
    ret^ = string{};
    
    idx := 0;
    if str[idx] != open do return false;
    
    idx += 1;
    level := 1;
    for level > 0
    {
        if      str[idx] == open  do level += 1;
        else if str[idx] == close do level -= 1;
        idx += 1;
        if idx >= len(str) do return false;
    }
    
    ret^ = str[:idx];
    str^ = str[idx:];
    
    return true;
}

read_int :: proc(str: ^string, ret: $T/^$E) -> bool
{
    ret^ = 0;
    
    if len(str) == 0 do return false;
    
    sign := int(1);
    idx := 0;
    
    if str[idx] == '-'
    {
        sign = -1;
        idx += 1;
    }
    
    for idx < len(str) && '0' <= str[idx] && str[idx] <= '9'
    {
        ret^ *= 10;
        ret^ += E(str[idx] - '0');
        idx += 1;
    }
    
    ret^ *= E(sign);
    
    if idx == 0 do return false;
    
    str^ = str[idx:];
    return true;
}

read_float :: proc(str: ^string, ret: $T/^$E) -> bool
{
    ret^ = 0;
    
    if len(str) == 0 do return false;
    
    sign := E(1);
    idx := 0;
    
    if str[idx] == '-'
    {
        sign = -1;
        idx += 1;
    }
    
    for idx < len(str) && '0' <= str[idx] && str[idx] <= '9'
    {
        ret^ *= 10;
        ret^ += E(str[idx] - '0');
        idx += 1;
    }
    
    ret^ *= E(sign);
    
    if idx < len(str) && str[idx] == '.'
    {
        frac: E = 0;
        div:  E = 10.0;
        idx += 1;
        for idx < len(str) && char_is_num(str[idx])
        {
            frac += E(str[idx] - '0') / div;
            div *= 10;
            idx += 1;
        }
        ret^ += frac * sign;
    }
    
    str^ = str[idx:];
    return true;
}

read_any :: proc(str: ^string, arg: any, verb: u8 = 'v') -> bool
{
    ok := false;
    
    switch verb
    {
        case 'v':
        if arg == nil do panic("ERROR: Format specifier '%v' cannot be non-capturing");
        
        switch kind in arg
        {
            case ^f32:  ok = read_float(str, kind);
            case ^f64:  ok = read_float(str, kind);
            
            case ^i8:   ok = read_int(str, kind);
            case ^i16:  ok = read_int(str, kind);
            case ^i32:  ok = read_int(str, kind);
            case ^i64:  ok = read_int(str, kind);
            case ^i128: ok = read_int(str, kind);
            case ^int:  ok = read_int(str, kind);
            case ^u8:   ok = read_int(str, kind);
            case ^u16:  ok = read_int(str, kind);
            case ^u32:  ok = read_int(str, kind);
            case ^u64:  ok = read_int(str, kind);
            case ^u128: ok = read_int(str, kind);
            case ^uint: ok = read_int(str, kind);
            
            case ^string:
            if str[0] == '"' || str[0] == '\'' do ok = read_string(str, kind);
            else do ok = read_ident(str, kind);
            
            case: fmt.eprintf("Invalid type %T\n", kind);
        }
        
        case 'f':
        if arg == nil
        {
            temp: f64;
            return read_float(str, &temp);
        }
        
        switch kind in arg
        {
            case ^f32:  ok = read_float(str, kind);
            case ^f64:  ok = read_float(str, kind);
            case: fmt.eprintf("Invalid type %T for specifier %%%c\n", kind, verb);
        }
        
        case 'd':
        if arg == nil
        {
            temp: i64;
            return read_int(str, &temp);
        }
        
        switch kind in arg
        {
            case ^i8:   ok = read_int(str, kind);
            case ^i16:  ok = read_int(str, kind);
            case ^i32:  ok = read_int(str, kind);
            case ^i64:  ok = read_int(str, kind);
            case ^i128: ok = read_int(str, kind);
            case ^int:  ok = read_int(str, kind);
            
            case ^u8:   ok = read_int(str, kind);
            case ^u16:  ok = read_int(str, kind);
            case ^u32:  ok = read_int(str, kind);
            case ^u64:  ok = read_int(str, kind);
            case ^u128: ok = read_int(str, kind);
            case ^uint: ok = read_int(str, kind);
            
            case: fmt.eprintf("Invalid type %T for specifier %%%c\n", kind, verb);
        }
        
        case 'c':
        if arg == nil do return read_char(str, nil);
        
        switch kind in arg
        {
            case ^u8: ok = read_char(str, kind);
            case: fmt.eprintf("Invalid type %T for specifier %%%c\n", kind, verb);
        }
        
        case 'q':
        if arg == nil
        {
            temp: string;
            return read_string(str, &temp);
        }
        
        switch kind in arg
        {
            case ^string: ok = read_string(str, kind);
            
            case: fmt.eprintf("Invalid type %T for specifier %%%c\n", kind, verb);
        }
        
        case 's':
        if arg == nil
        {
            temp: string;
            return read_ident(str, &temp);
        }
        
        switch kind in arg
        {
            case ^string: ok = read_ident(str, kind);
            
            case: fmt.eprintf("Invalid type %T for specifier %%%c\n", kind, verb);
        }
        
        case 'W':
        if arg == nil
        {
            temp: string;
            return read_non_whitespace(str, &temp);
        }
        
        switch kind in arg
        {
            case ^string: ok = read_non_whitespace(str, kind);
            
            case: fmt.eprintf("Invalid type %T for specifier %%%c\n", kind, verb);
        }
        
        case 'F':
        if arg == nil
        {
            temp: string;
            return read_filepath(str, &temp);
        }
        
        switch kind in arg
        {
            case ^string: ok = read_filepath(str, kind);
            
            case: fmt.eprintf("Invalid type %T for specifier %%%c\n", kind, verb);
        }
        
        case '_':
        ok = read_whitespace(str, false);
        
        case '>':
        ok = read_whitespace(str, true);
        
        case: fmt.eprintf("Invalid format specifier %%%c\n", verb);
    }
    
    return ok;
}

read_types :: proc(str: ^string, args: ..any) -> bool
{
    ok: bool;
    for v in args
    {
        ok = read_any(str, v);
        if len(str) > 0 do str^ = strings.trim_left_space(str^);
        if !ok do return false;
    }
    return true;
}

read_fmt :: proc(str: ^string, fmt_str: string, args: ..any) -> bool
{
    ok: bool;
    
    sidx := 0;
    fidx := 0;
    aidx := 0;
    
    for fidx < len(fmt_str)
    {
        if sidx >= len(str) do return false;
        if fmt_str[fidx] != '%'
        {
            
            if str[sidx] == fmt_str[fidx]
            {
                sidx += 1;
                fidx += 1;
                continue;
            }
            else if fmt_str[fidx] == '\n' && strings.has_prefix(str[sidx:], "\r\n")
            {
                sidx += 2;
                fidx += 1;
                continue;
            }
            else
            {
                if sidx > 0 do str^ = str[sidx:];
                return false;
            }
        }
        
        /* if aidx >= len(args) do */
        /*     return false; */
        
        str^ = str[sidx:];
        sidx = 0;
        fidx += 1; // %
        
        
        
        capture := true;
        if fmt_str[fidx] == '^' // %^s (non-capturing)
        {
            capture = false;
            fidx += 1;
        }
        
        arg: any = nil;
        if capture && aidx < len(args) do arg = args[aidx];
        switch fmt_str[fidx]
        {
            case 'v': fallthrough;
            case 'f': fallthrough;
            case 'd': fallthrough;
            case 'c': fallthrough;
            case 'q': fallthrough;
            case 's': fallthrough;
            case 'F': fallthrough;
            case 'W': fallthrough;
            case 'b':
            ok = read_any(str, arg, fmt_str[fidx]);
            if capture do aidx += 1;
            fidx += 1;
            
            case '_': fallthrough;
            case '>':
            ok = read_any(str, nil, fmt_str[fidx]);
            fidx += 1;
            
            case 'B':
            fmt_copy := fmt_str[fidx+1:];
            true_str: string;
            false_str: string;
            if !read_fmt(&fmt_copy, "{%_%s%_,%_%s%_}", &true_str, &false_str)
            {
                fmt.eprintf("Format specifier %%B must be followed by boolean specifiers: {true,false}\n");
                break;
            }
            
            switch kind in arg
            {
                case ^bool: ok = read_custom_bool(str, true_str, false_str, kind);
                case: fmt.eprintf("Invalid type %T for specifier %%B\n", kind);
            }
            
            if capture do aidx += 1;
            fidx += len(fmt_str) - len(fmt_copy) - 1;
            
            case 'S':
            fmt_copy := fmt_str[fidx+1:];
            open, close: byte;
            if !read_fmt(&fmt_copy, "%c%c", &open, &close)
            {
                fmt.eprintf("Format specifier %%S must be followed by delimiter characters: i.e %%S(), %%S{}\n");
                break;
            }
            
            if arg == nil
            {
                temp: string;
                ok = read_surround(str, open, close, &temp);
            }
            
            switch kind in arg
            {
                case ^string: ok = read_surround(str, open, close, kind);
                case: fmt.eprintf("Invalid type %T for specifier %%S\n", kind);
            }
            
            if capture do aidx += 1;
            fidx += 3;
            
            case:
            fmt.eprintf("Invalid format specifier '%%%c'\n", fmt_str[fidx]);
            return false;
        }
        if !ok do return false;
    }
    str^ = str[sidx:];
    return true;
}

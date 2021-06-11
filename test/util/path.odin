package util

@private
is_sep :: proc(c: byte) -> bool
{
    result := c == '/';
    when ODIN_OS == "windows" 
    {
        result ||= c == '\\';
    }
    return result;
}

when ODIN_OS == "windows" do SEP :: "\\";
else do SEP :: "/";

dir :: proc(path: string) -> string
{
    idx := len(path)-1;
    for idx >= 0
    {
        if is_sep(path[idx])
        {
            if idx == 0 
            {
                return SEP;
            }
            else 
            {
                return path[:idx];
            }
        }
        idx -= 1;
    }
    
    return "";
}

base :: proc(path: string, keep_ext := true) -> string
{
    end := len(path);
    idx := end-1;
    res := string{};
    
    for idx >= 0
    {
        if is_sep(path[idx])
        {
            if idx == end-1
            {
                end = idx;
            }
            else
            {
                return path[idx+1:end];
            }
        }
        else if path[idx] == '.' && !keep_ext
        {
            end = idx;
        }
        idx -= 1;
    }
    
    return path[:end];
}

name :: proc(path: string) -> string
{
    return base(path, false);
}

ext :: proc(path: string) -> string
{
    idx := len(path)-1;
    
    for idx >= 0
    {
        if path[idx] == '.' 
        {
            return path[idx+1:];
        }
        if is_sep(path[idx]) do return "";
        idx -= 1;
    }
    
    return "";
}

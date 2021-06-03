@version 430 core

@vertex
layout(location = 0) in vec3 vertex_position;
layout(location = 1) in vec2 vertex_uv;
@out frag
{
    vec3 position;
    vec2 uv;
};

void main()
{
    frag.position = vertex_position;
    frag.uv = vertex_uv;
    
    gl_Position = vec4(vertex_position, 1);
}

@fragment

@in frag;

out vec3 color;
uniform sampler2D albedo_map;

void main()
{
    //color = vec3(1, 0, 0);
    vec3 hdr = texture(albedo_map, frag.uv).rgb;
    float I = (20*hdr.r + 40*hdr.g + hdr.b) / 61;
    float logI = log(I);
    
    color = hdr / (hdr + vec3(1.0));
    color = pow(color, vec3(1.0/2.2));
}
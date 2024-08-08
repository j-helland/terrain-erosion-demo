#version 330 core
out vec4 FragColor;

in VS_OUT {
    float Height;
    vec3 Position;
    vec3 Normal;
} fs_in;

vec2 brighten(vec2 v)
{
    return sqrt(v);
}

void main()
{
    // Slightly nicer looking erosion near the floor.
    if (fs_in.Height < 1e-6) discard;

    // Use planar normal data for R and B channels.
    // Mix in height to G channel and scale luminosity by height (bottom smoothly disappears from view).
    vec2 n = brighten(0.5 * (normalize(fs_in.Normal.xz) + 1.0));
    vec3 c = sqrt(fs_in.Height) * normalize(vec3(n.x, 0.5 * fs_in.Height, n.y));
    FragColor = vec4(c, 1.0);
}
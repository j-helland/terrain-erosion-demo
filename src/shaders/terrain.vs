#version 330 core
layout (location = 0) in vec3 aPos;
layout (location = 1) in vec3 aNormal;

out VS_OUT {
    float Height;
    vec3 Position;
    vec3 Normal;
} vs_out;

uniform mat4 uModel;
uniform mat4 uView;
uniform mat4 uProjection;

void main()
{
    vs_out.Height = aPos.y;
    vs_out.Position = (uView * uModel * vec4(aPos, 1.0)).xyz;
    vs_out.Normal = mat3(inverse(transpose(uModel))) * aNormal; // TODO: normal matrix should be CPU side and sent as uniform
    gl_Position = uProjection * uView * uModel * vec4(aPos, 1.0);
}

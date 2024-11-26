const THREAD_COUNT = 16;
const PI = 3.1415927f;
const MAX_DIST = 1000.0;

@group(0) @binding(0)  
  var<storage, read_write> fb : array<vec4f>;

@group(1) @binding(0)
  var<storage, read_write> uniforms : array<f32>;

@group(2) @binding(0)
  var<storage, read_write> shapesb : array<shape>;

@group(2) @binding(1)
  var<storage, read_write> shapesinfob : array<vec4f>;

struct shape {
  transform : vec4f, // xyz = position
  radius : vec4f, // xyz = scale, w = global scale
  rotation : vec4f, // xyz = rotation
  op : vec4f, // x = operation, y = k value, z = repeat mode, w = repeat offset
  color : vec4f, // xyz = color
  animate_transform : vec4f, // xyz = animate position value (sin amplitude), w = animate speed
  animate_rotation : vec4f, // xyz = animate rotation value (sin amplitude), w = animate speed
  quat : vec4f, // xyzw = quaternion
  transform_animated : vec4f, // xyz = position buffer
};

struct march_output {
  color : vec3f,
  depth : f32,
  outline : bool,
};

fn op_smooth_union(d1: f32, d2: f32, col1: vec3f, col2: vec3f, k: f32) -> vec4f
{
  // União suave usando um fator k
  var h = clamp(0.5 + 0.5 * (d2 - d1) / max(k, 0.0001), 0.0, 1.0);

  // Interpola cores suavemente
  var color = mix(col2, col1, h);

  // Calcula a distância final
  var dist = mix(d2, d1, h);

  return vec4f(color, dist);
}

fn op_smooth_subtraction(d1: f32, d2: f32, col1: vec3f, col2: vec3f, k: f32) -> vec4f
{
  var k_eps = max(k, 0.0001);
  return vec4f(col1, d1);
}

fn op_smooth_intersection(d1: f32, d2: f32, col1: vec3f, col2: vec3f, k: f32) -> vec4f
{
  var k_eps = max(k, 0.0001);
  return vec4f(col1, d1);
}

fn op(op: f32, d1: f32, d2: f32, col1: vec3f, col2: vec3f, k: f32) -> vec4f
{
  // union
  if (op < 1.0)
  {
    return op_smooth_union(d1, d2, col1, col2, k);
  }

  // subtraction
  if (op < 2.0)
  {
    return op_smooth_subtraction(d2, d1, col2, col1, k);
  }

  // intersection
  return op_smooth_intersection(d2, d1, col2, col1, k);
}

fn repeat(p: vec3f, offset: vec3f) -> vec3f
{
  return modc(p + 0.5 * offset, offset) - 0.5 * offset;
}

fn transform_p(p: vec3f, option: vec2f) -> vec3f
{
  // normal mode
  if (option.x <= 1.0)
  {
    return p;
  }

  // return repeat / mod mode
  return repeat(p, vec3f(option.y));
}

fn scene(p: vec3f) -> vec4f // xyz = color, w = distance
{
    var d = mix(100.0, p.y, uniforms[17]);

    var spheresCount = i32(uniforms[2]);
    var boxesCount = i32(uniforms[3]);
    var torusCount = i32(uniforms[4]);

    var all_objects_count = spheresCount + boxesCount + torusCount;
    var result = vec4f(vec3f(1.0), d);

    for (var i = 0; i < all_objects_count; i = i + 1)
    {
      // get shape and shape order (shapesinfo)
      // shapesinfo has the following format:
      // x: shape type (0: sphere, 1: box, 2: torus)
      // y: shape index
      // order matters for the operations, they're sorted on the CPU side

      // call transform_p and the sdf for the shape
      // call op function with the shape operation

      // op format:
      // x: operation (0: union, 1: subtraction, 2: intersection)
      // y: k value
      // z: repeat mode (0: normal, 1: repeat)
      // w: repeat offset

      // Get shape information
      let shape_info = shapesinfob[i];
      let shape_type = i32(shape_info.x);
      let shape_index = i32(shape_info.y);
      let shape = shapesb[shape_index];

      // Apply transformations
      var pos = p - shape.transform.xyz;
      pos = transform_p(pos, shape.op.zw);

      // Compute SDF based on shape type
      var dist = 0.0;
      var color = shape.color.xyz;

      if (shape_type == 0) {
        dist = sdf_sphere(pos, shape.radius, shape.quat);
      } else if (shape_type == 1) {
        dist = sdf_round_box(pos, shape.radius.xyz, shape.radius.w, shape.quat);
      } else if (shape_type == 2) {
        dist = sdf_torus(pos, shape.radius.xy, shape.quat);
      }

      if (i == 0) {
        result = vec4f(color, dist);
      } else {
        result = op(shape.op.x, result.w, dist, result.xyz, color, shape.op.y);
      }
    }

    return result;
}

fn march(ro: vec3f, rd: vec3f) -> march_output
{
  var max_marching_steps = i32(uniforms[5]);
  var EPSILON = uniforms[23];

  var depth = 0.0;
  var color = vec3f(0.0);
  var march_step = uniforms[22];
  
  for (var i = 0; i < max_marching_steps; i = i + 1)
  {
      // raymarch algorithm
      // call scene function and march
      // if the depth is greater than the max distance or the distance is less than the epsilon, break
      var p = ro + rd * depth;
      var scene_result = scene(p);

      if (scene_result.w < EPSILON) {
          color = scene_result.xyz;
          break;
      }

      depth += scene_result.w;

      if (depth > MAX_DIST) {
          break;
      }
  }

  return march_output(color, depth, false);
}

fn get_normal(p: vec3f) -> vec3f
{
  let epsilon = 0.001;
  return normalize(vec3f(
      scene(p + vec3f(epsilon, 0.0, 0.0)).w - scene(p - vec3f(epsilon, 0.0, 0.0)).w,
      scene(p + vec3f(0.0, epsilon, 0.0)).w - scene(p - vec3f(0.0, epsilon, 0.0)).w,
      scene(p + vec3f(0.0, 0.0, epsilon)).w - scene(p - vec3f(0.0, 0.0, epsilon)).w
  ));
}

// https://iquilezles.org/articles/rmshadows/
fn get_soft_shadow(ro: vec3f, rd: vec3f, tmin: f32, tmax: f32, k: f32) -> f32
{
  var res = 1.0; // Inicializa o resultado como "sem sombra"
  var t = tmin; // Começa do valor mínimo de profundidade

  // Percorre o raio para calcular a sombra suave
  while (t < tmax) {
      var p = ro + t * rd; // Ponto atual ao longo do raio
      var d = scene(p).w; // Distância até o objeto mais próximo

      if (d < 0.001) {
          // Se a distância for menor que um epsilon, o ponto está dentro da sombra
          return 0.0;
      }

      // Calcula a fração de sombra com base na distância
      res = min(res, k * d / t);

      // Avança ao longo do raio com um limite mínimo e máximo para estabilidade
      t += clamp(d, 0.01, 0.1); // Avanço baseado na distância
  }

  // Garante que o valor esteja no intervalo [0, 1]
  return clamp(res, 0.0, 1.0);
}

fn get_AO(current: vec3f, normal: vec3f) -> f32
{
  var occ = 0.0;
  var sca = 1.0;
  for (var i = 0; i < 5; i = i + 1)
  {
    var h = 0.001 + 0.15 * f32(i) / 4.0;
    var d = scene(current + h * normal).w;
    occ += (h - d) * sca;
    sca *= 0.95;
  }

  return clamp( 1.0 - 2.0 * occ, 0.0, 1.0 ) * (0.5 + 0.5 * normal.y);
}

fn get_ambient_light(light_pos: vec3f, sun_color: vec3f, rd: vec3f) -> vec3f
{
  var backgroundcolor1 = int_to_rgb(i32(uniforms[12]));
  var backgroundcolor2 = int_to_rgb(i32(uniforms[29]));
  var backgroundcolor3 = int_to_rgb(i32(uniforms[30]));
  
  var ambient = backgroundcolor1 - rd.y * rd.y * 0.5;
  ambient = mix(ambient, 0.85 * backgroundcolor2, pow(1.0 - max(rd.y, 0.0), 4.0));

  var sundot = clamp(dot(rd, normalize(vec3f(light_pos))), 0.0, 1.0);
  var sun = 0.25 * sun_color * pow(sundot, 5.0) + 0.25 * vec3f(1.0,0.8,0.6) * pow(sundot, 64.0) + 0.2 * vec3f(1.0,0.8,0.6) * pow(sundot, 512.0);
  ambient += sun;
  ambient = mix(ambient, 0.68 * backgroundcolor3, pow(1.0 - max(rd.y, 0.0), 16.0));

  return ambient;
}

fn get_light(current: vec3f, obj_color: vec3f, rd: vec3f) -> vec3f
{
  var light_position = vec3f(uniforms[13], uniforms[14], uniforms[15]);
  var sun_color = int_to_rgb(i32(uniforms[16]));
  var ambient = get_ambient_light(light_position, sun_color, rd);
  var normal = get_normal(current);

  // calculate light based on the normal
  // if the object is too far away from the light source, return ambient light
  if (length(current) > uniforms[20] + uniforms[8])
  {
    return ambient;
  }

  // calculate the light intensity
  // Use:
  // - shadow
  // - ambient occlusion (optional)
  // - ambient light
  // - object color

  // Cálculo da direção da luz (do ponto atual para a luz)
  var light_dir = normalize(light_position - current);

  // Intensidade difusa (modelo Lambertian)
  var diff_intensity = max(dot(normal, light_dir), 0.0);

  // Cálculo de sombras suaves (projeção de sombras no plano)
  var shadow = get_soft_shadow(current + normal * uniforms[23], light_dir, 0.001, MAX_DIST, 32.0);

  // Ambient Occlusion (opcional)
  var ao = get_AO(current, normal);

  // Luz difusa final com sombras e AO
  var diffuse = diff_intensity * obj_color * sun_color * shadow * ao;

  // Modula a luz ambiente com o AO
  ambient = ambient * ao * obj_color;

  // Combina a luz ambiente e difusa
  var color = mix(ambient, diffuse, diff_intensity);

  // Garante que os valores de cor estejam no intervalo [0, 1]
  return clamp(color, vec3f(0.0), vec3f(1.0));
}

fn set_camera(ro: vec3f, ta: vec3f, cr: f32) -> mat3x3<f32>
{
  var cw = normalize(ta - ro);
  var cp = vec3f(sin(cr), cos(cr), 0.0);
  var cu = normalize(cross(cw, cp));
  var cv = normalize(cross(cu, cw));
  return mat3x3<f32>(cu, cv, cw);
}

fn animate(val: vec3f, time_scale: f32, offset: f32) -> vec3f
{
  return vec3f(0.0);
}

@compute @workgroup_size(THREAD_COUNT, 1, 1)
fn preprocess(@builtin(global_invocation_id) id : vec3u)
{
  var time = uniforms[0];
  var spheresCount = i32(uniforms[2]);
  var boxesCount = i32(uniforms[3]);
  var torusCount = i32(uniforms[4]);
  var all_objects_count = spheresCount + boxesCount + torusCount;

  if (id.x >= u32(all_objects_count))
  {
    return;
  }

  // optional: performance boost
  // Do all the transformations here and store them in the buffer since this is called only once per object and not per pixel
}

@compute @workgroup_size(THREAD_COUNT, THREAD_COUNT, 1)
fn render(@builtin(global_invocation_id) id : vec3u)
{
  // unpack data
  var fragCoord = vec2f(f32(id.x), f32(id.y));
  var rez = vec2(uniforms[1]);
  var time = uniforms[0];

  // camera setup
  var lookfrom = vec3(uniforms[6], uniforms[7], uniforms[8]);
  var lookat = vec3(uniforms[9], uniforms[10], uniforms[11]);
  var camera = set_camera(lookfrom, lookat, 0.0);
  var ro = lookfrom;

  // get ray direction
  var uv = (fragCoord - 0.5 * rez) / rez.y;
  uv.y = -uv.y;
  var rd = camera * normalize(vec3(uv, 1.0));

  // call march function and get the color/depth
  // move ray based on the depth
  // get light
  var color = vec3f(1.0);
  var march_result = march(ro, rd);
  var p = ro + march_result.depth * rd;
  color = get_light(p, march_result.color, rd);
  
  // display the result
  color = linear_to_gamma(color);
  fb[mapfb(id.xy, uniforms[1])] = vec4(color, 1.0);
}
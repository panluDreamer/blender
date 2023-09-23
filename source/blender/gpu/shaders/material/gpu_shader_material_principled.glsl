/* SPDX-FileCopyrightText: 2019-2023 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

vec3 tint_from_color(vec3 color)
{
  float lum = dot(color, vec3(0.3, 0.6, 0.1));  /* luminance approx. */
  return (lum > 0.0) ? color / lum : vec3(1.0); /* normalize lum. to isolate hue+sat */
}

float principled_sheen(float NV, float rough)
{
  /* Empirical approximation (manual curve fitting) to the sheen albedo. Can be refined. */
  float den = 35.6694f * rough * rough - 24.4269f * rough * NV - 0.1405f * NV * NV +
              6.1211f * rough + 0.28105f * NV - 0.1405f;
  float num = 58.5299f * rough * rough - 85.0941f * rough * NV + 9.8955f * NV * NV +
              1.9250f * rough + 74.2268f * NV - 0.2246f;
  return saturate(den / num);
}

float ior_from_F0(float F0)
{
  float f = sqrt(clamp(F0, 0.0, 0.99));
  return (-f - 1.0) / (f - 1.0);
}

void node_bsdf_principled(vec4 base_color,
                          float metallic,
                          float roughness,
                          float ior,
                          float transmission,
                          float alpha,
                          vec3 N,
                          float weight,
                          float subsurface,
                          vec3 subsurface_radius,
                          float subsurface_scale,
                          float subsurface_ior,
                          float subsurface_anisotropy,
                          float specular,
                          vec4 specular_tint,
                          float anisotropic,
                          float anisotropic_rotation,
                          vec3 T,
                          float coat,
                          float coat_roughness,
                          float coat_ior,
                          vec4 coat_tint,
                          vec3 CN,
                          float sheen,
                          float sheen_roughness,
                          vec4 sheen_tint,
                          vec4 emission,
                          float emission_strength,
                          const float do_diffuse,
                          const float do_coat,
                          const float do_refraction,
                          const float do_multiscatter,
                          float do_sss,
                          out Closure result)
{
  /* Match cycles. */
  metallic = clamp(metallic, 0.0, 1.0);
  roughness = clamp(roughness, 0.0, 1.0);
  ior = max(ior, 1e-5);
  transmission = clamp(transmission, 0.0, 1.0);
  subsurface = clamp(subsurface, 0.0, 1.0);
  specular = max(specular, 0.0);
  specular_tint = max(specular_tint, vec4(0.0));
  /* Not used by EEVEE */
  /* anisotropic = clamp(anisotropic, 0.0, 1.0) */
  coat = clamp(coat, 0.0, 1.0);
  coat_roughness = clamp(coat_roughness, 0.0, 1.0);
  coat_ior = max(coat_ior, 1.0);
  sheen = clamp(sheen, 0.0, 1.0);
  sheen_roughness = clamp(sheen_roughness, 0.0, 1.0);
  emission_strength = max(emission_strength, 0.0);
  alpha = clamp(alpha, 0.0, 1.0);

  N = safe_normalize(N);
  CN = safe_normalize(CN);
  vec3 V = cameraVec(g_data.P);
  float NV = dot(N, V);

  ClosureTransparency transparency_data;
  transparency_data.weight = weight;
  transparency_data.transmittance = vec3(1.0 - alpha);
  transparency_data.holdout = 0.0;
  weight *= alpha;

  /* First layer: Sheen */
  /* TODO: Maybe sheen should be specular. */
  vec3 sheen_color = sheen * sheen_tint.rgb * principled_sheen(NV, sheen_roughness);
  ClosureDiffuse diffuse_data;
  diffuse_data.color = weight * sheen_color;
  diffuse_data.N = N;
  /* Attenuate lower layers */
  weight *= (1.0 - max_v3(sheen_color));

  /* Second layer: Coat */
  ClosureReflection coat_data;
  coat_data.N = CN;
  coat_data.roughness = coat_roughness;
  float coat_NV = dot(coat_data.N, V);
  float reflectance = bsdf_lut(coat_NV, coat_data.roughness, coat_ior, 0.0).x;
  coat_data.weight = weight * coat * reflectance;
  coat_data.color = vec3(1.0);
  /* Attenuate lower layers */
  weight *= (1.0 - reflectance * coat);

  if (coat == 0) {
    coat_tint.rgb = vec3(1.0);
  }
  else if (!all(equal(coat_tint.rgb, vec3(1.0)))) {
    float coat_neta = 1.0 / coat_ior;
    float NT = fast_sqrt(1.0 - coat_neta * coat_neta * (1 - NV * NV));
    /* Tint lower layers. */
    coat_tint.rgb = pow(coat_tint.rgb, vec3(coat / NT));
  }

  /* Attenuated by sheen and coat. */
  ClosureEmission emission_data;
  emission_data.weight = weight;
  emission_data.emission = coat_tint.rgb * emission.rgb * emission_strength;

  /* Metallic component */
  ClosureReflection reflection_data;
  reflection_data.N = N;
  reflection_data.roughness = roughness;

  if (true) {
    vec3 F0 = base_color.rgb;
    vec3 F90 = vec3(1.0);
    vec2 split_sum = brdf_lut(NV, roughness);
    vec3 metallic_brdf = (do_multiscatter != 0.0) ? F_brdf_multi_scatter(F0, F90, split_sum) :
                                                    F_brdf_single_scatter(F0, F90, split_sum);
    reflection_data.color = weight * metallic * metallic_brdf;
    /* Attenuate lower layers */
    weight *= (1.0 - metallic);
  }

  /* Transmission component */
  ClosureRefraction refraction_data;
  vec3 reflection_tint = specular_tint.rgb;
  if (true) {
    vec3 F0 = vec3(F0_from_ior(ior)) * reflection_tint;
    vec3 F90 = vec3(1.0);
    vec3 reflectance, transmittance;
    bsdf_lut(
        F0, F90, base_color.rgb, NV, roughness, ior, do_multiscatter, reflectance, transmittance);

    reflection_data.color += weight * transmission * reflectance;

    refraction_data.weight = weight * transmission;
    refraction_data.color = transmittance * coat_tint.rgb;
    refraction_data.N = N;
    refraction_data.roughness = roughness;
    refraction_data.ior = ior;
    /* Attenuate lower layers */
    weight *= (1.0 - transmission);
  }

  /* Specular component */
  if (true) {
    float eta = ior;
    float f0 = F0_from_ior(eta);
    if (specular != 0.5) {
      f0 *= 2.0 * specular;
      eta = ior_from_F0(f0);
      if (ior < 1.0) {
        eta = 1.0 / eta;
      }
    }

    vec3 F0 = vec3(f0) * reflection_tint;
    F0 = clamp(F0, vec3(0.0), vec3(1.0));
    vec3 F90 = vec3(1.0);
    vec3 reflectance, unused;
    bsdf_lut(F0, F90, vec3(0.0), NV, roughness, eta, do_multiscatter, reflectance, unused);

    reflection_data.color += weight * reflectance;
    /* Attenuate lower layers */
    weight *= (1.0 - max_v3(reflectance));
  }

  /* Diffuse component */
  if (true) {
    diffuse_data.sss_radius = subsurface_radius * subsurface_scale;
    diffuse_data.sss_id = uint(do_sss);
    diffuse_data.color += weight * base_color.rgb * coat_tint.rgb;
  }

  /* Adjust the weight of picking the closure. */
  reflection_data.color *= coat_tint.rgb;
  reflection_data.weight = avg(reflection_data.color);
  reflection_data.color *= safe_rcp(reflection_data.weight);

  diffuse_data.weight = avg(diffuse_data.color);
  diffuse_data.color *= safe_rcp(diffuse_data.weight);

  /* Ref. #98190: Defines are optimizations for old compilers.
   * Might become unnecessary with EEVEE-Next. */
  if (do_diffuse == 0.0 && do_refraction == 0.0 && do_coat != 0.0) {
#ifdef PRINCIPLED_COAT
    /* Metallic & Coat case. */
    result = closure_eval(reflection_data, coat_data);
#endif
  }
  else if (do_diffuse == 0.0 && do_refraction == 0.0 && do_coat == 0.0) {
#ifdef PRINCIPLED_METALLIC
    /* Metallic case. */
    result = closure_eval(reflection_data);
#endif
  }
  else if (do_diffuse != 0.0 && do_refraction == 0.0 && do_coat == 0.0) {
#ifdef PRINCIPLED_DIELECTRIC
    /* Dielectric case. */
    result = closure_eval(diffuse_data, reflection_data);
#endif
  }
  else if (do_diffuse == 0.0 && do_refraction != 0.0 && do_coat == 0.0) {
#ifdef PRINCIPLED_GLASS
    /* Glass case. */
    result = closure_eval(reflection_data, refraction_data);
#endif
  }
  else {
#ifdef PRINCIPLED_ANY
    /* Un-optimized case. */
    result = closure_eval(diffuse_data, reflection_data, coat_data, refraction_data);
#endif
  }
  Closure emission_cl = closure_eval(emission_data);
  Closure transparency_cl = closure_eval(transparency_data);
  result = closure_add(result, emission_cl);
  result = closure_add(result, transparency_cl);
}

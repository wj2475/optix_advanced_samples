/* 
 * Copyright (c) 2018, NVIDIA CORPORATION. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *  * Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 *  * Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *  * Neither the name of NVIDIA CORPORATION nor the names of its
 *    contributors may be used to endorse or promote products derived
 *    from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include <optix.h>
#include <optixu/optixu_math_namespace.h>
#include "helpers.h"
#include "random.h"
#include "commonStructs_rbf.h"

using namespace optix;

rtBuffer<float4>    positions_buffer;

rtDeclareVariable(float3,        eye, , );
rtDeclareVariable(float3,        U, , );
rtDeclareVariable(float3,        V, , );
rtDeclareVariable(float3,        W, , );
rtDeclareVariable(float3,        bad_color, , );
rtDeclareVariable(float,         scene_epsilon, , );
rtBuffer<uchar4, 2>              output_buffer;
rtBuffer<float4, 2>              accum_buffer;
rtDeclareVariable(rtObject,      top_object, , );
rtDeclareVariable(unsigned int,  radiance_ray_type, , );
rtDeclareVariable(unsigned int,  frame, , );
rtDeclareVariable(uint2,         launch_index, rtLaunchIndex, );

rtDeclareVariable(int,           tf_type, ,  );
rtDeclareVariable(float,         fixed_radius, ,  );
rtDeclareVariable(float3,        bbox_min, , );
rtDeclareVariable(float3,        bbox_max, , );

rtDeclareVariable(float,         opacity, , );
rtDeclareVariable(float,         segment_size, , );
rtDeclareVariable(float,         wScale, , );


__device__ float4 tf(float v)
{
  if (tf_type == 1)
  {
    if (v < .5f)
      return lerp( make_float4(1,1,0,0), make_float4(1,1,1,0.5f), v * 2.f);
    else
      return lerp( make_float4(1,1,1,0.5f), make_float4(1,0,0,1), v * 2.f - 1.f);
  }
  else if (tf_type == 2)
  {
    if (v < .5f)
      return lerp( make_float4(0,0,1,0), make_float4(1,1,1,0.5f), v * 2.f);
    else
      return lerp( make_float4(1,1,1,0.5f), make_float4(1,0,0,1), v * 2.f - 1.f);
  }
  else
  {
    if (v < .33f)
      return lerp( make_float4(1,0,1,0), make_float4(0,0,1,0.33f), (v-0.f) * 3.f);
    else if (v < .66f)
      return lerp( make_float4(0,0,1,.33f), make_float4(0,1,1,0.66f), (v-0.33f) * 3.f);
    else
      return lerp( make_float4(0,1,0,0.5f), make_float4(1,1,1,1), (v-0.66f) * 3.f);
  }
}

RT_PROGRAM void pinhole_camera()
{

  size_t2 screen = output_buffer.size();
  unsigned int seed = tea<16>(screen.x*launch_index.y+launch_index.x, frame);

  float2 subpixel_jitter = make_float2(0.0f, 0.0f);

  float2 d = (make_float2(launch_index) + subpixel_jitter) / make_float2(screen) * 2.f - 1.f;
  float3 ray_origin = eye;
  float3 ray_direction = normalize(d.x*U + d.y*V + W);

  optix::Ray ray(ray_origin, ray_direction, radiance_ray_type, scene_epsilon, RT_DEFAULT_MAX);

  PerRayData_radiance_rbf prd;

  //ray-AABB intersection to determine number of segments
 
  float3 t0, t1, tmin, tmax;
  t0 = (bbox_max - ray_origin) / ray_direction;
  t1 = (bbox_min - ray_origin) / ray_direction;
  tmax = fmaxf(t0, t1);
  tmin = fminf(t0, t1);
  float tenter = fmaxf(0.f, fmaxf(tmin.x, fmaxf(tmin.y, tmin.z)));
  float texit = fminf(tmax.x, fminf(tmax.y, tmax.z));

  float spacing = (RBF_SAMPLES * segment_size) * fixed_radius;

  float3 result = make_float3(0);
  float result_alpha = 0.f;
  
  if (tenter < texit)
  {
    float tbuffer = 0.f;

    //for each segment, 
    //  traverse the BVH (collect deep samples in prd.rbfs), 
    //  sort,
    //  integrate.
    
    while(tbuffer < texit && result_alpha < 0.97f)
    {
      prd.rbfi = 0;
      ray.tmin = fmaxf(tenter, tbuffer);
      ray.tmax = fminf(texit, tbuffer + spacing);

      if (ray.tmax > tenter)    //doing this will keep rays more coherent
      {
        rtTrace(top_object, ray, prd);

        //imperative bitonic sort, modified to support non-powers-of-2
        int N = prd.rbfi;
        int Nup2 = 1;
        while (Nup2 < N)
          Nup2 = Nup2 << 1;
        Nup2 = min(Nup2, RBF_SAMPLES);

        //power of two clamp
        for(int i=N; i<Nup2; i++)
          prd.rbfs[i].x = 1e20f;
        N = Nup2;

        for (int k=2; k<=N; k=k<<1) {
          for (int j=k>>1; j>0; j=j>>1) {
            for (int i=0; i<N; i++) {
              const int ij=i^j;
              if (ij>i) {
                const int ik = i&k;
                const float2 tmp = prd.rbfs[i];
                if (ik==0 && tmp.x > prd.rbfs[ij].x) {   //sort ascending
                  prd.rbfs[i] = prd.rbfs[ij];
                  prd.rbfs[ij] = tmp;
                }
                if (ik!=0 && tmp.x < prd.rbfs[ij].x) {   //sort descending
                  prd.rbfs[i] = prd.rbfs[ij];
                  prd.rbfs[ij] = tmp;
                }
              }
            }
          }
        }

        const float inv_fixed_radius_scale = 2.f / fixed_radius;

        //integrate depth-sorted list of RBFs
        for(int i=0; i<prd.rbfi; i++) {

          float trbf = prd.rbfs[i].x;
          int idx = __float_as_int(prd.rbfs[i].y);
          float3 hit_sample = ray.origin + ray.direction * trbf;

          float4 pos = positions_buffer[idx];
          float3 hit_normal = make_float3(pos.x, pos.y, pos.z) - hit_sample;
          float drbf = length(hit_normal) * inv_fixed_radius_scale;
          drbf = fmaxf(0.f, fminf(1.f, wScale * pos.w * exp(-drbf*drbf)));
          float4 color_sample = tf(drbf);

          float alpha = color_sample.w * opacity;
          float alpha_1msa = alpha * (1.0 - result_alpha);
          result += make_float3(color_sample.x, color_sample.y, color_sample.z) * alpha_1msa;
          result_alpha += alpha_1msa;
        }
      }

      tbuffer += spacing;
    }

  }

  //write to frame buffer
  float4 acc_val =  make_float4(result, 0.f);
  output_buffer[launch_index] = make_color( make_float3( acc_val ) );
  accum_buffer[launch_index] = acc_val;
}

RT_PROGRAM void exception()
{
  const unsigned int code = rtGetExceptionCode();
  rtPrintf( "Caught exception 0x%X at launch index (%d,%d)\n", code, launch_index.x, launch_index.y );
  output_buffer[launch_index] = make_color( bad_color );
}


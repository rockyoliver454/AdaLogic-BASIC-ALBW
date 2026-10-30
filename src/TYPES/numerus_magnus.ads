-- ============================================================
--     _      _      ____
--    / \    | |    | __ )
--   / _ \   | |    |  _ \
--  / ___ \  | |___ | |_) |
-- /_/   \_\ |_____||____/
--
--  AdaLogic BASIC (ALB)
--  Copyright 2014-2026 Rocky L. Oliver d/b/a Oliver Softworks
--
--  Licensed under the Apache License, Version 2.0 (the "License");
--  you may not use this file except in compliance with the License.
--  You may obtain a copy of the License at
--
--      http://www.apache.org/licenses/LICENSE-2.0
--
--  Unless required by applicable law or agreed to in writing, software
--  distributed under the License is distributed on an "AS IS" BASIS,
--  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
--  See the License for the specific language governing permissions and
--  limitations under the License.
--
--  Contact: contact@alb-lang.org
--  https://alb-lang.org | https://alb-lang.com | https://alb-lang.dev
-- ============================================================

pragma SPARK_Mode (On);

package Numerus_Magnus is
   pragma Pure;

   -- ==========================================
   -- Da Exact Unsigned Hardware Types
   -- ==========================================
   type U8  is mod 2**8;
   type U16 is mod 2**16;
   type U32 is mod 2**32;
   type U64 is mod 2**64;

   -- ==========================================
   -- Da Exact Signed Hardware Types
   -- ==========================================
   type S8  is range -2**7 .. 2**7 - 1;
   type S16 is range -2**15 .. 2**15 - 1;
   type S32 is range -2**31 .. 2**31 - 1;
   type S64 is range -2**63 .. 2**63 - 1;

   -- ==========================================
   -- IEEE 754 floating-point hardware types
   -- (F32/F64 are approximate; rounding/NaN/inf are inherent)
   -- ==========================================
   type F32 is digits 6;
   type F64 is digits 15;

   -- ==========================================
   -- Da Manual 128-Bit Chained Constructs
   -- ==========================================
   type U128 is record
      High : U64 := 0;
      Low  : U64 := 0;
   end record;

   type S128 is record
      High : S64 := 0;
      Low  : U64 := 0; -- Low bits act as unsigned carry
   end record;

   type F128 is record
      High : F64 := 0.0;
      Low  : F64 := 0.0;
   end record;

   -- ==========================================
   -- SPARK Compliant Math Procedures for 128-bit
   -- ==========================================
   -- Strictly in/out. Nae side-effects. Safe bounds checkin' built-in.
   procedure Add_U128 (A : in U128; B : in U128; Result : out U128; Overflow : out Boolean);
   procedure Sub_U128 (A : in U128; B : in U128; Result : out U128; Underflow : out Boolean);

   procedure Add_S128 (A : in S128; B : in S128; Result : out S128; Overflow : out Boolean);
   procedure Sub_S128 (A : in S128; B : in S128; Result : out S128; Overflow : out Boolean);

   -- ==========================================
   -- Da SIMD Vector & Matrix Hardware Types
   -- ==========================================
   type Lane_Index_4 is range 0 .. 3;
   type Lane_Index_2 is range 0 .. 1;

   -- 64-bit paired vectors (Perfect for pure 2D)
   type F32x2 is array (Lane_Index_2) of F32;
   for F32x2'Alignment      use 8;
   for F32x2'Component_Size use 32;
   for F32x2'Size           use 64;

   -- 128-bit quad vectors (The Workhorses)
   type F32x4 is array (Lane_Index_4) of F32;
   for F32x4'Alignment      use 16;
   for F32x4'Component_Size use 32;
   for F32x4'Size           use 128;

   type U32x4 is array (Lane_Index_4) of U32;
   for U32x4'Alignment      use 16;
   for U32x4'Component_Size use 32;
   for U32x4'Size           use 128;

   type S32x4 is array (Lane_Index_4) of S32;
   for S32x4'Alignment      use 16;
   for S32x4'Component_Size use 32;
   for S32x4'Size           use 128;

   -- Da Hardware Matrices (Arrays o' Vectors)
   type Mat2x2 is array (0 .. 1) of F32x2;
   for Mat2x2'Alignment use 8;

   type Mat3x3 is array (0 .. 2) of F32x4;
   -- Note: Mat3x3 uses F32x4 rows sae da 4th lane acts as padding for clean SIMD FMA!
   for Mat3x3'Alignment use 16;

   type Mat4x4 is array (0 .. 3) of F32x4;
   for Mat4x4'Alignment use 16;

end Numerus_Magnus;

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
with Numerus_Magnus; use Numerus_Magnus;
with Range_Spec;     use Range_Spec;
with Pure_Types;     use Pure_Types;
with HW_Types;       use HW_Types;
with Bin_Types;      use Bin_Types;

package ALB_Types is
   pragma Pure;

   -- What a Reference is allowed tae point tae (Da Safe Pointer Limits)
   type Reference_Target is (Target_None, Target_Variable, Target_Block);

   -- Da Safe Pointer: An index-based Reference dat canna dangle
   type ALB_Reference is record
      Target : Reference_Target := Target_None;
      Index  : Natural := 0;
   end record;

   -- Da explicit lexicon o' types our language kens
   type ALB_Type_Tag is (
      Type_None,
      
      -- Core Numerics
      Type_U8, Type_U16, Type_U32, Type_U64, Type_U128,
      Type_S8, Type_S16, Type_S32, Type_S64, Type_S128,
      Type_F32, Type_F64, Type_F128,
      
      -- Da SIMD Vector & Matrix Roster
      Type_F32x2, Type_F32x4, 
      Type_U32x4, Type_S32x4,
      Type_Mat2x2, Type_Mat3x3, Type_Mat4x4,                   
      
      -- Logic & Text
      Type_Boolean,
      Type_Char,       -- Single Character
      Type_Reference,  -- Da Safe Pointer
      
      -- Experimental / advanced numeric types
      Type_Pure,       -- Rational fixed-point (experimental: slow, denominator blow-up)
      Type_HW8,        -- 8-bit Hardware Flags
      Type_HW16,       -- 16-bit Hardware Flags
      Type_HW32,       -- 32-bit Hardware Flags
      Type_HW64,       -- 64-bit Hardware Flags
      Type_Binary      -- Binary Span (Raw Buffer View)
   );

   -- Da strict, zero-heap container for a' variables in da engine
   type ALB_Value (Tag : ALB_Type_Tag := Type_None) is record
      case Tag is
         when Type_U8   => Val_U8   : U8;
         when Type_U16  => Val_U16  : U16;
         when Type_U32  => Val_U32  : U32;
         when Type_U64  => Val_U64  : U64;
         when Type_U128 => Val_U128 : U128;

         when Type_S8   => Val_S8   : S8;
         when Type_S16  => Val_S16  : S16;
         when Type_S32  => Val_S32  : S32;
         when Type_S64  => Val_S64  : S64;
         when Type_S128 => Val_S128 : S128;

         when Type_F32  => Val_F32  : F32;
         when Type_F64  => Val_F64  : F64;
         when Type_F128 => Val_F128 : F128;
            
         -- Da Hardware Vector Fields (Just the declarations!)
         when Type_F32x2  => Val_F32x2  : F32x2;
         when Type_F32x4  => Val_F32x4  : F32x4;
         when Type_U32x4  => Val_U32x4  : U32x4;
         when Type_S32x4  => Val_S32x4  : S32x4;
         
         -- Da Matrix Fields
         when Type_Mat2x2 => Val_Mat2x2 : Mat2x2;
         when Type_Mat3x3 => Val_Mat3x3 : Mat3x3;
         when Type_Mat4x4 => Val_Mat4x4 : Mat4x4;

         when Type_Boolean   => Val_Bool : Boolean;
         when Type_Char      => Val_Char : Character;      
         when Type_Reference => Val_Ref  : ALB_Reference;  
         
         -- The New High-Integrity Types
         when Type_Pure      => Val_Pure : Pure_Rational;
         when Type_HW8       => Val_HW8  : HW_Bitset_8;
         when Type_HW16      => Val_HW16 : HW_Bitset_16;
         when Type_HW32      => Val_HW32 : HW_Bitset_32;
         when Type_HW64      => Val_HW64 : HW_Bitset_64;
         when Type_Binary    => Val_Bin  : Binary_Span;

         when Type_None => null;
      end case;
   end record;

   -- SPARK compliant verification procedures. Nae side-effects!
   procedure Verify_Type (Val : in ALB_Value; Expected : in ALB_Type_Tag; Success : out Boolean);
   
   -- Safe default initialization tae prevent uninitialized memory reads
   procedure Init_Value (Tag : in ALB_Type_Tag; Val : out ALB_Value; Success : out Boolean);

end ALB_Types;

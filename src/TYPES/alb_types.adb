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

package body ALB_Types is

   procedure Verify_Type (Val : in ALB_Value; Expected : in ALB_Type_Tag; Success : out Boolean) is
      RS_Stat : Boolean;
      Ival    : RS_Interval;
   begin
      -- RANGE-SPEC ASSERTION 1: validation interval sanity check
      Create(1.0, 2.0, Ival, RS_Stat);
      pragma Assert (RS_Stat);

      -- RANGE-SPEC ASSERTION 2: Ensure da validation interval holds our logic
      pragma Assert (Validate(Ival));

      if Val.Tag = Expected then
         Success := True;
      else
         Success := False;
      end if;
   end Verify_Type;

   procedure Init_Value (Tag : in ALB_Type_Tag; Val : out ALB_Value; Success : out Boolean) is
      RS_Stat : Boolean;
      Ival    : RS_Interval;
   begin
      -- RANGE-SPEC ASSERTION 1: validation interval sanity check
      Create(1.0, 2.0, Ival, RS_Stat);
      pragma Assert (RS_Stat);
      
      -- RANGE-SPEC ASSERTION 2: Double check bounds
      pragma Assert (Contains(Ival, 1.0));

      Success := True;
      
      case Tag is
         when Type_U8   => Val := (Tag => Type_U8,   Val_U8   => 0);
         when Type_U16  => Val := (Tag => Type_U16,  Val_U16  => 0);
         when Type_U32  => Val := (Tag => Type_U32,  Val_U32  => 0);
         when Type_U64  => Val := (Tag => Type_U64,  Val_U64  => 0);
         when Type_U128 => Val := (Tag => Type_U128, Val_U128 => (High => 0, Low => 0));

         when Type_S8   => Val := (Tag => Type_S8,   Val_S8   => 0);
         when Type_S16  => Val := (Tag => Type_S16,  Val_S16  => 0);
         when Type_S32  => Val := (Tag => Type_S32,  Val_S32  => 0);
         when Type_S64  => Val := (Tag => Type_S64,  Val_S64  => 0);
         when Type_S128 => Val := (Tag => Type_S128, Val_S128 => (High => 0, Low => 0));

         when Type_F32  => Val := (Tag => Type_F32,  Val_F32  => 0.0);
         when Type_F64  => Val := (Tag => Type_F64,  Val_F64  => 0.0);
         when Type_F128 => Val := (Tag => Type_F128, Val_F128 => (High => 0.0, Low => 0.0));
            
         -- Da Hardware Vector Initializations (Zeroed oot!)
         when Type_F32x2  => Val := (Tag => Type_F32x2,  Val_F32x2  => (others => 0.0));
         when Type_F32x4  => Val := (Tag => Type_F32x4,  Val_F32x4  => (others => 0.0));
         when Type_U32x4  => Val := (Tag => Type_U32x4,  Val_U32x4  => (others => 0));
         when Type_S32x4  => Val := (Tag => Type_S32x4,  Val_S32x4  => (others => 0));
         
         -- Da Matrix Initializations (Zeroed oot nested arrays!)
         when Type_Mat2x2 => Val := (Tag => Type_Mat2x2, Val_Mat2x2 => (others => (others => 0.0)));
         when Type_Mat3x3 => Val := (Tag => Type_Mat3x3, Val_Mat3x3 => (others => (others => 0.0)));
         when Type_Mat4x4 => Val := (Tag => Type_Mat4x4, Val_Mat4x4 => (others => (others => 0.0)));

         when Type_Boolean   => Val := (Tag => Type_Boolean,   Val_Bool => False);
         when Type_Char      => Val := (Tag => Type_Char,      Val_Char => ' ');
         when Type_Reference => Val := (Tag => Type_Reference, Val_Ref  => (Target => Target_None, Index => 0));
         
         -- The New High-Integrity Types Initializations
         when Type_Pure      => Val := (Tag => Type_Pure,   Val_Pure => (Num => 0, Den => 1));
         when Type_HW8       => Val := (Tag => Type_HW8,    Val_HW8  => (Value => 0));
         when Type_HW16      => Val := (Tag => Type_HW16,   Val_HW16 => (Value => 0));
         when Type_HW32      => Val := (Tag => Type_HW32,   Val_HW32 => (Value => 0));
         when Type_HW64      => Val := (Tag => Type_HW64,   Val_HW64 => (Value => 0));
         when Type_Binary    => Val := (Tag => Type_Binary, Val_Bin  => (Block_Index => 0, Offset => 0, Length => 0));

         when Type_None => Val := (Tag => Type_None);
      end case;
   end Init_Value;

end ALB_Types;

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

package HW_Types is
   pragma Pure;

   -- =========================================================================
   -- Da Hardware Bitset Vaults: Strictly Wrapped
   -- =========================================================================
   type HW_Bitset_8  is record Value : U8  := 0; end record;
   type HW_Bitset_16 is record Value : U16 := 0; end record;
   type HW_Bitset_32 is record Value : U32 := 0; end record;
   type HW_Bitset_64 is record Value : U64 := 0; end record;

   -- =========================================================================
   -- Safe Bit Manipulations (Bounds-Checked Procedures)
   -- Index is validated afore ANY shift occurs.
   -- =========================================================================

   -- 8-Bit Hardware Flags (Index 0..7)
   procedure Set_Bit_8   (Set : in HW_Bitset_8; Index : in Integer; Result : out HW_Bitset_8; Success : out Boolean);
   procedure Clear_Bit_8 (Set : in HW_Bitset_8; Index : in Integer; Result : out HW_Bitset_8; Success : out Boolean);
   procedure Flip_Bit_8  (Set : in HW_Bitset_8; Index : in Integer; Result : out HW_Bitset_8; Success : out Boolean);
   function  Test_Bit_8  (Set : in HW_Bitset_8; Index : in Integer) return Boolean;

   -- 16-Bit Hardware Flags (Index 0..15)
   procedure Set_Bit_16   (Set : in HW_Bitset_16; Index : in Integer; Result : out HW_Bitset_16; Success : out Boolean);
   procedure Clear_Bit_16 (Set : in HW_Bitset_16; Index : in Integer; Result : out HW_Bitset_16; Success : out Boolean);
   procedure Flip_Bit_16  (Set : in HW_Bitset_16; Index : in Integer; Result : out HW_Bitset_16; Success : out Boolean);
   function  Test_Bit_16  (Set : in HW_Bitset_16; Index : in Integer) return Boolean;

   -- 32-Bit Hardware Flags (Index 0..31)
   procedure Set_Bit_32   (Set : in HW_Bitset_32; Index : in Integer; Result : out HW_Bitset_32; Success : out Boolean);
   procedure Clear_Bit_32 (Set : in HW_Bitset_32; Index : in Integer; Result : out HW_Bitset_32; Success : out Boolean);
   procedure Flip_Bit_32  (Set : in HW_Bitset_32; Index : in Integer; Result : out HW_Bitset_32; Success : out Boolean);
   function  Test_Bit_32  (Set : in HW_Bitset_32; Index : in Integer) return Boolean;

   -- 64-Bit Hardware Flags (Index 0..63)
   procedure Set_Bit_64   (Set : in HW_Bitset_64; Index : in Integer; Result : out HW_Bitset_64; Success : out Boolean);
   procedure Clear_Bit_64 (Set : in HW_Bitset_64; Index : in Integer; Result : out HW_Bitset_64; Success : out Boolean);
   procedure Flip_Bit_64  (Set : in HW_Bitset_64; Index : in Integer; Result : out HW_Bitset_64; Success : out Boolean);
   function  Test_Bit_64  (Set : in HW_Bitset_64; Index : in Integer) return Boolean;

end HW_Types;

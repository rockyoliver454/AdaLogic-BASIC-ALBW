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

package body HW_Types is

   -- =========================================================================
   -- 8-Bit Implementations (0..7 shifted tae 1..8 for Math Vault)
   -- =========================================================================
   procedure Set_Bit_8 (Set : in HW_Bitset_8; Index : in Integer; Result : out HW_Bitset_8; Success : out Boolean) is
      RS_Stat : Boolean; Ival : RS_Interval; Shift : U8;
      Test_Val : Long_Float := Long_Float(Index) + 1.0;
   begin
      Create (1.0, 8.0, Ival, RS_Stat);
      if not RS_Stat or else not Contains (Ival, Test_Val) then
         Result := Set; Success := False; return;
      end if;
      Shift := 2 ** Natural(Index); 
      Result.Value := Set.Value or Shift;
      Success := True;
   end Set_Bit_8;

   procedure Clear_Bit_8 (Set : in HW_Bitset_8; Index : in Integer; Result : out HW_Bitset_8; Success : out Boolean) is
      RS_Stat : Boolean; Ival : RS_Interval; Shift : U8;
      Test_Val : Long_Float := Long_Float(Index) + 1.0;
   begin
      Create (1.0, 8.0, Ival, RS_Stat);
      if not RS_Stat or else not Contains (Ival, Test_Val) then
         Result := Set; Success := False; return;
      end if;
      Shift := 2 ** Natural(Index); 
      Result.Value := Set.Value and (not Shift);
      Success := True;
   end Clear_Bit_8;

   procedure Flip_Bit_8 (Set : in HW_Bitset_8; Index : in Integer; Result : out HW_Bitset_8; Success : out Boolean) is
      RS_Stat : Boolean; Ival : RS_Interval; Shift : U8;
      Test_Val : Long_Float := Long_Float(Index) + 1.0;
   begin
      Create (1.0, 8.0, Ival, RS_Stat);
      if not RS_Stat or else not Contains (Ival, Test_Val) then
         Result := Set; Success := False; return;
      end if;
      Shift := 2 ** Natural(Index); 
      Result.Value := Set.Value xor Shift;
      Success := True;
   end Flip_Bit_8;

   function Test_Bit_8 (Set : in HW_Bitset_8; Index : in Integer) return Boolean is
      RS_Stat : Boolean; Ival : RS_Interval; Shift : U8;
      Test_Val : Long_Float := Long_Float(Index) + 1.0;
   begin
      Create (1.0, 8.0, Ival, RS_Stat);
      if not RS_Stat or else not Contains (Ival, Test_Val) then return False; end if;
      Shift := 2 ** Natural(Index);
      return (Set.Value and Shift) /= 0;
   end Test_Bit_8;

   -- =========================================================================
   -- 16-Bit Implementations (0..15 shifted tae 1..16)
   -- =========================================================================
   procedure Set_Bit_16 (Set : in HW_Bitset_16; Index : in Integer; Result : out HW_Bitset_16; Success : out Boolean) is
      RS_Stat : Boolean; Ival : RS_Interval; Shift : U16;
      Test_Val : Long_Float := Long_Float(Index) + 1.0;
   begin
      Create (1.0, 16.0, Ival, RS_Stat);
      if not RS_Stat or else not Contains (Ival, Test_Val) then
         Result := Set; Success := False; return;
      end if;
      Shift := 2 ** Natural(Index); 
      Result.Value := Set.Value or Shift;
      Success := True;
   end Set_Bit_16;

   procedure Clear_Bit_16 (Set : in HW_Bitset_16; Index : in Integer; Result : out HW_Bitset_16; Success : out Boolean) is
      RS_Stat : Boolean; Ival : RS_Interval; Shift : U16;
      Test_Val : Long_Float := Long_Float(Index) + 1.0;
   begin
      Create (1.0, 16.0, Ival, RS_Stat);
      if not RS_Stat or else not Contains (Ival, Test_Val) then
         Result := Set; Success := False; return;
      end if;
      Shift := 2 ** Natural(Index); 
      Result.Value := Set.Value and (not Shift);
      Success := True;
   end Clear_Bit_16;

   procedure Flip_Bit_16 (Set : in HW_Bitset_16; Index : in Integer; Result : out HW_Bitset_16; Success : out Boolean) is
      RS_Stat : Boolean; Ival : RS_Interval; Shift : U16;
      Test_Val : Long_Float := Long_Float(Index) + 1.0;
   begin
      Create (1.0, 16.0, Ival, RS_Stat);
      if not RS_Stat or else not Contains (Ival, Test_Val) then
         Result := Set; Success := False; return;
      end if;
      Shift := 2 ** Natural(Index); 
      Result.Value := Set.Value xor Shift;
      Success := True;
   end Flip_Bit_16;

   function Test_Bit_16 (Set : in HW_Bitset_16; Index : in Integer) return Boolean is
      RS_Stat : Boolean; Ival : RS_Interval; Shift : U16;
      Test_Val : Long_Float := Long_Float(Index) + 1.0;
   begin
      Create (1.0, 16.0, Ival, RS_Stat);
      if not RS_Stat or else not Contains (Ival, Test_Val) then return False; end if;
      Shift := 2 ** Natural(Index);
      return (Set.Value and Shift) /= 0;
   end Test_Bit_16;

   -- =========================================================================
   -- 32-Bit Implementations (0..31 shifted tae 1..32)
   -- =========================================================================
   procedure Set_Bit_32 (Set : in HW_Bitset_32; Index : in Integer; Result : out HW_Bitset_32; Success : out Boolean) is
      RS_Stat : Boolean; Ival : RS_Interval; Shift : U32;
      Test_Val : Long_Float := Long_Float(Index) + 1.0;
   begin
      Create (1.0, 32.0, Ival, RS_Stat);
      if not RS_Stat or else not Contains (Ival, Test_Val) then
         Result := Set; Success := False; return;
      end if;
      Shift := 2 ** Natural(Index);
      Result.Value := Set.Value or Shift;
      Success := True;
   end Set_Bit_32;

   procedure Clear_Bit_32 (Set : in HW_Bitset_32; Index : in Integer; Result : out HW_Bitset_32; Success : out Boolean) is
      RS_Stat : Boolean; Ival : RS_Interval; Shift : U32;
      Test_Val : Long_Float := Long_Float(Index) + 1.0;
   begin
      Create (1.0, 32.0, Ival, RS_Stat);
      if not RS_Stat or else not Contains (Ival, Test_Val) then
         Result := Set; Success := False; return;
      end if;
      Shift := 2 ** Natural(Index);
      Result.Value := Set.Value and (not Shift);
      Success := True;
   end Clear_Bit_32;

   procedure Flip_Bit_32 (Set : in HW_Bitset_32; Index : in Integer; Result : out HW_Bitset_32; Success : out Boolean) is
      RS_Stat : Boolean; Ival : RS_Interval; Shift : U32;
      Test_Val : Long_Float := Long_Float(Index) + 1.0;
   begin
      Create (1.0, 32.0, Ival, RS_Stat);
      if not RS_Stat or else not Contains (Ival, Test_Val) then
         Result := Set; Success := False; return;
      end if;
      Shift := 2 ** Natural(Index);
      Result.Value := Set.Value xor Shift;
      Success := True;
   end Flip_Bit_32;

   function Test_Bit_32 (Set : in HW_Bitset_32; Index : in Integer) return Boolean is
      RS_Stat : Boolean; Ival : RS_Interval; Shift : U32;
      Test_Val : Long_Float := Long_Float(Index) + 1.0;
   begin
      Create (1.0, 32.0, Ival, RS_Stat);
      if not RS_Stat or else not Contains (Ival, Test_Val) then return False; end if;
      Shift := 2 ** Natural(Index);
      return (Set.Value and Shift) /= 0;
   end Test_Bit_32;

   -- =========================================================================
   -- 64-Bit Implementations (0..63 shifted tae 1..64)
   -- =========================================================================
   procedure Set_Bit_64 (Set : in HW_Bitset_64; Index : in Integer; Result : out HW_Bitset_64; Success : out Boolean) is
      RS_Stat : Boolean; Ival : RS_Interval; Shift : U64;
      Test_Val : Long_Float := Long_Float(Index) + 1.0;
   begin
      Create (1.0, 64.0, Ival, RS_Stat);
      if not RS_Stat or else not Contains (Ival, Test_Val) then
         Result := Set; Success := False; return;
      end if;
      Shift := 2 ** Natural(Index);
      Result.Value := Set.Value or Shift;
      Success := True;
   end Set_Bit_64;

   procedure Clear_Bit_64 (Set : in HW_Bitset_64; Index : in Integer; Result : out HW_Bitset_64; Success : out Boolean) is
      RS_Stat : Boolean; Ival : RS_Interval; Shift : U64;
      Test_Val : Long_Float := Long_Float(Index) + 1.0;
   begin
      Create (1.0, 64.0, Ival, RS_Stat);
      if not RS_Stat or else not Contains (Ival, Test_Val) then
         Result := Set; Success := False; return;
      end if;
      Shift := 2 ** Natural(Index);
      Result.Value := Set.Value and (not Shift);
      Success := True;
   end Clear_Bit_64;

   procedure Flip_Bit_64 (Set : in HW_Bitset_64; Index : in Integer; Result : out HW_Bitset_64; Success : out Boolean) is
      RS_Stat : Boolean; Ival : RS_Interval; Shift : U64;
      Test_Val : Long_Float := Long_Float(Index) + 1.0;
   begin
      Create (1.0, 64.0, Ival, RS_Stat);
      if not RS_Stat or else not Contains (Ival, Test_Val) then
         Result := Set; Success := False; return;
      end if;
      Shift := 2 ** Natural(Index);
      Result.Value := Set.Value xor Shift;
      Success := True;
   end Flip_Bit_64;

   function Test_Bit_64 (Set : in HW_Bitset_64; Index : in Integer) return Boolean is
      RS_Stat : Boolean; Ival : RS_Interval; Shift : U64;
      Test_Val : Long_Float := Long_Float(Index) + 1.0;
   begin
      Create (1.0, 64.0, Ival, RS_Stat);
      if not RS_Stat or else not Contains (Ival, Test_Val) then return False; end if;
      Shift := 2 ** Natural(Index);
      return (Set.Value and Shift) /= 0;
   end Test_Bit_64;

end HW_Types;

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

package body Roman_Spec is

   -- Private Data Tables (Interleaved data for safe iteration)
   type Roman_Entry is record
      Val   : Long_Integer;
      Glyph : Wide_String (1 .. 2);
      Len   : Natural;
   end record;
   
   type Roman_Table_Type is array (1 .. 13) of Roman_Entry;
   
   Roman_Table : constant Roman_Table_Type := (
      (1000, "M ", 1),
      (900,  "CM", 2),
      (500,  "D ", 1),
      (400,  "CD", 2),
      (100,  "C ", 1),
      (90,   "XC", 2),
      (50,   "L ", 1),
      (40,   "XL", 2),
      (10,   "X ", 1),
      (9,    "IX", 2),
      (5,    "V ", 1),
      (4,    "IV", 2),
      (1,    "I ", 1)
   );

   -- Helper: Get raw integer value of a single Roman character
   function Get_Char_Value (C : Wide_Character) return Long_Integer is
   begin
      case C is
         when 'M' => return 1000;
         when 'D' => return 500;
         when 'C' => return 100;
         when 'L' => return 50;
         when 'X' => return 10;
         when 'V' => return 5;
         when 'I' => return 1;
         when others => return 0;
      end case;
   end Get_Char_Value;

   -- Helper: Append Logic avoiding While loops for SPARK Provability
   procedure Append_Roman (Val_In : Long_Integer; Use_Vinculum : Boolean; Result : in out RS_Roman) is
      Current_Val : Long_Integer := Val_In;
      Count       : Long_Integer;
   begin
      for I in Roman_Table'Range loop
         Count := Current_Val / Roman_Table(I).Val;
         
         if Count > 0 then
            for C in 1 .. Count loop
               for K in 1 .. Roman_Table(I).Len loop
                  if Result.Length < 256 then
                     Result.Length := Result.Length + 1;
                     Result.Buffer(Result.Length) := Roman_Table(I).Glyph(K);
                     
                     -- Append Combining Overline (Vinculum)
                     if Use_Vinculum and then Result.Length < 256 then
                        Result.Length := Result.Length + 1;
                        Result.Buffer(Result.Length) := RS_Vinculum;
                     end if;
                  end if;
               end loop;
            end loop;
            Current_Val := Current_Val mod Roman_Table(I).Val;
         end if;
      end loop;
   end Append_Roman;

   -- Core Implementation

   procedure To_Roman (Value : Long_Integer; Result : out RS_Roman; Success : out Boolean) is
      Domain    : RS_Interval;
      Status    : Boolean;
      High_Part : Long_Integer;
      Low_Part  : Long_Integer;
   begin
      Result := (Value => 0, Buffer => (others => ' '), Length => 0, Valid => False);
      
      -- 1. Validation via RANGE-SPEC
      Create(1.0, Long_Float(RS_Roman_Max), Domain, Status);
      if not Status or else not Contains(Domain, Long_Float(Value)) then
         Success := False;
         return;
      end if;

      Result.Value := Value;

      -- 2. Decompose for Vinculum (Values >= 4000 use the bar)
      if Value >= 4000 then
         High_Part := Value / 1000;
         Low_Part  := Value mod 1000;
         
         -- Phase 1: High Order (Vinculum)
         Append_Roman(High_Part, True, Result);
         
         -- Phase 2: Low Order (Standard)
         if Low_Part > 0 then
            Append_Roman(Low_Part, False, Result);
         end if;
      else
         -- Standard range (1-3999)
         Append_Roman(Value, False, Result);
      end if;

      Result.Valid := True;
      Success := True;
   end To_Roman;

   procedure From_Roman (Input : RS_Roman; Result : out RS_Roman; Success : out Boolean) is
      type Workspace_Array is array (1 .. 256) of Long_Integer;
      Vals      : Workspace_Array := (others => 0);
      Val_Count : Natural := 0;
      I         : Natural := 1;
      Total     : Long_Integer := 0;
      Raw_Val   : Long_Integer;
      C         : Wide_Character;
      
      Check_Struct : RS_Roman;
      Check_Status : Boolean;
   begin
      Result := (Value => 0, Buffer => (others => ' '), Length => 0, Valid => False);
      if Input.Length = 0 or else not Input.Valid then 
         Success := False; return; 
      end if;

      -- PASS 1: Tokenize & Vinculum Handling
      while I <= Input.Length loop
         pragma Loop_Invariant (I >= 1);
         
         C := Input.Buffer(I);
         Raw_Val := Get_Char_Value(C);
         
         if Raw_Val = 0 then 
            Success := False; return; 
         end if;

         -- Look Ahead for Vinculum
         if I < Input.Length and then Input.Buffer(I + 1) = RS_Vinculum then
            Raw_Val := Raw_Val * 1000;
            I := I + 1; -- Skip the combining char
         end if;

         if Val_Count < 256 then
            Val_Count := Val_Count + 1;
            Vals(Val_Count) := Raw_Val;
         else
            Success := False; return;
         end if;
         
         I := I + 1;
      end loop;

      -- PASS 2: Summation with Subtractive Logic
      for J in 1 .. Val_Count loop
         if J < Val_Count and then Vals(J) < Vals(J+1) then
            Total := Total - Vals(J);
         else
            Total := Total + Vals(J);
         end if;
      end loop;

      -- PASS 3: Strict Canonical Verification
      To_Roman(Total, Check_Struct, Check_Status);
      if not Check_Status or else Check_Struct.Length /= Input.Length then
         Success := False; return;
      end if;

      -- Verify every character exactly matches
      for K in 1 .. Input.Length loop
         if Check_Struct.Buffer(K) /= Input.Buffer(K) then
            Success := False; return;
         end if;
      end loop;

      Result.Value  := Total;
      Result.Buffer := Input.Buffer;
      Result.Length := Input.Length;
      Result.Valid  := True;
      Success := True;
   end From_Roman;

   procedure Add_Roman (A, B : RS_Roman; Result : out RS_Roman; Success : out Boolean) is
      Int_A, Int_B, Int_Res : RS_Interval;
      Stat1, Stat2, Stat3   : Boolean;
   begin
      Result := (Value => 0, Buffer => (others => ' '), Length => 0, Valid => False);
      if not A.Valid or else not B.Valid then 
         Success := False; return; 
      end if;

      Scalar(Long_Float(A.Value), Int_A, Stat1);
      Scalar(Long_Float(B.Value), Int_B, Stat2);
      
      if not Stat1 or else not Stat2 then 
         Success := False; return; 
      end if;

      Add_Interval(Int_A, Int_B, Int_Res, Stat3);
      if not Stat3 then 
         Success := False; return; 
      end if;

      To_Roman(Long_Integer(Int_Res.Lower), Result, Success);
   end Add_Roman;

   procedure Sub_Roman (A, B : RS_Roman; Result : out RS_Roman; Success : out Boolean) is
      Int_A, Int_B, Int_Res : RS_Interval;
      Stat1, Stat2, Stat3   : Boolean;
   begin
      Result := (Value => 0, Buffer => (others => ' '), Length => 0, Valid => False);
      if not A.Valid or else not B.Valid then 
         Success := False; return; 
      end if;

      Scalar(Long_Float(A.Value), Int_A, Stat1);
      Scalar(Long_Float(B.Value), Int_B, Stat2);
      
      if not Stat1 or else not Stat2 then 
         Success := False; return; 
      end if;

      Sub_Interval(Int_A, Int_B, Int_Res, Stat3);
      if not Stat3 then 
         Success := False; return; 
      end if;

      -- Roman Numerals cannot be <= 0. To_Roman's RangeSpec validation will catch it!
      To_Roman(Long_Integer(Int_Res.Lower), Result, Success);
   end Sub_Roman;

end Roman_Spec;

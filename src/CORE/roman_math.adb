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

package body Roman_Math is

   -- -- Core Arithmetic Implementation -- --

   procedure Mul_Roman (A, B : RS_Roman; Result : out RS_Roman; Success : out Boolean) is
      Int_A, Int_B, Int_Res : RS_Interval;
      Stat1, Stat2, Stat3   : Boolean;
   begin
      Result := (Value => 0, Buffer => (others => ' '), Length => 0, Valid => False);
      if not A.Valid or else not B.Valid then Success := False; return; end if;

      Scalar(Long_Float(A.Value), Int_A, Stat1);
      Scalar(Long_Float(B.Value), Int_B, Stat2);
      if not Stat1 or else not Stat2 then Success := False; return; end if;

      Mul_Interval(Int_A, Int_B, Int_Res, Stat3);
      if not Stat3 then Success := False; return; end if;

      To_Roman(Long_Integer(Int_Res.Lower), Result, Success);
   end Mul_Roman;

   procedure Div_Roman (A, B : RS_Roman; Result : out RS_Roman; Success : out Boolean) is
      Int_A, Int_B, Int_Res : RS_Interval;
      Stat1, Stat2, Stat3   : Boolean;
   begin
      Result := (Value => 0, Buffer => (others => ' '), Length => 0, Valid => False);
      if not A.Valid or else not B.Valid then Success := False; return; end if;

      Scalar(Long_Float(A.Value), Int_A, Stat1);
      Scalar(Long_Float(B.Value), Int_B, Stat2);
      if not Stat1 or else not Stat2 then Success := False; return; end if;

      Div_Interval(Int_A, Int_B, Int_Res, Stat3);
      if not Stat3 then Success := False; return; end if;

      if Int_Res.Lower < 1.0 then Success := False; return; end if;

      To_Roman(Long_Integer(Int_Res.Lower), Result, Success);
   end Div_Roman;

   procedure Modulo_Roman (A, B : RS_Roman; Result : out RS_Roman; Success : out Boolean) is
      Res : Long_Integer;
   begin
      Result := (Value => 0, Buffer => (others => ' '), Length => 0, Valid => False);
      if not A.Valid or else not B.Valid or else B.Value = 0 then 
         Success := False; return; 
      end if;
      
      Res := A.Value mod B.Value;
      
      -- Modulo can return 0, which is invalid in Roman. We treat 0 as an error state.
      if Res < 1 then Success := False; return; end if;
      
      To_Roman(Res, Result, Success);
   end Modulo_Roman;


   -- -- Number Theory Implementation -- --

   procedure GCD_Roman (A, B : RS_Roman; Result : out RS_Roman; Success : out Boolean) is
      Num_A, Num_B, Temp : Long_Integer;
   begin
      Result := (Value => 0, Buffer => (others => ' '), Length => 0, Valid => False);
      if not A.Valid or else not B.Valid then Success := False; return; end if;

      Num_A := A.Value;
      Num_B := B.Value;
      
      -- Iterative Euclidean Algorithm
      while Num_B /= 0 loop
         pragma Loop_Invariant (Num_B >= 0);
         Temp  := Num_B;
         Num_B := Num_A mod Num_B;
         Num_A := Temp;
      end loop;

      if Num_A < 1 then Success := False; return; end if;
      To_Roman(Num_A, Result, Success);
   end GCD_Roman;

   procedure LCM_Roman (A, B : RS_Roman; Result : out RS_Roman; Success : out Boolean) is
      Gcd_Val      : RS_Roman;
      Product      : Long_Integer;
      Lcm_Val      : Long_Integer;
      Gcd_Success  : Boolean;
   begin
      Result := (Value => 0, Buffer => (others => ' '), Length => 0, Valid => False);
      if not A.Valid or else not B.Valid then Success := False; return; end if;

      GCD_Roman(A, B, Gcd_Val, Gcd_Success);
      if not Gcd_Success or else Gcd_Val.Value = 0 then Success := False; return; end if;

      Product := A.Value * B.Value;
      Lcm_Val := Product / Gcd_Val.Value;

      To_Roman(Lcm_Val, Result, Success);
   end LCM_Roman;

   procedure Exponent_Roman (Base : RS_Roman; Exp : Long_Integer; Result : out RS_Roman; Success : out Boolean) is
      Base_Val, Res_Val : Long_Integer;
      Current_Exp       : Long_Integer := Exp;
   begin
      Result := (Value => 0, Buffer => (others => ' '), Length => 0, Valid => False);
      if not Base.Valid or else Exp < 1 then Success := False; return; end if;

      Base_Val := Base.Value;
      Res_Val  := 1;

      while Current_Exp > 0 loop
         pragma Loop_Invariant (Current_Exp >= 0);
         
         -- Fast fail on overflow preventing mathematical faults
         if Res_Val > Long_Integer(RS_Roman_Max) / Base_Val then 
            Success := False; return; 
         end if;
         
         Res_Val     := Res_Val * Base_Val;
         Current_Exp := Current_Exp - 1;
      end loop;

      To_Roman(Res_Val, Result, Success);
   end Exponent_Roman;

   function Is_Prime_Roman (N : RS_Roman) return Boolean is
      Val : Long_Integer;
      I   : Long_Integer;
   begin
      if not N.Valid then return False; end if;
      Val := N.Value;

      if Val <= 1 then return False; end if;
      if Val <= 3 then return True; end if;

      if (Val mod 2 = 0) or else (Val mod 3 = 0) then return False; end if;

      I := 5;
      while (I * I) <= Val loop
         pragma Loop_Invariant (I > 0);
         if (Val mod I = 0) or else (Val mod (I + 2) = 0) then
            return False;
         end if;
         I := I + 6;
      end loop;

      return True;
   end Is_Prime_Roman;


   -- -- Utilities -- --

   procedure Clamp_Roman (Val, Min_Val, Max_Val : RS_Roman; Result : out RS_Roman; Success : out Boolean) is
   begin
      Result := (Value => 0, Buffer => (others => ' '), Length => 0, Valid => False);
      if not Val.Valid or else not Min_Val.Valid or else not Max_Val.Valid then 
         Success := False; return; 
      end if;

      if Val.Value < Min_Val.Value then
         Result := Min_Val;
      elsif Val.Value > Max_Val.Value then
         Result := Max_Val;
      else
         Result := Val;
      end if;
      
      Success := True;
   end Clamp_Roman;

end Roman_Math;

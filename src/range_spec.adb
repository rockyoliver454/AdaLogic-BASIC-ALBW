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

package body range_spec is

   -- Private Helpers
   function Min4 (A, B, C, D_Val : Long_Float) return Long_Float is
      Min_Val : Long_Float := A;
   begin
      if B < Min_Val then Min_Val := B; end if;
      if C < Min_Val then Min_Val := C; end if;
      if D_Val < Min_Val then Min_Val := D_Val; end if;
      return Min_Val;
   end Min4;

   function Max4 (A, B, C, D_Val : Long_Float) return Long_Float is
      Max_Val : Long_Float := A;
   begin
      if B > Max_Val then Max_Val := B; end if;
      if C > Max_Val then Max_Val := C; end if;
      if D_Val > Max_Val then Max_Val := D_Val; end if;
      return Max_Val;
   end Max4;

   function Apply_Epsilon_Down (Val : Long_Float) return Long_Float is
      New_Val : constant Long_Float := Val - RS_Epsilon;
   begin
      if Val > 0.0 and then New_Val <= 0.0 then
         return RS_Monad_Min;
      end if;
      return New_Val;
   end Apply_Epsilon_Down;

   function Apply_Epsilon_Up (Val : Long_Float) return Long_Float is
      New_Val : constant Long_Float := Val + RS_Epsilon;
   begin
      if Val < 0.0 and then New_Val >= 0.0 then
         return (0.0 - RS_Monad_Min);
      end if;
      return New_Val;
   end Apply_Epsilon_Up;

   -- Core Implementations
   procedure Scalar (Value : Long_Float; Result : out RS_Interval; Success : out Boolean) is
   begin
      Result := (Lower => 0.0, Upper => 0.0);
      
      -- The Monad Rejection: Reality cannot begin at absolute zero.
      if Value = 0.0 then 
         Success := False; 
         return; 
      end if;
      
      Result.Lower := Value;
      Result.Upper := Value;
      Success := True;
   end Scalar;

   procedure Create (Val_A, Val_B : Long_Float; Result : out RS_Interval; Success : out Boolean) is
      Min_Val, Max_Val : Long_Float;
   begin
      Result := (Lower => 0.0, Upper => 0.0);
      
      -- The Dyad Rejection: It requires difference.
      if Val_A = Val_B then Success := False; return; end if;
      if Val_A = 0.0 or else Val_B = 0.0 then Success := False; return; end if;
      if Val_A < 0.0 and then Val_B > 0.0 then Success := False; return; end if;
      
      if Val_A < Val_B then
         Min_Val := Val_A;
         Max_Val := Val_B;
      else
         Min_Val := Val_B;
         Max_Val := Val_A;
      end if;
      
      Result.Lower := Min_Val;
      Result.Upper := Max_Val;
      Success := True;
   end Create;

   procedure Add_Interval (A, B : RS_Interval; Result : out RS_Interval; Success : out Boolean) is
      New_Lower, New_Upper : Long_Float;
   begin
      Result := (Lower => 0.0, Upper => 0.0);
      if not Validate(A) or else not Validate(B) then 
         Success := False; return; 
      end if;
      
      New_Lower := A.Lower + B.Lower;
      New_Upper := A.Upper + B.Upper;
      
      if New_Lower < 0.0 and then New_Upper > 0.0 then Success := False; return; end if;
      if New_Lower = 0.0 or else New_Upper = 0.0 then Success := False; return; end if;
      
      Result.Lower := Apply_Epsilon_Down(New_Lower);
      Result.Upper := Apply_Epsilon_Up(New_Upper);
      Success := True;
   end Add_Interval;

   procedure Sub_Interval (A, B : RS_Interval; Result : out RS_Interval; Success : out Boolean) is
      New_Lower, New_Upper : Long_Float;
   begin
      Result := (Lower => 0.0, Upper => 0.0);
      if not Validate(A) or else not Validate(B) then 
         Success := False; return; 
      end if;
      
      New_Lower := A.Lower - B.Upper;
      New_Upper := A.Upper - B.Lower;
      
      if New_Lower < 0.0 and then New_Upper > 0.0 then Success := False; return; end if;
      if New_Lower = 0.0 or else New_Upper = 0.0 then Success := False; return; end if;
      
      Result.Lower := Apply_Epsilon_Down(New_Lower);
      Result.Upper := Apply_Epsilon_Up(New_Upper);
      Success := True;
   end Sub_Interval;

   procedure Mul_Interval (A, B : RS_Interval; Result : out RS_Interval; Success : out Boolean) is
      P1, P2, P3, P4, New_Lower, New_Upper : Long_Float;
   begin
      Result := (Lower => 0.0, Upper => 0.0);
      if not Validate(A) or else not Validate(B) then 
         Success := False; return; 
      end if;

      P1 := A.Lower * B.Lower;
      P2 := A.Lower * B.Upper;
      P3 := A.Upper * B.Lower;
      P4 := A.Upper * B.Upper;

      New_Lower := Min4(P1, P2, P3, P4);
      New_Upper := Max4(P1, P2, P3, P4);
      
      if New_Lower < 0.0 and then New_Upper > 0.0 then Success := False; return; end if;
      if New_Lower = 0.0 or else New_Upper = 0.0 then Success := False; return; end if;

      Result.Lower := Apply_Epsilon_Down(New_Lower);
      Result.Upper := Apply_Epsilon_Up(New_Upper);
      Success := True;
   end Mul_Interval;

   procedure Div_Interval (A, B : RS_Interval; Result : out RS_Interval; Success : out Boolean) is
      P1, P2, P3, P4, New_Lower, New_Upper : Long_Float;
   begin
      Result := (Lower => 0.0, Upper => 0.0);
      if not Validate(A) or else not Validate(B) then 
         Success := False; return; 
      end if;

      P1 := A.Lower / B.Lower;
      P2 := A.Lower / B.Upper;
      P3 := A.Upper / B.Lower;
      P4 := A.Upper / B.Upper;

      New_Lower := Min4(P1, P2, P3, P4);
      New_Upper := Max4(P1, P2, P3, P4);
      
      if New_Lower < 0.0 and then New_Upper > 0.0 then Success := False; return; end if;
      if New_Lower = 0.0 or else New_Upper = 0.0 then Success := False; return; end if;

      Result.Lower := Apply_Epsilon_Down(New_Lower);
      Result.Upper := Apply_Epsilon_Up(New_Upper);
      Success := True;
   end Div_Interval;

   function Overlaps (A, B : RS_Interval) return Boolean is
   begin
      if not Validate(A) or else not Validate(B) then return False; end if;
      if (A.Lower = 0.0 and then A.Upper = 0.0) or else 
         (B.Lower = 0.0 and then B.Upper = 0.0) then 
         return False; 
      end if;
      
      if A.Upper >= B.Lower and then B.Upper >= A.Lower then
         return True;
      end if;
      return False;
   end Overlaps;

   function Contains (A : RS_Interval; Value : Long_Float) return Boolean is
   begin
      if not Validate(A) then return False; end if;
      if A.Lower = 0.0 and then A.Upper = 0.0 then return False; end if;
      if Value = 0.0 then return False; end if;
      
      if Value >= A.Lower and then Value <= A.Upper then
         return True;
      end if;
      return False;
   end Contains;

   function Get_Width (A : RS_Interval) return Long_Float is
   begin
      if not Validate(A) then return 0.0; end if;
      if A.Lower = 0.0 and then A.Upper = 0.0 then return 0.0; end if;
      return A.Upper - A.Lower;
   end Get_Width;

   function Validate (A : RS_Interval) return Boolean is
   begin
      -- The Dormant Vessel
      if A.Lower = 0.0 and then A.Upper = 0.0 then return True; end if;
      
      if A.Lower = 0.0 or else A.Upper = 0.0 then return False; end if;
      if A.Lower < 0.0 and then A.Upper > 0.0 then return False; end if;
      if A.Lower <= A.Upper then return True; end if;
      
      return False;
   end Validate;

end range_spec;

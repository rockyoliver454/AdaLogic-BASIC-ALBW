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

package body Numerus_Magnus is

   procedure Add_U128 (A : in U128; B : in U128; Result : out U128; Overflow : out Boolean) is
      Carry : U64 := 0;
   begin
      Result.Low := A.Low + B.Low; 
      if Result.Low < A.Low then
         Carry := 1;
      end if;

      if U64'Last - A.High < B.High then
         Overflow := True;
         Result.High := A.High + B.High + Carry; 
      elsif U64'Last - (A.High + B.High) < Carry then
         Overflow := True;
         Result.High := A.High + B.High + Carry;
      else
         Overflow := False;
         Result.High := A.High + B.High + Carry;
      end if;
   end Add_U128;

   procedure Sub_U128 (A : in U128; B : in U128; Result : out U128; Underflow : out Boolean) is
      Borrow : U64 := 0;
   begin
      Result.Low := A.Low - B.Low;
      if A.Low < B.Low then
         Borrow := 1;
      end if;

      if A.High < B.High then
         Underflow := True;
         Result.High := A.High - B.High - Borrow;
      elsif A.High - B.High < Borrow then
         Underflow := True;
         Result.High := A.High - B.High - Borrow;
      else
         Underflow := False;
         Result.High := A.High - B.High - Borrow;
      end if;
   end Sub_U128;

   procedure Add_S128 (A : in S128; B : in S128; Result : out S128; Overflow : out Boolean) is
      Carry : S64 := 0;
   begin
      Result.Low := A.Low + B.Low;
      if Result.Low < A.Low then
         Carry := 1;
      end if;

      Overflow := False;

      if B.High > 0 then
         if A.High > S64'Last - B.High then
            Overflow := True;
         elsif A.High + B.High > S64'Last - Carry then
            Overflow := True;
         end if;
      elsif B.High < 0 then
         if A.High < S64'First - B.High then
            Overflow := True;
         end if;
      else
         if A.High > S64'Last - Carry then
            Overflow := True;
         end if;
      end if;

      if Overflow then
         Result.High := 0; 
      else
         Result.High := A.High + B.High + Carry;
      end if;
   end Add_S128;

   procedure Sub_S128 (A : in S128; B : in S128; Result : out S128; Overflow : out Boolean) is
      Borrow : S64 := 0;
   begin
      Result.Low := A.Low - B.Low;
      if A.Low < B.Low then
         Borrow := 1;
      end if;

      Overflow := False;

      if B.High > 0 then
         if A.High < S64'First + B.High then
            Overflow := True;
         elsif A.High - B.High < S64'First + Borrow then
            Overflow := True;
         end if;
      elsif B.High < 0 then
         if A.High > S64'Last + B.High then
            Overflow := True;
         elsif (A.High - B.High) < S64'First + Borrow then
            Overflow := True;
         end if;
      else
         if A.High < S64'First + Borrow then
            Overflow := True;
         end if;
      end if;

      if Overflow then
         Result.High := 0; 
      else
         Result.High := A.High - B.High - Borrow;
      end if;
   end Sub_S128;

end Numerus_Magnus;

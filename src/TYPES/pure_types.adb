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

package body Pure_Types is

   procedure Simplify_Pure (Target : in Pure_Rational; Result : out Pure_Rational; Success : out Boolean) is
      Abs_Num, Abs_Den : Long_Integer;
      R_Num, R_Den, R_GCD : RS_Roman;
      Stat1, Stat2, Stat3 : Boolean;
   begin
      if Target.Num = 0 then
         Result := (Num => 0, Den => 1);
         Success := True;
         return;
      end if;

      Abs_Num := abs Target.Num;
      Abs_Den := abs Target.Den;

      To_Roman (Abs_Num, R_Num, Stat1);
      To_Roman (Abs_Den, R_Den, Stat2);

      if Stat1 and then Stat2 then
         GCD_Roman (R_Num, R_Den, R_GCD, Stat3);
         if Stat3 and then R_GCD.Value > 0 then
            Result.Num := Target.Num / R_GCD.Value;
            Result.Den := Target.Den / R_GCD.Value;
            if Result.Den < 0 then
               Result.Num := -Result.Num;
               Result.Den := -Result.Den;
            end if;
            Success := True;
            return;
         end if;
      end if;

      Result := Target;
      if Result.Den < 0 then
         Result.Num := -Result.Num;
         Result.Den := -Result.Den;
      end if;
      Success := True;
   end Simplify_Pure;

   procedure Create_Pure (Numerator, Denominator : Long_Integer; Result : out Pure_Rational; Success : out Boolean) is
      RS_Stat : Boolean;
      Ival    : RS_Interval;
   begin
      -- FIX: Use Scalar. If Denominator is 0, Scalar returns False instantly!
      Scalar (Long_Float(Denominator), Ival, RS_Stat);
      
      if not RS_Stat then
         Result := (Num => 0, Den => 1);
         Success := False;
         return;
      end if;

      Simplify_Pure ((Num => Numerator, Den => Denominator), Result, Success);
   end Create_Pure;

   procedure Add_Pure (A, B : Pure_Rational; Result : out Pure_Rational; Success : out Boolean) is
      Raw_Result : Pure_Rational;
   begin
      Raw_Result.Num := (A.Num * B.Den) + (B.Num * A.Den);
      Raw_Result.Den := A.Den * B.Den;
      Simplify_Pure (Raw_Result, Result, Success);
   end Add_Pure;

   procedure Sub_Pure (A, B : Pure_Rational; Result : out Pure_Rational; Success : out Boolean) is
      Raw_Result : Pure_Rational;
   begin
      Raw_Result.Num := (A.Num * B.Den) - (B.Num * A.Den);
      Raw_Result.Den := A.Den * B.Den;
      Simplify_Pure (Raw_Result, Result, Success);
   end Sub_Pure;

   procedure Mul_Pure (A, B : Pure_Rational; Result : out Pure_Rational; Success : out Boolean) is
      Raw_Result : Pure_Rational;
   begin
      Raw_Result.Num := A.Num * B.Num;
      Raw_Result.Den := A.Den * B.Den;
      Simplify_Pure (Raw_Result, Result, Success);
   end Mul_Pure;

   procedure Div_Pure (A, B : Pure_Rational; Result : out Pure_Rational; Success : out Boolean) is
      Raw_Result : Pure_Rational;
      RS_Stat    : Boolean;
      Ival       : RS_Interval;
   begin
      -- FIX: Use Scalar tae catch B's zero numerator!
      Scalar (Long_Float(B.Num), Ival, RS_Stat);
      
      if not RS_Stat then
         Result := (0, 1);
         Success := False;
         return;
      end if;

      Raw_Result.Num := A.Num * B.Den;
      Raw_Result.Den := A.Den * B.Num;
      Simplify_Pure (Raw_Result, Result, Success);
   end Div_Pure;

end Pure_Types;

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
with Range_Spec;    use Range_Spec;
with Roman_Spec;    use Roman_Spec;
with Roman_Math;    use Roman_Math;
with Numerus_Verus; use Numerus_Verus;

package Pure_Types is
   pragma Pure;

   -- =========================================================================
   -- Rational fixed-point type (experimental)
   --
   -- Keeps values as Num/Den to avoid some IEEE 754 rounding. Tradeoffs:
   --   - exact only for rational values, not irrationals/transcendentals
   --   - denominators can explode in size and performance
   --   - zero denominator must be guarded at runtime
   --   - no SIMD/GPU acceleration; slower than floats for bulk math
   -- =========================================================================
   type Pure_Rational is record
      Num : Long_Integer := 0;
      Den : Long_Integer := 1; -- runtime-checked non-zero
   end record;

   -- Core Initialization (guards against zero denominator)
   procedure Create_Pure (Numerator, Denominator : Long_Integer; Result : out Pure_Rational; Success : out Boolean);

   -- Canonical simplification using Roman_Math GCD (still bounded by integer range)
   procedure Simplify_Pure (Target : in Pure_Rational; Result : out Pure_Rational; Success : out Boolean);

   -- =========================================================================
   -- Pure Arithmetic (In/Out Procedures Only for SPARK Compliancy)
   -- =========================================================================
   procedure Add_Pure (A, B : Pure_Rational; Result : out Pure_Rational; Success : out Boolean);
   procedure Sub_Pure (A, B : Pure_Rational; Result : out Pure_Rational; Success : out Boolean);
   procedure Mul_Pure (A, B : Pure_Rational; Result : out Pure_Rational; Success : out Boolean);
   procedure Div_Pure (A, B : Pure_Rational; Result : out Pure_Rational; Success : out Boolean);

end Pure_Types;

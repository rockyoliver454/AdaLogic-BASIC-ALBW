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
with Range_Spec; use Range_Spec;
with Roman_Spec; use Roman_Spec;

package Roman_Math is

   pragma Pure;

   -- Core Arithmetic
   procedure Mul_Roman (A, B : RS_Roman; Result : out RS_Roman; Success : out Boolean);
   procedure Div_Roman (A, B : RS_Roman; Result : out RS_Roman; Success : out Boolean);
   procedure Modulo_Roman (A, B : RS_Roman; Result : out RS_Roman; Success : out Boolean);

   -- Number Theory
   procedure GCD_Roman (A, B : RS_Roman; Result : out RS_Roman; Success : out Boolean);
   procedure LCM_Roman (A, B : RS_Roman; Result : out RS_Roman; Success : out Boolean);
   procedure Exponent_Roman (Base : RS_Roman; Exp : Long_Integer; Result : out RS_Roman; Success : out Boolean);
   
   -- Evaluator Function (Takes only 'in' params, returns Boolean)
   function Is_Prime_Roman (N : RS_Roman) return Boolean;

   -- Utilities
   procedure Clamp_Roman (Val, Min_Val, Max_Val : RS_Roman; Result : out RS_Roman; Success : out Boolean);

end Roman_Math;

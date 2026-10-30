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

package range_spec is

   pragma Pure;

   RS_Epsilon   : constant Long_Float := 1.0e-15;
   RS_Monad_Min : constant Long_Float := 2.0e-15;

   type RS_Interval is record
      Lower : Long_Float := 0.0;
      Upper : Long_Float := 0.0;
   end record;

   -- Core Interface (Changed to Procedures for SPARK compliance)
   procedure Scalar (Value : Long_Float; Result : out RS_Interval; Success : out Boolean);
   procedure Create (Val_A, Val_B : Long_Float; Result : out RS_Interval; Success : out Boolean);
   
   procedure Add_Interval (A, B : RS_Interval; Result : out RS_Interval; Success : out Boolean);
   procedure Sub_Interval (A, B : RS_Interval; Result : out RS_Interval; Success : out Boolean);
   procedure Mul_Interval (A, B : RS_Interval; Result : out RS_Interval; Success : out Boolean);
   procedure Div_Interval (A, B : RS_Interval; Result : out RS_Interval; Success : out Boolean);
   
   -- Analysis (These stay functions because they only have 'in' parameters)
   function Overlaps (A, B : RS_Interval) return Boolean;
   function Contains (A : RS_Interval; Value : Long_Float) return Boolean;
   function Get_Width (A : RS_Interval) return Long_Float;
   function Validate (A : RS_Interval) return Boolean;

end range_spec;

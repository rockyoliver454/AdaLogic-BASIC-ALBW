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

package Numerus_Verus is
   pragma Pure;

   function NV_Validate_Rational_Circle (Radius : Integer) return Boolean;
   
   -- The Tetractys Architecture (Generators are now Procedures)
   procedure NV_Monad_Init (Value : Long_Float; Result : out RS_Interval; Success : out Boolean);
   procedure NV_Dyad_Create_Bound (Val_A, Val_B : Long_Float; Result : out RS_Interval; Success : out Boolean);
   
   -- Evaluators remain Functions
   function NV_Triad_Resolve (Interval : RS_Interval; Test_Value : Long_Float) return Boolean;
   function NV_Tetrad_Validate_Sphere (Radius : Integer) return Boolean;
   function NV_Decad_System_Check return Boolean;

   -- The Harmony o' the Spheres
   procedure NV_Astronomy_Scale_Orbit (Radius : Integer; Harmonic_Ratio : Long_Float; Result : out RS_Interval; Success : out Boolean);
   function NV_Astronomy_Orbit_Check (Orbit_Interval : RS_Interval; X, Y, Z : Integer) return Boolean;
   function NV_Astronomy_Get_Resonance (Distance_Squared, Target_Radius_Squared : Long_Float) return Long_Float;
   procedure NV_Astronomy_Pulse_Time (Current_Tick : Integer; Next_Tick : out Integer; Success : out Boolean);
   function NV_Astronomy_System_Alignment_Check (Body_Count : Integer) return Boolean;

end Numerus_Verus;

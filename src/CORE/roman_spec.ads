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

package Roman_Spec is

   pragma Pure;

   -- Constants
   RS_Roman_Max : constant := 3_999_999;
   RS_Vinculum  : constant Wide_Character := Wide_Character'Val(16#0305#);

   -- Fixed bounded buffer for SPARK
   subtype Roman_Buffer is Wide_String (1 .. 256);

   type RS_Roman is record
      Value  : Long_Integer := 0;
      Buffer : Roman_Buffer := (others => ' ');
      Length : Natural := 0;
      Valid  : Boolean := False;
   end record;

   -- Core Interface (Strictly Procedures for SPARK compliance)
   
   -- Converts Integer -> Roman String (Strict RangeSpec check)
   procedure To_Roman (Value : Long_Integer; Result : out RS_Roman; Success : out Boolean);
   
   -- Converts Roman String -> Integer (Strict Format check & Canonical Verification)
   procedure From_Roman (Input : RS_Roman; Result : out RS_Roman; Success : out Boolean);
   
   -- Arithmetic (Wraps RangeSpec math + auto-conversion)
   procedure Add_Roman (A, B : RS_Roman; Result : out RS_Roman; Success : out Boolean);
   procedure Sub_Roman (A, B : RS_Roman; Result : out RS_Roman; Success : out Boolean);

end Roman_Spec;

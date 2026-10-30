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

package Bin_Types is
   pragma Pure;

   -- =========================================================================
   -- Da Binary Span: A Zero-Heap, strictly bounded viewport intae raw memory.
   -- =========================================================================
   type Binary_Span is record
      Block_Index : Natural := 0;  -- Which STATIC/SLIDE block holds the raw bytes
      Offset      : Natural := 0;  -- The starting byte index (e.g., skip 14 bytes header)
      Length      : Natural := 0;  -- The STRICT physical size we are allowed tae see
   end record;

   -- Safe Initialization
   procedure Create_Span (Block_ID, Start_Offset, Span_Length : Natural; Result : out Binary_Span; Success : out Boolean);

   -- =========================================================================
   -- The Iron Guard: Bounds Verification
   -- Validates dat readin' 'Data_Size' bytes starting at 'Read_Offset' 
   -- will NOT breach the Span's strict Length.
   -- =========================================================================
   function Validate_Access (Span : Binary_Span; Read_Offset, Data_Size : Natural) return Boolean;

end Bin_Types;

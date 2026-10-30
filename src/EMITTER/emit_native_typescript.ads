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

with AST; use AST;

package Emit_Native_TypeScript with SPARK_Mode => On is

   procedure Set_No_Console_Overlay (Enabled : in Boolean);

   --  Runtime-preamble trim (--rt-trim):  emit only the ALB_*/alb*
   --  helpers the program's emitted text actually references, plus a
   --  word-boundary closure over helper-to-helper references.
   --  Default is ON.  --rt-keep=<name> pins a helper unconditionally.
   procedure Set_Rt_Trim (Enabled : in Boolean);
   procedure Add_Rt_Keep (Name : in String);
   procedure Clear_Rt_Keep;

   procedure Compile_To_File
     (Root            : in AST_Node;
      Output_Filename : in String);

end Emit_Native_TypeScript;

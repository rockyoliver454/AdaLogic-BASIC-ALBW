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

--  WAT -> wasm binary assembler for `ENABLE WASM ... END ENABLE` blocks.
--
--  Scope (MVP + memory):
--    fields:    (module), (type), (import) func/memory/global,
--               (func) with inline import/export, (memory) with inline
--               data/export/import, (global) mut/immutable with inline
--               export/import, (export), (start), (data) active segments
--    instrs:    full MVP opcode set — numeric ops for i32/i64/f32/f64,
--               conversions + reinterpret, locals/globals, call,
--               block/loop/if/else/end, br/br_if/br_table, return,
--               drop/select, all load/store widths + memory.size/grow
--    literals:  dec/hex ints (underscored), dec/hex floats, inf, nan,
--               nan:0xPAYLOAD, string escapes \t \n \r \" \' \\ \xHH
--    indices:   $names or numeric everywhere; named labels on
--               block/loop/if for br/br_if/br_table
--    both flat and folded (s-expr) instruction forms
--
--  Deliberately NOT in v1 (each fails loud, never silently):
--    tables/elem/call_indirect, reference types, SIMD, multi-value
--    results, passive data segments, memory.init/data.drop, custom
--    sections (incl. name section), inline `(func)` type shorthand
--    inside (type ...).
--
--  Bounded tables + first-error ledger — nothing is silently dropped.

with Interfaces;            use Interfaces;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

package Wat_Assembler is

   Max_Output_Bytes : constant := 262144;
   Max_Exports      : constant := 512;
   Max_Params       : constant := 64;
   Max_Results      : constant := 4;

   subtype Wasm_Byte is Interfaces.Unsigned_8;
   type Byte_Vec is array (Positive range <>) of Wasm_Byte;

   type Value_Type is (VT_I32, VT_I64, VT_F32, VT_F64);

   type Param_Vec  is array (1 .. Max_Params) of Value_Type;
   type Result_Vec is array (1 .. Max_Results) of Value_Type;

   type Export_Record is record
      Name         : Unbounded_String := To_Unbounded_String ("");
      Is_Function  : Boolean := False;
      Param_Count  : Natural := 0;
      Params       : Param_Vec := (others => VT_I32);
      Result_Count : Natural := 0;
      Results      : Result_Vec := (others => VT_I32);
   end record;

   type Export_Array is array (1 .. Max_Exports) of Export_Record;

   --  Assemble Source (the inner text of an ENABLE WASM block) into a
   --  complete wasm module.  On success Error = "" and
   --  Bytes (1 .. Byte_Count) holds the module; Exports lists every
   --  exported entity (kind + signature for funcs).  On failure Error
   --  is "line N: message" for the FIRST problem hit — the caller is
   --  expected to fatal with it.
   procedure Assemble
     (Source       : String;
      Bytes        : out Byte_Vec;
      Byte_Count   : out Natural;
      Exports      : out Export_Array;
      Export_Count : out Natural;
      Error        : out Unbounded_String);

end Wat_Assembler;

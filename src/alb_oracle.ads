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

package ALB_Oracle is
   
   type Oracle_Code is (
      Err_None,
      
      -- Lexer Errors (The Mouth)
      Err_Lex_Unclosed_String, Err_Lex_Invalid_Hex, Err_Lex_Invalid_Bin, Err_Lex_Rogue_Symbol,
      
      -- Parser Errors (The Brain)
      Err_Parse_Missing_Then, Err_Parse_Missing_Until, Err_Parse_Missing_To,
      Err_Parse_Missing_Assign, Err_Parse_Missing_Type_Name, Err_Parse_Missing_Bracket,
      Err_Parse_Block_Overflow, Err_Parse_Expected_Value,
      Err_Parse_Reserved_Keyword,
                        
                        -- DA NEW PARSER ERRORS FOR STRUCTS
      Err_Parse_Expected_Type,
      Err_Parse_Expected_Var,
      Err_Parse_Expected_Block_End,
      Err_Parse_Rogue_Syntax,
      Err_Parse_Misplaced_Decl,
      
      -- Interpreter & Type Errors (The Vault)
      Err_Type_Conflict, Err_Symbol_Redeclared, Err_Mem_Out_Of_Bounds, Err_Sandbox_Violation, Err_Call_Stack_Overflow, Err_Proc_Not_Found,
      Err_Runtime_IO_Failure, Err_Runtime_Invalid_Handle, Err_Runtime_Unsupported,
      
      -- Compiler & Emitter Errors (The Forge)
      Err_Emit_Symbol_Not_Found,
      Err_Emit_Invalid_Type_Cast,
      Err_Emit_Struct_Field_Missing,
      Err_Emit_Win32_ABI_Mismatch,    -- DA FIX: Proper SDL3 Error Code!
      Err_Compiler_AST_Mismatch,

      -- Lexer Errors, cont.
      Err_Lex_Bad_Interp
   );

   -- Bounded strings for maximum verbosity without heap allocation (Rule 3)
   subtype Oracle_String is String (1 .. 256);

   type Oracle_Consultation is record
      Code          : Oracle_Code := Err_None;
      Breach        : Oracle_String := (others => ' ');
      Breach_Len    : Natural := 0;
      
      Context       : Oracle_String := (others => ' ');
      Context_Len   : Natural := 0;
      
      Counsel       : Oracle_String := (others => ' ');
      Counsel_Len   : Natural := 0;
   end record;

   -- The primary interface now accepts a dynamic argument for pinpoint accuracy!
   procedure Summon_Counsel (Code : in Oracle_Code; Arg : in String; Consultation : out Oracle_Consultation);

   -- The Centralized Render Forge (The Source Lens)
   --  procedure Render_Consultation (Source_Script : String; Line, Col : Positive; Code : Oracle_Code; Arg : String := "");
   -- The Centralized Render Forge (The Source Lens)
   procedure Render_Consultation (Source_Script : String; Abs_Line, Rel_Line, Col : Positive; File_Name : String; Code : Oracle_Code; Arg : String := "");
   
   --function Calculate_Levenshtein_Distance (S1, S2 : String);

end ALB_Oracle;

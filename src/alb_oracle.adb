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
with Ada.Text_IO; use Ada.Text_IO;

package body ALB_Oracle is
   
  
   
   -- DA TYPO FORGE: Calculates edit distance without touchin' the heap!
   function Calculate_Levenshtein_Distance (S1, S2 : String) return Natural is
      -- Rule 3: Fixed memory bounds! Limit comparison to 32 chars to prevent blowout.
      Max_Len : constant := 32;
      L1      : constant Natural := Natural'Min(S1'Length, Max_Len);
      L2      : constant Natural := Natural'Min(S2'Length, Max_Len);
      
      -- Fixed 33x33 stack-allocated grid
      type Grid is array (0 .. Max_Len, 0 .. Max_Len) of Natural;
      D : Grid := (others => (others => 0));
      
      Cost : Natural;
   begin
      -- Fast exits
      if L1 = 0 then return L2; end if;
      if L2 = 0 then return L1; end if;

      for I in 0 .. L1 loop D(I, 0) := I; end loop;
      for J in 0 .. L2 loop D(0, J) := J; end loop;

      for I in 1 .. L1 loop
         for J in 1 .. L2 loop
            if S1(S1'First + I - 1) = S2(S2'First + J - 1) then
               Cost := 0;
            else
               Cost := 1;
            end if;
            
            D(I, J) := Natural'Min(
                         Natural'Min(D(I - 1, J) + 1, D(I, J - 1) + 1),
                         D(I - 1, J - 1) + Cost);
         end loop;
      end loop;
      
      return D(L1, L2);
   end Calculate_Levenshtein_Distance;

   -- DA ORACLE'S EYE: Scans for close matches in our keywords
   procedure Suggest_Correction (Target : String; Suggestion : out Oracle_String; S_Len : out Natural) is
      type Kw_Rec is record
         Txt : String (1 .. 12);
         Len : Natural;
      end record;
      Kws : constant array (1 .. 16) of Kw_Rec :=
        ((Txt => "PRINT       ", Len => 5), (Txt => "PRINT$      ", Len => 6), 
         (Txt => "WHILE       ", Len => 5), (Txt => "REPEAT      ", Len => 6),
         (Txt => "PROCEDURE   ", Len => 9), (Txt => "FUNCTION    ", Len => 8), 
         (Txt => "STRUCT      ", Len => 6), (Txt => "MODULE      ", Len => 6),
         (Txt => "REQUIRE     ", Len => 7), (Txt => "ENSURE      ", Len => 6), 
         (Txt => "ASSERT      ", Len => 6), (Txt => "RETRACT     ", Len => 7),
         (Txt => "FIND        ", Len => 4), (Txt => "FINDALL     ", Len => 7), 
         (Txt => "KNOWS       ", Len => 5), (Txt => "MATCH       ", Len => 5));
      Dist : Natural;
      Best_Dist : Natural := 999;
      Best_Idx  : Natural := 0;
   begin
      Suggestion := (others => ' ');
      S_Len := 0;
      if Target'Length = 0 then return; end if;
      
      for I in Kws'Range loop
         Dist := Calculate_Levenshtein_Distance (Target, Kws(I).Txt(1 .. Kws(I).Len));
         if Dist < Best_Dist then
            Best_Dist := Dist;
            Best_Idx := I;
         end if;
      end loop;
      
      -- If it's a wee slip (distance 1 or 2), we offer a hand!
      if Best_Dist <= 2 and Best_Idx > 0 then
         for I in 1 .. Kws(Best_Idx).Len loop
            Suggestion(I) := Kws(Best_Idx).Txt(I);
         end loop;
         S_Len := Kws(Best_Idx).Len;
      end if;
   end Suggest_Correction;

   procedure Summon_Counsel (Code : in Oracle_Code; Arg : in String; Consultation : out Oracle_Consultation) is
      
      procedure Load (B, C, Co : String) is
         B_Len  : Natural := B'Length;
         C_Len  : Natural := C'Length;
         Co_Len : Natural := Co'Length;
      begin
         Consultation.Code := Code;
         if B_Len > 256 then B_Len := 256; end if;
         if C_Len > 256 then C_Len := 256; end if;
         if Co_Len > 256 then Co_Len := 256; end if;
         
         Consultation.Breach_Len := B_Len;
         for I in 1 .. 256 loop
            if I <= B_Len then Consultation.Breach(I) := B(B'First + I - 1);
            else Consultation.Breach(I) := ' '; end if;
         end loop;
         
         Consultation.Context_Len := C_Len;
         for I in 1 .. 256 loop
            if I <= C_Len then Consultation.Context(I) := C(C'First + I - 1);
            else Consultation.Context(I) := ' '; end if;
         end loop;
         
         Consultation.Counsel_Len := Co_Len;
         for I in 1 .. 256 loop
            if I <= Co_Len then Consultation.Counsel(I) := Co(Co'First + I - 1);
            else Consultation.Counsel(I) := ' '; end if;
         end loop;
      end Load;
   begin
      case Code is
         when Err_None => Load("No Error.", "The engine is in a pure state.", "Proceed with execution.");
         
         -- PARSER FAULTS
         when Err_Parse_Missing_Then => 
            Load("Missing 'THEN' Keyword.", "An IF or FOR statement is missing its THEN delimiter.", "Append THEN before the execution block.");
         when Err_Parse_Missing_Until => 
            Load("Missing 'UNTIL' Keyword.", "A REPEAT loop must end with an UNTIL condition.", "Close the loop with UNTIL <condition>.");
         when Err_Parse_Missing_To => 
            Load("Missing 'TO' Keyword.", "A FOR loop requires a target boundary.", "Format: FOR I = 1 TO 10 THEN...");
         when Err_Parse_Missing_Assign => 
            Load("Missing Assignment Operator (=).", "A variable declaration or mutation lacks an '=' symbol.", "Ensure you provide an expression to evaluate.");
         when Err_Parse_Missing_Type_Name => 
            Load("Missing Type Name.", "An AS cast requires a strict type or struct name.", "Example: LET X AS U32");
         when Err_Parse_Missing_Bracket => 
            Load("Unbalanced Brackets or Parentheses.", "An expression or array index is missing its closing bracket.", "Ensure all '(' and '[' are properly closed.");
         when Err_Parse_Expected_Value => 
            declare
               Sug : Oracle_String;
               SLen : Natural;
            begin
               Suggest_Correction(Arg, Sug, SLen);
               if SLen > 0 then
                  Load("Unexpected Token Encountered.", "The parser expected a valid variable, literal, or expression.", "Did ye mean '" & String(Sug(1..SLen)) & "'?");
               else
                  Load("Unexpected Token Encountered.", "The parser expected a valid variable, literal, or expression.", "Review the syntax near this token.");
               end if;
            end;
         when Err_Parse_Block_Overflow => 
            Load("Execution Block Overflow.", "A BEGIN..END block contains too many statements.", "Break the logic down into smaller procedures.");
            
         -- DYNAMIC COMPILER FAULTS
         when Err_Type_Conflict =>
            Load("Type Conflict on '" & Arg & "'.",
                 "The compiler found types it could not reconcile for this operation or declaration.",
                 "Review the surrounding expression or declaration if the generated code still behaves incorrectly.");

         when Err_Symbol_Redeclared =>
            Load("Identifier Redeclared in Active Scope: '" & Arg & "'.",
                 "A symbol with this name already exists earlier in the same semantic scope, but the new LET tries to introduce it with a different strong type.",
                 "Rename the later local, reuse the existing symbol, or move shared state to globals. At top level, ON TICK and ON PAINT currently share the surrounding BEGIN scope.");
                 
         when Err_Emit_Symbol_Not_Found =>
            Load("Unresolved Native Symbol '" & Arg & "'.",
                 "The Compiler tried to resolve a variable or function memory address, but it wasn't present in the Vault.",
                 "Ensure the variable or struct is properly declared before use in the execution flow.");
                 
         when Err_Proc_Not_Found =>
            declare
               Sug : Oracle_String;
               SLen : Natural;
            begin
               Suggest_Correction(Arg, Sug, SLen);
               if SLen > 0 then
                  Load("Unknown Target Procedure '" & Arg & "'.",
                       "The CALL keyword attempted to execute a subroutine, but it is not registered.",
                       "Did ye mean '" & String(Sug(1..SLen)) & "'?");
               else
                  Load("Unknown Target Procedure '" & Arg & "'.",
                       "The CALL keyword attempted to execute a subroutine, but it is not registered.",
                       "Verify the spelling of the target procedure.");
               end if;
            end;

         when Err_Runtime_IO_Failure =>
            Load("Runtime I/O Operation Failed near '" & Arg & "'.",
                 "The player couldna complete a file or console operation requested by the script.",
                 "Check that the path, mode, and target data make sense, and ensure the file is accessible.");

         when Err_Runtime_Invalid_Handle =>
            Load("Invalid Runtime File Handle '" & Arg & "'.",
                 "The script tried tae read, write, or close a file handle that isna currently open in the player.",
                 "Store the result of OPEN(...) in a variable and pass that same live handle tae READ, WRITE, or CLOSE.");

         when Err_Runtime_Unsupported =>
            Load("Runtime Feature Not Yet Supported: '" & Arg & "'.",
                 "The script reached a construct the player recognizes, but this executable hasna implemented fully yet.",
                 "Prefer a simpler equivalent for now, or extend alb_player so this feature gains a real runtime path.");
            
         -- COMPILER & EMITTER FAULTS (DA FORGE)
                 
         when Err_Emit_Invalid_Type_Cast =>
            Load("Invalid Native Type Cast on '" & Arg & "'.",
                 "The Emitter canna safely morph the given expression intae the target machine type.",
                 "Check yer types and ensure ye are using the correct Constructor or intrinsic conversion.");

         when Err_Emit_Struct_Field_Missing =>
            Load("Struct Field Missing or Unaligned: '" & Arg & "'.",
                 "An attempt was made tae access a field that disna exist within the defined structural blueprint.",
                 "Check the field name against yer original DEFINE STRUCT block, minding yer spelling.");

         when Err_Emit_Win32_ABI_Mismatch =>
            Load("Win32 ABI Mismatch Detected near '" & Arg & "'.",
                 "The parameter sizing or calling convention disna align wi' strict Windows API requirements.",
                 "Verify that strings are properly formatted an' integers match the required bit-width (e.g., U32 for DWORD).");

         when Err_Compiler_AST_Mismatch =>
            Load("AST Structural Mismatch: '" & Arg & "'.",
                 "The emission forge encountered a node type it didna expect while generating machine code.",
                 "This is an internal engine anomaly. Verify the AST topology leading tae this instruction isna malformed.");
                 
         -- NEW STRUCT PARSING FAULTS
         when Err_Parse_Expected_Type => 
            Load("Missing or Invalid Type Declaration.", "The parser expected a valid data type or struct name after 'AS'.", "Provide a valid type identifier (e.g., U32, String).");
            
         when Err_Parse_Expected_Var => 
            Load("Expected Variable or Identifier.", "The parser expected a valid logic variable or atom for a structural name.", "Ensure ye are using a proper identifier name afore ye continue.");
            
         when Err_Parse_Expected_Block_End => 
            Load("Missing Block Terminator.", "The structural block wasna closed properly wi' its matching END statement.", "Check yer END STRUCT tokens.");
            
         when Err_Parse_Rogue_Syntax =>
            Load("Rogue Syntax Detected.", "The parser stumbled across structural tokens it completely disna recognize in this context.", "Check yer spelling an' struct syntax carefully.");

         when Err_Parse_Misplaced_Decl =>
            Load("Misplaced Declaration: '" & Arg & "'.",
                 "STRICT storage arrays carry executable state and must live inside the MODULE body — a DECLARE MODULE block only describes the interface (signatures and struct types). Previously this was silently dropped, leaving the name to resolve as an undeclared scalar: indexed reads/writes then corrupt neighbouring static memory at runtime.",
                 "Move the STRICT declaration out of DECLARE MODULE and into the matching MODULE block.");
         
         when Err_Sandbox_Violation =>
            Load("Memory Firewall Violation for '" & Arg & "'.",
                 "The current execution sandbox forbids this read/write operation according to the active MEMORY_FIREWALL policy.",
                 "Review your PERMIT_READ, PERMIT_WRITE, and DENY_ALL rules.");

         when Err_Mem_Out_Of_Bounds =>
            Load("Memory Access Out Of Bounds for '" & Arg & "'.",
                 "An array or struct index attempts to access a memory block outside its declared 1-based bounds or the index is 0.",
                 "Ensure array indices start at 1 and do not exceed the declared bounds.");

         when Err_Lex_Bad_Interp =>
            Load("Bad String Interpolation.",
                 "A backtick string has an empty {..}, an unterminated {..} (missing '}'), or interpolation nested deeper than the compiler's bound.",
                 "Close the interpolation with '}', use {{ for a literal brace, or move the expression to a LET variable.");

         -- Fallback for others (You can expand the rest here exactly as before, just appending Arg where useful)
         when others =>
            Load("Engine Anomaly Detected [" & Arg & "].", "The oracle encountered a state it could not fully decipher.", "Review the syntax at the provided coordinates.");
      end case;
   end Summon_Counsel;

   --  procedure Render_Consultation (Source_Script : String; Line, Col : Positive; Code : Oracle_Code; Arg : String := "") is
   --     Consult   : Oracle_Consultation;
   --     ESC       : constant Character := Character'Val(27);
   --  
   --     -- Lens bounds
   --     Line_Start : Positive := Source_Script'First;
   --     Line_End   : Natural  := 0;
   --     Curr_Line  : Positive := 1;
   --  begin
   --     Summon_Counsel(Code, Arg, Consult);
   --  
   --     -- 1. Find the exact line in the source code (Zero-Heap String Searching)
   --     for I in Source_Script'Range loop
   --        if Source_Script(I) = ASCII.LF then
   --           if Curr_Line = Line then
   --              Line_End := I - 1;
   --              exit;
   --           end if;
   --           Curr_Line := Curr_Line + 1;
   --           Line_Start := I + 1;
   --        end if;
   --     end loop;
   --     if Line_End = 0 then Line_End := Source_Script'Last; end if;
   --  
   --     -- 2. Render the Display
   --     Put_Line (ESC & "[1;33m" & "======================================================" & ESC & "[0m");
   --     Put_Line (ESC & "[1;31m" & "                 ALB DIAGNOSTIC FORGE                 " & ESC & "[0m");
   --     Put_Line (ESC & "[1;33m" & "======================================================" & ESC & "[0m");
   --  
   --     Put_Line ("LOCATION : Line " & Positive'Image(Line) & " | Col " & Positive'Image(Col));
   --     New_Line;
   --  
   --     -- The Source Lens
   --     if Line_Start <= Line_End then
   --        Put_Line (ESC & "[0;37m" & "  | " & Source_Script(Line_Start .. Line_End) & ESC & "[0m");
   --        Put ("  | ");
   --        for I in 1 .. Col - 1 loop Put (" "); end loop;
   --        Put_Line (ESC & "[1;31m" & "^------- BREACH HERE" & ESC & "[0m");
   --     end if;
   --  
   --     New_Line;
   --     Put_Line (ESC & "[1;31m" & "BREACH   : " & ESC & "[0m" & String(Consult.Breach(1..Consult.Breach_Len)));
   --     New_Line;
   --     Put_Line (ESC & "[1;36m" & "CONTEXT  : " & ESC & "[0m" & String(Consult.Context(1..Consult.Context_Len)));
   --     New_Line;
   --     Put_Line (ESC & "[1;32m" & "COUNSEL  : " & ESC & "[0m" & String(Consult.Counsel(1..Consult.Counsel_Len)));
   --     Put_Line (ESC & "[1;33m" & "======================================================" & ESC & "[0m");
   --  end Render_Consultation;
   
   procedure Render_Consultation (Source_Script : String; Abs_Line, Rel_Line, Col : Positive; File_Name : String; Code : Oracle_Code; Arg : String := "") is
      Consult    : Oracle_Consultation;
      ESC        : constant Character := Character'Val(27);
      Line_Start : Positive := Source_Script'First;
      Line_End   : Natural  := 0;
      Curr_Line  : Positive := 1;
   begin
      Summon_Counsel(Code, Arg, Consult);
      
      -- 1. Find the exact line in the merged buffer using the Absolute Line!
      for I in Source_Script'Range loop
         if Source_Script(I) = ASCII.LF then
            if Curr_Line = Abs_Line then
               Line_End := I - 1;
               exit;
            end if;
            Curr_Line := Curr_Line + 1;
            Line_Start := I + 1;
         end if;
      end loop;
      if Line_End = 0 then Line_End := Source_Script'Last; end if;

      -- 2. Render the Display wi' the REAL File an' Relative Line!
      Put_Line (ESC & "[1;33m" & "======================================================" & ESC & "[0m");
      Put_Line (ESC & "[1;31m" & "                 ALB DIAGNOSTIC FORGE                 " & ESC & "[0m");
      Put_Line (ESC & "[1;33m" & "======================================================" & ESC & "[0m");
      
      Put_Line ("LOCATION : File [" & File_Name & "] | Line " & Positive'Image(Rel_Line) & " | Col " & Positive'Image(Col));
      New_Line;
      
      if Line_Start <= Line_End then
         Put_Line (ESC & "[0;37m" & "  | " & Source_Script(Line_Start .. Line_End) & ESC & "[0m");
         Put ("  | ");
         for I in 1 .. Col - 1 loop Put (" "); end loop;
         Put_Line (ESC & "[1;31m" & "^------- BREACH HERE" & ESC & "[0m");
      end if;
      
      New_Line;
      Put_Line (ESC & "[1;31m" & "BREACH   : " & ESC & "[0m" & String(Consult.Breach(1..Consult.Breach_Len)));
      New_Line;
      Put_Line (ESC & "[1;36m" & "CONTEXT  : " & ESC & "[0m" & String(Consult.Context(1..Consult.Context_Len)));
      New_Line;
      Put_Line (ESC & "[1;32m" & "COUNSEL  : " & ESC & "[0m" & String(Consult.Counsel(1..Consult.Counsel_Len)));
      Put_Line (ESC & "[1;33m" & "======================================================" & ESC & "[0m");
   end Render_Consultation;

   
   
end ALB_Oracle;

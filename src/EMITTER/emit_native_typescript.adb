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

with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;           use Ada.Text_IO;

with Compiler_State; use Compiler_State;
with Tokenizer;      use Tokenizer;
with AST;            use AST;

package body Emit_Native_TypeScript is

   Max_Symbols       : constant Natural := 32_768;
   Max_Structs       : constant Natural := 1024;
   Max_Fields        : constant Natural := 8192;
   Max_Routines      : constant Natural := 8192;
   Max_Params        : constant Natural := 64;
   Max_Event_Blocks  : constant Natural := 1024;
   Max_Predicates    : constant Natural := 2048;
   Max_Logic_Rules   : constant Natural := 2048;
   Max_Logic_Watches : constant Natural := 512;
   Max_Rule_Body_Terms : constant Natural := 16;
   --  PREDICATE closed world: declared name+arity contract.
   Max_Declared_Preds : constant Natural := 512;
   --  Match albt Max_Foreign_Exports so full-engine libgamedeck EXPORT_ES
   --  (+ optional EXPORT_WASM) façades fit in one web library weave.
   Max_Foreign_Bindings : constant Natural := 8192;

   type Value_Kind is
     (VK_Unknown,
      VK_Number,
      VK_Boolean,
      VK_String,
      VK_Binary,
      VK_Pure,
      VK_U8,
      VK_U16,
      VK_S8,
      VK_S16,
      VK_U32,
      VK_U64,
      VK_S32,
      VK_F64,
      VK_F32,
      VK_HW8,
      VK_HW16,
      VK_HW32,
      VK_U128,
      VK_Struct);

   type Symbol_Kind is
     (Sym_Scalar,
      Sym_Strict_Array,
      Sym_Slide_Array,
      Sym_Parallel_Field,
      Sym_Temporal,
      Sym_Struct_Var,
      Sym_Const,
      Sym_Param);

   type Param_Mode_Kind is (Param_In, Param_Out);
   type Foreign_Link_Kind is
     (Foreign_None,
      Foreign_Compat,
      Foreign_ES,
      Foreign_WASM);
   type Dim_List is array (1 .. 4) of Integer;
   type Param_Mode_List is array (1 .. Max_Params) of Param_Mode_Kind;
   type Node_Index_List is array (1 .. Max_Event_Blocks) of Node_Index;
   type Rule_Node_List is array (1 .. Max_Logic_Rules) of Node_Index;
   type Watch_Node_List is array (1 .. Max_Logic_Watches) of Node_Index;

   type Foreign_Binding_Record is record
      Active    : Boolean := False;
      Node      : Node_Index := 0;
      Link_Kind : Foreign_Link_Kind := Foreign_None;
      Name      : Unbounded_String := To_Unbounded_String ("");
      JS_Name   : Unbounded_String := To_Unbounded_String ("");
      Path      : Unbounded_String := To_Unbounded_String ("");
      Is_Function : Boolean := False;
      Return_Tag  : Value_Kind := VK_Number;
   end record;

   type Predicate_Record is record
      Active : Boolean := False;
      Name   : Unbounded_String := To_Unbounded_String ("");
      Id     : Natural := 0;
   end record;

   type Symbol_Record is record
      Active       : Boolean := False;
      Name         : Unbounded_String := To_Unbounded_String ("");
      Scope        : Unbounded_String := To_Unbounded_String ("");
      JS_Name      : Unbounded_String := To_Unbounded_String ("");
      Struct_Name  : Unbounded_String := To_Unbounded_String ("");
      Tag          : Value_Kind := VK_Unknown;
      Kind         : Symbol_Kind := Sym_Scalar;
      Rank         : Natural := 0;
      Dims         : Dim_List := (others => 0);
      Capacity     : Integer := 0;
      Active_Size  : Integer := 0;
      History_Size : Integer := 0;
      Offset_Bytes : Integer := 0;
      Aux_Offset   : Integer := 0;
      Is_Bigint    : Boolean := False;
      --  ROUTINE-alias name when the var was declared `AS <routine type>`
      --  (e.g. `LET f AS Cmp`). Used to strict-check LAMBDA re-binds.
      Routine_Alias : Unbounded_String := To_Unbounded_String ("");
   end record;

   type Struct_Record is record
      Active     : Boolean := False;
      Name       : Unbounded_String := To_Unbounded_String ("");
      Size_Bytes : Integer := 0;
   end record;

   type Field_Record is record
      Active       : Boolean := False;
      Struct_Name  : Unbounded_String := To_Unbounded_String ("");
      Field_Name   : Unbounded_String := To_Unbounded_String ("");
      JS_Field     : Unbounded_String := To_Unbounded_String ("");
      Type_Name    : Unbounded_String := To_Unbounded_String ("");
      Tag          : Value_Kind := VK_Unknown;
      Offset_Bytes : Integer := 0;
      Bit_Width    : Integer := 0;
      Bit_Shift    : Integer := 0;
   end record;

   type Routine_Record is record
      Active      : Boolean := False;
      Name        : Unbounded_String := To_Unbounded_String ("");
      JS_Name     : Unbounded_String := To_Unbounded_String ("");
      Param_Count : Natural := 0;
      Param_Modes : Param_Mode_List := (others => Param_In);
      Return_Kind : Value_Kind := VK_Unknown;
   end record;

   Symbols  : array (1 .. Max_Symbols) of Symbol_Record;
   Structs  : array (1 .. Max_Structs) of Struct_Record;
   Fields   : array (1 .. Max_Fields) of Field_Record;
   Routines : array (1 .. Max_Routines) of Routine_Record;
   Predicates : array (1 .. Max_Predicates) of Predicate_Record;
   Foreign_Imports : array (1 .. Max_Foreign_Bindings) of Foreign_Binding_Record;
   Foreign_Exports : array (1 .. Max_Foreign_Bindings) of Foreign_Binding_Record;

   --  TYPE aliases: range types map to their base kind; routine types
   --  are opaque function values (VK_Number storage, JS is dynamic).
   Max_Type_Aliases : constant := 512;
   type Type_Alias_Record is record
      Name        : Unbounded_String := To_Unbounded_String ("");
      Base_Name   : Unbounded_String := To_Unbounded_String ("");
      Is_Routine  : Boolean := False;
      Active      : Boolean := False;
      --  AST node of the AST_Routine_Type_Decl — lets LAMBDA strict-check
      --  walk the declared signature (Arg_List params + ret).
      Decl_Node   : Node_Index := 0;
   end record;
   Type_Aliases      : array (1 .. Max_Type_Aliases) of Type_Alias_Record;
   Type_Alias_Count  : Natural := 0;

   Symbol_Count  : Natural := 0;
   Struct_Count  : Natural := 0;
   Field_Count   : Natural := 0;
   Routine_Count : Natural := 0;
   Predicate_Count : Natural := 0;
   --  PREDICATE closed world: only declared names may be
   --  asserted/queried/retracted/fact'd — name + arg count checked at
   --  compile time via the Predicate_Id_Expr choke point.
   Declared_Pred_Names : array (1 .. Max_Declared_Preds)
     of Unbounded_String := (others => To_Unbounded_String (""));
   Declared_Pred_Arity : array (1 .. Max_Declared_Preds)
     of Natural := (others => 0);
   Declared_Pred_Count : Natural := 0;
   --  REVERSIBLE block context (FASM parity): REV* ops are fatal outside
   --  a REVERSIBLE block; block children must be reversible ops only.
   Reversible_Depth : Natural := 0;
   Foreign_Import_Count : Natural := 0;
   Foreign_Export_Count : Natural := 0;

   Out_File     : Ada.Text_IO.File_Type;
   File_Open    : Boolean := False;
   Indent_Level : Natural := 0;

   --  Line-buffered output: Emit/New_Line_Emit accumulate into
   --  Out_Lines instead of writing Out_File directly so the runtime
   --  preamble (Emit_Runtime's byte range) can be filtered at flush
   --  time by the --rt-trim pass.  Flush_Output writes everything.
   Max_Out_Lines : constant := 262144;
   Out_Lines  : array (1 .. Max_Out_Lines) of Unbounded_String;
   Out_Line_N : Natural := 0;
   Out_Cur    : Unbounded_String := To_Unbounded_String ("");

   --  --rt-trim state.  Rt_Start/Rt_End mark the 1-based line range
   --  Emit_Runtime produced (half-open).  Rt_Keep pins named helpers.
   Rt_Trim_Enabled : Boolean := True;
   Max_Rt_Keep     : constant := 128;
   Rt_Keep   : array (1 .. Max_Rt_Keep) of Unbounded_String;
   Rt_Keep_N : Natural := 0;
   Rt_Start  : Natural := 0;
   Rt_End    : Natural := 0;

   Current_Module  : Unbounded_String := To_Unbounded_String ("");
   Current_Routine : Unbounded_String := To_Unbounded_String ("");
   Current_Routine_Out_Count : Natural := 0;
   --  LAMBDA support: anonymous routines hoist to top-level
   --  `function __alb_lambda_N` (globals+params only — no captures).
   Max_Lambdas : constant := 512;
   Lambda_Queue : array (1 .. Max_Lambdas) of Node_Index := (others => 0);
   --  Per-queued name of the variable the lambda binds to (self-recursion
   --  ban); "" for member-field targets.
   Lambda_Bound_Queue : array (1 .. Max_Lambdas) of Unbounded_String :=
     (others => To_Unbounded_String (""));
   Lambda_Count : Natural := 0;
   --  Emission-time guards: set while Emit_Lambda_Decl runs.
   In_Lambda             : Boolean := False;
   Lambda_Bound          : Unbounded_String := To_Unbounded_String ("");
   Current_Routine_Out_Names : array (1 .. Max_Params) of Unbounded_String :=
     (others => To_Unbounded_String (""));
   Saw_Create      : Boolean := False;
   Saw_Listen      : Boolean := False;
   No_Console_Overlay : Boolean := False;
   Tick_Blocks     : Node_Index_List := (others => 0);
   Paint_Blocks    : Node_Index_List := (others => 0);
   Key_Blocks      : Node_Index_List := (others => 0);
   Rule_Nodes      : Rule_Node_List := (others => 0);
   Watch_Nodes     : Watch_Node_List := (others => 0);
   Tick_Block_Count  : Natural := 0;
   Paint_Block_Count : Natural := 0;
   Key_Block_Count   : Natural := 0;
   Rule_Node_Count   : Natural := 0;
   Watch_Node_Count  : Natural := 0;
   Temp_Name_Counter : Natural := 0;
   Next_Address_Byte : Integer := 1;
   Need_Module_Support : Boolean := False;
   Need_Static_Graphics_Runtime : Boolean := False;
   Need_Markov_Runtime : Boolean := False;
   Need_Neural_Runtime : Boolean := False;
   --  EMOTION engine: compile-time registry — each emotion is a global
   --  `ALB_EMOTION_<name>` Uint8Array(8); ops resolve the axis name to a
   --  byte offset at compile time (FASM does the same via Find_Emotion).
   Max_Emotions : constant := 128;
   Max_Emotion_Axes : constant := 8;
   type Emotion_Axis_Names is array (1 .. Max_Emotion_Axes)
     of Unbounded_String;
   type Emotion_Record is record
      Name       : Unbounded_String := To_Unbounded_String ("");
      Axes       : Emotion_Axis_Names :=
        (others => To_Unbounded_String (""));
      Axis_Count : Natural := 0;
      Active     : Boolean := False;
   end record;
   Emotions      : array (1 .. Max_Emotions) of Emotion_Record;
   Emotion_Count : Natural := 0;
   Need_Network_Runtime : Boolean := False;
   Need_Process_Runtime : Boolean := False;
   Need_Compat_Runtime : Boolean := False;
   Need_Wasm_Loaders : Boolean := False;
   Shoebox_Root : Unbounded_String := To_Unbounded_String ("");
   Max_Mode_Nesting : constant Natural := 32;
   type Mode_Text_Stack is array (1 .. Max_Mode_Nesting) of Unbounded_String;
   Stride_Depth : Natural := 0;
   Stride_Step_Stack : Mode_Text_Stack := (others => To_Unbounded_String (""));
   Symbolic_Depth : Natural := 0;
   Exact_Depth : Natural := 0;

   function Expr (Node_Index_Value : Node_Index) return String;
   function Big_Expr (Node_Index_Value : Node_Index) return String;
   function Int_Kind (K : Value_Kind) return Boolean;
   function Raw_Feature_Atom (Index : Node_Index) return String;
   procedure Register_Routine_Signature (Index : Node_Index);
   procedure Emit_Block (Block_Node : Node_Index);
   function Queue_Lambda (Index : Node_Index) return String;
   procedure Check_Lambda_Bind (Lambda_Node : Node_Index; Alias_Name : String);
   procedure Lambda_Bound_Guard (Raw : String);
   procedure Lambda_Orphan_Guard (Raw : String);
   function Routine_Alias_Of (Token_Idx : Natural) return String;
   procedure Emit_Lambda_Decl
     (Index      : Node_Index;
      Lam_Name   : String;
      Bound_Name : String := "");
   procedure Flush_Lambda_Decls;
   function Statement_Target_Name
     (Target_Node : Node_Index;
      Assign_Kind : Value_Kind := VK_Unknown) return String;
   function Emit_Call_Expr_With_Out
     (Target_Name : String;
      Arg_List    : Node_Index) return String;
   function Out_Arg_Name (Arg_Node : Node_Index) return String;

   function Trim_Image (N : Integer) return String is
      S : constant String := Integer'Image (N);
   begin
      return Ada.Strings.Fixed.Trim (S, Ada.Strings.Both);
   end Trim_Image;

   function Raw_Lexeme (Token_Index : Natural) return String is
      Tok : Token;
   begin
      if Token_Index = 0 or else Token_Index > Tokens'Length then
         return "";
      end if;

      Tok := Tokens (Token_Index);
      if Tok.Length = 0 then
         return "";
      end if;

      return Input_Buffer (Tok.Start .. Tok.Start + Tok.Length - 1);
   end Raw_Lexeme;

   function Upper_Text (S : String) return String is
      R : String (S'Range);
   begin
      for I in S'Range loop
         R (I) := Ada.Characters.Handling.To_Upper (S (I));
      end loop;
      return R;
   end Upper_Text;

   --  ENABLE/INLINE <LANG> block tokens cover the whole
   --  "ENABLE TYPESCRIPT" .. "END ENABLE" wrapper; emit only the
   --  inner source lines so the raw splice stays valid TS.
   function Enable_Inner_Text (Token_Index : Natural) return String is
      Raw     : constant String := Raw_Lexeme (Token_Index);
      Up      : constant String := Upper_Text (Raw);
      First   : Natural := Raw'First;
      Last_E  : Natural;
      Cut     : Natural;
   begin
      while First <= Raw'Last and then Raw (First) /= ASCII.LF loop
         First := First + 1;
      end loop;
      if First > Raw'Last then
         return "";
      end if;
      First := First + 1;  --  skip past the ENABLE <LANG> line
      Last_E := Ada.Strings.Fixed.Index (Up, "END ENABLE", Going => Ada.Strings.Backward);
      if Last_E = 0 then
         Last_E := Raw'Last + 1;
      else
         --  back up to the start of the END ENABLE line
         Cut := Last_E;
         while Cut > First and then Raw (Cut - 1) /= ASCII.LF loop
            Cut := Cut - 1;
         end loop;
         Last_E := Cut;
      end if;
      if Last_E <= First then
         return "";
      end if;
      return Raw (First .. Last_E - 1);
   end Enable_Inner_Text;

   --  BRAILLE / NEMETH block tokens cover the whole
   --  "BRAILLE" .. "END BRAILLE" wrapper; the lexer guarantees the
   --  final lexeme line is the terminator, so the inner text is
   --  everything between the first LF and the start of the last line.
   --  The returned slice stays a view into the source buffer — the
   --  block body is compile-time static data, never heap-allocated.
   function Block_Inner_Text (Token_Index : Natural) return String is
      Raw   : constant String := Raw_Lexeme (Token_Index);
      First : Natural := Raw'First;
      P     : Natural;
   begin
      while First <= Raw'Last and then Raw (First) /= ASCII.LF loop
         First := First + 1;
      end loop;
      if First > Raw'Last then
         return "";
      end if;
      First := First + 1;  --  skip past the BRAILLE / NEMETH opener line

      P := Raw'Last;
      if Raw (P) = ASCII.LF then
         P := P - 1;  --  drop the terminator line's trailing newline
      end if;
      while P > First and then Raw (P - 1) /= ASCII.LF loop
         P := P - 1;
      end loop;
      --  P = start of the final (END <WORD>) line
      if P <= First then
         return "";
      end if;
      return Raw (First .. P - 1);
   end Block_Inner_Text;

   --  Read the optional flags off a BRAILLE / NEMETH opener line:
   --  `BRAILLE G1` selects TranscribeG1, `VERIFY` fatals when the
   --  error ledger is non-empty, `OUT "path"` writes the BRF
   --  transcript to a file, and `AS name` captures the transcript
   --  into name_uni / name_brf / name_ncells / name_cell(i) snapshot
   --  bindings.  Everything lives on the token's first line; the
   --  tokenizer has already validated the tail's shape.
   procedure Block_Opener_Flags
     (Token_Index : Natural;
      Has_G1      : out Boolean;
      Verify      : out Boolean;
      Name        : out Unbounded_String;
      Out_Path    : out Unbounded_String)
   is
      Raw : constant String := Raw_Lexeme (Token_Index);
      EOL : Natural;
      P   : Natural;

      function Is_Ident_Char (Ch : Character) return Boolean is
      begin
         return Ch in 'A' .. 'Z' or else Ch in 'a' .. 'z'
           or else Ch in '0' .. '9' or else Ch = '_';
      end Is_Ident_Char;

      procedure Skip_Blanks is
      begin
         while P <= EOL and then
           (Raw (P) = ' ' or else Raw (P) = ASCII.HT)
         loop
            P := P + 1;
         end loop;
      end Skip_Blanks;
   begin
      Has_G1   := False;
      Verify   := False;
      Name     := Null_Unbounded_String;
      Out_Path := Null_Unbounded_String;

      EOL := Raw'First;
      while EOL <= Raw'Last and then Raw (EOL) /= ASCII.LF loop
         EOL := EOL + 1;
      end loop;
      EOL := EOL - 1;
      if EOL < Raw'First then
         return;
      end if;

      --  skip the opener keyword itself
      P := Raw'First;
      while P <= EOL and then Is_Ident_Char (Raw (P)) loop
         P := P + 1;
      end loop;

      while P <= EOL loop
         Skip_Blanks;
         exit when P > EOL;
         exit when Raw (P) = '-' and then P < EOL
           and then Raw (P + 1) = '-';

         declare
            W_End : Natural := P;
         begin
            while W_End <= EOL and then Is_Ident_Char (Raw (W_End)) loop
               W_End := W_End + 1;
            end loop;
            if W_End = P then
               P := P + 1;   --  stray non-ident char; keep scanning
            else
               declare
                  W : constant String := Raw (P .. W_End - 1);
               begin
                  if Upper_Text (W) = "G1" then
                     Has_G1 := True;
                     P := W_End;
                  elsif Upper_Text (W) = "VERIFY" then
                     Verify := True;
                     P := W_End;
                  elsif Upper_Text (W) = "AS" then
                     P := W_End;
                     Skip_Blanks;
                     W_End := P;
                     while W_End <= EOL
                       and then Is_Ident_Char (Raw (W_End))
                     loop
                        W_End := W_End + 1;
                     end loop;
                     if W_End > P then
                        Name := To_Unbounded_String (Raw (P .. W_End - 1));
                     end if;
                     P := W_End;
                  elsif Upper_Text (W) = "OUT" then
                     P := W_End;
                     Skip_Blanks;
                     if P <= EOL and then Raw (P) = '"' then
                        W_End := P + 1;
                        while W_End <= EOL
                          and then Raw (W_End) /= '"'
                        loop
                           W_End := W_End + 1;
                        end loop;
                        if W_End <= EOL then
                           Out_Path := To_Unbounded_String
                             (Raw (P + 1 .. W_End - 1));
                           P := W_End + 1;
                        else
                           P := EOL;
                        end if;
                     else
                        P := W_End;
                     end if;
                  else
                     P := P + W'Length;
                  end if;
               end;
            end if;
         end;
      end loop;
   end Block_Opener_Flags;

   function U (S : String) return Unbounded_String renames To_Unbounded_String;
   function Escape_TS_String (Text : String) return String;
   function Resolve_Symbol (Raw : String) return Symbol_Record;
   function Is_Array_Kind (K : Symbol_Kind) return Boolean;
   function Find_Symbol_Shaped
     (Scope      : String;
      Name       : String;
      Want_Array : Boolean;
      Strict     : Boolean := False) return Natural;
   function Resolve_Symbol_Shaped
     (Raw        : String;
      Want_Array : Boolean;
      Strict     : Boolean := False) return Symbol_Record;
   function Target_Symbol (Target_Node : Node_Index) return Symbol_Record;
   function Collect_Module_Member_Name (Node_Index_Value : Node_Index) return String;

   function Safe_JS_Name (Name : String) return String is
      Result : Unbounded_String := To_Unbounded_String ("");
      C      : Character;
      Text   : constant String := Ada.Strings.Fixed.Trim (Name, Ada.Strings.Both);
      Upper  : constant String := Upper_Text (Text);
      Needs_Prefix : Boolean := False;
   begin
      if Text'Length = 0 then
         return "alb_anon";
      end if;

      if Text (Text'First) in '0' .. '9' then
         Append (Result, "alb_");
      end if;

      for I in Text'Range loop
         C := Text (I);
         if (C in 'a' .. 'z') or else (C in 'A' .. 'Z')
           or else (C in '0' .. '9') or else C = '_'
         then
            Append (Result, C);
         elsif C = '.' then
            Append (Result, "_");
         else
            Append (Result, "_");
         end if;
      end loop;

      Needs_Prefix :=
        Upper = "BREAK" or else
        Upper = "CASE" or else
        Upper = "CATCH" or else
        Upper = "CLASS" or else
        Upper = "CONST" or else
        Upper = "CONTINUE" or else
        Upper = "DEBUGGER" or else
        Upper = "DEFAULT" or else
        Upper = "DELETE" or else
        Upper = "DO" or else
        Upper = "ELSE" or else
        Upper = "ENUM" or else
        Upper = "EXPORT" or else
        Upper = "EXTENDS" or else
        Upper = "FALSE" or else
        Upper = "FINALLY" or else
        Upper = "FOR" or else
        Upper = "FUNCTION" or else
        Upper = "IF" or else
        Upper = "IMPLEMENTS" or else
        Upper = "IMPORT" or else
        Upper = "IN" or else
        Upper = "INSTANCEOF" or else
        Upper = "INTERFACE" or else
        Upper = "LET" or else
        Upper = "NEW" or else
        Upper = "NULL" or else
        Upper = "OF" or else
        Upper = "PACKAGE" or else
        Upper = "PRIVATE" or else
        Upper = "PROTECTED" or else
        Upper = "PUBLIC" or else
        Upper = "RETURN" or else
        Upper = "STATIC" or else
        Upper = "SUPER" or else
        Upper = "SWITCH" or else
        Upper = "THIS" or else
        Upper = "THROW" or else
        Upper = "TRUE" or else
        Upper = "TRY" or else
        Upper = "TYPEOF" or else
        Upper = "VAR" or else
        Upper = "VOID" or else
        Upper = "WHILE" or else
        Upper = "WITH" or else
        Upper = "WORKER" or else
        Upper = "YIELD";

      if Needs_Prefix then
         return "alb_" & To_String (Result);
      end if;

      return To_String (Result);
   end Safe_JS_Name;

   function Scoped_Name (Name : String) return String is
   begin
      if Length (Current_Module) = 0 then
         return Safe_JS_Name (Name);
      else
         return Safe_JS_Name (To_String (Current_Module) & "_" & Name);
      end if;
   end Scoped_Name;

   function Starts_With (Text : String; Prefix : String) return Boolean is
   begin
      return Prefix'Length <= Text'Length
        and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix;
   end Starts_With;

   function Next_Temp_Name (Prefix : String) return String is
   begin
      Temp_Name_Counter := Temp_Name_Counter + 1;
      return "__alb_" & Safe_JS_Name (Prefix) & "_" & Trim_Image (Integer (Temp_Name_Counter));
   end Next_Temp_Name;

   function Ensure_Predicate_Id (Name : String) return Natural is
      Trimmed : constant String := Ada.Strings.Fixed.Trim (Name, Ada.Strings.Both);
   begin
      if Trimmed'Length = 0 then
         return 0;
      end if;

      for I in 1 .. Predicate_Count loop
         if Predicates (I).Active
           and then To_String (Predicates (I).Name) = Trimmed
         then
            return Predicates (I).Id;
         end if;
      end loop;

      if Predicate_Count < Max_Predicates then
         Predicate_Count := Predicate_Count + 1;
         Predicates (Predicate_Count).Active := True;
         Predicates (Predicate_Count).Name := U (Trimmed);
         Predicates (Predicate_Count).Id := Predicate_Count;
         return Predicate_Count;
      end if;

      return 0;
   end Ensure_Predicate_Id;

   function Predicate_Name_From_Node (Pred_Node : Node_Index) return String is
      Node : AST_Node;
   begin
      if Pred_Node = 0 then
         return "";
      end if;

      Node := Tree (Pred_Node);

      case Node.Kind is
         when AST_Predicate | AST_Assert_Stmt | AST_Retract_Stmt =>
            return Raw_Lexeme (Node.Token_Index);
         when AST_Update_Stmt | AST_Findall_Query | AST_Query | AST_Knows_Query
           | AST_Rule_Decl | AST_Constraint_Decl =>
            if Node.Left_Child > 0 then
               return Predicate_Name_From_Node (Node.Left_Child);
            end if;
            return "";
         when AST_Knows_Change =>
            if Node.Right_Child > 0 then
               return Predicate_Name_From_Node (Node.Right_Child);
            end if;
            return "";
         when AST_Find_Query =>
            if Upper_Text (Raw_Lexeme (Node.Token_Index)) = "FIND"
              and then Node.Left_Child > 0
            then
               return Predicate_Name_From_Node (Node.Left_Child);
            end if;
            return Raw_Lexeme (Node.Token_Index);
         when AST_Func_Call | AST_Var_Expr | AST_Atom | AST_Logic_Var =>
            if Node.Token_Index > 0 then
               return Raw_Lexeme (Node.Token_Index);
            end if;
            return "";
         when others =>
            if Node.Token_Index > 0 then
               return Raw_Lexeme (Node.Token_Index);
            end if;
            return "";
      end case;
   end Predicate_Name_From_Node;

   function Predicate_First_Arg_Node (Pred_Node : Node_Index) return Node_Index is
      Node : AST_Node;
   begin
      if Pred_Node = 0 then
         return 0;
      end if;

      Node := Tree (Pred_Node);

      if Node.Kind = AST_Predicate and then Node.Left_Child > 0 then
         if Tree (Node.Left_Child).Kind = AST_Arg_List then
            return Tree (Node.Left_Child).Left_Child;
         else
            return Node.Left_Child;
         end if;
      elsif Node.Kind in AST_Update_Stmt | AST_Findall_Query | AST_Query
        | AST_Knows_Query | AST_Rule_Decl | AST_Constraint_Decl
      then
         return Predicate_First_Arg_Node (Node.Left_Child);
      elsif Node.Kind = AST_Knows_Change and then Node.Right_Child > 0 then
         return Predicate_First_Arg_Node (Node.Right_Child);
      elsif Node.Kind = AST_Find_Query then
         if Upper_Text (Raw_Lexeme (Node.Token_Index)) = "FIND"
           and then Node.Left_Child > 0
         then
            return Predicate_First_Arg_Node (Node.Left_Child);
         end if;
         return Node.Left_Child;
      elsif Node.Kind in AST_Assert_Stmt | AST_Retract_Stmt | AST_Find_Query then
         return Node.Left_Child;
      elsif Node.Kind = AST_Func_Call and then Node.Right_Child > 0 then
         if Tree (Node.Right_Child).Kind = AST_Arg_List then
            return Tree (Node.Right_Child).Left_Child;
         else
            return Node.Right_Child;
         end if;
      else
         return 0;
      end if;
   end Predicate_First_Arg_Node;

   function Find_Declared_Pred (Name : String) return Natural is
      Folded : constant String := Upper_Text (Name);
   begin
      for I in 1 .. Declared_Pred_Count loop
         if Upper_Text (To_String (Declared_Pred_Names (I))) = Folded then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Declared_Pred;

   function Predicate_Arg_Count (Pred_Node : Node_Index) return Natural is
      Arg  : Node_Index := Predicate_First_Arg_Node (Pred_Node);
      Cnt  : Natural := 0;
   begin
      while Arg > 0 and then Cnt < 8 loop
         Cnt := Cnt + 1;
         Arg := Tree (Arg).Next_Sibling;
      end loop;
      return Cnt;
   end Predicate_Arg_Count;

   function Predicate_Id_Expr (Pred_Node : Node_Index) return String is
      Name  : constant String := Predicate_Name_From_Node (Pred_Node);
      D_Idx : constant Natural := Find_Declared_Pred (Name);
      Arity : constant Natural := Predicate_Arg_Count (Pred_Node);
   begin
      if D_Idx = 0 then
         raise Program_Error with
           "PREDICATE closed world: '" & Name & "' is not declared — " &
           "add `PREDICATE " & Name & "(args...)` first";
      end if;
      if Declared_Pred_Arity (D_Idx) /= Arity then
         raise Program_Error with
           "PREDICATE '" & Name & "' declared with arity " &
           Trim_Image (Declared_Pred_Arity (D_Idx)) &
           " but used with " & Trim_Image (Arity);
      end if;
      return Trim_Image (Integer (Ensure_Predicate_Id (Name)));
   end Predicate_Id_Expr;

   function Predicate_Arg1_Expr (Pred_Node : Node_Index) return String is
      Arg_Node : constant Node_Index := Predicate_First_Arg_Node (Pred_Node);
   begin
      if Arg_Node > 0 then
         return Expr (Arg_Node);
      else
         return "0";
      end if;
   end Predicate_Arg1_Expr;

   function Predicate_Arity_Expr (Pred_Node : Node_Index) return String is
   begin
      if Predicate_First_Arg_Node (Pred_Node) > 0 then
         return "1";
      else
         return "0";
      end if;
   end Predicate_Arity_Expr;

   function Logic_Var_Name_From_Node (Pred_Node : Node_Index) return String is
      Arg_Node : constant Node_Index := Predicate_First_Arg_Node (Pred_Node);
   begin
      if Arg_Node > 0 and then Tree (Arg_Node).Kind = AST_Logic_Var then
         return Raw_Lexeme (Tree (Arg_Node).Token_Index);
      end if;
      return "";
   end Logic_Var_Name_From_Node;

   procedure Remember_Rule_Node (Rule_Node : Node_Index) is
   begin
      if Rule_Node > 0 and then Rule_Node_Count < Max_Logic_Rules then
         Rule_Node_Count := Rule_Node_Count + 1;
         Rule_Nodes (Rule_Node_Count) := Rule_Node;
      end if;
   end Remember_Rule_Node;

   procedure Remember_Watch_Node (Watch_Node : Node_Index) is
   begin
      if Watch_Node > 0 and then Watch_Node_Count < Max_Logic_Watches then
         Watch_Node_Count := Watch_Node_Count + 1;
         Watch_Nodes (Watch_Node_Count) := Watch_Node;
      end if;
   end Remember_Watch_Node;

   procedure Emit (Text : String) is
   begin
      Append (Out_Cur, Text);
   end Emit;

   procedure New_Line_Emit is
   begin
      if Out_Line_N >= Max_Out_Lines then
         raise Program_Error with "output line table full";
      end if;
      Out_Line_N := Out_Line_N + 1;
      Out_Lines (Out_Line_N) := Out_Cur;
      Out_Cur := To_Unbounded_String ("");
   end New_Line_Emit;

   procedure Emit_Indent is
   begin
      for I in 1 .. Indent_Level loop
         Emit ("    ");
      end loop;
   end Emit_Indent;

   procedure Line (Text : String) is
   begin
      Emit_Indent;
      Emit (Text);
      New_Line_Emit;
   end Line;

   --  `... AS name` capture on a BRAILLE / NEMETH block: snapshot the
   --  engine's three output forms into name_* bindings so a later
   --  block can't clobber them.  Cells + error texts are copied out —
   --  the engine arrays are shared global state.
   --    name_uni / name_brf   STRING   finished transcripts
   --    name_ncells           count    (-1 cells are line breaks)
   --    name_cell(i)          6-bit dot mask, -2 out of range
   --    name_errs / name_err(i)  transcription error ledger
   --    name_rows / name_row(i) / name_rowbrf(i)  line-split readback
   --  Nemeth captures additionally emit:
   --    name_src / name_rsrc  STRING   source / canonical re-read
   --    name_latex / name_mathml       B2 renderings
   --  When the program carries the MCP preamble, the capture also
   --  self-registers as alb://<Scheme>/<name> (JSON payload) so an
   --  agent can read transcripts with zero user glue; the typeof
   --  guard makes the registration a no-op otherwise.
   procedure Emit_Block_Capture
     (Name    : String;
      Eng     : String;
      Cells   : String;
      Brf_Tab : String;
      Scheme  : String;
      Src     : String)
   is
   begin
      if Name'Length = 0 then
         return;
      end if;
      Line ("var " & Name & "_uni = " & Eng & "_ToUni();");
      Line ("var " & Name & "_brf = " & Eng & "_ToBrf();");
      Line ("var " & Name & "_ncells = " & Eng & "_Count();");
      Line ("var " & Name & "_errs = " & Eng & "_ErrCount();");
      Line ("var " & Name & "_cells = " & Cells &
            ".slice(0, " & Name & "_ncells);");
      Line ("var " & Name & "_errtxt = [];");
      Line ("for (var __alb_bi = 0; __alb_bi < " & Name &
            "_errs; __alb_bi++) " &
            Name & "_errtxt.push(" & Eng & "_ErrText(__alb_bi));");
      Line ("function " & Name & "_cell(i: number): number { return " &
            "i >= 0 && i < " & Name & "_ncells ? Number(" & Name &
            "_cells[i]) : -2; }");
      Line ("function " & Name & "_err(i: number): string { return " &
            "i >= 0 && i < " & Name & "_errs ? " & Name &
            "_errtxt[i] : """"; }");
      Line ("var " & Name & "_rows = 0;");
      Line ("for (var __alb_bi = 0; __alb_bi < " & Name &
            "_ncells; __alb_bi++) { if (Number(" & Name &
            "_cells[__alb_bi]) === -1) " & Name & "_rows++; }");
      Line ("if (" & Name & "_ncells > 0) " & Name & "_rows++;");
      Line ("function " & Name &
            "_row(i: number): string { let r = 0, s = ''; for (let k" &
            " = 0; k < " & Name & "_ncells; k++) { const c = Number(" &
            Name & "_cells[k]); if (c === -1) { if (r === i) return s;" &
            " r++; continue; } if (r === i) s += " &
            "String.fromCharCode(10240 + c); } return r === i ? s :" &
            " ''; }");
      Line ("function " & Name &
            "_rowbrf(i: number): string { let r = 0, s = ''; for (let" &
            " k = 0; k < " & Name & "_ncells; k++) { const c =" &
            " Number(" & Name & "_cells[k]); if (c === -1) { if (r =" &
            "== i) return s; r++; continue; } if (r === i) s += " &
            "String.fromCharCode(Number(" & Brf_Tab & "[c])); }" &
            " return r === i ? s : ''; }");
      if Src'Length > 0 then
         Line ("var " & Name & "_src = " & Src & ";");
         Line ("var " & Name & "_rsrc = " & Eng & "_FromCells(" &
               Name & "_ncells);");
         Line ("var " & Name & "_latex = " & Eng & "_ToLatex(" &
               Name & "_src);");
         Line ("var " & Name & "_mathml = " & Eng & "_ToMathML(" &
               Name & "_src);");
         Line ("if (typeof albMcpResources !== 'undefined') { " &
               "albMcpResources[""alb://" & Scheme & "/" & Name &
               """] = { name: """ & Name &
               """, mimeType: 'application/json', fn: () => " &
               "JSON.stringify({brf: " & Name & "_brf, uni: " & Name &
               "_uni, ncells: " & Name & "_ncells, errors: " & Name &
               "_errs, errorText: " & Name & "_errtxt, latex: " &
               Name & "_latex, mathml: " & Name &
               "_mathml, rsrc: " & Name & "_rsrc }) }; }");
      else
         Line ("if (typeof albMcpResources !== 'undefined') { " &
               "albMcpResources[""alb://" & Scheme & "/" & Name &
               """] = { name: """ & Name &
               """, mimeType: 'application/json', fn: () => " &
               "JSON.stringify({brf: " & Name & "_brf, uni: " & Name &
               "_uni, ncells: " & Name & "_ncells, errors: " & Name &
               "_errs, errorText: " & Name & "_errtxt }) }; }");
      end if;
   end Emit_Block_Capture;

   procedure Reset_State is
   begin
      Out_Line_N := 0;
      Out_Cur := To_Unbounded_String ("");
      Rt_Start := 0;
      Rt_End := 0;
      --  Per-element clears, bounded by the live prefix: a whole-array
      --  `(others => (others => <>))` aggregate builds a full-size
      --  temporary on the stack (~6MB for Symbols alone) which blows
      --  the default 8MB POSIX main-thread stack.
      for I in 1 .. Symbol_Count loop
         Symbols (I) := (others => <>);
      end loop;
      for I in 1 .. Struct_Count loop
         Structs (I) := (others => <>);
      end loop;
      for I in 1 .. Field_Count loop
         Fields (I) := (others => <>);
      end loop;
      for I in 1 .. Routine_Count loop
         Routines (I) := (others => <>);
      end loop;
      for I in 1 .. Predicate_Count loop
         Predicates (I) := (others => <>);
      end loop;
      for I in 1 .. Foreign_Import_Count loop
         Foreign_Imports (I) := (others => <>);
      end loop;
      for I in 1 .. Foreign_Export_Count loop
         Foreign_Exports (I) := (others => <>);
      end loop;
      Symbol_Count := 0;
      Struct_Count := 0;
      Field_Count := 0;
      Routine_Count := 0;
      Predicate_Count := 0;
      Declared_Pred_Count := 0;
      Declared_Pred_Names := (others => U (""));
      Declared_Pred_Arity := (others => 0);
      Reversible_Depth := 0;
      Foreign_Import_Count := 0;
      Foreign_Export_Count := 0;
      Indent_Level := 0;
      Current_Module := U ("");
      Current_Routine := U ("");
      for I in 1 .. Type_Alias_Count loop
         Type_Aliases (I) := (others => <>);
      end loop;
      Type_Alias_Count := 0;
      Lambda_Queue := (others => 0);
      Lambda_Bound_Queue := (others => To_Unbounded_String (""));
      Lambda_Count := 0;
      In_Lambda := False;
      Lambda_Bound := To_Unbounded_String ("");
      Saw_Create := False;
      Saw_Listen := False;
      Tick_Blocks := (others => 0);
      Paint_Blocks := (others => 0);
      Key_Blocks := (others => 0);
      Rule_Nodes := (others => 0);
      Watch_Nodes := (others => 0);
      Tick_Block_Count := 0;
      Paint_Block_Count := 0;
      Key_Block_Count := 0;
      Rule_Node_Count := 0;
      Watch_Node_Count := 0;
      Temp_Name_Counter := 0;
      Next_Address_Byte := 1;
      Need_Module_Support := False;
      Need_Static_Graphics_Runtime := False;
      Need_Markov_Runtime := False;
      Need_Neural_Runtime := False;
      for I in 1 .. Emotion_Count loop
         Emotions (I) := (others => <>);
      end loop;
      Emotion_Count := 0;
      Need_Network_Runtime := False;
      Need_Process_Runtime := False;
      Need_Compat_Runtime := False;
      Need_Wasm_Loaders := False;
      Shoebox_Root := U ("");
      Stride_Depth := 0;
      Stride_Step_Stack := (others => U (""));
      Symbolic_Depth := 0;
      Exact_Depth := 0;
   end Reset_State;

   function Element_Bytes (Kind : Value_Kind) return Integer is
   begin
      case Kind is
         when VK_U8 | VK_S8 | VK_HW8 | VK_Boolean =>
            return 1;
         when VK_U16 | VK_S16 | VK_HW16 =>
            return 2;
         when VK_U32 | VK_U64 | VK_S32 | VK_HW32 | VK_Pure | VK_Number | VK_F64 =>
            return 4;
         when others =>
            return 4;
      end case;
   end Element_Bytes;

   function Allocate_Address_Bytes (Bytes : Integer) return Integer is
      Size : constant Integer := Integer'Max (1, Bytes);
      Base : constant Integer := Next_Address_Byte;
   begin
      Next_Address_Byte := Next_Address_Byte + Size;
      return Base;
   end Allocate_Address_Bytes;

   function Find_Type_Alias (Name : String) return Natural;

   function Type_From_Name (Name : String) return Value_Kind is
      T : constant String := Upper_Text (Ada.Strings.Fixed.Trim (Name, Ada.Strings.Both));
   begin
      if T = "BOOL" or else T = "BOOLEAN" then
         return VK_Boolean;
      elsif T = "STRING" then
         return VK_String;
      elsif T = "BINARY" then
         return VK_Binary;
      elsif T = "PURE" or else T = "RATIONAL" then
         return VK_Pure;
      elsif T = "U8" then
         return VK_U8;
      elsif T = "U16" then
         return VK_U16;
      elsif T = "S8" or else T = "I8" or else T = "INT8" then
         return VK_S8;
      elsif T = "S16" or else T = "I16" or else T = "INT16" then
         return VK_S16;
      elsif T = "U32" then
         return VK_U32;
      elsif T = "U64" then
         return VK_U64;
      elsif T = "S64" or else T = "I64" or else T = "INT64" then
         return VK_Number;
      elsif T = "S32" or else T = "I32" or else T = "INT32" then
         return VK_S32;
      elsif T = "F32" or else T = "SINGLE" or else T = "FLOAT" then
         return VK_F32;
      elsif T = "F64" or else T = "REAL" then
         return VK_F64;
      elsif T = "FLOAT2" or else T = "F32X2" or else
        T = "FLOAT4" or else T = "F32X4" or else
        T = "MAT2" or else T = "MAT2X2" or else
        T = "MAT3" or else T = "MAT3X3" or else
        T = "MAT4" or else T = "MAT4X4"
      then
         return VK_Struct;
      elsif T = "BOOLEAN" or else T = "BOOL" then
         return VK_Boolean;
      elsif T = "STRING" then
         return VK_String;
      elsif T = "BINARY" then
         return VK_Binary;
      elsif T = "HW8" then
         return VK_HW8;
      elsif T = "HW16" then
         return VK_HW16;
      elsif T = "HW32" then
         return VK_HW32;
      elsif T = "U128" then
         return VK_U128;
      else
         declare
            Alias_Id : constant Natural := Find_Type_Alias (T);
         begin
            if Alias_Id /= 0 then
               if Type_Aliases (Alias_Id).Is_Routine then
                  --  Function-valued: VK_Struct gives a pass-through cast
                  --  and the Find_Struct guard keeps it a scalar symbol.
                  return VK_Struct;
               end if;
               return Type_From_Name
                 (To_String (Type_Aliases (Alias_Id).Base_Name));
            end if;
         end;
         return VK_Struct;
      end if;
   end Type_From_Name;

   function Type_From_Token (Token_Index : Natural) return Value_Kind is
   begin
      if Token_Index = 0 then
         return VK_Unknown;
      end if;
      return Type_From_Name (Raw_Lexeme (Token_Index));
   end Type_From_Token;

   function Primitive_TS_Type (Kind : Value_Kind) return String is
   begin
      case Kind is
         when VK_Boolean =>
            return "boolean";
         when VK_String | VK_Binary =>
            return "string";
         when VK_U128 =>
            return "bigint";
         when others =>
            return "number";
      end case;
   end Primitive_TS_Type;

   function Default_Value
     (Kind        : Value_Kind;
      Struct_Name : String := "") return String is
   begin
      case Kind is
         when VK_Boolean =>
            return "false";
         when VK_String | VK_Binary =>
            return """""";
         when VK_U128 =>
            return "0n";
         when VK_F64 | VK_F32 =>
            return "0.0";
         when VK_Struct =>
            declare
               Shape_Name : constant String :=
                 Upper_Text (Ada.Strings.Fixed.Trim (Struct_Name, Ada.Strings.Both));
            begin
               if Shape_Name = "FLOAT2" or else Shape_Name = "F32X2" then
                  return "[0.0, 0.0]";
               elsif Shape_Name = "FLOAT4" or else Shape_Name = "F32X4" then
                  return "[0.0, 0.0, 0.0, 0.0]";
               elsif Shape_Name = "MAT2" or else Shape_Name = "MAT2X2" then
                  return "[[0.0, 0.0], [0.0, 0.0]]";
               elsif Shape_Name = "MAT3" or else Shape_Name = "MAT3X3" then
                  return "[[0.0, 0.0, 0.0], [0.0, 0.0, 0.0], [0.0, 0.0, 0.0]]";
               elsif Shape_Name = "MAT4" or else Shape_Name = "MAT4X4" then
                  return "[[0.0, 0.0, 0.0, 0.0], [0.0, 0.0, 0.0, 0.0], [0.0, 0.0, 0.0, 0.0], [0.0, 0.0, 0.0, 0.0]]";
               elsif Struct_Name'Length > 0 then
                  return "{} as " & Safe_JS_Name (Struct_Name);
               else
                  return "{}";
               end if;
            end;
         when others =>
            return "0";
      end case;
   end Default_Value;

   --  "{field1: d1, field2: d2}" literal for a STRUCT type name.
   function Struct_Literal (Struct_Name : String) return String is
      Field_Text : Unbounded_String := U ("");
      First      : Boolean := True;
      SName      : constant String := Safe_JS_Name (Struct_Name);
   begin
      for I in 1 .. Field_Count loop
         if Fields (I).Active
           and then To_String (Fields (I).Struct_Name) = SName
         then
            if not First then
               Append (Field_Text, ", ");
            end if;
            Append (Field_Text,
                    To_String (Fields (I).JS_Field) & ": " &
                    Default_Value (Fields (I).Tag, To_String (Fields (I).Type_Name)));
            First := False;
         end if;
      end loop;
      return "{" & To_String (Field_Text) & "}";
   end Struct_Literal;

   function Type_Annotation_From_Name (Name : String) return String is
      Upper : constant String := Upper_Text (Ada.Strings.Fixed.Trim (Name, Ada.Strings.Both));
      Kind  : constant Value_Kind := Type_From_Name (Name);
   begin
      if Upper = "FLOAT2" or else Upper = "F32X2" or else
        Upper = "FLOAT4" or else Upper = "F32X4" or else
        Upper = "MAT2" or else Upper = "MAT2X2" or else
        Upper = "MAT3" or else Upper = "MAT3X3" or else
        Upper = "MAT4" or else Upper = "MAT4X4"
      then
         return "number[]";
      elsif Kind = VK_Struct then
         return Safe_JS_Name (Name);
      else
         return Primitive_TS_Type (Kind);
      end if;
   end Type_Annotation_From_Name;

   function Cast_Expr (Kind : Value_Kind; Expr : String) return String is
   begin
      case Kind is
         when VK_Boolean =>
            return "Boolean(" & Expr & ")";
         when VK_String | VK_Binary =>
            return "String(" & Expr & ")";
         when VK_U8 =>
            return "albU8(" & Expr & ")";
         when VK_U16 =>
            return "albU16(" & Expr & ")";
         when VK_S8 =>
            return "albI8(" & Expr & ")";
         when VK_S16 =>
            return "albI16(" & Expr & ")";
         when VK_U32 =>
            return "albU32(" & Expr & ")";
         when VK_U64 =>
            return "albU64(" & Expr & ")";
         when VK_S32 | VK_HW8 | VK_HW16 | VK_HW32 =>
            return "albI32(" & Expr & ")";
         when VK_Number =>
            --  S64: assigning a non-integral value truncates toward zero,
            --  same as FASM cvttsd2si — `LET iv AS S64 = 4.47` stores 4.
            return "Math.trunc(Number(" & Expr & "))";
         when VK_F64 | VK_F32 | VK_Pure | VK_Unknown =>
            return "Number(" & Expr & ")";
         when VK_U128 =>
            return "BigInt(" & Expr & ")";
         when VK_Struct =>
            return Expr;
      end case;
   end Cast_Expr;

   function Is_Real_Number_Text (Text : String) return Boolean;
   function Find_Routine_For_Call (Target_Name : String) return Natural;
   function Num_Op (N : Node_Index; Text : String) return String;
   function Resolve_Routine_Name (Raw : String) return String;
   function Find_Field
     (Struct_Name : String;
      Field_Name  : String) return Natural;

   function Infer_Expr_Kind (Index : Node_Index) return Value_Kind is
      Node : AST_Node;
      Sym  : Symbol_Record;
   begin
      if Index = 0 then
         return VK_Unknown;
      end if;

      Node := Tree (Index);
      case Node.Kind is
         when AST_String_Expr | AST_TypeOf_Expr =>
            return VK_String;
         when AST_True | AST_False =>
            return VK_Boolean;
         when AST_Var_Expr =>
            if Node.Token_Index > 0 then
               Sym := Resolve_Symbol_Shaped
                 (Raw_Lexeme (Node.Token_Index),
                  Want_Array => Node.Left_Child > 0,
                  Strict     => Node.Left_Child = 0);
               if Sym.Active then
                  return Sym.Tag;
               end if;
            end if;
            return VK_Unknown;
         when AST_Temporal_Ref =>
            if Node.Left_Child > 0 and then Tree (Node.Left_Child).Token_Index > 0 then
               Sym := Resolve_Symbol (Raw_Lexeme (Tree (Node.Left_Child).Token_Index));
               if Sym.Active then
                  return Sym.Tag;
               end if;
            end if;
            return VK_Unknown;
         when AST_Cast_Expr | AST_Constructor =>
            if Node.Token_Index > 0 then
               return Type_From_Token (Node.Token_Index);
            end if;
            return VK_Unknown;
         when AST_Number_Expr =>
            if Node.Token_Index > 0
              and then Is_Real_Number_Text (Raw_Lexeme (Node.Token_Index))
            then
               return VK_F64;
            end if;
            return VK_Number;
         when AST_Unary_Minus =>
            return Infer_Expr_Kind (Node.Left_Child);
         when AST_BinOp =>
            declare
               Op : constant Token_Kind :=
                 (if Node.Token_Index > 0
                  then Tokens (Node.Token_Index).Kind
                  else Tok_Error);
               LK : constant Value_Kind := Infer_Expr_Kind (Node.Left_Child);
               RK : constant Value_Kind := Infer_Expr_Kind (Node.Right_Child);
            begin
               --  '|' / '&' are string concat: the result is always text
               --  regardless of operand kinds. Checking this first keeps a
               --  numeric operand from re-wrapping accumulated text in
               --  ALB_FText (which re-parses and eats separators).
               if Op = Tok_Pipe or else Op = Tok_Ampersand then
                  return VK_String;
               elsif Op in Tok_Less | Tok_Greater | Tok_Less_Equal |
                     Tok_Greater_Equal | Tok_Equal | Tok_Assign |
                     Tok_Not_Equal | Tok_Andalso | Tok_Orelse
               then
                  return VK_Boolean;
               elsif LK in VK_F64 | VK_F32 or else RK in VK_F64 | VK_F32 then
                  return VK_F64;
               elsif LK = VK_String or else RK = VK_String then
                  return VK_String;
               elsif Int_Kind (LK) and then Int_Kind (RK) then
                  --  int op int stays int — needed so `h*h - n*k*k <> 1`
                  --  and friends take the exact BigInt compare path.
                  return VK_Number;
               else
                  return VK_Unknown;
               end if;
            end;
         when AST_Member_Expr =>
            if Node.Left_Child > 0 and then Node.Right_Child > 0
              and then Tree (Node.Left_Child).Token_Index > 0
              and then Tree (Node.Right_Child).Token_Index > 0
            then
               declare
                  Left_Name  : constant String := Raw_Lexeme (Tree (Node.Left_Child).Token_Index);
                  Right_Name : constant String := Raw_Lexeme (Tree (Node.Right_Child).Token_Index);
                  Group_Sym  : constant Symbol_Record :=
                    Resolve_Symbol (Left_Name & "." & Right_Name);
                  Left_Sym   : constant Symbol_Record := Resolve_Symbol (Left_Name);
               begin
                  if Group_Sym.Active then
                     return Group_Sym.Tag;
                  elsif Left_Sym.Active and then Left_Sym.Kind = Sym_Struct_Var then
                     declare
                        Field_Id : constant Natural :=
                          Find_Field (To_String (Left_Sym.Struct_Name), Safe_JS_Name (Right_Name));
                     begin
                        if Field_Id /= 0 then
                           return Fields (Field_Id).Tag;
                        end if;
                     end;
                  end if;
               end;
            end if;
            return VK_Unknown;
         when AST_Choose =>
            if Node.Right_Child > 0
              and then Tree (Node.Right_Child).Left_Child > 0
            then
               return Infer_Expr_Kind (Tree (Node.Right_Child).Left_Child);
            end if;
            return VK_Unknown;
         when AST_Func_Call =>
            if Node.Left_Child > 0 then
               declare
                  Call_Node : constant AST_Node := Tree (Node.Left_Child);
                  Raw       : constant String :=
                    (if Call_Node.Token_Index > 0
                     then Upper_Text (Raw_Lexeme (Call_Node.Token_Index))
                     else "");
                  Raw_Case  : constant String :=
                    (if Call_Node.Token_Index > 0
                     then Raw_Lexeme (Call_Node.Token_Index)
                     else "");
               begin
                  if Raw = "LEFT" or else Raw = "LEFT$"
                    or else Raw = "RIGHT" or else Raw = "RIGHT$"
                    or else Raw = "MID" or else Raw = "MID$"
                    or else Raw = "CONCAT" or else Raw = "TYPEOF"
                    or else Raw = "UCASE" or else Raw = "UCASE$"
                    or else Raw = "LCASE" or else Raw = "LCASE$"
                    or else Raw = "TRIM" or else Raw = "TRIM$"
                    or else Raw = "SPC" or else Raw = "SPACE"
                    or else Raw = "STR" or else Raw = "STR$"
                    or else Raw = "CHR"
                  then
                     return VK_String;
                  elsif Raw = "ASIN" or else Raw = "ACOS"
                    or else Raw = "ATAN" or else Raw = "ATAN2"
                    or else Raw = "LN" or else Raw = "LOG"
                    or else Raw = "LOGN" or else Raw = "LOG2"
                    or else Raw = "LOG10" or else Raw = "POW"
                    or else Raw = "TAN"
                  then
                     return VK_F64;
                  elsif Raw = "SIN" or else Raw = "COS"
                    or else Raw = "SQRT" or else Raw = "EXP"
                  then
                     --  Same type-dependent contract as the call emitter.
                     declare
                        A0 : Node_Index := Node.Right_Child;
                     begin
                        if A0 > 0 and then Tree (A0).Kind = AST_Arg_List then
                           A0 := Tree (A0).Left_Child;
                        end if;
                        if A0 > 0
                          and then Infer_Expr_Kind (A0) in VK_F64 | VK_F32
                        then
                           return VK_F64;
                        end if;
                     end;
                  elsif Raw = "FLOOR" or else Raw = "CEIL"
                    or else Raw = "ABS" or else Raw = "ROUND"
                    or else Raw = "TRUNC"
                  then
                     --  Whole-number ops preserve the operand's kind —
                     --  FLOOR(9.75) stays F64 and prints "9.000000".
                     declare
                        A0 : Node_Index := Node.Right_Child;
                     begin
                        if A0 > 0 and then Tree (A0).Kind = AST_Arg_List then
                           A0 := Tree (A0).Left_Child;
                        end if;
                        if A0 > 0 then
                           return Infer_Expr_Kind (A0);
                        end if;
                     end;
                  elsif Raw = "CHOOSE" and then Node.Right_Child > 0 then
                     declare
                        Arg1 : constant Node_Index := Tree (Node.Right_Child).Left_Child;
                        Arg2 : constant Node_Index := (if Arg1 > 0 then Tree (Arg1).Next_Sibling else 0);
                     begin
                        if Arg2 > 0 then
                           return Infer_Expr_Kind (Arg2);
                        end if;
                     end;
                  else
                     declare
                        Routine_Id : constant Natural :=
                          Find_Routine_For_Call
                            ((if Call_Node.Kind = AST_Member_Expr
                              then Collect_Module_Member_Name (Node.Left_Child)
                              elsif Raw_Case'Length > 0
                              then Resolve_Routine_Name (Raw_Case)
                              else ""));
                     begin
                        if Routine_Id /= 0
                          and then Routines (Routine_Id).Return_Kind /= VK_Unknown
                        then
                           return Routines (Routine_Id).Return_Kind;
                        end if;
                     end;
                     --  `sa(i)`/`fa(i)` call-spelling array reads take the
                     --  element kind so `fa(2)` prints as F64.
                     if Raw_Case'Length > 0 then
                        declare
                           ASym : constant Symbol_Record :=
                             Resolve_Symbol_Shaped
                               (Raw_Case, Want_Array => True);
                        begin
                           if ASym.Active
                             and then ASym.Kind in Sym_Strict_Array |
                               Sym_Slide_Array | Sym_Parallel_Field
                           then
                              return ASym.Tag;
                           end if;
                        end;
                     end if;
                  end if;
               end;
            end if;
            return VK_Unknown;
         when others =>
            return VK_Unknown;
      end case;
   end Infer_Expr_Kind;

   function Is_Real_Number_Text (Text : String) return Boolean is
   begin
      for Ch of Text loop
         if Ch = '.' or else Ch = 'e' or else Ch = 'E' then
            return True;
         end if;
      end loop;
      return False;
   end Is_Real_Number_Text;

   function Uses_Real_Power (Index : Node_Index) return Boolean is
      Node : AST_Node;
      Kind : Value_Kind;
   begin
      if Index = 0 then
         return False;
      end if;

      Kind := Infer_Expr_Kind (Index);
      if Kind in VK_F64 | VK_F32 then
         return True;
      end if;

      Node := Tree (Index);
      case Node.Kind is
         when AST_Number_Expr =>
            if Node.Token_Index > 0 then
               return Is_Real_Number_Text (Raw_Lexeme (Node.Token_Index));
            end if;
         when AST_Unary_Minus =>
            return Uses_Real_Power (Node.Left_Child);
         when AST_Cast_Expr | AST_Constructor =>
            if Node.Token_Index > 0 then
               declare
                  Raw : constant String := Upper_Text (Raw_Lexeme (Node.Token_Index));
               begin
                  return Raw = "F64" or else Raw = "REAL" or else Raw = "F32" or else Raw = "SINGLE" or else Raw = "FLOAT";
               end;
            end if;
         when others =>
            null;
      end case;

      return False;
   end Uses_Real_Power;

   --  Explicit 64-bit element types get BigInt-backed storage — f64
   --  elements silently lose low bits past 2^53 (bit-packed sieves,
   --  u64 masks), which corrupts every subsequent AND/OR probe.
   function Is_Bigint_Type_Name (Name : String) return Boolean is
      T : constant String := Upper_Text (Ada.Strings.Fixed.Trim (Name, Ada.Strings.Both));
   begin
      return T = "S64" or else T = "I64" or else T = "INT64"
        or else T = "U64" or else T = "U128" or else T = "S128" or else T = "I128";
   end Is_Bigint_Type_Name;

   function Is_Unsigned_Bigint_Type_Name (Name : String) return Boolean is
      T : constant String := Upper_Text (Ada.Strings.Fixed.Trim (Name, Ada.Strings.Both));
   begin
      return T = "U64" or else T = "U128";
   end Is_Unsigned_Bigint_Type_Name;

   function Typed_Array_Name (Kind : Value_Kind) return String is
   begin
      case Kind is
         when VK_U8 | VK_Boolean =>
            return "Uint8Array";
         when VK_S8 | VK_HW8 =>
            return "Int8Array";
         when VK_U16 =>
            return "Uint16Array";
         when VK_S16 | VK_HW16 =>
            return "Int16Array";
         when VK_U32 =>
            return "Uint32Array";
         when VK_U64 | VK_Number | VK_U128 =>
            --  JS has no 64-bit typed array; Float64Array keeps S64/U64
            --  values exact up to 2^53 (Int32Array silently wraps at 2^32 —
            --  e.g. a STRICT S64 holding an MD5 word reads back negative).
            return "Float64Array";
         when VK_F64 | VK_Pure =>
            return "Float64Array";
         when others =>
            return "Int32Array";
      end case;
   end Typed_Array_Name;

   procedure Register_Type_Alias
     (Name       : String;
      Base_Name  : String;
      Is_Routine : Boolean;
      Decl_Node  : Node_Index := 0) is
      N : constant String := Ada.Strings.Fixed.Trim (Name, Ada.Strings.Both);
   begin
      if N'Length = 0 then
         return;
      end if;
      for I in 1 .. Type_Alias_Count loop
         if Type_Aliases (I).Active
           and then To_String (Type_Aliases (I).Name) = N
         then
            return;
         end if;
      end loop;
      if Type_Alias_Count < Max_Type_Aliases then
         Type_Alias_Count := Type_Alias_Count + 1;
         Type_Aliases (Type_Alias_Count).Active := True;
         Type_Aliases (Type_Alias_Count).Name := To_Unbounded_String (N);
         Type_Aliases (Type_Alias_Count).Base_Name :=
           To_Unbounded_String (Ada.Strings.Fixed.Trim (Base_Name, Ada.Strings.Both));
         Type_Aliases (Type_Alias_Count).Is_Routine := Is_Routine;
         Type_Aliases (Type_Alias_Count).Decl_Node := Decl_Node;
      end if;
   end Register_Type_Alias;

   function Find_Type_Alias (Name : String) return Natural is
      N : constant String :=
        Upper_Text (Ada.Strings.Fixed.Trim (Name, Ada.Strings.Both));
   begin
      for I in 1 .. Type_Alias_Count loop
         if Type_Aliases (I).Active
           and then Upper_Text (To_String (Type_Aliases (I).Name)) = N
         then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Type_Alias;

   function Find_Struct (Name : String) return Natural is
   begin
      for I in 1 .. Struct_Count loop
         if Structs (I).Active and then To_String (Structs (I).Name) = Name then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Struct;

   function Find_Field
     (Struct_Name : String;
      Field_Name  : String) return Natural is
   begin
      for I in 1 .. Field_Count loop
         if Fields (I).Active
           and then To_String (Fields (I).Struct_Name) = Struct_Name
           and then To_String (Fields (I).Field_Name) = Field_Name
         then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Field;

   function Field_Read_Expr
     (Base_Expr : String;
      Field_Id  : Natural) return String is
      Mask : Integer := 0;
   begin
      if Field_Id = 0 or else Field_Id > Field_Count then
         return Base_Expr & ".alb_missing_field";
      end if;

      if Fields (Field_Id).Bit_Width > 0 then
         Mask := 2 ** Integer'Min (30, Fields (Field_Id).Bit_Width) - 1;
         return "((" & Base_Expr & "." & To_String (Fields (Field_Id).JS_Field) &
           " >>> " & Trim_Image (Fields (Field_Id).Bit_Shift) & ") & " &
           Trim_Image (Mask) & ")";
      else
         return Base_Expr & "." & To_String (Fields (Field_Id).JS_Field);
      end if;
   end Field_Read_Expr;

   function Field_Write_Expr
     (Base_Expr   : String;
      Field_Id    : Natural;
      Value_Expr  : String) return String is
      Mask : Integer := 0;
   begin
      if Field_Id = 0 or else Field_Id > Field_Count then
         return Base_Expr & ".alb_missing_field = " & Value_Expr;
      end if;

      if Fields (Field_Id).Bit_Width > 0 then
         Mask := 2 ** Integer'Min (30, Fields (Field_Id).Bit_Width) - 1;
         return Base_Expr & "." & To_String (Fields (Field_Id).JS_Field) &
           " = ((" & Base_Expr & "." & To_String (Fields (Field_Id).JS_Field) &
           " & ~(" & Trim_Image (Mask) & " << " & Trim_Image (Fields (Field_Id).Bit_Shift) &
           ")) | ((Number(" & Value_Expr & ") & " & Trim_Image (Mask) & ") << " &
           Trim_Image (Fields (Field_Id).Bit_Shift) & "))";
      else
         return Base_Expr & "." & To_String (Fields (Field_Id).JS_Field) &
           " = " & Value_Expr;
      end if;
   end Field_Write_Expr;

   --  ALB identifiers are case-insensitive (MixedCase / mixedcase /
   --  MIXEDCASE are the same variable). Name comparisons fold to upper.
   function Find_Symbol
     (Scope : String;
      Name  : String) return Natural is
      Folded : constant String := Upper_Text (Name);
   begin
      for I in reverse 1 .. Symbol_Count loop
         if Symbols (I).Active
           and then To_String (Symbols (I).Scope) = Scope
           and then Upper_Text (To_String (Symbols (I).Name)) = Folded
         then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Symbol;

   function Find_Routine (JS_Name : String) return Natural is
      Folded : constant String := Upper_Text (JS_Name);
   begin
      for I in 1 .. Routine_Count loop
         if Routines (I).Active
           and then Upper_Text (To_String (Routines (I).JS_Name)) = Folded then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Routine;

   procedure Register_Symbol
     (Scope        : String;
      Name         : String;
      JS_Name      : String;
      Tag          : Value_Kind;
      Kind         : Symbol_Kind;
      Rank         : Natural := 0;
      Dims         : Dim_List := (others => 0);
      Capacity     : Integer := 0;
      Active_Size  : Integer := 0;
      History_Size : Integer := 0;
      Struct_Name  : String := "";
      Offset_Bytes : Integer := 0;
      Is_Bigint    : Boolean := False;
      Routine_Alias : String := "") is
      Existing : constant Natural :=
        Find_Symbol_Shaped (Scope, Name, Is_Array_Kind (Kind),
                            Strict => True);
   begin
      --  Dedup only within the same shape: `STRICT R[16]` must not block
      --  a later `LET r` — ALB distinguishes array vs scalar by use form.
      if Existing /= 0 then
         return;
      end if;

      if Symbol_Count < Max_Symbols then
         Symbol_Count := Symbol_Count + 1;
         Symbols (Symbol_Count).Active := True;
         Symbols (Symbol_Count).Scope := U (Scope);
         Symbols (Symbol_Count).Name := U (Name);
         Symbols (Symbol_Count).JS_Name := U (JS_Name);
         Symbols (Symbol_Count).Tag := Tag;
         Symbols (Symbol_Count).Kind := Kind;
         Symbols (Symbol_Count).Rank := Rank;
         Symbols (Symbol_Count).Dims := Dims;
         Symbols (Symbol_Count).Capacity := Capacity;
         Symbols (Symbol_Count).Active_Size := Active_Size;
         Symbols (Symbol_Count).History_Size := History_Size;
         Symbols (Symbol_Count).Struct_Name := U (Struct_Name);
         Symbols (Symbol_Count).Offset_Bytes := Offset_Bytes;
         Symbols (Symbol_Count).Aux_Offset := 0;
         Symbols (Symbol_Count).Is_Bigint := Is_Bigint;
         Symbols (Symbol_Count).Routine_Alias := U (Routine_Alias);
      end if;
   end Register_Symbol;

   procedure Register_Routine
     (Name        : String;
      JS_Name     : String;
      Param_Count : Natural;
      Param_Modes : Param_Mode_List;
      Return_Kind : Value_Kind := VK_Unknown) is
      Existing : constant Natural := Find_Routine (JS_Name);
   begin
      if Existing /= 0 then
         Routines (Existing).Param_Count := Param_Count;
         Routines (Existing).Param_Modes := Param_Modes;
         if Return_Kind /= VK_Unknown then
            Routines (Existing).Return_Kind := Return_Kind;
         end if;
         return;
      end if;

      if Routine_Count < Max_Routines then
         Routine_Count := Routine_Count + 1;
         Routines (Routine_Count).Active := True;
         Routines (Routine_Count).Name := U (Name);
         Routines (Routine_Count).JS_Name := U (JS_Name);
         Routines (Routine_Count).Param_Count := Param_Count;
         Routines (Routine_Count).Param_Modes := Param_Modes;
         Routines (Routine_Count).Return_Kind := Return_Kind;
      end if;
   end Register_Routine;

   procedure Emit_Current_Out_Writebacks is
   begin
      for I in 1 .. Current_Routine_Out_Count loop
         Line
           ("__out_" & To_String (Current_Routine_Out_Names (I)) &
              ".value = " & To_String (Current_Routine_Out_Names (I)) & ";");
      end loop;
   end Emit_Current_Out_Writebacks;

   function Push_Shadow_Symbol
     (Scope   : String;
      Name    : String;
      JS_Name : String;
      Tag     : Value_Kind;
      Kind    : Symbol_Kind := Sym_Scalar) return Natural
   is
   begin
      if Symbol_Count >= Max_Symbols then
         return 0;
      end if;

      Symbol_Count := Symbol_Count + 1;
      Symbols (Symbol_Count).Active := True;
      Symbols (Symbol_Count).Name := U (Name);
      Symbols (Symbol_Count).Scope := U (Scope);
      Symbols (Symbol_Count).JS_Name := U (JS_Name);
      Symbols (Symbol_Count).Struct_Name := U ("");
      Symbols (Symbol_Count).Tag := Tag;
      Symbols (Symbol_Count).Kind := Kind;
      Symbols (Symbol_Count).Rank := 0;
      Symbols (Symbol_Count).Dims := (others => 0);
      Symbols (Symbol_Count).Capacity := 0;
      Symbols (Symbol_Count).Active_Size := 0;
      Symbols (Symbol_Count).History_Size := 0;
      Symbols (Symbol_Count).Offset_Bytes := 0;
      Symbols (Symbol_Count).Aux_Offset := 0;
      return Symbol_Count;
   end Push_Shadow_Symbol;

   procedure Pop_Shadow_Symbol (Id : Natural) is
   begin
      if Id in 1 .. Symbol_Count then
         Symbols (Id).Active := False;
      end if;
   end Pop_Shadow_Symbol;

   function Resolve_Var_Name (Raw : String) return String is
      Idx : Natural := 0;
      Scoped : constant String := Scoped_Name (Raw);
   begin
      Lambda_Bound_Guard (Raw);
      --  Bare-name context: scalars only (an indexed `a[i]` form binds the
      --  array). A scalar/array case-pair (`r`/`R`) must never cross-bind.
      if Length (Current_Routine) > 0 then
         Idx := Find_Symbol_Shaped
           (To_String (Current_Routine), Raw, Want_Array => False,
            Strict => True);
         if Idx /= 0 then
            return To_String (Symbols (Idx).JS_Name);
         end if;
      end if;

      Idx := Find_Symbol_Shaped
        ("", Scoped, Want_Array => False, Strict => True);
      if Idx /= 0 then
         return To_String (Symbols (Idx).JS_Name);
      end if;

      Idx := Find_Symbol_Shaped
        ("", Safe_JS_Name (Raw), Want_Array => False, Strict => True);
      if Idx /= 0 then
         return To_String (Symbols (Idx).JS_Name);
      end if;

      Idx := Find_Symbol_Shaped
        ("", Raw, Want_Array => False, Strict => True);
      if Idx /= 0 then
         return To_String (Symbols (Idx).JS_Name);
      end if;

      Lambda_Orphan_Guard (Raw);
      return Safe_JS_Name (Raw);
   end Resolve_Var_Name;

   function Resolve_Symbol (Raw : String) return Symbol_Record is
      Idx : Natural := 0;
      Dummy : Symbol_Record;
   begin
      Lambda_Bound_Guard (Raw);
      if Length (Current_Routine) > 0 then
         Idx := Find_Symbol (To_String (Current_Routine), Raw);
         if Idx /= 0 then
            return Symbols (Idx);
         end if;
      end if;

      Idx := Find_Symbol ("", Scoped_Name (Raw));
      if Idx /= 0 then
         return Symbols (Idx);
      end if;

      Idx := Find_Symbol ("", Raw);
      if Idx /= 0 then
         return Symbols (Idx);
      end if;

      Lambda_Orphan_Guard (Raw);
      return Dummy;
   end Resolve_Symbol;

   --  ALB lets a scalar and an array share one case-folded name
   --  (`LET r` next to `STRICT R[16]`) — use shape disambiguates:
   --  indexed syntax binds the array, bare syntax the scalar.
   function Is_Array_Kind (K : Symbol_Kind) return Boolean is
     (K in Sym_Strict_Array | Sym_Slide_Array | Sym_Parallel_Field);

   function Find_Symbol_Shaped
     (Scope      : String;
      Name       : String;
      Want_Array : Boolean;
      Strict     : Boolean := False) return Natural is
      Folded : constant String := Upper_Text (Name);
   begin
      for I in reverse 1 .. Symbol_Count loop
         if Symbols (I).Active
           and then To_String (Symbols (I).Scope) = Scope
           and then Upper_Text (To_String (Symbols (I).Name)) = Folded
           and then Is_Array_Kind (Symbols (I).Kind) = Want_Array
         then
            return I;
         end if;
      end loop;
      if not Strict then
         for I in reverse 1 .. Symbol_Count loop
            if Symbols (I).Active
              and then To_String (Symbols (I).Scope) = Scope
              and then Upper_Text (To_String (Symbols (I).Name)) = Folded
            then
               return I;
            end if;
         end loop;
      end if;
      return 0;
   end Find_Symbol_Shaped;

   function Resolve_Symbol_Shaped
     (Raw        : String;
      Want_Array : Boolean;
      Strict     : Boolean := False) return Symbol_Record is
      Idx : Natural := 0;
      Dummy : Symbol_Record;
   begin
      Lambda_Bound_Guard (Raw);
      if Length (Current_Routine) > 0 then
         Idx := Find_Symbol_Shaped
           (To_String (Current_Routine), Raw, Want_Array, Strict);
         if Idx /= 0 then
            return Symbols (Idx);
         end if;
      end if;

      Idx := Find_Symbol_Shaped ("", Scoped_Name (Raw), Want_Array, Strict);
      if Idx /= 0 then
         return Symbols (Idx);
      end if;

      Idx := Find_Symbol_Shaped ("", Raw, Want_Array, Strict);
      if Idx /= 0 then
         return Symbols (Idx);
      end if;

      Lambda_Orphan_Guard (Raw);
      return Dummy;
   end Resolve_Symbol_Shaped;

   function Target_Symbol (Target_Node : Node_Index) return Symbol_Record is
      Node  : constant AST_Node := Tree (Target_Node);
      Dummy : Symbol_Record;
   begin
      if Target_Node = 0 then
         return Dummy;
      elsif Node.Kind = AST_Var_Expr then
         return Resolve_Symbol_Shaped
           ((if Node.Token_Index > 0 then Raw_Lexeme (Node.Token_Index) else ""),
            Want_Array => Node.Left_Child > 0,
            Strict     => Node.Left_Child = 0);
      elsif Node.Kind = AST_Temporal_Ref then
         if Node.Left_Child > 0 then
            return Target_Symbol (Node.Left_Child);
         end if;
         return Dummy;
      elsif Node.Kind = AST_Member_Expr then
         declare
            Left_Node  : constant AST_Node := Tree (Node.Left_Child);
            Right_Node : constant AST_Node := Tree (Node.Right_Child);
            Left_Name  : constant String := (if Left_Node.Token_Index > 0 then Raw_Lexeme (Left_Node.Token_Index) else "");
            Right_Name : constant String := (if Right_Node.Token_Index > 0 then Raw_Lexeme (Right_Node.Token_Index) else "");
            Group_Sym  : constant Symbol_Record := Resolve_Symbol (Left_Name & "." & Right_Name);
         begin
            if Left_Node.Kind = AST_Var_Expr and then Left_Node.Left_Child > 0 then
               declare
                  Scoped_Field : constant String := Scoped_Name (Left_Name) & "." & Right_Name;
                  Field_Sym_Id : Natural :=
                    Find_Symbol_Shaped ("", Scoped_Field, Want_Array => True);
               begin
                  if Field_Sym_Id = 0 then
                     Field_Sym_Id := Find_Symbol_Shaped
                       ("", Left_Name & "." & Right_Name, Want_Array => True);
                  end if;

                  if Field_Sym_Id /= 0 then
                     return Symbols (Field_Sym_Id);
                  end if;
               end;
            end if;

            if Group_Sym.Active then
               return Group_Sym;
            end if;

            return Resolve_Symbol (Collect_Module_Member_Name (Target_Node));
         end;
      end if;

      return Dummy;
   end Target_Symbol;

   function Resolve_Routine_Name (Raw : String) return String is
      Scoped_JS : constant String := Scoped_Name (Raw);
      Plain_JS  : constant String := Safe_JS_Name (Raw);
   begin
      if Find_Routine (Scoped_JS) /= 0 then
         return Scoped_JS;
      elsif Find_Routine (Plain_JS) /= 0 then
         return Plain_JS;
      else
         return "";
      end if;
   end Resolve_Routine_Name;

   function Join_Arg_List (Arg_List : Node_Index) return String is
      Args  : Unbounded_String := U ("");
      Curr  : Node_Index := 0;
      First : Boolean := True;
   begin
      if Arg_List > 0 then
         if Tree (Arg_List).Kind = AST_Null then
            return "";
         elsif Tree (Arg_List).Kind = AST_Arg_List then
            Curr := Tree (Arg_List).Left_Child;
         else
            Curr := Arg_List;
         end if;

         while Curr > 0 loop
            if not First then
               Append (Args, ", ");
            end if;
            --  BigInt-array element reads arrive as JS bigint; callee
            --  params are declared `number`, so coerce those reads.
            Append (Args, Num_Op (Curr, Expr (Curr)));
            First := False;
            Curr := Tree (Curr).Next_Sibling;
         end loop;
      end if;

      return To_String (Args);
   end Join_Arg_List;

   function Routine_Has_Out (Routine_Id : Natural) return Boolean is
   begin
      if Routine_Id = 0 then
         return False;
      end if;
      for I in 1 .. Routines (Routine_Id).Param_Count loop
         if Routines (Routine_Id).Param_Modes (I) = Param_Out then
            return True;
         end if;
      end loop;
      return False;
   end Routine_Has_Out;

   function Peel_To_Func_Call (Node : Node_Index) return Node_Index is
      Curr : Node_Index := Node;
   begin
      while Curr > 0 loop
         case Tree (Curr).Kind is
            when AST_Cast_Expr | AST_Constructor =>
               Curr := Tree (Curr).Left_Child;

            when AST_BinOp =>
               if Tree (Curr).Token_Index > 0
                 and then Tokens (Tree (Curr).Token_Index).Kind = Tok_Assign
               then
                  Curr := Tree (Curr).Right_Child;
               else
                  exit;
               end if;

            when AST_Func_Call =>
               return Curr;

            when others =>
               exit;
         end case;
      end loop;
      return 0;
   end Peel_To_Func_Call;

   function Find_Func_Call_In_Expr (Node : Node_Index) return Node_Index is
      Peeled : constant Node_Index := Peel_To_Func_Call (Node);
   begin
      if Peeled /= 0 then
         return Peeled;
      end if;

      if Node = 0 then
         return 0;
      elsif Tree (Node).Kind = AST_BinOp then
         declare
            Right_Call : constant Node_Index :=
              Find_Func_Call_In_Expr (Tree (Node).Right_Child);
         begin
            if Right_Call /= 0 then
               return Right_Call;
            end if;
            return Find_Func_Call_In_Expr (Tree (Node).Left_Child);
         end;
      else
         return 0;
      end if;
   end Find_Func_Call_In_Expr;

   function Func_Call_Target_Name (Call_Node : Node_Index) return String is
      Target_Node : constant Node_Index := Tree (Call_Node).Left_Child;
   begin
      if Target_Node = 0 then
         return "";
      elsif Tree (Target_Node).Kind = AST_Member_Expr then
         return Collect_Module_Member_Name (Target_Node);
      elsif Tree (Target_Node).Token_Index > 0 then
         declare
            Resolved : constant String :=
              Resolve_Routine_Name (Raw_Lexeme (Tree (Target_Node).Token_Index));
         begin
            if Resolved'Length > 0 then
               return Resolved;
            else
               return Safe_JS_Name (Raw_Lexeme (Tree (Target_Node).Token_Index));
            end if;
         end;
      else
         return "";
      end if;
   end Func_Call_Target_Name;

   function Find_Routine_For_Call (Target_Name : String) return Natural is
      Id : Natural := Find_Routine (Target_Name);
   begin
      if Id /= 0 then
         return Id;
      end if;

      for I in 1 .. Routine_Count loop
         if Routines (I).Active
           and then To_String (Routines (I).JS_Name) = Target_Name
         then
            return I;
         end if;
      end loop;

      for I in 1 .. Routine_Count loop
         if Routines (I).Active
           and then Ada.Strings.Fixed.Index (Target_Name, To_String (Routines (I).JS_Name)) > 0
         then
            return I;
         end if;
      end loop;

      if Ada.Strings.Fixed.Index (Target_Name, "VecU32At") > 0 then
         Id := Find_Routine ("ALBVector_VecU32At");
         if Id /= 0 then
            return Id;
         end if;
      end if;

      return 0;
   end Find_Routine_For_Call;

   --  BigInt-backed array elements (`STRICT a[N] AS S64` -> BigInt64Array)
   --  read as JS bigint. That's required so `AND`/`OR`/`MOD`/compare paths
   --  stay exact, but `a[i] + 1`/`Math.imul(a[i],k)` throw on mixed
   --  bigint/number operands — coerce those reads through albNum.
   function Num_Op (N : Node_Index; Text : String) return String is
   begin
      if N > 0
        and then Tree (N).Kind = AST_Var_Expr
        and then Tree (N).Left_Child > 0
        and then Tree (N).Token_Index > 0
      then
         declare
            S : constant Symbol_Record :=
              Resolve_Symbol_Shaped
                (Raw_Lexeme (Tree (N).Token_Index), Want_Array => True);
         begin
            if S.Active and then S.Is_Bigint then
               return "albNum(" & Text & ")";
            end if;
         end;
      end if;
      return Text;
   end Num_Op;

   function Emit_Value_Expr_With_Out (Value_Node : Node_Index) return String is
      Call_Node   : Node_Index := 0;
      Target_Name : String := "";
      Routine_Id  : Natural := 0;
   begin
      Call_Node := Find_Func_Call_In_Expr (Value_Node);
      if Call_Node = 0 then
         return Expr (Value_Node);
      end if;

      Target_Name := Func_Call_Target_Name (Call_Node);
      if Target_Name'Length = 0 then
         return Expr (Value_Node);
      end if;

      Routine_Id := Find_Routine_For_Call (Target_Name);
      if Routine_Has_Out (Routine_Id)
        or else Ada.Strings.Fixed.Index (Target_Name, "VecU32At") > 0
      then
         return Emit_Call_Expr_With_Out
           (Target_Name, Tree (Call_Node).Right_Child);
      end if;

      return Expr (Value_Node);
   exception
      when others =>
         return Expr (Value_Node);
   end Emit_Value_Expr_With_Out;

   function Out_Arg_Name (Arg_Node : Node_Index) return String is
   begin
      if Arg_Node > 0
        and then Tree (Arg_Node).Kind = AST_Var_Expr
        and then Tree (Arg_Node).Left_Child = 0
        and then Tree (Arg_Node).Token_Index > 0
      then
         return Resolve_Var_Name (Raw_Lexeme (Tree (Arg_Node).Token_Index));
      else
         return Statement_Target_Name (Arg_Node);
      end if;
   end Out_Arg_Name;

   function Join_Arg_List_For_Call
     (Arg_List   : Node_Index;
      Routine_Id : Natural) return String is
      Args     : Unbounded_String := U ("");
      Curr     : Node_Index := 0;
      First    : Boolean := True;
      Param_No : Natural := 0;
   begin
      if Arg_List > 0 then
         if Tree (Arg_List).Kind = AST_Null then
            return "";
         elsif Tree (Arg_List).Kind = AST_Arg_List then
            Curr := Tree (Arg_List).Left_Child;
         else
            Curr := Arg_List;
         end if;

         while Curr > 0 loop
            Param_No := Param_No + 1;
            if not First then
               Append (Args, ", ");
            end if;
            if Routine_Id > 0
              and then Param_No <= Routines (Routine_Id).Param_Count
              and then Routines (Routine_Id).Param_Modes (Param_No) = Param_Out
            then
               Args := Args & ("{ value: " & Out_Arg_Name (Curr) & " }");
            else
               Args := Args & Num_Op (Curr, Expr (Curr));
            end if;
            First := False;
            Curr := Tree (Curr).Next_Sibling;
         end loop;
      end if;

      return To_String (Args);
   end Join_Arg_List_For_Call;

   function Emit_Call_Expr_With_Out
     (Target_Name : String;
      Arg_List    : Node_Index) return String is
      Routine_Id : constant Natural := Find_Routine_For_Call (Target_Name);
      Curr       : Node_Index := 0;
      Param_No   : Natural := 0;
      Decls      : Unbounded_String := U ("");
      Writes     : Unbounded_String := U ("");
      Call_Args  : Unbounded_String := U ("");
      First      : Boolean := True;
   begin
      if Routine_Id = 0 then
         return Target_Name & "(" & Join_Arg_List (Arg_List) & ")";
      end if;

      if Arg_List > 0 and then Tree (Arg_List).Kind = AST_Arg_List then
         Curr := Tree (Arg_List).Left_Child;
      else
         Curr := Arg_List;
      end if;

      while Curr > 0 and then Param_No < Max_Params loop
         Param_No := Param_No + 1;
         if Routines (Routine_Id).Param_Modes (Param_No) = Param_Out then
            if Length (Decls) > 0 then
               Decls := Decls & " ";
            end if;
            Decls :=
              Decls &
              ("const __out_" & Trim_Image (Integer (Param_No)) &
                 " = { value: " & Out_Arg_Name (Curr) & " };");
            if Length (Writes) > 0 then
               Writes := Writes & " ";
            end if;
            Writes :=
              Writes &
              (Out_Arg_Name (Curr) &
                 " = __out_" & Trim_Image (Integer (Param_No)) & ".value;");
            if not First then
               Call_Args := Call_Args & ", ";
            end if;
            Call_Args := Call_Args & ("__out_" & Trim_Image (Integer (Param_No)));
         else
            if not First then
               Call_Args := Call_Args & ", ";
            end if;
            Call_Args := Call_Args & Num_Op (Curr, Expr (Curr));
         end if;
         First := False;
         Curr := Tree (Curr).Next_Sibling;
      end loop;

      return
        "(() => { " & To_String (Decls) &
        " const __ret = " & Target_Name & "(" & To_String (Call_Args) & "); " &
        To_String (Writes) & " return __ret; })()";
   exception
      when others =>
         return Target_Name & "(" & Join_Arg_List (Arg_List) & ")";
   end Emit_Call_Expr_With_Out;

   function Predicate_Key_Expr (Pred_Node : Node_Index) return String is
      Node : constant AST_Node := Tree (Pred_Node);
   begin
      if Pred_Node = 0 then
         return Escape_TS_String ("");
      end if;

      case Node.Kind is
         when AST_Assert_Stmt | AST_Retract_Stmt =>
            return "ALB_PRED(" &
              Escape_TS_String (Raw_Lexeme (Node.Token_Index)) &
              (if Node.Left_Child > 0 then ", " & Expr (Node.Left_Child) else "") &
              ")";
         when AST_Predicate =>
            return "ALB_PRED(" &
              Escape_TS_String (Raw_Lexeme (Node.Token_Index)) &
              (if Node.Left_Child > 0 then ", " & Join_Arg_List (Node.Left_Child) else "") &
              ")";
         when AST_Func_Call =>
            if Node.Left_Child > 0 and then Tree (Node.Left_Child).Token_Index > 0 then
               return "ALB_PRED(" &
                 Escape_TS_String (Raw_Lexeme (Tree (Node.Left_Child).Token_Index)) &
                 (if Node.Right_Child > 0 then ", " & Join_Arg_List (Node.Right_Child) else "") &
                 ")";
            end if;
            return Expr (Pred_Node);
         when AST_Var_Expr | AST_Atom | AST_Logic_Var =>
            return Escape_TS_String (Raw_Lexeme (Node.Token_Index));
         when others =>
            return Expr (Pred_Node);
      end case;
   end Predicate_Key_Expr;

   function Static_Int_Pow
     (Base     : Integer;
      Exponent : Integer) return Integer is
      Result : Integer := 1;
   begin
      if Exponent < 0 then
         return 0;
      end if;

      for I in 1 .. Exponent loop
         Result := Result * Base;
      end loop;

      return Result;
   exception
      when others =>
         return 0;
   end Static_Int_Pow;

   function Eval_Static_Int (Index : Node_Index) return Integer;

   function Eval_Static_Int (Index : Node_Index) return Integer is
      Node : AST_Node;
      Tok_Kind : Token_Kind := Tok_Error;
      Left_Val : Integer := 0;
      Right_Val : Integer := 0;
      Text : Unbounded_String := U ("");
   begin
      if Index = 0 then
         return 0;
      end if;

      Node := Tree (Index);
      if Node.Token_Index > 0 then
         Tok_Kind := Tokens (Node.Token_Index).Kind;
         Text := U (Raw_Lexeme (Node.Token_Index));
      end if;

      case Node.Kind is
         when AST_Number_Expr =>
            return Integer'Value (Ada.Strings.Fixed.Trim (To_String (Text), Ada.Strings.Both));
         when AST_Hex_Expr =>
            declare
               T : constant String := To_String (Text);
            begin
               return Integer'Value ("16#" & T (T'First + 1 .. T'Last) & "#");
            end;
         when AST_Bin_Expr =>
            declare
               T : constant String := To_String (Text);
            begin
               return Integer'Value ("2#" & T (T'First + 1 .. T'Last) & "#");
            end;
         when AST_Octal_Expr =>
            declare
               T : constant String := To_String (Text);
            begin
               return Integer'Value ("8#" & T (T'First + 1 .. T'Last) & "#");
            end;
         when AST_Const_Ref =>
            declare
               T    : constant String := To_String (Text);
               Name : constant String := Safe_JS_Name (T (T'First + 1 .. T'Last));
               Idx  : constant Natural :=
                 Find_Symbol_Shaped ("", Name, Want_Array => True);
            begin
               if Idx /= 0 then
                  if Symbols (Idx).Kind in Sym_Strict_Array | Sym_Slide_Array |
                     Sym_Parallel_Field
                  then
                     declare
                        Declared : Integer := 1;
                     begin
                        for I in Symbols (Idx).Dims'Range loop
                           if Symbols (Idx).Dims (I) > 0 then
                              Declared := Declared * Symbols (Idx).Dims (I);
                           end if;
                        end loop;
                        return Declared;
                     end;
                  else
                     return Symbols (Idx).Capacity;
                  end if;
               end if;
            end;
            return 0;
         when AST_Unary_Minus =>
            return -Eval_Static_Int (Node.Left_Child);
         when AST_BinOp =>
            Left_Val := Eval_Static_Int (Node.Left_Child);
            Right_Val := Eval_Static_Int (Node.Right_Child);
            case Tok_Kind is
               when Tok_Plus =>
                  return Left_Val + Right_Val;
               when Tok_Minus =>
                  return Left_Val - Right_Val;
               when Tok_Mul =>
                  return Left_Val * Right_Val;
               when Tok_Div =>
                  if Right_Val = 0 then
                     return 0;
                  end if;
                  return Left_Val / Right_Val;
               when Tok_Mod =>
                  if Right_Val = 0 then
                     return 0;
                  end if;
                  return Left_Val mod Right_Val;
               when Tok_Shl =>
                  return Left_Val * (2 ** Right_Val);
               when Tok_Shr =>
                  return Left_Val / (2 ** Right_Val);
               when Tok_Pow =>
                  return Static_Int_Pow (Left_Val, Right_Val);
               when others =>
                  return 0;
            end case;
         when others =>
            return 0;
      end case;
   exception
      when others =>
         return 0;
   end Eval_Static_Int;

   function Escape_TS_String (Text : String) return String is
      R : Unbounded_String := U ("""");
      C : Character;
   begin
      for I in Text'Range loop
         C := Text (I);
         case C is
            when '"' =>
               Append (R, "\" & """");
            when '\' =>
               Append (R, "\\");
            when ASCII.LF =>
               Append (R, "\n");
            when ASCII.CR =>
               null;
            when ASCII.HT =>
               Append (R, "\t");
            when others =>
               Append (R, C);
         end case;
      end loop;
      Append (R, """");
      return To_String (R);
   end Escape_TS_String;

   function Strip_String_Node (Idx : Node_Index) return String is
      Tok : Token;
   begin
      if Idx = 0 or else Tree (Idx).Token_Index = 0 then
         return "";
      end if;

      Tok := Tokens (Tree (Idx).Token_Index);
      if Tok.Length >= 2 then
         return Input_Buffer (Tok.Start + 1 .. Tok.Start + Tok.Length - 2);
      else
         return "";
      end if;
   end Strip_String_Node;

   function Foreign_Link_From_Kind (Kind : Node_Kind) return Foreign_Link_Kind is
   begin
      case Kind is
         when AST_Import_ES | AST_Export_ES =>
            return Foreign_ES;
         when AST_Import_WASM | AST_Export_WASM =>
            return Foreign_WASM;
         when AST_Import_DLL | AST_Import_SO | AST_Import_Dylib | AST_Import_Jar |
              AST_Export_DLL | AST_Export_SO | AST_Export_Dylib | AST_Export_Jar =>
            return Foreign_Compat;
         when others =>
            return Foreign_None;
      end case;
   end Foreign_Link_From_Kind;

   function JSImport_Specifier (Raw_Path : String) return String is
      use type Ada.Directories.File_Kind;
      Trimmed : constant String :=
        Ada.Strings.Fixed.Trim (Raw_Path, Ada.Strings.Both);
      function Normalize_Module_Path (Text : String) return String is
         Result : String (1 .. Text'Length) := Text;
      begin
         for I in Result'Range loop
            if Result (I) = '\' then
               Result (I) := '/';
            end if;
         end loop;
         return Result;
      end Normalize_Module_Path;
   begin
      if Trimmed'Length = 0 then
         return "./missing.js";
      end if;

      if Trimmed'Length >= 5
        and then Trimmed (Trimmed'First .. Trimmed'First + 4) = "data:"
      then
         return Trimmed;
      end if;

      for I in Trimmed'First + 1 .. Trimmed'Last loop
         if Trimmed (I) = ':' then
            return Trimmed;
         elsif Trimmed (I) = '/' or else Trimmed (I) = '\' then
            exit;
         end if;
      end loop;

      if Trimmed (Trimmed'First) = '.' then
         return Normalize_Module_Path (Trimmed);
      end if;

      for I in Trimmed'Range loop
         if Trimmed (I) = '/' or else Trimmed (I) = '\' then
            return "./" & Ada.Directories.Base_Name (Trimmed);
         end if;
      end loop;

      if Trimmed (Trimmed'First) = '.'
        or else Trimmed (Trimmed'First) = '/'
        or else Trimmed (Trimmed'First) = '\'
      then
         return "./" & Ada.Directories.Base_Name (Trimmed);
      end if;

      return Trimmed;
   exception
      when others =>
         return "./" & Safe_JS_Name (Trimmed);
   end JSImport_Specifier;

   function Resolve_Static_Asset_Path (Raw_Path : String) return String is
      Trimmed : constant String :=
        Ada.Strings.Fixed.Trim (Raw_Path, Ada.Strings.Both);
      CWD     : constant String := Ada.Directories.Current_Directory;
      Direct  : constant String :=
        (if Length (Shoebox_Root) > 0
         then Ada.Directories.Compose (To_String (Shoebox_Root), Trimmed)
         else Trimmed);
   begin
      if Trimmed'Length = 0 then
         return "";
      end if;

      if Ada.Directories.Exists (Trimmed) then
         return Trimmed;
      elsif Length (Shoebox_Root) > 0 and then Ada.Directories.Exists (Direct) then
         return Direct;
      else
         declare
            Fallback : constant String := Ada.Directories.Compose (CWD, Trimmed);
         begin
            if Ada.Directories.Exists (Fallback) then
               return Fallback;
            elsif Length (Shoebox_Root) > 0 then
               return Direct;
            else
               return Fallback;
            end if;
         end;
      end if;
   exception
      when others =>
         return Trimmed;
   end Resolve_Static_Asset_Path;

   procedure Register_Foreign_Import (Binding_Node : Node_Index) is
      Decl_Node  : constant Node_Index := Tree (Binding_Node).Left_Child;
      Name_Node  : constant Node_Index := (if Decl_Node > 0 then Tree (Decl_Node).Left_Child else 0);
      Raw_Name   : constant String := (if Name_Node > 0 then Raw_Lexeme (Tree (Name_Node).Token_Index) else "");
      Link_Kind  : constant Foreign_Link_Kind := Foreign_Link_From_Kind (Tree (Binding_Node).Kind);
      JS_Name    : constant String :=
        (if Upper_Text (Raw_Name) = "GETTICKCOUNT"
         then "ALB_User_GetTickCount"
         else Scoped_Name (Raw_Name));
      Path_Text  : constant String :=
        (if Tree (Binding_Node).Right_Child > 0
         then Strip_String_Node (Tree (Binding_Node).Right_Child)
         else "");
   begin
      if Foreign_Import_Count >= Max_Foreign_Bindings or else Raw_Name'Length = 0 then
         return;
      end if;

      Foreign_Import_Count := Foreign_Import_Count + 1;
      Foreign_Imports (Foreign_Import_Count).Active := True;
      Foreign_Imports (Foreign_Import_Count).Node := Binding_Node;
      Foreign_Imports (Foreign_Import_Count).Link_Kind := Link_Kind;
      Foreign_Imports (Foreign_Import_Count).Name := U (Raw_Name);
      Foreign_Imports (Foreign_Import_Count).JS_Name := U (JS_Name);
      Foreign_Imports (Foreign_Import_Count).Path := U (Path_Text);
      Foreign_Imports (Foreign_Import_Count).Is_Function := Tree (Decl_Node).Kind = AST_Function_Decl;
      Foreign_Imports (Foreign_Import_Count).Return_Tag := Type_From_Token (Tree (Decl_Node).Token_Index);

      Register_Routine_Signature (Decl_Node);
      if Link_Kind = Foreign_ES or else Link_Kind = Foreign_WASM then
         Need_Module_Support := True;
      end if;
      if Link_Kind = Foreign_WASM then
         Need_Wasm_Loaders := True;
      elsif Link_Kind = Foreign_Compat then
         Need_Compat_Runtime := True;
      end if;
   end Register_Foreign_Import;

   procedure Register_Foreign_Export (Binding_Node : Node_Index) is
      Decl_Node  : constant Node_Index := Tree (Binding_Node).Left_Child;
      Name_Node  : constant Node_Index := (if Decl_Node > 0 then Tree (Decl_Node).Left_Child else 0);
      Raw_Name   : constant String := (if Name_Node > 0 then Raw_Lexeme (Tree (Name_Node).Token_Index) else "");
      Link_Kind  : constant Foreign_Link_Kind := Foreign_Link_From_Kind (Tree (Binding_Node).Kind);
      JS_Name    : constant String :=
        (if Upper_Text (Raw_Name) = "GETTICKCOUNT"
         then "ALB_User_GetTickCount"
         else Scoped_Name (Raw_Name));
   begin
      if Foreign_Export_Count >= Max_Foreign_Bindings or else Raw_Name'Length = 0 then
         return;
      end if;

      Foreign_Export_Count := Foreign_Export_Count + 1;
      Foreign_Exports (Foreign_Export_Count).Active := True;
      Foreign_Exports (Foreign_Export_Count).Node := Binding_Node;
      Foreign_Exports (Foreign_Export_Count).Link_Kind := Link_Kind;
      Foreign_Exports (Foreign_Export_Count).Name := U (Raw_Name);
      Foreign_Exports (Foreign_Export_Count).JS_Name := U (JS_Name);
      Foreign_Exports (Foreign_Export_Count).Is_Function := Tree (Decl_Node).Kind = AST_Function_Decl;
      Foreign_Exports (Foreign_Export_Count).Return_Tag := Type_From_Token (Tree (Decl_Node).Token_Index);

      if Link_Kind = Foreign_ES or else Link_Kind = Foreign_WASM then
         Need_Module_Support := True;
      elsif Link_Kind = Foreign_Compat then
         Need_Compat_Runtime := True;
      end if;
   end Register_Foreign_Export;

   --  ---- MCP: agent-callable server surface ------------------------
   --  MCP SERVER blocks, MCP TOOL/RESOURCE registrations, and the
   --  `MCP TOOL` routine attribute are gathered during Scan_Features;
   --  Emit_Mcp_Runtime then emits the JSON-RPC stdio runtime plus the
   --  generated tool/resource tables.  stdout becomes the protocol
   --  channel while MCP is live, so albStdout reroutes to stderr.
   Max_Mcp_Entries : constant := 64;
   type Mcp_Entry_Record is record
      Active      : Boolean := False;
      Is_Resource : Boolean := False;
      Wire_Name   : Unbounded_String;  --  tool name or resource URI
      Display     : Unbounded_String;  --  resource display name
      JS_Name     : Unbounded_String;  --  emitted TS routine
      Desc        : Unbounded_String;
      Mime        : Unbounded_String;
      Decl_Node   : Node_Index := 0;
      Is_Function : Boolean := False;
   end record;
   Mcp_Entries      : array (1 .. Max_Mcp_Entries) of Mcp_Entry_Record;
   Mcp_Entry_Count  : Natural := 0;
   Mcp_Server_Name  : Unbounded_String := U ("alb-app");
   Mcp_Server_Ver   : Unbounded_String := U ("1.0.0");
   Need_Mcp_Runtime : Boolean := False;

   --  routine name -> decl map so bare TOOL/RESOURCE names resolve to
   --  their emitted JS names (modules included via Scoped_Name).
   Max_Mcp_Decls : constant := 4096;
   Mcp_Decl_Name  : array (1 .. Max_Mcp_Decls) of Unbounded_String;
   Mcp_Decl_JS    : array (1 .. Max_Mcp_Decls) of Unbounded_String;
   Mcp_Decl_Node  : array (1 .. Max_Mcp_Decls) of Node_Index := (others => 0);
   Mcp_Decl_Func  : array (1 .. Max_Mcp_Decls) of Boolean := (others => False);
   Mcp_Decl_Count : Natural := 0;

   --  MCP registration nodes are pended during Scan_Features and
   --  flushed afterwards so TOOL/RESOURCE bindings resolve regardless
   --  of declaration order in the source.
   Mcp_Pending       : array (1 .. Max_Mcp_Decls) of Node_Index := (others => 0);
   Mcp_Pending_Count : Natural := 0;

   function JSON_Escape (S : String) return String is
      R : Unbounded_String := Null_Unbounded_String;
   begin
      for C of S loop
         case C is
            when '"'      => Append (R, "\""");
            when '\'     => Append (R, "\\");
            when ASCII.LF => Append (R, "\n");
            when ASCII.CR => Append (R, "\r");
            when ASCII.HT => Append (R, "\t");
            when others   =>
               if C >= ' ' then Append (R, C); end if;
         end case;
      end loop;
      return To_String (R);
   end JSON_Escape;

   procedure Register_Mcp_Decl (Name_Node : Node_Index; Decl : Node_Index) is
   begin
      if Decl = 0 then
         return;
      end if;
      if Mcp_Decl_Count >= Max_Mcp_Decls then
         --  loud overflow: every routine registers here, so the cap must
         --  track the largest program's routine count (was 256; a big
         --  app + vendored modules silently dropped all bindings)
         Line ("/* ALBW warning: MCP decl table full (" &
               Max_Mcp_Decls'Image & " routines) - raise Max_Mcp_Decls */");
         return;
      end if;
      if Name_Node = 0 or else Tree (Name_Node).Token_Index = 0 then
         return;
      end if;
      Mcp_Decl_Count := Mcp_Decl_Count + 1;
      Mcp_Decl_Name (Mcp_Decl_Count) :=
        U (Upper_Text (Raw_Lexeme (Tree (Name_Node).Token_Index)));
      Mcp_Decl_JS (Mcp_Decl_Count) :=
        U (Scoped_Name (Raw_Lexeme (Tree (Name_Node).Token_Index)));
      Mcp_Decl_Node (Mcp_Decl_Count) := Decl;
      Mcp_Decl_Func (Mcp_Decl_Count) := Tree (Decl).Kind = AST_Function_Decl;
   end Register_Mcp_Decl;

   function Lookup_Mcp_Decl (Name : String) return Natural is
      U_Name : constant String := Upper_Text (Name);
   begin
      for I in 1 .. Mcp_Decl_Count loop
         if To_String (Mcp_Decl_Name (I)) = U_Name then
            return I;
         end if;
      end loop;
      return 0;
   end Lookup_Mcp_Decl;

   procedure Register_Mcp_Tool (Node : Node_Index) is
   begin
      if Node = 0 or else Mcp_Entry_Count >= Max_Mcp_Entries
        or else Tree (Node).Token_Index = 0
      then
         return;
      end if;
      declare
         Raw : constant String := Raw_Lexeme (Tree (Node).Token_Index);
         Idx : constant Natural := Lookup_Mcp_Decl (Raw);
      begin
         if Idx = 0 then
            Line ("/* ALBW warning: MCP tool '" & Raw &
                  "' bound to undeclared routine - skipped */");
            return;
         end if;
         Need_Mcp_Runtime := True;
         Mcp_Entry_Count := Mcp_Entry_Count + 1;
         Mcp_Entries (Mcp_Entry_Count).Active := True;
         Mcp_Entries (Mcp_Entry_Count).Is_Resource := False;
         Mcp_Entries (Mcp_Entry_Count).Wire_Name :=
           U (if Tree (Node).Left_Child > 0
              then Strip_String_Node (Tree (Node).Left_Child) else Raw);
         Mcp_Entries (Mcp_Entry_Count).Desc :=
           U (if Tree (Node).Right_Child > 0
              then Strip_String_Node (Tree (Node).Right_Child) else "");
         Mcp_Entries (Mcp_Entry_Count).JS_Name := Mcp_Decl_JS (Idx);
         Mcp_Entries (Mcp_Entry_Count).Decl_Node := Mcp_Decl_Node (Idx);
         Mcp_Entries (Mcp_Entry_Count).Is_Function := Mcp_Decl_Func (Idx);
      end;
   end Register_Mcp_Tool;

   procedure Register_Mcp_Resource (Node : Node_Index) is
   begin
      if Node = 0 or else Mcp_Entry_Count >= Max_Mcp_Entries
        or else Tree (Node).Token_Index = 0
      then
         return;
      end if;
      declare
         Raw : constant String := Raw_Lexeme (Tree (Node).Token_Index);
         Idx : constant Natural := Lookup_Mcp_Decl (Raw);
         Uri : constant String :=
           (if Tree (Node).Left_Child > 0
            then Strip_String_Node (Tree (Node).Left_Child) else "");
      begin
         if Idx = 0 then
            Line ("/* ALBW warning: MCP resource '" & Uri &
                  "' bound to undeclared routine - skipped */");
            return;
         end if;
         Need_Mcp_Runtime := True;
         Mcp_Entry_Count := Mcp_Entry_Count + 1;
         Mcp_Entries (Mcp_Entry_Count).Active := True;
         Mcp_Entries (Mcp_Entry_Count).Is_Resource := True;
         Mcp_Entries (Mcp_Entry_Count).Wire_Name := U (Uri);
         Mcp_Entries (Mcp_Entry_Count).Display :=
           U (if Tree (Node).Right_Child > 0
              then Strip_String_Node (Tree (Node).Right_Child) else Uri);
         Mcp_Entries (Mcp_Entry_Count).JS_Name := Mcp_Decl_JS (Idx);
         Mcp_Entries (Mcp_Entry_Count).Decl_Node := Mcp_Decl_Node (Idx);
         Mcp_Entries (Mcp_Entry_Count).Mime := U ("application/json");
      end;
   end Register_Mcp_Resource;

   procedure Register_Mcp_Server (Node : Node_Index) is
      E : Node_Index;
   begin
      if Node = 0 then
         return;
      end if;
      Need_Mcp_Runtime := True;
      if Tree (Node).Left_Child > 0 then
         Mcp_Server_Name := U (Strip_String_Node (Tree (Node).Left_Child));
         if Tree (Tree (Node).Left_Child).Next_Sibling > 0 then
            Mcp_Server_Ver :=
              U (Strip_String_Node
                   (Tree (Tree (Node).Left_Child).Next_Sibling));
         end if;
      end if;
      E := Tree (Node).Right_Child;
      while E > 0 loop
         case Tree (E).Kind is
            when AST_Mcp_Tool     => Register_Mcp_Tool (E);
            when AST_Mcp_Resource => Register_Mcp_Resource (E);
            when others           => null;
         end case;
         E := Tree (E).Next_Sibling;
      end loop;
   end Register_Mcp_Server;

   --  Resolve every pended MCP node once all routine decls are known.
   procedure Flush_Mcp_Registrations is
   begin
      for I in 1 .. Mcp_Pending_Count loop
         case Tree (Mcp_Pending (I)).Kind is
            when AST_Mcp_Server   => Register_Mcp_Server (Mcp_Pending (I));
            when AST_Mcp_Tool     => Register_Mcp_Tool (Mcp_Pending (I));
            when AST_Mcp_Resource => Register_Mcp_Resource (Mcp_Pending (I));
            when others           => null;
         end case;
      end loop;
   end Flush_Mcp_Registrations;

   --  Walk a bound routine's params -> JSON-schema properties, the
   --  required list, and the JS coercion expressions for the call.
   procedure Mcp_Param_Specs
     (Decl  : Node_Index;
      Props : out Unbounded_String;
      Req   : out Unbounded_String;
      Args  : out Unbounded_String)
   is
      List, P, Name_Node, Type_Node : Node_Index := 0;
      Mode_Tok  : Natural := 0;
      Is_Out    : Boolean := False;
      PName, JSN : Unbounded_String;
      Kind      : Value_Kind := VK_Number;
      First     : Boolean := True;
   begin
      Props := Null_Unbounded_String;
      Req   := Null_Unbounded_String;
      Args  := Null_Unbounded_String;
      if Decl = 0 or else Tree (Decl).Left_Child = 0 then
         return;
      end if;
      List := Tree (Tree (Decl).Left_Child).Right_Child;
      if List = 0 or else Tree (List).Kind /= AST_Arg_List then
         return;
      end if;
      P := Tree (List).Left_Child;
      while P > 0 loop
         if Tree (P).Kind = AST_Param_Decl
           and then Tree (P).Left_Child > 0
         then
            Mode_Tok  := Tree (P).Token_Index;
            Is_Out    := Mode_Tok > 0
              and then Tokens (Mode_Tok).Kind = Tok_Out;
            Name_Node := Tree (P).Left_Child;
            PName     := U (Raw_Lexeme (Tree (Name_Node).Token_Index));
            JSN       := U (Safe_JS_Name (To_String (PName)));
            Type_Node := Tree (P).Right_Child;
            Kind      :=
              (if Type_Node > 0 and then Tree (Type_Node).Token_Index > 0
               then Type_From_Name
                      (Raw_Lexeme (Tree (Type_Node).Token_Index))
               else VK_Number);
            if not First then
               Append (Args, ", ");
            end if;
            if Is_Out then
               --  OUT params get the {value: x} box the callee writes
               --  back through; nothing useful returns over JSON-RPC.
               Append (Args, "{ value: 0 }");
            else
               if not First then
                  Append (Props, ",");
                  Append (Req, ",");
               end if;
               case Kind is
                  when VK_String | VK_Binary =>
                     Append (Props, """" & JSON_Escape (To_String (PName)) &
                             """:{""type"":""string""}");
                     Append (Args, "String(a['" & To_String (JSN) &
                             "'] === undefined ? '' : a['" &
                             To_String (JSN) & "'])");
                  when VK_Boolean =>
                     Append (Props, """" & JSON_Escape (To_String (PName)) &
                             """:{""type"":""boolean""}");
                     Append (Args, "Boolean(a['" & To_String (JSN) & "'])");
                  when VK_F64 | VK_Unknown =>
                     Append (Props, """" & JSON_Escape (To_String (PName)) &
                             """:{""type"":""number""}");
                     Append (Args, "Number(a['" & To_String (JSN) & "'])");
                  when others =>
                     Append (Props, """" & JSON_Escape (To_String (PName)) &
                             """:{""type"":""integer""}");
                     Append (Args, "Math.trunc(Number(a['" &
                             To_String (JSN) & "']))");
               end case;
               Append (Req, """" & JSON_Escape (To_String (PName)) & """");
            end if;
            First := False;
         end if;
         P := Tree (P).Next_Sibling;
      end loop;
   end Mcp_Param_Specs;

   procedure Scan_Features (First : Node_Index) is
      Curr : Node_Index := First;
   begin
      while Curr > 0 loop
         case Tree (Curr).Kind is
            when AST_Program | AST_Block_Stmt =>
               Scan_Features (Tree (Curr).Left_Child);

            when AST_Module =>
               declare
                  Name_Node    : constant Node_Index := Tree (Curr).Left_Child;
                  Saved_Module : constant Unbounded_String := Current_Module;
               begin
                  if Name_Node > 0 and then Tree (Name_Node).Token_Index > 0 then
                     Current_Module := U (Safe_JS_Name (Raw_Lexeme (Tree (Name_Node).Token_Index)));
                  end if;
                  Scan_Features (Tree (Curr).Right_Child);
                  Current_Module := Saved_Module;
               end;

            when AST_DeclareModule =>
               declare
                  Name_Node    : constant Node_Index := Tree (Curr).Left_Child;
                  Saved_Module : constant Unbounded_String := Current_Module;
               begin
                  if Name_Node > 0 and then Tree (Name_Node).Token_Index > 0 then
                     Current_Module := U (Safe_JS_Name (Raw_Lexeme (Tree (Name_Node).Token_Index)));
                  end if;
                  Scan_Features (Tree (Curr).Right_Child);
                  Current_Module := Saved_Module;
               end;

            when AST_Procedure_Decl | AST_Function_Decl =>
               Register_Routine_Signature (Curr);
               Register_Mcp_Decl (Tree (Curr).Left_Child, Curr);
               --  `MCP TOOL` attribute: registration nodes ride at the
               --  tail of the arg-list child chain.
               declare
                  L : constant Node_Index :=
                    Tree (Tree (Curr).Left_Child).Right_Child;
                  P : Node_Index := 0;
               begin
                  if L > 0 and then Tree (L).Kind = AST_Arg_List then
                     P := Tree (L).Left_Child;
                     while P > 0 loop
                        if Tree (P).Kind = AST_Mcp_Tool then
                           Register_Mcp_Tool (P);
                        end if;
                        P := Tree (P).Next_Sibling;
                     end loop;
                  end if;
               end;
               Scan_Features (Tree (Curr).Right_Child);

            when AST_Import_DLL | AST_Import_SO | AST_Import_Dylib | AST_Import_Jar =>
               --  DLL/SO imports are native-facing declarations. Registration
               --  records both the routine signature (call sites type-check)
               --  and the import itself so a compat wrapper routing through
               --  ALB_COMPAT_IMPORT is emitted — Node can then service the
               --  deterministic subset (process info, file ops) the suite
               --  exercises.
               Register_Foreign_Import (Curr);

            when AST_Import_ES | AST_Import_WASM =>
               Register_Foreign_Import (Curr);

            when AST_Export_DLL | AST_Export_SO | AST_Export_Dylib | AST_Export_Jar =>
               null;

            when AST_Export_ES | AST_Export_WASM =>
               Register_Foreign_Export (Curr);

            when AST_Static_Sprite_Decl | AST_Static_Surface_Decl | AST_Color_Lut_Decl |
                 AST_Visual_Rule_Decl | AST_Render_Viewport_Decl | AST_Apply_Lut_Stmt |
                 AST_Blit_Safe_Stmt | AST_Set_Shoebox_Stmt =>
               Need_Static_Graphics_Runtime := True;

            when AST_Markov_Model_Decl | AST_Predict_Markov_Stmt =>
               Need_Markov_Runtime := True;

            when AST_Neural_Topology_Decl | AST_Infer_Network_Stmt | AST_Train_Network_Stmt =>
               Need_Neural_Runtime := True;

            when AST_Memory_Firewall_Decl | AST_Network_Socket_Decl |
                 AST_Network_Listen_Stmt | AST_Network_Accept_Stmt |
                 AST_Network_Receive_Stmt | AST_Network_Send_Stmt |
                 AST_Network_Close_Stmt =>
               Need_Network_Runtime := True;

            when AST_Process_Handle_Decl | AST_Read_Process_Memory_Expr |
                 AST_Read_Process_Memory_Stmt | AST_Write_Process_Memory_Stmt |
                 AST_Monitor_Process_Memory_Stmt | AST_Dump_Process_Memory_Stmt |
                 AST_Terminate_Process_Stmt | AST_Create_Process_Stmt |
                 AST_Elevate_Privileges_Stmt | AST_Hack_Memory_Stmt |
                 AST_Inject_Code_Memory_Stmt | AST_Inject_Code_Stmt |
                 AST_Hijack_Process_Memory_Stmt | AST_Sniff_Network_Stmt |
                 AST_Encrypt_File_Stmt | AST_Decrypt_File_Stmt =>
               Need_Process_Runtime := True;

            when AST_Mcp_Server | AST_Mcp_Tool | AST_Mcp_Resource =>
               --  defer binding: bound routines may be declared later
               if Mcp_Pending_Count < Max_Mcp_Decls then
                  Mcp_Pending_Count := Mcp_Pending_Count + 1;
                  Mcp_Pending (Mcp_Pending_Count) := Curr;
               end if;

            when AST_Mcp_Pump | AST_Mcp_Listen =>
               Need_Mcp_Runtime := True;

            when others =>
               if Tree (Curr).Left_Child > 0 then
                  Scan_Features (Tree (Curr).Left_Child);
               end if;
               if Tree (Curr).Right_Child > 0 then
                  Scan_Features (Tree (Curr).Right_Child);
               end if;
         end case;
         Curr := Tree (Curr).Next_Sibling;
      end loop;
   end Scan_Features;

   function As_Text_Expr (Node_Index_Value : Node_Index) return String;
   function Firewall_Key_For_Node (Target_Node : Node_Index) return String;
   function Wrap_Firewall_Read
     (Node_Index_Value : Node_Index;
      Value_Text       : String) return String;
   function Wrap_Firewall_Write
     (Node_Index_Value : Node_Index;
      Value_Text       : String) return String;
   procedure Emit_Firewall_Touch
     (Node_Index_Value : Node_Index;
      Need_Read        : Boolean;
      Need_Write       : Boolean);

   function Collect_Module_Member_Name (Node_Index_Value : Node_Index) return String is
      Node       : constant AST_Node := Tree (Node_Index_Value);
      Left_Node  : constant Node_Index := Node.Left_Child;
      Right_Node : constant Node_Index := Node.Right_Child;
   begin
      if Left_Node = 0 or else Right_Node = 0 then
         return "alb_missing_member";
      end if;

      return Safe_JS_Name (Raw_Lexeme (Tree (Left_Node).Token_Index) & "_" &
                           Raw_Lexeme (Tree (Right_Node).Token_Index));
   end Collect_Module_Member_Name;

   function Build_Array_Index
     (Dims       : Dim_List;
      Rank       : Natural;
      Bound_Node : Node_Index) return String
   is
      Bounds : array (1 .. 4) of Unbounded_String := (others => U ("0"));
      Count  : Natural := 0;
      Curr   : Node_Index := Bound_Node;
      Expr_Builder : Unbounded_String := U ("");
   begin
      while Curr > 0 and then Count < 4 loop
         Count := Count + 1;
         Bounds (Count) := U (Expr (Curr));
         Curr := Tree (Curr).Next_Sibling;
      end loop;

      --  STRICT arrays accept both 0- and 1-based indices (matching the
      --  fasm16 contract of reserving one extra slot per dimension), so the
      --  flat index uses the raw bound with (dim + 1) strides.
      if Rank = 0 then
         return "0";
      elsif Rank = 1 then
         return "(" & To_String (Bounds (1)) & ")";
      else
         Append (Expr_Builder, "(" & To_String (Bounds (1)) & ")");
         for I in 2 .. Rank loop
            Append
              (Expr_Builder,
               " * " & Trim_Image (Dims (I) + 1) & " + (" &
               To_String (Bounds (I)) & ")");
         end loop;
         return "(" & To_String (Expr_Builder) & ")";
      end if;
   end Build_Array_Index;

   function Field_Offset_Expr
     (Struct_Name : String;
      Field_Name  : String) return String is
      Field_Id : constant Natural := Find_Field (Struct_Name, Safe_JS_Name (Field_Name));
   begin
      if Field_Id /= 0 then
         return Trim_Image (Fields (Field_Id).Offset_Bytes);
      else
         return "0";
      end if;
   end Field_Offset_Expr;

   function Address_Expr_For (Target_Node : Node_Index) return String is
      TNode : constant AST_Node := Tree (Target_Node);
   begin
      if Target_Node = 0 then
         return "0";
      elsif TNode.Kind = AST_Var_Expr then
         declare
            Raw_Name : constant String := Raw_Lexeme (TNode.Token_Index);
            S        : constant Symbol_Record := Resolve_Symbol (Raw_Name);
            Elem     : constant Integer := Element_Bytes (S.Tag);
         begin
            if not S.Active or else S.Offset_Bytes <= 0 then
               return "0";
            elsif TNode.Left_Child > 0
              and then S.Kind in Sym_Strict_Array | Sym_Slide_Array | Sym_Parallel_Field
            then
               return "(" & Trim_Image (S.Offset_Bytes) & " + (" &
                 Build_Array_Index (S.Dims, S.Rank, TNode.Left_Child) & ") * " &
                 Trim_Image (Elem) & ")";
            else
               return Trim_Image (S.Offset_Bytes);
            end if;
         end;
      elsif TNode.Kind = AST_Member_Expr then
         declare
            Left_Node  : constant AST_Node := Tree (TNode.Left_Child);
            Right_Node : constant AST_Node := Tree (TNode.Right_Child);
            Left_Name  : constant String := (if Left_Node.Token_Index > 0 then Raw_Lexeme (Left_Node.Token_Index) else "");
            Right_Name : constant String := (if Right_Node.Token_Index > 0 then Raw_Lexeme (Right_Node.Token_Index) else "");
            Group_Sym  : constant Symbol_Record := Resolve_Symbol (Left_Name & "." & Right_Name);
            Left_Sym   : constant Symbol_Record := Resolve_Symbol (Left_Name);
         begin
            if Left_Node.Kind = AST_Var_Expr and then Left_Node.Left_Child > 0 then
               declare
                  Field_Id : Natural :=
                    Find_Symbol_Shaped
                      ("", Scoped_Name (Left_Name) & "." & Right_Name,
                       Want_Array => True);
               begin
                  if Field_Id = 0 then
                     Field_Id := Find_Symbol_Shaped
                       ("", Left_Name & "." & Right_Name, Want_Array => True);
                  end if;
                  if Field_Id /= 0 and then Symbols (Field_Id).Offset_Bytes > 0 then
                     return "(" & Trim_Image (Symbols (Field_Id).Offset_Bytes) & " + (" &
                       Build_Array_Index (Symbols (Field_Id).Dims, Symbols (Field_Id).Rank, Left_Node.Left_Child) &
                       ") * " & Trim_Image (Element_Bytes (Symbols (Field_Id).Tag)) & ")";
                  end if;
               end;
            end if;

            if Right_Node.Kind = AST_Var_Expr
              and then Right_Node.Left_Child > 0
              and then Group_Sym.Active
              and then Group_Sym.Offset_Bytes > 0
              and then Group_Sym.Kind in Sym_Strict_Array | Sym_Slide_Array | Sym_Parallel_Field
            then
               return "(" & Trim_Image (Group_Sym.Offset_Bytes) & " + (" &
                 Build_Array_Index (Group_Sym.Dims, Group_Sym.Rank, Right_Node.Left_Child) &
                 ") * " & Trim_Image (Element_Bytes (Group_Sym.Tag)) & ")";
            end if;

            if Left_Sym.Active and then Left_Sym.Kind = Sym_Struct_Var and then Left_Sym.Offset_Bytes > 0 then
               return "(" & Trim_Image (Left_Sym.Offset_Bytes) & " + " &
                 Field_Offset_Expr (To_String (Left_Sym.Struct_Name), Right_Name) & ")";
            end if;
            return "0";
         end;
      else
         return "0";
      end if;
   end Address_Expr_For;

   function As_Text_Expr (Node_Index_Value : Node_Index) return String is
   begin
      --  F64/F32 values print the 6-decimal real form (same contract as the
      --  FASM/MALBR backends' "%.6f" path); everything else String(v).
      if Node_Index_Value > 0
        and then Infer_Expr_Kind (Node_Index_Value) in VK_F64 | VK_F32
      then
         return "ALB_FText(" & Expr (Node_Index_Value) & ")";
      else
         return "ALB_Text(" & Expr (Node_Index_Value) & ")";
      end if;
   end As_Text_Expr;

   function Feature_Text_Expr (Node_Index_Value : Node_Index) return String is
   begin
      if Node_Index_Value = 0 then
         return Escape_TS_String ("");
      elsif Tree (Node_Index_Value).Kind = AST_String_Expr then
         return Expr (Node_Index_Value);
      elsif Tree (Node_Index_Value).Kind in AST_Var_Expr | AST_Atom | AST_Logic_Var then
         return Escape_TS_String (Raw_Feature_Atom (Node_Index_Value));
      else
         return As_Text_Expr (Node_Index_Value);
      end if;
   end Feature_Text_Expr;

   procedure Emit_Warn_Once
     (Key     : String;
      Message : String) is
   begin
      Line ("ALB_WARN_ONCE(" & Escape_TS_String (Key) & ", " &
            Escape_TS_String (Message) & ");");
   end Emit_Warn_Once;

   procedure Emit_Fallback_Body (Fallback_Node : Node_Index) is
   begin
      if Fallback_Node = 0 then
         return;
      elsif Tree (Fallback_Node).Kind = AST_Fallback_Block then
         Emit_Block (Tree (Fallback_Node).Left_Child);
      else
         Emit_Block (Fallback_Node);
      end if;
   end Emit_Fallback_Body;

   procedure Ensure_Special_Scalar
     (Raw_Name : String;
      Tag      : Value_Kind := VK_U64) is
      Routine_Name : constant String := To_String (Current_Routine);
      Plain_JS     : constant String := Safe_JS_Name (Raw_Name);
      Scoped_JS    : constant String := Scoped_Name (Raw_Name);
   begin
      if Routine_Name'Length > 0 then
         if Find_Symbol_Shaped (Routine_Name, Raw_Name,
                                Want_Array => False, Strict => True) = 0
         then
            Register_Symbol (Routine_Name, Raw_Name, Plain_JS, Tag, Sym_Scalar);
            Line ("var " & Plain_JS & ": " & Primitive_TS_Type (Tag) &
                  " = " & Default_Value (Tag) & ";");
         end if;
      elsif Find_Symbol_Shaped ("", Scoped_JS,
                                Want_Array => False, Strict => True) = 0
        and then Find_Symbol_Shaped ("", Raw_Name,
                                     Want_Array => False, Strict => True) = 0
      then
         Register_Symbol ("", Scoped_JS, Scoped_JS, Tag, Sym_Scalar);
         Line ("var " & Scoped_JS & ": " & Primitive_TS_Type (Tag) &
               " = " & Default_Value (Tag) & ";");
      end if;
   end Ensure_Special_Scalar;

   function Expr (Node_Index_Value : Node_Index) return String is
      Node       : AST_Node;
      Tok_Text   : Unbounded_String := U ("");
      Tok_Kind   : Token_Kind := Tok_Error;
      Sym        : Symbol_Record;
   begin
      if Node_Index_Value = 0 then
         return "0";
      end if;

      Node := Tree (Node_Index_Value);
      if Node.Token_Index > 0 then
         Tok_Text := U (Raw_Lexeme (Node.Token_Index));
         Tok_Kind := Tokens (Node.Token_Index).Kind;
      end if;

      case Node.Kind is
         when AST_Number_Expr =>
            return To_String (Tok_Text);
         when AST_Hex_Expr =>
            declare
               T : constant String := To_String (Tok_Text);
            begin
               return "0x" & T (T'First + 1 .. T'Last);
            end;
         when AST_Bin_Expr =>
            declare
               T : constant String := To_String (Tok_Text);
            begin
               return "0b" & T (T'First + 1 .. T'Last);
            end;
         when AST_Octal_Expr =>
            declare
               T : constant String := To_String (Tok_Text);
               P : Natural := T'First + 1;  --  skip the '&' marker
            begin
               if P <= T'Last and then T (P) in 'O' | 'o' then
                  P := P + 1;               --  skip the 'O' prefix too
               end if;
               return "0o" & T (P .. T'Last);
            end;
         when AST_String_Expr =>
            declare
               T : constant String := To_String (Tok_Text);
            begin
               --  ALB string literals have no escape processing — every
               --  char between the quotes is literal — so the TS literal
               --  must re-escape the content rather than copy the source
               --  spelling verbatim (`"a\\b"` in ALB prints `a\\b`).
               --  Strip by position whenever the span is delimiter-
               --  bracketed: '"'/'`' for real literals, '{'/'}' for the
               --  interpolation splice's fragment spans (`pre{, }post`,
               --  and the '{{X' escape -> '{').
               if T'Length >= 2
                 and then T (T'First) in '"' | '`' | '{' | '}'
               then
                  return Escape_TS_String (T (T'First + 1 .. T'Last - 1));
               else
                  return Escape_TS_String (T);
               end if;
            end;
         when AST_True =>
            return "true";
         when AST_False =>
            return "false";
         when AST_Const_Ref =>
            declare
               T : constant String := To_String (Tok_Text);
            begin
               return Safe_JS_Name (T (T'First + 1 .. T'Last));
            end;
         when AST_Var_Expr =>
            declare
               Raw_Name : constant String := To_String (Tok_Text);
               S        : constant Symbol_Record :=
                 Resolve_Symbol_Shaped
                   (Raw_Name,
                    Want_Array => Node.Left_Child > 0,
                    Strict     => Node.Left_Child = 0);
            begin
               if Node.Left_Child > 0
                 and then S.Active
                 and then S.Kind in Sym_Strict_Array | Sym_Slide_Array
               then
                  return Wrap_Firewall_Read
                    (Node_Index_Value,
                     To_String (S.JS_Name) &
                       "[" & Build_Array_Index (S.Dims, S.Rank, Node.Left_Child) & "]");
               else
                  return Wrap_Firewall_Read
                    (Node_Index_Value,
                     Resolve_Var_Name (Raw_Name));
               end if;
            end;
         when AST_Member_Expr =>
            declare
               Left_Node  : constant AST_Node := Tree (Node.Left_Child);
               Right_Node : constant AST_Node := Tree (Node.Right_Child);
               Left_Name  : constant String := Raw_Lexeme (Left_Node.Token_Index);
               Right_Name : constant String := Raw_Lexeme (Right_Node.Token_Index);
               Group_Sym  : constant Symbol_Record := Resolve_Symbol (Left_Name & "." & Right_Name);
               Left_Sym   : constant Symbol_Record := Resolve_Symbol (Left_Name);
            begin
               if Left_Node.Kind = AST_Var_Expr and then Left_Node.Left_Child > 0 then
                  declare
                     Scoped_Field : constant String := Scoped_Name (Left_Name) & "." & Right_Name;
                     Field_Sym_Id : Natural :=
                       Find_Symbol_Shaped ("", Scoped_Field, Want_Array => True);
                  begin
                     if Field_Sym_Id = 0 then
                        Field_Sym_Id := Find_Symbol_Shaped
                          ("", Left_Name & "." & Right_Name, Want_Array => True);
                     end if;

                     if Field_Sym_Id /= 0 then
                        return Wrap_Firewall_Read
                          (Node_Index_Value,
                           To_String (Symbols (Field_Sym_Id).JS_Name) &
                             "[" &
                             Build_Array_Index
                               (Symbols (Field_Sym_Id).Dims,
                                Symbols (Field_Sym_Id).Rank,
                                Left_Node.Left_Child) &
                             "]");
                     end if;
                  end;
               end if;

               if Right_Node.Kind = AST_Var_Expr
                 and then Right_Node.Left_Child > 0
                 and then Group_Sym.Active
                 and then Group_Sym.Kind in Sym_Strict_Array | Sym_Slide_Array | Sym_Parallel_Field
               then
                  return Wrap_Firewall_Read
                    (Node_Index_Value,
                     To_String (Group_Sym.JS_Name) &
                       "[" &
                       Build_Array_Index
                         (Group_Sym.Dims,
                          Group_Sym.Rank,
                          Right_Node.Left_Child) &
                       "]");
               end if;

               if Left_Sym.Active and then Left_Sym.Kind = Sym_Struct_Var then
                  declare
                     Field_Id : constant Natural :=
                       Find_Field (To_String (Left_Sym.Struct_Name), Safe_JS_Name (Right_Name));
                  begin
                     return Wrap_Firewall_Read
                       (Node_Index_Value,
                        Field_Read_Expr (To_String (Left_Sym.JS_Name), Field_Id));
                  end;
               elsif Group_Sym.Active then
                  return Wrap_Firewall_Read
                    (Node_Index_Value,
                     To_String (Group_Sym.JS_Name));
               else
                  return Wrap_Firewall_Read
                    (Node_Index_Value,
                     Collect_Module_Member_Name (Node_Index_Value));
               end if;
            end;
         when AST_BinOp =>
            declare
               --  `|` children are emitted through As_Text_Expr directly —
               --  routing them through Expr first and As_Text_Expr again
               --  emitted every subtree twice per level, i.e. O(2^depth) on
               --  left-leaning concat chains (BUG_REPORT_albw_concat_hang).
               L : constant String :=
                 (if Tok_Kind = Tok_Pipe
                  then As_Text_Expr (Node.Left_Child)
                  else Expr (Node.Left_Child));
               R : constant String :=
                 (if Tok_Kind = Tok_Pipe
                  then As_Text_Expr (Node.Right_Child)
                  else Expr (Node.Right_Child));
            begin
               case Tok_Kind is
                  when Tok_Pipe =>
                     --  `|` carves an arena string — ALB_CAT accounts the
                     --  watermark so MEMUSED()/CLAIM/SWEEP stay honest.
                     return "ALB_CAT(" & L & ", " & R & ")";
                  when Tok_Plus =>
                     return "(" & Num_Op (Node.Left_Child, L) & " + " &
                       Num_Op (Node.Right_Child, R) & ")";
                  when Tok_Minus =>
                     return "(" & Num_Op (Node.Left_Child, L) & " - " &
                       Num_Op (Node.Right_Child, R) & ")";
                  when Tok_Mul =>
                     declare
                        LK : constant Value_Kind := Infer_Expr_Kind (Node.Left_Child);
                        RK : constant Value_Kind := Infer_Expr_Kind (Node.Right_Child);
                        LN : constant String := Num_Op (Node.Left_Child, L);
                        RN : constant String := Num_Op (Node.Right_Child, R);
                     begin
                        if LK in VK_F64 | VK_F32 or else RK in VK_F64 | VK_F32 then
                           return "(" & LN & " * " & RN & ")";
                        elsif LK = VK_U64 or else RK = VK_U64 then
                           --  64-bit operands keep the full f64 range; imul
                           --  would truncate to 32 bits.
                           return "(" & LN & " * " & RN & ")";
                        elsif LK = VK_U32 or else RK = VK_U32 then
                           --  ALB int multiply wraps; Math.imul preserves the
                           --  low 32 bits exactly (f64 '*' loses them > 2^53).
                           return "(albU32(Math.imul(" & LN & ", " & RN & ")))";
                        elsif LK in VK_S32 | VK_S16 | VK_S8 |
                              VK_U8 | VK_U16 | VK_HW8 | VK_HW16 | VK_HW32 |
                              VK_Boolean
                          or else RK in VK_S32 | VK_S16 | VK_S8 |
                              VK_U8 | VK_U16 | VK_HW8 | VK_HW16 | VK_HW32 |
                              VK_Boolean
                        then
                           return "(Math.imul(" & LN & ", " & RN & "))";
                        else
                           --  VK_Number / unknown: plain '*' stays exact to
                           --  2^53, matching i64-range semantics far better
                           --  than a 32-bit truncating imul.
                           return "(" & LN & " * " & RN & ")";
                        end if;
                     end;
                  when Tok_Div =>
                     declare
                        Res_Kind : constant Value_Kind := Infer_Expr_Kind (Node_Index_Value);
                     begin
                        if Res_Kind in VK_F64 | VK_F32
                          or else Infer_Expr_Kind (Node.Left_Child) in VK_F64 | VK_F32
                          or else Infer_Expr_Kind (Node.Right_Child) in VK_F64 | VK_F32
                          or else Uses_Real_Power (Node.Left_Child)
                          or else Uses_Real_Power (Node.Right_Child)
                        then
                           return "(" & L & " / " & R & ")";
                        else
                           return "albDivB(" & Big_Expr (Node.Left_Child) & ", " &
                             Big_Expr (Node.Right_Child) & ")";
                        end if;
                     end;
                  when Tok_Mod =>
                     declare
                        Res_Kind : constant Value_Kind := Infer_Expr_Kind (Node_Index_Value);
                        LK       : constant Value_Kind := Infer_Expr_Kind (Node.Left_Child);
                        RK       : constant Value_Kind := Infer_Expr_Kind (Node.Right_Child);
                     begin
                        if Res_Kind in VK_F64 | VK_F32
                          or else LK in VK_F64 | VK_F32
                          or else RK in VK_F64 | VK_F32
                        then
                           return "albMod(" & L & ", " & R & ")";
                        else
                           return "albModB(" & Big_Expr (Node.Left_Child) & ", " &
                             Big_Expr (Node.Right_Child) & ")";
                        end if;
                     end;
                  when Tok_Pow =>
                     if Uses_Real_Power (Node.Left_Child)
                       or else Uses_Real_Power (Node.Right_Child)
                     then
                        return "Math.pow(" & L & ", " & R & ")";
                     end if;
                     return "ALB_POW(" & L & ", " & R & ")";
                  when Tok_Less | Tok_Greater | Tok_Less_Equal |
                    Tok_Greater_Equal =>
                     --  Integer-kind comparisons evaluate through BigInt so
                     --  intermediates beyond 2^53 (h*h in Pell's equation)
                     --  stay exact; mixed float compares keep number paths.
                     if Int_Kind (Infer_Expr_Kind (Node.Left_Child))
                       and then Int_Kind (Infer_Expr_Kind (Node.Right_Child))
                     then
                        declare
                           BL : constant String := Big_Expr (Node.Left_Child);
                           BR : constant String := Big_Expr (Node.Right_Child);
                        begin
                           case Tok_Kind is
                              when Tok_Less =>
                                 return "(" & BL & " < " & BR & " ? 1 : 0)";
                              when Tok_Greater =>
                                 return "(" & BL & " > " & BR & " ? 1 : 0)";
                              when Tok_Less_Equal =>
                                 return "(" & BL & " <= " & BR & " ? 1 : 0)";
                              when others =>
                                 return "(" & BL & " >= " & BR & " ? 1 : 0)";
                           end case;
                        end;
                     end if;
                     case Tok_Kind is
                        when Tok_Less =>
                           return "(" & L & " < " & R & " ? 1 : 0)";
                        when Tok_Greater =>
                           return "(" & L & " > " & R & " ? 1 : 0)";
                        when Tok_Less_Equal =>
                           return "(" & L & " <= " & R & " ? 1 : 0)";
                        when others =>
                           return "(" & L & " >= " & R & " ? 1 : 0)";
                     end case;
                  when Tok_Equal | Tok_Assign =>
                     if Tree (Node.Left_Child).Kind = AST_True then
                        return "(Boolean(" & R & ") ? 1 : 0)";
                     elsif Tree (Node.Right_Child).Kind = AST_True then
                        return "(Boolean(" & L & ") ? 1 : 0)";
                     elsif Tree (Node.Left_Child).Kind = AST_False then
                        return "(Boolean(" & R & ") ? 0 : 1)";
                     elsif Tree (Node.Right_Child).Kind = AST_False then
                        return "(Boolean(" & L & ") ? 0 : 1)";
                     end if;
                     if Int_Kind (Infer_Expr_Kind (Node.Left_Child))
                       and then Int_Kind (Infer_Expr_Kind (Node.Right_Child))
                     then
                        return "(" & Big_Expr (Node.Left_Child) & " === " &
                          Big_Expr (Node.Right_Child) & " ? 1 : 0)";
                     end if;
                     return "(" & L & " === " & R & " ? 1 : 0)";
                  when Tok_Not_Equal =>
                     if Tree (Node.Left_Child).Kind = AST_True then
                        return "(Boolean(" & R & ") ? 0 : 1)";
                     elsif Tree (Node.Right_Child).Kind = AST_True then
                        return "(Boolean(" & L & ") ? 0 : 1)";
                     elsif Tree (Node.Left_Child).Kind = AST_False then
                        return "(Boolean(" & R & ") ? 1 : 0)";
                     elsif Tree (Node.Right_Child).Kind = AST_False then
                        return "(Boolean(" & L & ") ? 1 : 0)";
                     end if;
                     if Int_Kind (Infer_Expr_Kind (Node.Left_Child))
                       and then Int_Kind (Infer_Expr_Kind (Node.Right_Child))
                     then
                        return "(" & Big_Expr (Node.Left_Child) & " !== " &
                          Big_Expr (Node.Right_Child) & " ? 1 : 0)";
                     end if;
                     return "(" & L & " !== " & R & " ? 1 : 0)";
                  when Tok_And =>
                     --  ALB AND/OR/XOR/SHL/SHR are i64 bitwise (FASM `and`/
                     --  `or`/`xor`/`shl`/`sar`). BigInt keeps masks >= 2^31
                     --  and negative results (-1, BASIC TRUE) faithful;
                     --  asIntN wraps shifts like the hardware; Number() is
                     --  exact through 2^53. Plain JS `&` would int32-wrap.
                     return "(Number(BigInt.asIntN(64, (albBig(" & L & ")) & (albBig(" & R & ")))))";
                  when Tok_Or =>
                     return "(Number(BigInt.asIntN(64, (albBig(" & L & ")) | (albBig(" & R & ")))))";
                  when Tok_Xor =>
                     return "(Number(BigInt.asIntN(64, (albBig(" & L & ")) ^ (albBig(" & R & ")))))";
                  when Tok_Shl =>
                     return "(Number(BigInt.asIntN(64, (albBig(" & L & ")) << (albBig(" & R & ")))))";
                  when Tok_Shr =>
                     return "(Number(BigInt.asIntN(64, (albBig(" & L & ")) >> (albBig(" & R & ")))))";
                  when Tok_Andalso =>
                     --  Short-circuit AND — the right operand is embedded
                     --  behind the conditional so it never evaluates when
                     --  the left side is falsy.
                     return "(Boolean(" & L & ") ? (Boolean(" & R & ") ? 1 : 0) : 0)";
                  when Tok_Orelse =>
                     return "(Boolean(" & L & ") ? 1 : (Boolean(" & R & ") ? 1 : 0))";
                  when others =>
                     return "(" & L & " + " & R & ")";
               end case;
            end;
         when AST_Unary_Minus =>
            return "(-" & Expr (Node.Left_Child) & ")";
         when AST_Not =>
            declare
               Op_Node : constant Node_Index := Node.Left_Child;
               Logical : Boolean := False;
            begin
               if Op_Node > 0
                 and then Tree (Op_Node).Kind = AST_BinOp
                 and then Tokens (Tree (Op_Node).Token_Index).Kind in
                   Tok_Equal | Tok_Assign | Tok_Not_Equal | Tok_Less |
                   Tok_Greater | Tok_Less_Equal | Tok_Greater_Equal
               then
                  Logical := True;
               end if;
               if Logical then
                  return "(Boolean(" & Expr (Node.Left_Child) & ") ? 0 : 1)";
               end if;
               --  Bitwise NOT — BASIC TRUE is -1 (whole-register complement),
               --  same as FASM `not`. BigInt keeps full i64 width.
               return "(Number(~(albBig(" & Expr (Node.Left_Child) & "))))";
            end;
         when AST_Cast_Expr =>
            return Cast_Expr (Type_From_Token (Node.Token_Index), Expr (Node.Left_Child));
         when AST_Str_Len =>
            return "LEN(" & Expr (Node.Left_Child) & ")";
         when AST_Str_Left =>
            return "LEFT(" & Expr (Node.Left_Child) & ", " &
              Expr (Node.Right_Child) & ")";
         when AST_Str_Right =>
            return "RIGHT(" & Expr (Node.Left_Child) & ", " &
              Expr (Node.Right_Child) & ")";
         when AST_Str_Mid =>
            declare
               Start_Node : constant Node_Index :=
                 (if Node.Right_Child > 0
                    and then Tree (Node.Right_Child).Kind = AST_Arg_List
                  then Tree (Node.Right_Child).Left_Child
                  else Node.Right_Child);
               Count_Node : constant Node_Index :=
                 (if Start_Node > 0 then Tree (Start_Node).Next_Sibling else 0);
            begin
               return "MID(" & Expr (Node.Left_Child) & ", " &
                 (if Start_Node > 0 then Expr (Start_Node) else "1") & ", " &
                 (if Count_Node > 0 then Expr (Count_Node) else "0") & ")";
            end;
         when AST_Constructor =>
            declare
               Ctor_Name : constant String := Upper_Text (To_String (Tok_Text));
               A1        : Node_Index := Node.Left_Child;
               A2        : Node_Index := 0;
            begin
               if A1 > 0 then
                  A2 := Tree (A1).Next_Sibling;
               end if;

               if Ctor_Name = "PURE" or else Ctor_Name = "RATIONAL" then
                  return "PURE(" &
                    (if A1 > 0 then Expr (A1) else "0") &
                    ", " &
                    (if A2 > 0 then Expr (A2) else "1") &
                    ")";
               elsif Ctor_Name = "U8" then
                  return Cast_Expr (VK_U8, Expr (A1));
               elsif Ctor_Name = "U16" then
                  return Cast_Expr (VK_U16, Expr (A1));
                elsif Ctor_Name = "U32" then
                   return Cast_Expr (VK_U32, Expr (A1));
                elsif Ctor_Name = "U64" then
                   return Cast_Expr (VK_U64, Expr (A1));
                elsif Ctor_Name = "S8" or else Ctor_Name = "I8" or else Ctor_Name = "INT8" then
                   return Cast_Expr (VK_S8, Expr (A1));
                elsif Ctor_Name = "S16" or else Ctor_Name = "I16" or else Ctor_Name = "INT16" then
                   return Cast_Expr (VK_S16, Expr (A1));
                elsif Ctor_Name = "S32" or else Ctor_Name = "I32" or else Ctor_Name = "INT32" then
                   return Cast_Expr (VK_S32, Expr (A1));
                elsif Ctor_Name = "S64" or else Ctor_Name = "I64" or else Ctor_Name = "INT64" then
                   return Cast_Expr (VK_Number, Expr (A1));
               elsif Ctor_Name = "F64" or else Ctor_Name = "REAL" then
                  return Cast_Expr (VK_F64, Expr (A1));
               elsif Ctor_Name = "HW8" then
                  return Cast_Expr (VK_HW8, Expr (A1));
               elsif Ctor_Name = "HW16" then
                  return Cast_Expr (VK_HW16, Expr (A1));
               elsif Ctor_Name = "HW32" then
                  return Cast_Expr (VK_HW32, Expr (A1));
               else
                  return Expr (A1);
               end if;
            end;
         when AST_Func_Call =>
            declare
               Target_Node : constant Node_Index := Node.Left_Child;
               Arg_List    : constant Node_Index := Node.Right_Child;
               Target_Name : Unbounded_String := U ("alb_missing_call");
               TNode       : AST_Node;
               Raw         : Unbounded_String := U ("");
               Raw_Upper    : Unbounded_String := U ("");
               Routine_Name : Unbounded_String := U ("");
               Args_Text    : constant String := Join_Arg_List (Arg_List);
            begin
               if Target_Node > 0 then
                  TNode := Tree (Target_Node);
                  if TNode.Kind in AST_Var_Expr | AST_Atom | AST_Logic_Var then
                     Raw := U (Raw_Lexeme (TNode.Token_Index));
                     Raw_Upper := U (Upper_Text (To_String (Raw)));
                     Routine_Name := U (Resolve_Routine_Name (To_String (Raw)));
                     --  BRAILLE / NEMETH one-shot expression builtins:
                     --  transcribe the arg in place (comma expr) and
                     --  read the result back.  Reserved builtin names —
                     --  like LEFT/CHR they shadow any user routine.
                     if To_String (Raw_Upper) = "BRF" then
                        return "(Ueb_Transcribe(" & Args_Text &
                          "), Ueb_ToBrf())";
                     elsif To_String (Raw_Upper) = "UNI" then
                        return "(Ueb_Transcribe(" & Args_Text &
                          "), Ueb_ToUni())";
                     elsif To_String (Raw_Upper) = "BRFG1" then
                        return "(Ueb_TranscribeG1(" & Args_Text &
                          "), Ueb_ToBrf())";
                     elsif To_String (Raw_Upper) = "NBRF" then
                        return "(Nemeth_Transcribe(" & Args_Text &
                          "), Nemeth_ToBrf())";
                     elsif To_String (Raw_Upper) = "NUNI" then
                        return "(Nemeth_Transcribe(" & Args_Text &
                          "), Nemeth_ToUni())";
                     --  back-translation (B1b):  BRF/UNI text ->
                     --  canonical source.
                     elsif To_String (Raw_Upper) = "UNBRF" then
                        return "Nemeth_FromBrf(" & Args_Text & ")";
                     elsif To_String (Raw_Upper) = "UNUNI" then
                        return "Nemeth_FromUni(" & Args_Text & ")";
                     end if;
                     if To_String (Raw_Upper) = "LEFT" or else To_String (Raw_Upper) = "LEFT$" then
                        Target_Name := U ("LEFT");
                     elsif To_String (Raw_Upper) = "RIGHT" or else To_String (Raw_Upper) = "RIGHT$" then
                        Target_Name := U ("RIGHT");
                     elsif To_String (Raw_Upper) = "MID" or else To_String (Raw_Upper) = "MID$" then
                        Target_Name := U ("MID");
                     elsif To_String (Raw_Upper) = "LEN" then
                        Target_Name := U ("LEN");
                     elsif To_String (Raw_Upper) = "CHR" then
                        Target_Name := U ("CHR");
                     elsif To_String (Raw_Upper) = "ASC" then
                        Target_Name := U ("ASC");
                     elsif To_String (Raw_Upper) = "CONCAT" then
                        Target_Name := U ("CONCAT");
                     elsif To_String (Raw_Upper) = "EXP" then
                        Target_Name := U ("Math.exp");
                     elsif To_String (Raw_Upper) = "SQRT"
                       or else To_String (Raw_Upper) = "SIN"
                       or else To_String (Raw_Upper) = "COS"
                     then
                        --  ALB contract (matches FASM): F64/F32 args take
                        --  radians-domain real math; integer args take the
                        --  degree/fixed-point helpers (isqrt for SQRT).
                        declare
                           A0 : Node_Index := Arg_List;
                        begin
                           if A0 > 0 and then Tree (A0).Kind = AST_Arg_List then
                              A0 := Tree (A0).Left_Child;
                           end if;
                           if A0 > 0
                             and then Infer_Expr_Kind (A0) in VK_F64 | VK_F32
                           then
                              if To_String (Raw_Upper) = "SIN" then
                                 Target_Name := U ("Math.sin");
                              elsif To_String (Raw_Upper) = "COS" then
                                 Target_Name := U ("Math.cos");
                              else
                                 Target_Name := U ("Math.sqrt");
                              end if;
                           else
                              Target_Name := U ("ALB_" & To_String (Raw_Upper));
                           end if;
                        end;
                     elsif To_String (Raw_Upper) = "ASIN" then
                        Target_Name := U ("Math.asin");
                     elsif To_String (Raw_Upper) = "ACOS" then
                        Target_Name := U ("Math.acos");
                     elsif To_String (Raw_Upper) = "ATAN" then
                        Target_Name := U ("Math.atan");
                     elsif To_String (Raw_Upper) = "ATAN2" then
                        Target_Name := U ("Math.atan2");
                     elsif To_String (Raw_Upper) = "TAN" then
                        Target_Name := U ("Math.tan");
                     elsif To_String (Raw_Upper) = "LN"
                       or else To_String (Raw_Upper) = "LOG"
                       or else To_String (Raw_Upper) = "LOGN"
                     then
                        Target_Name := U ("Math.log");
                     elsif To_String (Raw_Upper) = "LOG2" then
                        Target_Name := U ("Math.log2");
                     elsif To_String (Raw_Upper) = "LOG10" then
                        Target_Name := U ("Math.log10");
                     elsif To_String (Raw_Upper) = "POW" then
                        Target_Name := U ("Math.pow");
                     elsif To_String (Raw_Upper) = "FLOOR" then
                        Target_Name := U ("Math.floor");
                     elsif To_String (Raw_Upper) = "CEIL" then
                        Target_Name := U ("Math.ceil");
                     elsif To_String (Raw_Upper) = "TRUNC" then
                        Target_Name := U ("Math.trunc");
                     elsif To_String (Raw_Upper) = "ROUND" then
                        Target_Name := U ("ALB_ROUND");
                     elsif To_String (Raw_Upper) = "ABS" then
                        Target_Name := U ("Math.abs");
                     elsif To_String (Raw_Upper) = "SGN" then
                        Target_Name := U ("Math.sign");
                     elsif To_String (Raw_Upper) = "ROL"
                       or else To_String (Raw_Upper) = "ROR"
                     then
                        --  Rotate at the operand's native width (U8 arg ->
                        --  8-bit rotate, matching MALBR/FASM semantics).
                        declare
                           A0 : Node_Index := Arg_List;
                           W  : Integer := 64;
                        begin
                           if A0 > 0 and then Tree (A0).Kind = AST_Arg_List then
                              A0 := Tree (A0).Left_Child;
                           end if;
                           if A0 > 0 then
                              case Infer_Expr_Kind (A0) is
                                 when VK_U8 | VK_S8 | VK_HW8 => W := 8;
                                 when VK_U16 | VK_S16 | VK_HW16 => W := 16;
                                 when VK_U32 | VK_S32 | VK_HW32 => W := 32;
                                 when others => W := 64;
                              end case;
                           end if;
                           if To_String (Raw_Upper) = "ROL" then
                              return "ALB_ROL(" & Args_Text & ", " &
                                Ada.Strings.Fixed.Trim
                                  (Integer'Image (W), Ada.Strings.Both) & ")";
                           else
                              return "ALB_ROR(" & Args_Text & ", " &
                                Ada.Strings.Fixed.Trim
                                  (Integer'Image (W), Ada.Strings.Both) & ")";
                           end if;
                        end;
                     elsif To_String (Raw_Upper) = "BSET" then
                        Target_Name := U ("ALB_BSET");
                     elsif To_String (Raw_Upper) = "BCLR" then
                        Target_Name := U ("ALB_BCLR");
                     elsif To_String (Raw_Upper) = "BTST" then
                        Target_Name := U ("ALB_BTST");
                     elsif To_String (Raw_Upper) = "MIN" then
                        Target_Name := U ("Math.min");
                     elsif To_String (Raw_Upper) = "MAX" then
                        Target_Name := U ("Math.max");
                     elsif To_String (Raw_Upper) = "UCASE"
                       or else To_String (Raw_Upper) = "UCASE$"
                     then
                        Target_Name := U ("UCASE");
                     elsif To_String (Raw_Upper) = "LCASE"
                       or else To_String (Raw_Upper) = "LCASE$"
                     then
                        Target_Name := U ("LCASE");
                     elsif To_String (Raw_Upper) = "TRIM"
                       or else To_String (Raw_Upper) = "TRIM$"
                     then
                        Target_Name := U ("TRIM");
                     elsif To_String (Raw_Upper) = "SPC"
                       or else To_String (Raw_Upper) = "SPACE"
                     then
                        Target_Name := U ("SPC");
                     elsif To_String (Raw_Upper) = "STR"
                       or else To_String (Raw_Upper) = "STR$"
                     then
                        --  STR of an F64 prints the 6-decimal real form.
                        declare
                           A0 : Node_Index := Arg_List;
                        begin
                           if A0 > 0 and then Tree (A0).Kind = AST_Arg_List then
                              A0 := Tree (A0).Left_Child;
                           end if;
                           if A0 > 0
                             and then Infer_Expr_Kind (A0) in VK_F64 | VK_F32
                           then
                              Target_Name := U ("ALB_FText");
                           else
                              Target_Name := U ("ALB_Text");
                           end if;
                        end;
                     elsif To_String (Raw_Upper) = "VAL" then
                        Target_Name := U ("ALB_Val");
                     elsif To_String (Raw_Upper) = "INSTR" then
                        Target_Name := U ("ALB_Instr");
                     elsif To_String (Raw_Upper) = "CHOOSE" then
                        Target_Name := U ("ALB_Choose");
                     elsif To_String (Raw_Upper) = "TIME"
                       or else To_String (Raw_Upper) = "TIME$"
                     then
                        Target_Name := U ("ALB_Time_Str");
                     elsif To_String (Raw_Upper) = "DATE"
                       or else To_String (Raw_Upper) = "DATE$"
                     then
                        Target_Name := U ("ALB_Date_Str");
                     elsif To_String (Raw_Upper) = "TIMER" then
                        Target_Name := U ("ALB_Timer");
                     elsif To_String (Raw_Upper) = "ENV"
                       or else To_String (Raw_Upper) = "ENV$"
                     then
                        Target_Name := U ("ALB_Env");
                     elsif To_String (Raw_Upper) = "ARGC" then
                        Target_Name := U ("ALB_Argc");
                     elsif To_String (Raw_Upper) = "ARGV"
                       or else To_String (Raw_Upper) = "ARGV$"
                     then
                        Target_Name := U ("ALB_Argv");
                     elsif To_String (Raw_Upper) = "SHELL"
                       or else To_String (Raw_Upper) = "EXEC"
                     then
                        Target_Name := U ("ALB_Shell");
                     elsif To_String (Raw_Upper) = "KILL"
                       or else To_String (Raw_Upper) = "DELETE"
                     then
                        Target_Name := U ("ALB_Kill");
                     elsif To_String (Raw_Upper) = "DIR"
                       or else To_String (Raw_Upper) = "DIR$"
                     then
                        Target_Name := U ("ALB_Dir");
                     elsif To_String (Raw_Upper) = "MEMUSED" then
                        Target_Name := U ("ALB_MemUsed");
                     elsif To_String (Raw_Upper) = "MEMFREE" then
                        Target_Name := U ("ALB_MemFree");
                     elsif To_String (Raw_Upper) = "PRINT_PURE" then
                        Target_Name := U ("PRINT_PURE");
                     elsif To_String (Raw_Upper) = "RATIONAL" then
                        Target_Name := U ("PURE");
                     elsif To_String (Raw_Upper) = "REAL" then
                        Target_Name := U ("F64");
                     elsif To_String (Raw_Upper) = "GETTICKCOUNT" then
                        if Length (Routine_Name) > 0 then
                           Target_Name := Routine_Name;
                        else
                           Target_Name := U ("ALB_GetTickCount");
                        end if;
                      elsif To_String (Raw_Upper) = "U8"
                        or else To_String (Raw_Upper) = "U16"
                        or else To_String (Raw_Upper) = "S8"
                        or else To_String (Raw_Upper) = "S16"
                        or else To_String (Raw_Upper) = "I8"
                        or else To_String (Raw_Upper) = "I16"
                        or else To_String (Raw_Upper) = "INT8"
                        or else To_String (Raw_Upper) = "INT16"
                        or else To_String (Raw_Upper) = "U32"
                        or else To_String (Raw_Upper) = "U64"
                        or else To_String (Raw_Upper) = "S64"
                        or else To_String (Raw_Upper) = "I32"
                        or else To_String (Raw_Upper) = "INT32"
                        or else To_String (Raw_Upper) = "I64"
                        or else To_String (Raw_Upper) = "INT64"
                        or else To_String (Raw_Upper) = "U128"
                        or else To_String (Raw_Upper) = "S32"
                       or else To_String (Raw_Upper) = "F64"
                       or else To_String (Raw_Upper) = "REAL"
                       or else To_String (Raw_Upper) = "HW8"
                       or else To_String (Raw_Upper) = "HW16"
                       or else To_String (Raw_Upper) = "HW32"
                       or else To_String (Raw_Upper) = "SIN"
                       or else To_String (Raw_Upper) = "COS"
                       or else To_String (Raw_Upper) = "SQRT"
                       or else To_String (Raw_Upper) = "EXP"
                       or else To_String (Raw_Upper) = "RND"
                       or else To_String (Raw_Upper) = "COLLIDE_RECT"
                       or else To_String (Raw_Upper) = "PURE"
                       or else To_String (Raw_Upper) = "RATIONAL"
                       or else To_String (Raw_Upper) = "PURE_NUM"
                       or else To_String (Raw_Upper) = "PURE_DEN"
                       or else To_String (Raw_Upper) = "PURE_ADD"
                       or else To_String (Raw_Upper) = "PURE_SUB"
                       or else To_String (Raw_Upper) = "PURE_MUL"
                       or else To_String (Raw_Upper) = "PURE_DIV"
                       or else To_String (Raw_Upper) = "PURE_POW"
                     then
                        Target_Name := Raw_Upper;
                     else
                        if Length (Routine_Name) > 0 then
                           Target_Name := Routine_Name;
                        else
                           --  `sa(i)` is the call-spelling array read —
                           --  same indexing as `sa[i]` on STRICT arrays.
                           declare
                              ASym : constant Symbol_Record :=
                                Resolve_Symbol (To_String (Raw));
                              First_Arg : Node_Index := Arg_List;
                           begin
                              if First_Arg > 0
                                and then Tree (First_Arg).Kind = AST_Arg_List
                              then
                                 First_Arg := Tree (First_Arg).Left_Child;
                              end if;
                              if ASym.Active
                                and then ASym.Kind in Sym_Strict_Array |
                                  Sym_Slide_Array | Sym_Parallel_Field
                                and then First_Arg > 0
                              then
                                 return Wrap_Firewall_Read
                                   (Node_Index_Value,
                                    To_String (ASym.JS_Name) & "[" &
                                    Build_Array_Index
                                      (ASym.Dims, ASym.Rank, First_Arg) & "]");
                              end if;
                              --  Routine-typed vars / params call through
                              --  the variable: `cmp(a,b)` -> `cmp(a,b)`.
                              if ASym.Active then
                                 return To_String (ASym.JS_Name) & "(" &
                                   Args_Text & ")";
                              end if;
                           end;
                           Target_Name := U ("ALB_PRED(" &
                             Escape_TS_String (To_String (Raw)) &
                             (if Args_Text'Length > 0 then ", " & Args_Text else "") &
                             ")");
                        end if;
                     end if;
                  elsif TNode.Kind = AST_Member_Expr then
                     --  `h.check(...)` calls through a routine-typed struct
                     --  field; `Mod.Fn(...)` resolves to the flat JS name.
                     --  A module routine wins over a same-named module var
                     --  (ALB is case-insensitive: `depth` and `Depth` fold
                     --  identically — the call form must prefer the routine).
                     declare
                        Flat : constant String :=
                          Collect_Module_Member_Name (Target_Node);
                     begin
                        if Find_Routine_For_Call (Flat) /= 0 then
                           Target_Name := U (Flat);
                        else
                           Target_Name := U (Expr (Target_Node));
                        end if;
                     end;
                  else
                     Target_Name := U (Expr (Target_Node));
                  end if;
               end if;

               if Starts_With (To_String (Target_Name), "ALB_PRED(") then
                  return To_String (Target_Name);
               end if;

               declare
                  Routine_Id : constant Natural :=
                    Find_Routine_For_Call (To_String (Target_Name));
               begin
                  if Routine_Has_Out (Routine_Id)
                    or else Ada.Strings.Fixed.Index (To_String (Target_Name), "VecU32At") > 0
                  then
                     return Emit_Call_Expr_With_Out
                       (To_String (Target_Name), Arg_List);
                  end if;
               end;

               declare
                  Routine_Id : constant Natural :=
                    Find_Routine_For_Call (To_String (Target_Name));
               begin
                  return
                    To_String (Target_Name) & "(" &
                    Join_Arg_List_For_Call (Arg_List, Routine_Id) & ")";
               end;
            end;
         when AST_Choose =>
            return "ALB_Choose(" & Expr (Node.Left_Child) & ", " &
              (if Node.Right_Child > 0
               then Expr (Tree (Node.Right_Child).Left_Child)
               else "0") & ", " &
              (if Node.Right_Child > 0
               then Expr (Tree (Node.Right_Child).Right_Child)
               else "0") & ")";
         when AST_Key_State =>
            return "ALB_KEY(" & Expr (Node.Left_Child) & ")";
         when AST_Mouse_X =>
            return "ALB_MOUSE_X()";
         when AST_Mouse_Y =>
            return "ALB_MOUSE_Y()";
         when AST_Mouse_Wheel =>
            return "ALB_MOUSE_WHEEL()";
         when AST_Mouse_Click =>
            return "ALB_MOUSE_CLICK(" &
              (if Node.Left_Child > 0 then Expr (Node.Left_Child) else "0") & ")";
         when AST_VMouse_X =>
            return "ALB_VMOUSE_X()";
         when AST_VMouse_y =>
            return "ALB_VMOUSE_Y()";
         when AST_SCREEN_WIDTH =>
            return "ALB_SCREEN_WIDTH()";
         when AST_SCREEN_HEIGHT =>
            return "ALB_SCREEN_HEIGHT()";
         when AST_VIRTUAL_WIDTH =>
            return "ALB_VIRTUAL_WIDTH()";
         when AST_VIRTUAL_HEIGHT =>
            return "ALB_VIRTUAL_HEIGHT()";
         when AST_Peek_Expr =>
            return "ALB_PEEK(" & Expr (Node.Left_Child) & ")";
         when AST_Deref_Expr =>
            return "ALB_DEREF(" & Expr (Node.Left_Child) & ")";
         when AST_Lambda_Expr =>
            --  Anonymous routine value: hoists to `function __alb_lambda_N`
            --  (emitted at top level by Flush_Lambda_Decls); the binding
            --  site stores the name.  The strict sig check ran in
            --  Emit_Assignment before we got here.
            return Queue_Lambda (Node_Index_Value);
         when AST_Ref_Expr =>
            --  `REF r` takes a routine's value (JS functions are first
            --  class). Routine names resolve to the JS function; anything
            --  else falls back to the numeric-address path.
            declare
               RT : constant AST_Node := Tree (Node.Left_Child);
            begin
               if RT.Kind = AST_Member_Expr then
                  return Collect_Module_Member_Name (Node.Left_Child);
               elsif RT.Kind in AST_Var_Expr | AST_Atom | AST_Logic_Var then
                  declare
                     Resolved : constant String :=
                       Resolve_Routine_Name (Raw_Lexeme (RT.Token_Index));
                  begin
                     if Resolved'Length > 0 then
                        return Resolved;
                     end if;
                  end;
               end if;
               return Address_Expr_For (Node.Left_Child);
            end;
         when AST_AddressOf =>
            return Address_Expr_For (Node.Left_Child);
         when AST_Read_Process_Memory_Expr =>
            return "ALB_PROCESS_READ_SCALAR(" &
              Expr (Node.Left_Child) & ", " &
              (if Node.Right_Child > 0 then Expr (Node.Right_Child) else "0") & ")";
         when AST_Read_Pixel =>
            return "ALB_READ_PIXEL(" & Expr (Node.Left_Child) & ", " &
              (if Node.Right_Child > 0 then Expr (Node.Right_Child) else "0") & ")";
         when AST_Rnd_Expr =>
            return "ALB_RND(" & Expr (Node.Left_Child) & ")";
         when AST_SizeOf_Expr =>
            declare
               Size_Sym : Symbol_Record;
            begin
               if Node.Left_Child > 0 and then Tree (Node.Left_Child).Token_Index > 0 then
                  Size_Sym := Resolve_Symbol (Raw_Lexeme (Tree (Node.Left_Child).Token_Index));
                  if Size_Sym.Active then
                     return Trim_Image (Element_Bytes (Size_Sym.Tag));
                  end if;
               end if;
               return "4";
            end;
         when AST_OffsetOf_Expr =>
            if Node.Left_Child > 0 and then Node.Right_Child > 0 then
               return Field_Offset_Expr
                 (Safe_JS_Name (Raw_Lexeme (Tree (Node.Left_Child).Token_Index)),
                  Raw_Lexeme (Tree (Node.Right_Child).Token_Index));
            else
               return "0";
            end if;
         when AST_TypeOf_Expr =>
            return Escape_TS_String ("number");
         when AST_Temporal_Ref =>
            declare
               Base_Name : constant String := Raw_Lexeme (Tree (Node.Left_Child).Token_Index);
               JS_Base   : constant String := Resolve_Var_Name (Base_Name);
               Sel       : constant Token_Kind := Tokens (Node.Token_Index).Kind;
               TSym      : constant Symbol_Record := Resolve_Symbol (Base_Name);
               Hist      : constant String := Trim_Image (Integer'Max (1, TSym.History_Size));
            begin
               case Sel is
                  when Tok_Now =>
                     return JS_Base;
                  when Tok_Past =>
                     return JS_Base & "_history[(" & JS_Base & "_head + " & Hist & " - 1) % " & Hist & "]";
                  when Tok_Future =>
                     --  @future needs the FASM sandboxed ON-TICK
                     --  prediction (save world, suppress IO, tick,
                     --  capture, restore) — no ALBW equivalent; fail
                     --  loud rather than read a stale slot.
                     raise Program_Error with
                       "TEMPORAL @future is not supported on ALBW " &
                       "(requires the FASM sandboxed ON-TICK " &
                       "prediction loop) — use @now/@past";
                  when Tok_Timeline =>
                     return Trim_Image (TSym.Aux_Offset);
                  when others =>
                     return JS_Base;
               end case;
            end;
         when AST_Find_Query =>
            if Upper_Text (Raw_Lexeme (Node.Token_Index)) = "FIND" then
               if Node.Left_Child > 0 then
                  return "ALB_REL_FIND1(" & Predicate_Id_Expr (Node.Left_Child) & ")";
               else
                  return "0";
               end if;
            else
               return "ALB_REL_HAS(" &
                 Predicate_Id_Expr (Node_Index_Value) & ", " &
                 Predicate_Arity_Expr (Node_Index_Value) & ", " &
                 Predicate_Arg1_Expr (Node_Index_Value) &
                 ", 0, 0, 0)";
            end if;
         when AST_Query =>
            if Node.Left_Child > 0 then
               return "ALB_REL_HAS(" &
                 Predicate_Id_Expr (Node.Left_Child) & ", " &
                 Predicate_Arity_Expr (Node.Left_Child) & ", " &
                 Predicate_Arg1_Expr (Node.Left_Child) &
                 ", 0, 0, 0)";
            else
               return "0";
            end if;
         when AST_Knows_Query =>
            if Node.Left_Child > 0 then
               return "ALB_REL_HAS(" &
                 Predicate_Id_Expr (Node.Left_Child) & ", " &
                 Predicate_Arity_Expr (Node.Left_Child) & ", " &
                 Predicate_Arg1_Expr (Node.Left_Child) &
                 ", 0, 0, 0)";
            else
               return "0";
            end if;
         when AST_File_Open =>
            return "ALB_Open(" & Expr (Node.Left_Child) & ", " &
              Expr (Node.Right_Child) & ")";
         when AST_File_Len =>
            return "ALB_FileLen(" & Expr (Node.Left_Child) & ")";
         when AST_File_Seek =>
            return "ALB_Seek(" & Expr (Node.Left_Child) & ", " &
              Expr (Node.Right_Child) & ")";
         when AST_File_Read =>
            return "ALB_Read(" & Expr (Node.Left_Child) & ", " &
              Expr (Node.Right_Child) & ")";
         when AST_Inline_Typescript_Expr =>
            return "(" & Enable_Inner_Text (Node.Token_Index) & ")";
         when others =>
            return "0";
      end case;
   end Expr;

   --  Re-emit an integer-valued expression in BigInt space. ALB S64/U64
   --  arithmetic is bit-exact (MALBR i64/u64 semantics); f64 loses the low
   --  bits past 2^53, which silently changes any downstream MOD/DIV result
   --  (deterministic LCGs like `seed*1103515245 MOD 2^31` are the canonical
   --  Rosetta pattern). Each leaf converts through albBig; inner
   --  +,-,*,/,MOD stay exact in bigint.
   function Int_Kind (K : Value_Kind) return Boolean is
   begin
      return K in VK_Number | VK_S32 | VK_U32 | VK_U64 | VK_S8 | VK_U8 |
        VK_S16 | VK_U16 | VK_HW8 | VK_HW16 | VK_HW32 | VK_Boolean;
   end Int_Kind;

   function Big_Expr (Node_Index_Value : Node_Index) return String is
      N : AST_Node;
      Op : Token_Kind;
   begin
      if Node_Index_Value = 0 then
         return "0n";
      end if;
      N := Tree (Node_Index_Value);
      case N.Kind is
         when AST_BinOp =>
            Op := (if N.Token_Index > 0
                   then Tokens (N.Token_Index).Kind
                   else Tok_Error);
            declare
               LB : constant String := Big_Expr (N.Left_Child);
               RB : constant String := Big_Expr (N.Right_Child);
            begin
               case Op is
                  when Tok_Plus =>
                     return "(" & LB & " + " & RB & ")";
                  when Tok_Minus =>
                     return "(" & LB & " - " & RB & ")";
                  when Tok_Mul =>
                     return "(" & LB & " * " & RB & ")";
                  when Tok_Div =>
                     return "(" & LB & " / " & RB & ")";
                  when Tok_Mod =>
                     return "(" & LB & " % " & RB & ")";
                  when Tok_And =>
                     return "(" & LB & " & " & RB & ")";
                  when Tok_Or =>
                     return "(" & LB & " | " & RB & ")";
                  when Tok_Xor =>
                     return "(" & LB & " ^ " & RB & ")";
                  when Tok_Shl =>
                     return "(" & LB & " << " & RB & ")";
                  when Tok_Shr =>
                     return "(" & LB & " >> " & RB & ")";
                  when others =>
                     return "albBig(" & Expr (Node_Index_Value) & ")";
               end case;
            end;
         when AST_Unary_Minus =>
            return "(-" & Big_Expr (N.Left_Child) & ")";
         when others =>
            --  Numbers, vars, array refs, calls, casts: evaluate normally
            --  then lift to bigint. albBig guards NaN/Infinity.
            return "albBig(" & Expr (Node_Index_Value) & ")";
      end case;
   end Big_Expr;

   procedure Emit_Mcp_Runtime is
      DQ : constant String := (1 => ASCII.Quotation);
      Props, Req, Args : Unbounded_String;
      T     : Unbounded_String;
      First : Boolean;
   begin
      --  stdout is the protocol channel while MCP is live: every
      --  PRINT/PRINT$ reroutes to stderr via albMcpActive.
      Line ("const albMcpQueue: string[] = [];");
      Line ("let albMcpPartial = '';");
      Line ("let albMcpStarted = false;");
      Line ("let albMcpAuto = false;");
      Line ("const albMcpInfo = { name: " & DQ &
            JSON_Escape (To_String (Mcp_Server_Name)) &
            DQ & ", version: " & DQ &
            JSON_Escape (To_String (Mcp_Server_Ver)) & DQ & " };");

      T := U ("const albMcpTools: Record<string, { description: string; inputSchema: object; fn: (a: Record<string, unknown>) => unknown }> = {");
      First := True;
      for I in 1 .. Mcp_Entry_Count loop
         if Mcp_Entries (I).Active
           and then not Mcp_Entries (I).Is_Resource
         then
            Mcp_Param_Specs (Mcp_Entries (I).Decl_Node, Props, Req, Args);
            if not First then Append (T, ","); end if;
            First := False;
            Append (T, DQ & JSON_Escape (To_String (Mcp_Entries (I).Wire_Name)) &
                    DQ & ": { description: " & DQ &
                    JSON_Escape (To_String (Mcp_Entries (I).Desc)) &
                    DQ & ", inputSchema: {""type"":""object"",""properties"":{" &
                    To_String (Props) & "},""required"":[" &
                    To_String (Req) & "]}, fn: (a) => ");
            if Mcp_Entries (I).Is_Function then
               Append (T, To_String (Mcp_Entries (I).JS_Name) &
                       "(" & To_String (Args) & ")");
            else
               Append (T, "{ " & To_String (Mcp_Entries (I).JS_Name) &
                       "(" & To_String (Args) & "); return 'ok'; }");
            end if;
            Append (T, " }");
         end if;
      end loop;
      Append (T, " };");
      Line (To_String (T));

      T := U ("const albMcpResources: Record<string, { name: string; mimeType: string; fn: () => unknown }> = {");
      First := True;
      for I in 1 .. Mcp_Entry_Count loop
         if Mcp_Entries (I).Active
           and then Mcp_Entries (I).Is_Resource
         then
            if not First then Append (T, ","); end if;
            First := False;
            Append (T, DQ & JSON_Escape (To_String (Mcp_Entries (I).Wire_Name)) &
                    DQ & ": { name: " & DQ &
                    JSON_Escape (To_String (Mcp_Entries (I).Display)) &
                    DQ & ", mimeType: " & DQ &
                    JSON_Escape (To_String (Mcp_Entries (I).Mime)) &
                    DQ & ", fn: () => " &
                    To_String (Mcp_Entries (I).JS_Name) & "() }");
         end if;
      end loop;
      Append (T, " };");
      Line (To_String (T));

      Line ("function albMcpSend(o: unknown): void { const g = globalThis as { [key: string]: unknown }; const p = g['process'] as { stdout?: { write(s: string): unknown } } | undefined; if (p && p.stdout) p.stdout.write(JSON.stringify(o) + '\n'); }");
      Line ("function albMcpHandle(line: string): void { const t = line.trim(); if (!t.length) return; let msg: { [key: string]: unknown }; try { msg = JSON.parse(t) as { [key: string]: unknown }; } catch { return; } if (!msg || typeof msg !== 'object') return; const method = typeof msg['method'] === 'string' ? msg['method'] as string : ''; const id = msg['id']; const hasId = id !== undefined && id !== null; const reply = (r: unknown): void => { if (hasId) albMcpSend({ jsonrpc: '2.0', id, result: r }); }; const fail = (c: number, m: string): void => { if (hasId) albMcpSend({ jsonrpc: '2.0', id, error: { code: c, message: m } }); }; if (method === 'initialize') { reply({ protocolVersion: '2025-03-26', capabilities: { tools: {}, resources: {} }, serverInfo: albMcpInfo }); return; } if (method === 'notifications/initialized' || method === 'initialized') return; if (method === 'ping') { reply({}); return; } if (method === 'tools/list') { reply({ tools: Object.keys(albMcpTools).map((n) => ({ name: n, description: albMcpTools[n].description, inputSchema: albMcpTools[n].inputSchema })) }); return; } if (method === 'tools/call') { const p = msg['params'] as { [key: string]: unknown } | undefined; const n = p && typeof p['name'] === 'string' ? p['name'] as string : ''; const tool = albMcpTools[n]; if (!tool) { fail(-32602, 'unknown tool: ' + n); return; } const mcpArgs = (p && p['arguments'] ? p['arguments'] : {}) as Record<string, unknown>; const mcpReq = (tool.inputSchema['required'] as string[] | undefined) || []; for (const mcpRn of mcpReq) { if (!(mcpRn in mcpArgs)) { fail(-32602, 'missing required arg: ' + mcpRn); return; } } const mcpProps = (tool.inputSchema['properties'] as { [key: string]: { type?: string } } | undefined) || {}; for (const mcpK of Object.keys(mcpArgs)) { const mcpT = mcpProps[mcpK] ? mcpProps[mcpK].type : undefined; const mcpV = mcpArgs[mcpK]; if ((mcpT === 'integer' || mcpT === 'number') && (typeof mcpV !== 'number' || !isFinite(mcpV))) { fail(-32602, 'bad arg type: ' + mcpK); return; } if (mcpT === 'string' && typeof mcpV !== 'string') { fail(-32602, 'bad arg type: ' + mcpK); return; } if (mcpT === 'boolean' && typeof mcpV !== 'boolean') { fail(-32602, 'bad arg type: ' + mcpK); return; } } try { const r = tool.fn(mcpArgs); reply({ content: [{ type: 'text', text: typeof r === 'string' ? r : JSON.stringify(r === undefined ? null : r) }] }); } catch (err) { reply({ content: [{ type: 'text', text: 'tool error: ' + (err instanceof Error ? err.message : String(err)) }], isError: true }); } return; } if (method === 'resources/list') { reply({ resources: Object.keys(albMcpResources).map((u) => ({ uri: u, name: albMcpResources[u].name, mimeType: albMcpResources[u].mimeType })) }); return; } if (method === 'resources/read') { const p = msg['params'] as { [key: string]: unknown } | undefined; const u = p && typeof p['uri'] === 'string' ? p['uri'] as string : ''; const res = albMcpResources[u]; if (!res) { fail(-32602, 'unknown resource: ' + u); return; } try { reply({ contents: [{ uri: u, mimeType: res.mimeType, text: String(res.fn()) }] }); } catch (err) { fail(-32603, 'resource error: ' + (err instanceof Error ? err.message : String(err))); } return; } if (method === 'prompts/list') { reply({ prompts: [] }); return; } if (method.indexOf('notifications/') === 0) return; fail(-32601, 'method not found: ' + method); }");
      Line ("function albMcpStart(): void { if (albMcpStarted) return; albMcpStarted = true; const g = globalThis as { [key: string]: unknown }; const p = g['process'] as { stdin?: { setEncoding(e: string): void; resume(): void; unref?(): void; on(ev: string, cb: (c: string) => void): void }; versions?: { node?: unknown } } | undefined; if (!p || !p.versions || !p.versions.node || !p.stdin) return; p.stdin.setEncoding('utf8'); p.stdin.on('data', (chunk: string) => { albMcpActive = true; albMcpPartial += chunk; let i = albMcpPartial.indexOf('\n'); while (i >= 0) { albMcpQueue.push(albMcpPartial.slice(0, i)); albMcpPartial = albMcpPartial.slice(i + 1); i = albMcpPartial.indexOf('\n'); } if (albMcpAuto) albMcpPump(); }); p.stdin.on('end', () => { if (albMcpPartial.trim().length) albMcpQueue.push(albMcpPartial); albMcpPartial = ''; if (albMcpAuto) albMcpPump(); }); if (!albMcpAuto && typeof p.stdin.unref === 'function') p.stdin.unref(); p.stdin.resume(); }");
      Line ("function albMcpPump(): void { albMcpStart(); while (albMcpQueue.length > 0) { const l = albMcpQueue.shift(); if (l !== undefined) albMcpHandle(l); } }");
      Line ("function albMcpListen(): void { albMcpAuto = true; albMcpStart(); const g = globalThis as { [key: string]: unknown }; const p = g['process'] as { stdin?: { ref?(): void } } | undefined; if (p && p.stdin && typeof p.stdin.ref === 'function') p.stdin.ref(); albMcpPump(); }");
   end Emit_Mcp_Runtime;

   procedure Emit_Runtime is
   begin
      Rt_Start := Out_Line_N + 1;
      Line ("/* Generated by ALBW - AdaLogic BASIC to TypeScript */");
      Line ("'use strict';");
      New_Line_Emit;
      Line ("type ALBValue = number | boolean | string | bigint;");
      Line ("type ALBNumericArray = Int8Array | Uint8Array | Int16Array | Uint16Array | Int32Array | Uint32Array | Float64Array | BigInt64Array | BigUint64Array;");
      Line ("const albKeys = new Uint8Array(512);");
      Line ("const albMouseButtons = new Uint8Array(8);");
      Line ("const albVas = new Int32Array(65536);");
      Line ("const albSaveStore: Record<string, string> = Object.create(null);");
      Line ("const albGcAlive = new Uint8Array(1024);");
      Line ("let albArenaUsed = 0;");
      Line ("const albArenaCap = 1048576;");
      Line ("const albArenaMark = new Float64Array(1024);");
      Line ("const albGcRefs = new Uint16Array(1024);");
      Line ("const albGcChildA = new Uint16Array(1024);");
      Line ("const albGcChildB = new Uint16Array(1024);");
      Line ("const albGcChildC = new Uint16Array(1024);");
      Line ("const albGcChildD = new Uint16Array(1024);");
      Line ("const albFactLive = new Uint8Array(1024);");
      Line ("const albFactKey = new Array<string>(1024).fill('');");
      Line ("const albFactValue = new Array<ALBValue>(1024).fill(0);");
      Line ("const albRelLive = new Uint8Array(1024);");
      Line ("const albRelPred = new Uint16Array(1024);");
      Line ("const albRelArity = new Uint8Array(1024);");
      Line ("const albRelArg1 = new Int32Array(1024);");
      Line ("const albRelArg2 = new Int32Array(1024);");
      Line ("const albRelArg3 = new Int32Array(1024);");
      Line ("const albRelArg4 = new Int32Array(1024);");
      Line ("const albRelValue = new Int32Array(1024);");
      Line ("const albRuleHeadPred = new Uint16Array(128);");
      Line ("const albRuleFlags = new Uint8Array(128);");
      Line ("const albRuleBodyLen = new Uint8Array(128);");
      Line ("const albRuleBodyPred = new Uint16Array(1024);");
      Line ("const albRuleBodyArgMode = new Uint8Array(1024);");
      Line ("const albRuleBodyArgConst = new Int32Array(1024);");
      Line ("const albRuleCutPos = new Int16Array(128).fill(-1);");
      Line ("let albRuleCount = 0;");
      Line ("const albFileLive = new Uint8Array(64);");
      Line ("const albFileMode = new Array<string>(64).fill('');");
      Line ("const albFileName = new Array<string>(64).fill('');");
      Line ("const albFileBuffer = new Array<string>(64).fill('');");
      Line ("const albFileCursor = new Int32Array(64);");
      Line ("let albCanvas: HTMLCanvasElement | null = null;");
      Line ("let albCtx: CanvasRenderingContext2D | null = null;");
      Line ("let albConsoleDisabled = " &
            (if No_Console_Overlay then "true" else "false") & ";");
      Line ("let albConsoleRoot: HTMLDivElement | null = null;");
      Line ("let albConsoleOutput: HTMLPreElement | null = null;");
      Line ("const albTextRows: string[] = [''];");
      Line ("let albTextCursorX = 1;");
      Line ("let albTextCursorY = 1;");
      Line ("let albAudioCtx: AudioContext | null = null;");
      Line ("const albActiveMusicVoices: Array<[OscillatorNode, GainNode]> = [];");
      Line ("let albCurrentColor = '#ffffff';");
      Line ("let albColorValue = 0xffffffff;");
      Line ("let albBaseWidth = 320;");
      Line ("let albBaseHeight = 200;");
      Line ("let albWindowWidth = 320;");
      Line ("let albWindowHeight = 200;");
      Line ("let albVirtualWidth = 320;");
      Line ("let albVirtualHeight = 200;");
      Line ("let albScaleX = 1;");
      Line ("let albScaleY = 1;");
      Line ("let albOffsetX = 0;");
      Line ("let albOffsetY = 0;");
      Line ("let albOriginX = 0;");
      Line ("let albOriginY = 0;");
      Line ("let albAlphaChannel = 0;");
      Line ("let albAlphaValue = 255;");
      Line ("let albStretchy = false;");
      Line ("let albResizable = true;");
      Line ("let albRunning = true;");
      Line ("var albMcpActive = false;");
      Line ("let albShutdownDone = false;");
      Line ("let albMouseX = 0;");
      Line ("let albMouseY = 0;");
      Line ("let albMouseWheel = 0;");
      Line ("let albDelayUntil = 0;");
      Line ("let albFrameInterval = 16;");
      Line ("let albLastFrame = 0;");
      Line ("let ALB_ON_TICK = (): void => {};");
      Line ("let ALB_ON_PAINT = (): void => {};");
      Line ("let ALB_ON_KEY = (): void => {};");
      Line ("const albWasmBindings: Record<string, (...args: any[]) => any> = Object.create(null);");
      Line ("const albWasmLoaders: Array<Promise<void>> = [];");
      Line ("const ALB_WASM_HOST_IMPORTS: Record<string, Record<string, (...args: any[]) => any>> = { alb: Object.create(null) };");
      Line ("const albCompatExports: Record<string, (...args: any[]) => any> = Object.create(null);");
      Line ("let albCompatTick = 0;");
      Line ("let ALB_STATIC_Active_Lut: Uint32Array | null = null;");
      Line ("let ALB_STATIC_Active_Visual: unknown = null;");
      Line ("let ALB_STATIC_Active_Context: unknown = null;");
      Line ("let ALB_STATIC_Active_Context_Used = false;");
      Line ("let albNextProcessHandle = 1;");
      Line ("const albProcessTable: Record<number, any> = Object.create(null);");
      Line ("const albProcessMonitor: Record<string, number> = Object.create(null);");
      Line ("let albNextNetworkHandle = 1;");
      Line ("const albNetworkTable: Record<number, any> = Object.create(null);");
      Line ("let albNextSnifferHandle = 1;");
      Line ("const albSnifferTable: Record<number, any> = Object.create(null);");
      Line ("const albNetworkBus: Record<string, Uint8Array[]> = Object.create(null);");
      Line ("const albFirewallStack: any[] = [];");
      Line ("const albWarnedKeys = new Set<string>();");
      Line ("let albCurrentFont = " &
            (if No_Console_Overlay
             then """8px Consolas, 'Courier New', monospace"""
             else """16px Consolas, 'Courier New', monospace""") & ";");
      New_Line_Emit;
      Line ("function ALB_FATAL(err: unknown): never { albRunning = false; const message = err instanceof Error ? err.message : String(err); console.error('ALBW fatal:', err); if (typeof document !== 'undefined') { let node = document.getElementById('alb-fatal'); if (!node) { node = document.createElement('pre'); node.id = 'alb-fatal'; node.style.whiteSpace = 'pre-wrap'; node.style.background = '#22090a'; node.style.color = '#ffd7d7'; node.style.padding = '12px'; node.style.margin = '12px'; document.body.appendChild(node); } node.textContent = message; } throw (err instanceof Error ? err : new Error(message)); }");
      Line ("function ALB_WARN_ONCE(key: string, message: string): void { if (albWarnedKeys.has(key)) return; albWarnedKeys.add(key); console.warn('ALBW:', message); }");
      Line ("function ALB_Text(v: ALBValue): string { const n = Number(v); if (typeof v === 'number' && Number.isNaN(n)) return 'nan'; if (typeof v === 'number' && !Number.isFinite(n)) return n < 0 ? '-inf' : 'inf'; if (typeof v === 'number' && Number.isInteger(n) && Math.abs(n) >= 1e15) return BigInt(n).toString(); return String(v); }");
      Line ("function albEnsureTextRow(row: number): void { while (albTextRows.length < row) albTextRows.push(''); }");
      Line ("function albRenderTextConsole(): void { if (albConsoleDisabled || typeof document === 'undefined') return; if (!albConsoleRoot || !albConsoleOutput) return; albEnsureTextRow(albTextCursorY); albConsoleOutput.textContent = albTextRows.join('\n'); albConsoleRoot.scrollTop = albConsoleRoot.scrollHeight; }");
      Line ("function albRefreshTextConsoleLayout(): void { if (albConsoleDisabled || !albConsoleRoot) return; if (albCanvas) { albConsoleRoot.style.position = 'fixed'; albConsoleRoot.style.left = '0'; albConsoleRoot.style.right = '0'; albConsoleRoot.style.top = 'auto'; albConsoleRoot.style.bottom = '0'; albConsoleRoot.style.height = '40vh'; albConsoleRoot.style.maxHeight = '40vh'; albConsoleRoot.style.borderTop = '1px solid #1b2f4f'; albConsoleRoot.style.display = 'block'; } else { albConsoleRoot.style.position = 'fixed'; albConsoleRoot.style.left = '0'; albConsoleRoot.style.right = '0'; albConsoleRoot.style.top = '0'; albConsoleRoot.style.bottom = '0'; albConsoleRoot.style.height = '100vh'; albConsoleRoot.style.maxHeight = 'none'; albConsoleRoot.style.borderTop = 'none'; albConsoleRoot.style.display = 'block'; } }");
      Line ("function albEnsureTextConsole(): void { if (albConsoleDisabled || typeof document === 'undefined' || !document.body) return; if (!albConsoleRoot) { albConsoleRoot = document.createElement('div'); albConsoleRoot.id = 'alb-console'; albConsoleRoot.style.boxSizing = 'border-box'; albConsoleRoot.style.padding = '14px 16px'; albConsoleRoot.style.overflow = 'auto'; albConsoleRoot.style.background = '#050511'; albConsoleRoot.style.color = '#f5f7ff'; albConsoleRoot.style.fontFamily = 'Consolas, Courier New, monospace'; albConsoleRoot.style.fontSize = '15px'; albConsoleRoot.style.lineHeight = '1.4'; albConsoleRoot.style.whiteSpace = 'pre-wrap'; albConsoleRoot.style.wordBreak = 'break-word'; albConsoleRoot.style.zIndex = '10'; albConsoleOutput = document.createElement('pre'); albConsoleOutput.id = 'alb-console-output'; albConsoleOutput.style.margin = '0'; albConsoleOutput.style.whiteSpace = 'pre-wrap'; albConsoleOutput.style.wordBreak = 'break-word'; albConsoleOutput.style.minHeight = '100%'; albConsoleRoot.appendChild(albConsoleOutput); document.body.appendChild(albConsoleRoot); } albRefreshTextConsoleLayout(); albRenderTextConsole(); }");
      Line ("function albWriteText(text: string): void { for (const ch of text) { if (ch === '\r') continue; if (ch === '\n') { albTextCursorY += 1; albTextCursorX = 1; albEnsureTextRow(albTextCursorY); continue; } albEnsureTextRow(albTextCursorY); const row = albTextCursorY - 1; const col = Math.max(1, albTextCursorX | 0) - 1; const line = albTextRows[row] ?? ''; const padded = col > line.length ? line.padEnd(col, ' ') : line; albTextRows[row] = padded.slice(0, col) + ch + (col < padded.length ? padded.slice(col + 1) : ''); albTextCursorX = col + 2; } }");
      Line ("function albConsoleWrite(text: string, newline: boolean): void { if (albConsoleDisabled) return; albEnsureTextConsole(); albWriteText(text); if (newline) { albTextCursorY += 1; albTextCursorX = 1; albEnsureTextRow(albTextCursorY); } albRenderTextConsole(); }");
      Line ("function albPromptContext(): string { const lines = albTextRows.join('\n').replace(/\\s+$/u, '').split('\n'); const tail = lines.slice(-18).join('\n').trim(); if (!tail) return ''; return tail.length > 1800 ? ('...' + tail.slice(tail.length - 1797)) : tail; }");
      Line ("function albStdout(text: string, newline: boolean): void { const g = globalThis as { [key: string]: unknown }; const nodeProcess = g['process'] as { versions?: { node?: unknown }; stdout?: { write(s: string, enc: string): unknown }; stderr?: { write(s: string, enc: string): unknown } } | undefined; if (nodeProcess && nodeProcess.versions && nodeProcess.versions.node) { const sink = (albMcpActive && nodeProcess.stderr) ? nodeProcess.stderr : nodeProcess.stdout; if (sink) { sink.write(text + (newline ? '\n' : ''), 'latin1'); } } else { console.log(text); } }");
      Line ("function ALB_PRINT(v: ALBValue): void { if (albConsoleDisabled) return; const text = String(v); albStdout(text, true); albConsoleWrite(text, true); }");
      Line ("function ALB_PRINT_RAW(v: ALBValue): void { if (albConsoleDisabled) return; const text = String(v); albStdout(text, true); albConsoleWrite(text, false); }");
      Line ("let albStdinLines: string[] | null = null;");
      Line ("function albNextStdinLine(): string { if (albStdinLines === null) { albStdinLines = []; const g = globalThis as { [key: string]: unknown }; const nodeProcess = g['process'] as { versions?: { node?: unknown } } | undefined; if (nodeProcess && nodeProcess.versions && nodeProcess.versions.node) { try { const req = eval('require') as (name: string) => { readFileSync(fd: number, enc: string): unknown }; const data = String(req('fs').readFileSync(0, 'latin1')); albStdinLines = data.split(/\r?\n/u); while (albStdinLines.length > 0 && albStdinLines[albStdinLines.length - 1] === '') albStdinLines.pop(); } catch {} } } return albStdinLines.length > 0 ? String(albStdinLines.shift()) : ''; }");
      Line ("function ALB_PROMPT_TEXT(promptText: ALBValue = ''): string { const prompt = String(promptText); albEnsureTextConsole(); if (prompt.length > 0) albConsoleWrite(prompt, true); if (typeof window === 'undefined' || typeof window.prompt !== 'function') { if (prompt.length > 0) albStdout(prompt, false); return albNextStdinLine(); } const promptBody = albPromptContext() || prompt; const response = String(window.prompt(promptBody) ?? ''); albConsoleWrite('> ' + response, true); return response; }");
      Line ("function ALB_READLINE_TEXT(): string { return ALB_PROMPT_TEXT(''); }");
      Line ("function ALB_LOCATE(x: number, y: number): void { if (albConsoleDisabled) return; albEnsureTextConsole(); albTextCursorX = Math.max(1, x | 0); albTextCursorY = Math.max(1, y | 0); albEnsureTextRow(albTextCursorY); albRenderTextConsole(); }");
      Line ("function albU8(v: ALBValue): number { return Number(v) & 0xff; }");
      Line ("function albU16(v: ALBValue): number { return Number(v) & 0xffff; }");
      Line ("function albU32(v: ALBValue): number { return Number(v) >>> 0; }");
      Line ("function albU64(v: ALBValue): number { const n = Math.trunc(Number(v)); if (!Number.isFinite(n)) return 0; if (n >= 0 && n < 18446744073709551616) return n; return Number(BigInt.asUintN(64, BigInt(n))); }");
      Line ("function albS64(v: ALBValue): number { const n = Math.trunc(Number(v)); if (!Number.isFinite(n)) return 0; if (n >= -9223372036854775808 && n <= 9223372036854775807) return n; return Number(BigInt.asIntN(64, BigInt(n))); }");
      Line ("function albI8(v: ALBValue): number { const n = Number(v) & 0xff; return n >= 0x80 ? n - 0x100 : n; }");
      Line ("function albI16(v: ALBValue): number { const n = Number(v) & 0xffff; return n >= 0x8000 ? n - 0x10000 : n; }");
      Line ("function albI32(v: ALBValue): number { return Number(v) | 0; }");
      Line ("function U8(v: ALBValue): number { return albU8(v); }");
      Line ("function U16(v: ALBValue): number { return albU16(v); }");
      Line ("function S8(v: ALBValue): number { return albI8(v); }");
      Line ("function I8(v: ALBValue): number { return albI8(v); }");
      Line ("function S16(v: ALBValue): number { return albI16(v); }");
      Line ("function I16(v: ALBValue): number { return albI16(v); }");
      Line ("function U32(v: ALBValue): number { return albU32(v); }");
      Line ("function U64(v: ALBValue): number { return albU64(v); }");
      Line ("function S64(v: ALBValue): number { return albS64(v); }");
      Line ("function I64(v: ALBValue): number { return albS64(v); }");
      Line ("function U128(v: ALBValue): bigint { return BigInt(Math.trunc(Number(v))); }");
      Line ("function S32(v: ALBValue): number { return albI32(v); }");
      Line ("function I32(v: ALBValue): number { return albI32(v); }");
      Line ("function HW8(v: ALBValue): number { return albI32(v); }");
      Line ("function HW16(v: ALBValue): number { return albI32(v); }");
      Line ("function HW32(v: ALBValue): number { return albI32(v); }");
      Line ("function F64(v: ALBValue): number { return Number(v); }");
      Line ("const ALB_PURE_NUM_BITS = 21;");
      Line ("const ALB_PURE_NUM_MOD = 1 << ALB_PURE_NUM_BITS;");
      Line ("const ALB_PURE_NUM_SIGN = 1 << (ALB_PURE_NUM_BITS - 1);");
      Line ("const ALB_PURE_DEN_LIMIT = 0x7fffffff;");
      Line ("function albPureAbs(v: number): number { return v < 0 ? 0 - v : v; }");
      Line ("function albPureIsPacked(v: ALBValue): boolean { return Number.isFinite(Number(v)) && Math.trunc(Number(v)) >= ALB_PURE_NUM_MOD; }");
      Line ("function albPureGcd(a: number, b: number): number { let x = Math.trunc(albPureAbs(a)); let y = Math.trunc(albPureAbs(b)); while (y !== 0) { const t = x % y; x = y; y = t; } return x === 0 ? 1 : x; }");
      Line ("function albPurePack(num: number, den: number): number { let n = Math.trunc(num); let d = Math.trunc(den); if (d === 0) return ALB_PURE_NUM_MOD; if (d < 0) { n = 0 - n; d = 0 - d; } if (n === 0) return ALB_PURE_NUM_MOD; let g = albPureGcd(n, d); n = Math.trunc(n / g); d = Math.trunc(d / g); const maxNum = ALB_PURE_NUM_SIGN - 1; while ((albPureAbs(n) > maxNum || d > ALB_PURE_DEN_LIMIT) && d > 1) { n = Math.trunc(n / 2); d = Math.max(1, Math.trunc(d / 2)); g = albPureGcd(n, d); n = Math.trunc(n / g); d = Math.trunc(d / g); } const enc = n < 0 ? (ALB_PURE_NUM_MOD + n) : n; return d * ALB_PURE_NUM_MOD + enc; }");
      Line ("function PURE(num: ALBValue, den: ALBValue = 1): number { return albPurePack(Number(num), Number(den)); }");
      Line ("function PURE_NUM(v: ALBValue): number { const pv = Math.trunc(Number(v)); if (!albPureIsPacked(pv)) return pv; const enc = pv % ALB_PURE_NUM_MOD; return enc >= ALB_PURE_NUM_SIGN ? enc - ALB_PURE_NUM_MOD : enc; }");
      Line ("function PURE_DEN(v: ALBValue): number { const pv = Math.trunc(Number(v)); if (!albPureIsPacked(pv)) return 1; const den = Math.trunc(pv / ALB_PURE_NUM_MOD); return den <= 0 ? 1 : den; }");
      Line ("function PURE_ADD(a: ALBValue, b: ALBValue): number { const an = PURE_NUM(a); const ad = PURE_DEN(a); const bn = PURE_NUM(b); const bd = PURE_DEN(b); const g = albPureGcd(ad, bd); const leftMul = Math.trunc(bd / g); const rightMul = Math.trunc(ad / g); return albPurePack(an * leftMul + bn * rightMul, ad * leftMul); }");
      Line ("function PURE_SUB(a: ALBValue, b: ALBValue): number { const an = PURE_NUM(a); const ad = PURE_DEN(a); const bn = PURE_NUM(b); const bd = PURE_DEN(b); const g = albPureGcd(ad, bd); const leftMul = Math.trunc(bd / g); const rightMul = Math.trunc(ad / g); return albPurePack(an * leftMul - bn * rightMul, ad * leftMul); }");
      Line ("function PURE_MUL(a: ALBValue, b: ALBValue): number { let an = PURE_NUM(a); let ad = PURE_DEN(a); let bn = PURE_NUM(b); let bd = PURE_DEN(b); const g1 = albPureGcd(an, bd); an = Math.trunc(an / g1); bd = Math.trunc(bd / g1); const g2 = albPureGcd(bn, ad); bn = Math.trunc(bn / g2); ad = Math.trunc(ad / g2); return albPurePack(an * bn, ad * bd); }");
      Line ("function PURE_DIV(a: ALBValue, b: ALBValue): number { let an = PURE_NUM(a); let ad = PURE_DEN(a); let bn = PURE_NUM(b); let bd = PURE_DEN(b); if (bn === 0) return ALB_PURE_NUM_MOD; if (bn < 0) { bn = 0 - bn; bd = 0 - bd; } const g1 = albPureGcd(an, bn); an = Math.trunc(an / g1); bn = Math.trunc(bn / g1); const g2 = albPureGcd(bd, ad); bd = Math.trunc(bd / g2); ad = Math.trunc(ad / g2); return albPurePack(an * bd, ad * bn); }");
      Line ("function PURE_POW(a: ALBValue, b: ALBValue): number { const expNum = PURE_NUM(b); const expDen = PURE_DEN(b); if (expDen === 1) { if (expNum === 0) return PURE(1, 1); let factor = a; let power = expNum; let result = PURE(1, 1); if (power < 0) { if (PURE_NUM(a) === 0) return PURE(0, 1); factor = PURE_DIV(PURE(1, 1), a); power = 0 - power; } while (power > 0) { if ((power & 1) !== 0) result = PURE_MUL(result, factor); power = Math.trunc(power / 2); if (power > 0) factor = PURE_MUL(factor, factor); } return result; } const av = PURE_NUM(a) / PURE_DEN(a); const bv = expNum / expDen; const pv = Math.pow(av, bv); return albPurePack(Math.round(pv * 1000000), 1000000); }");
      Line ("function albPowInt(base: number, exp: number): number { let result = 1; let factor = Math.trunc(base); let power = Math.trunc(exp); if (power < 0) { if (factor === 1) return 1; if (factor === -1) return (power & 1) !== 0 ? -1 : 1; return 0; } while (power > 0) { if ((power & 1) !== 0) result *= factor; power = Math.trunc(power / 2); if (power > 0) factor *= factor; } return result; }");
      Line ("function ALB_POW(a: ALBValue, b: ALBValue): number { const base = Number(a); const exp = Number(b); if (Number.isFinite(base) && Number.isFinite(exp) && Math.trunc(base) === base && Math.trunc(exp) === exp) return albPowInt(base, exp); return Math.pow(base, exp); }");
      Line ("function albDiv(a: ALBValue, b: ALBValue): number { const dv = Number(b); return dv === 0 ? 0 : Math.trunc(Number(a) / dv); }");
      Line ("function albBig(v: ALBValue): bigint { if (typeof v === 'bigint') return v; const n = Number(v); return Number.isFinite(n) ? BigInt(Math.trunc(n)) : 0n; }");
      Line ("function albNum(v: ALBValue): any { return typeof v === 'bigint' ? Number(v) : v; }");
      Line ("function albDivB(a: bigint, b: bigint): number { return b === 0n ? 0 : Number(a / b); }");
      Line ("function albModB(a: bigint, b: bigint): number { return b === 0n ? 0 : Number(a % b); }");
      Line ("function albMod(a: ALBValue, b: ALBValue): number { const dv = Number(b); return dv === 0 ? 0 : (Number(a) % dv); }");
      Line ("function albColorToCss(c: number): string { const v = c >>> 0; const r = (v >> 16) & 255; const g = (v >> 8) & 255; const b = v & 255; let a = (v >> 24) & 255; if (a === 0) a = albAlphaChannel > 0 ? albAlphaValue : 255; return `rgba(${r}, ${g}, ${b}, ${Math.max(0, Math.min(255, a)) / 255})`; }");
      Line ("function albEnsureAudio(): AudioContext { if (!albAudioCtx) albAudioCtx = new AudioContext(); if (albAudioCtx.state === 'suspended') void albAudioCtx.resume(); return albAudioCtx; }");
      Line ("function albUpdateMouseFromEvent(ev: MouseEvent): void { if (!albCanvas) return; const rect = albCanvas.getBoundingClientRect(); const px = ev.clientX - rect.left; const py = ev.clientY - rect.top; albMouseX = Math.trunc((px - albOffsetX) / (albScaleX || 1)); albMouseY = Math.trunc((py - albOffsetY) / (albScaleY || 1)); }");
      Line ("function albApplyCurrentFont(): void { if (!albCtx) return; albCtx.font = albCurrentFont; albCtx.textBaseline = 'top'; }");
      Line ("function albKeyState(code: number): number { return code > 0 && code < albKeys.length ? (albKeys[code | 0] | 0) : 0; }");
      Line ("function albStopMusicVoices(): void { while (albActiveMusicVoices.length > 0) { const pair = albActiveMusicVoices.pop(); if (!pair) continue; const osc = pair[0]; const gain = pair[1]; try { osc.onended = null; osc.stop(); } catch { } try { osc.disconnect(); } catch { } try { gain.disconnect(); } catch { } } }");
      Line ("function albPcSpeakerTone(ctx: AudioContext, hz: number, start: number, dur: number): void { const osc = ctx.createOscillator(); const gain = ctx.createGain(); const freq = Math.max(32, Math.min(12000, Math.round(hz))); const endAt = start + Math.max(0.01, dur); const peakAt = start + Math.min(0.0025, dur * 0.2); const holdAt = start + Math.max(0.004, dur * 0.7); const voice: [OscillatorNode, GainNode] = [osc, gain]; albActiveMusicVoices.push(voice); osc.type = 'square'; osc.frequency.setValueAtTime(freq, start); gain.gain.setValueAtTime(0.0001, start); gain.gain.exponentialRampToValueAtTime(0.05, peakAt); gain.gain.setValueAtTime(0.05, holdAt); gain.gain.exponentialRampToValueAtTime(0.0001, start + Math.max(0.008, dur * 0.96)); osc.connect(gain).connect(ctx.destination); osc.start(start); osc.stop(endAt); osc.onended = () => { const idx = albActiveMusicVoices.indexOf(voice); if (idx >= 0) albActiveMusicVoices.splice(idx, 1); try { osc.disconnect(); } catch { } try { gain.disconnect(); } catch { } }; }");
      Line ("function albUpdateMetrics(): void {");
      Indent_Level := Indent_Level + 1;
      Line ("if (!albCanvas) return;");
      Line ("albWindowWidth = albCanvas.clientWidth || albBaseWidth;");
      Line ("albWindowHeight = albCanvas.clientHeight || albBaseHeight;");
      Line ("if (albCanvas.width !== albWindowWidth) albCanvas.width = albWindowWidth;");
      Line ("if (albCanvas.height !== albWindowHeight) albCanvas.height = albWindowHeight;");
      Line ("if (albStretchy) { albScaleX = albWindowWidth / albBaseWidth; albScaleY = albWindowHeight / albBaseHeight; albVirtualWidth = albBaseWidth; albVirtualHeight = albBaseHeight; albOffsetX = 0; albOffsetY = 0; } else { const scale = Math.min(albWindowWidth / albBaseWidth, albWindowHeight / albBaseHeight); albScaleX = scale; albScaleY = scale; albVirtualWidth = albBaseWidth; albVirtualHeight = albBaseHeight; albOffsetX = Math.trunc((albWindowWidth - albBaseWidth * scale) * 0.5); albOffsetY = Math.trunc((albWindowHeight - albBaseHeight * scale) * 0.5); }");
      Indent_Level := Indent_Level - 1;
      Line ("}");
      Line ("function albMapKeyEvent(ev: KeyboardEvent): number {");
      Indent_Level := Indent_Level + 1;
      Line ("switch (ev.code) {");
      Indent_Level := Indent_Level + 1;
      Line ("case 'KeyA': return 4;");
      Line ("case 'KeyB': return 5;");
      Line ("case 'KeyC': return 6;");
      Line ("case 'KeyD': return 7;");
      Line ("case 'KeyE': return 8;");
      Line ("case 'KeyF': return 9;");
      Line ("case 'KeyG': return 10;");
      Line ("case 'KeyH': return 11;");
      Line ("case 'KeyI': return 12;");
      Line ("case 'KeyJ': return 13;");
      Line ("case 'KeyK': return 14;");
      Line ("case 'KeyL': return 15;");
      Line ("case 'KeyM': return 16;");
      Line ("case 'KeyN': return 17;");
      Line ("case 'KeyO': return 18;");
      Line ("case 'KeyP': return 19;");
      Line ("case 'KeyQ': return 20;");
      Line ("case 'KeyR': return 21;");
      Line ("case 'KeyS': return 22;");
      Line ("case 'KeyT': return 23;");
      Line ("case 'KeyU': return 24;");
      Line ("case 'KeyV': return 25;");
      Line ("case 'KeyW': return 26;");
      Line ("case 'KeyX': return 27;");
      Line ("case 'KeyY': return 28;");
      Line ("case 'KeyZ': return 29;");
      Line ("case 'Digit1': return 30;");
      Line ("case 'Digit2': return 31;");
      Line ("case 'Digit3': return 32;");
      Line ("case 'Digit4': return 33;");
      Line ("case 'Digit5': return 34;");
      Line ("case 'Digit6': return 35;");
      Line ("case 'Digit7': return 36;");
      Line ("case 'Digit8': return 37;");
      Line ("case 'Digit9': return 38;");
      Line ("case 'Digit0': return 39;");
      Line ("case 'Enter': return 40;");
      Line ("case 'Escape': return 41;");
      Line ("case 'Backspace': return 42;");
      Line ("case 'Tab': return 43;");
      Line ("case 'Space': return 44;");
      Line ("case 'Minus': return 45;");
      Line ("case 'Equal': return 46;");
      Line ("case 'BracketLeft': return 47;");
      Line ("case 'BracketRight': return 48;");
      Line ("case 'Backslash': return 49;");
      Line ("case 'Semicolon': return 51;");
      Line ("case 'Quote': return 52;");
      Line ("case 'Backquote': return 53;");
      Line ("case 'Comma': return 54;");
      Line ("case 'Period': return 55;");
      Line ("case 'Slash': return 56;");
      Line ("case 'ArrowRight': return 79;");
      Line ("case 'ArrowLeft': return 80;");
      Line ("case 'ArrowDown': return 81;");
      Line ("case 'ArrowUp': return 82;");
      Line ("case 'ShiftLeft': return 225;");
      Line ("case 'ShiftRight': return 229;");
      Line ("case 'ControlLeft': return 224;");
      Line ("case 'ControlRight': return 228;");
      Line ("case 'AltLeft': return 226;");
      Line ("case 'AltRight': return 230;");
      Line ("default: return 0;");
      Indent_Level := Indent_Level - 1;
      Line ("}");
      Indent_Level := Indent_Level - 1;
      Line ("}");
      Line ("function albHandleKey(ev: KeyboardEvent, down: number): void {");
      Indent_Level := Indent_Level + 1;
      Line ("const sc = albMapKeyEvent(ev);");
      Line ("if (sc > 0 && sc < albKeys.length) { albKeys[sc] = down; ev.preventDefault(); try { ALB_ON_KEY(); } catch (err) { ALB_FATAL(err); } }");
      Indent_Level := Indent_Level - 1;
      Line ("}");
      Line ("function ALB_CREATE_WINDOW(title: string, width: number, height: number): void {");
      Indent_Level := Indent_Level + 1;
      Line ("albBaseWidth = Math.max(1, width | 0); albBaseHeight = Math.max(1, height | 0); albVirtualWidth = albBaseWidth; albVirtualHeight = albBaseHeight;");
      Line ("document.title = title;");
      Line ("if (!albCanvas) { albCanvas = document.createElement('canvas'); albCanvas.width = albBaseWidth; albCanvas.height = albBaseHeight; albCanvas.tabIndex = 0; albCanvas.style.display = 'block'; albCanvas.style.background = '#000'; albCanvas.style.margin = '0 auto'; albCanvas.style.outline = 'none'; albCanvas.style.touchAction = 'none'; document.body.style.margin = '0'; document.body.style.background = '#000'; document.body.style.overflow = 'hidden'; document.body.appendChild(albCanvas); albCtx = albCanvas.getContext('2d', { alpha: true }); window.addEventListener('keydown', (ev) => { albHandleKey(ev, 1); }); window.addEventListener('keyup', (ev) => { albHandleKey(ev, 0); }); window.addEventListener('blur', () => { albKeys.fill(0); albMouseButtons.fill(0); }); window.addEventListener('mousemove', (ev) => { albUpdateMouseFromEvent(ev); }); albCanvas.addEventListener('mousedown', (ev) => { albUpdateMouseFromEvent(ev); albCanvas!.focus(); if (ev.button < albMouseButtons.length) albMouseButtons[ev.button] = 1; ev.preventDefault(); }); window.addEventListener('mouseup', (ev) => { albUpdateMouseFromEvent(ev); if (ev.button < albMouseButtons.length) albMouseButtons[ev.button] = 0; }); albCanvas.addEventListener('wheel', (ev) => { albUpdateMouseFromEvent(ev as unknown as MouseEvent); if (ev.deltaY < 0) albMouseWheel += 1; else if (ev.deltaY > 0) albMouseWheel -= 1; ev.preventDefault(); }, { passive: false }); albCanvas.addEventListener('contextmenu', (ev) => { ev.preventDefault(); }); window.addEventListener('resize', albUpdateMetrics); albCanvas.focus(); }");
      Line ("if (albConsoleDisabled) { albResizable = true; albCanvas.style.width = '100vw'; albCanvas.style.height = '100vh'; if (albConsoleRoot) albConsoleRoot.style.display = 'none'; } else if (albResizable) { albCanvas.style.width = '100vw'; albCanvas.style.height = '100vh'; } else { albCanvas.style.width = `${albBaseWidth}px`; albCanvas.style.height = `${albBaseHeight}px`; }");
      Line ("albUpdateMetrics();");
      Line ("albApplyCurrentFont();");
      Line ("if (!albConsoleDisabled) albRefreshTextConsoleLayout();");
      Line ("window.addEventListener('pagehide', () => { albRunning = false; ALB_ProgramShutdown(); });");
      Indent_Level := Indent_Level - 1;
      Line ("}");
      Line ("function ALB_SET_FULLSCREEN(v: boolean): void { if (v && albCanvas && !document.fullscreenElement) { void albCanvas.requestFullscreen(); } else if (!v && document.fullscreenElement) { void document.exitFullscreen(); } }");
      Line ("function ALB_SET_RESIZABLE(v: boolean): void { albResizable = v; if (albCanvas) { if (v) { albCanvas.style.width = '100vw'; albCanvas.style.height = '100vh'; } else { albCanvas.style.width = `${albBaseWidth}px`; albCanvas.style.height = `${albBaseHeight}px`; } albUpdateMetrics(); } }");
      Line ("function ALB_SET_STRETCHY(v: boolean): void { albStretchy = v; albUpdateMetrics(); }");
      Line ("function ALB_PREPARE_FRAME(): void { if (!albCtx || !albCanvas) return; albUpdateMetrics(); albCtx.setTransform(albScaleX, 0, 0, albScaleY, albOffsetX + albOriginX * albScaleX, albOffsetY + albOriginY * albScaleY); albCtx.imageSmoothingEnabled = false; albCtx.globalAlpha = 1; albCtx.strokeStyle = albCurrentColor; albCtx.fillStyle = albCurrentColor; albApplyCurrentFont(); }");
      Line ("function ALB_COLOR(v: number): void { albColorValue = v >>> 0; albCurrentColor = albColorToCss(albColorValue); if (albCtx) { albCtx.strokeStyle = albCurrentColor; albCtx.fillStyle = albCurrentColor; } }");
      Line ("function ALB_CLEAR(v: number): void { if (!albCtx) return; ALB_COLOR(v); albCtx.save(); albCtx.setTransform(1, 0, 0, 1, 0, 0); albCtx.fillStyle = albCurrentColor; albCtx.fillRect(0, 0, albCanvas?.width ?? albBaseWidth, albCanvas?.height ?? albBaseHeight); albCtx.restore(); ALB_PREPARE_FRAME(); }");
      Line ("function ALB_DRAW_RECT(x: number, y: number, w: number, h: number): void { if (!albCtx) return; albCtx.strokeRect(x, y, w, h); }");
      Line ("function ALB_FILL_RECT(x: number, y: number, w: number, h: number): void { if (!albCtx) return; albCtx.fillRect(x, y, w, h); }");
      Line ("function ALB_DRAW_LINE(x1: number, y1: number, x2: number, y2: number): void { if (!albCtx) return; albCtx.beginPath(); albCtx.moveTo(x1 + 0.5, y1 + 0.5); albCtx.lineTo(x2 + 0.5, y2 + 0.5); albCtx.stroke(); }");
      Line ("function ALB_DRAW_CIRCLE(x: number, y: number, r: number): void { if (!albCtx) return; albCtx.beginPath(); albCtx.arc(x, y, r, 0, Math.PI * 2); albCtx.stroke(); }");
      Line ("function ALB_FILL_CIRCLE(x: number, y: number, r: number): void { if (!albCtx) return; albCtx.beginPath(); albCtx.arc(x, y, r, 0, Math.PI * 2); albCtx.fill(); }");
      Line ("function ALB_DRAW_TRIANGLE(x1: number, y1: number, x2: number, y2: number, x3: number, y3: number): void { if (!albCtx) return; albCtx.beginPath(); albCtx.moveTo(x1, y1); albCtx.lineTo(x2, y2); albCtx.lineTo(x3, y3); albCtx.closePath(); albCtx.stroke(); }");
      Line ("function ALB_FILL_TRIANGLE(x1: number, y1: number, x2: number, y2: number, x3: number, y3: number): void { if (!albCtx) return; albCtx.beginPath(); albCtx.moveTo(x1, y1); albCtx.lineTo(x2, y2); albCtx.lineTo(x3, y3); albCtx.closePath(); albCtx.fill(); }");
      Line ("function ALB_PLOT(x: number, y: number): void { if (!albCtx) return; albCtx.fillRect(x, y, 1, 1); }");
      Line ("function ALB_DRAW_TEXT(x: number, y: number, t: string): void { if (!albCtx) return; albApplyCurrentFont(); albCtx.fillText(t, x, y); }");
      Line ("function ALB_SET_ALPHA(channel: number, value: number): void { albAlphaChannel = channel | 0; albAlphaValue = Math.max(0, Math.min(255, value | 0)); ALB_COLOR(albColorValue); }");
      Line ("function ALB_SET_CLIP(x: number, y: number, w: number, h: number): void { if (!albCtx) return; albCtx.restore?.(); albCtx.save(); ALB_PREPARE_FRAME(); albCtx.beginPath(); albCtx.rect(x, y, w, h); albCtx.clip(); }");
      Line ("function ALB_SET_ORIGIN(x: number, y: number): void { albOriginX = x | 0; albOriginY = y | 0; }");
      Line ("function ALB_READ_PIXEL(x: number, y: number): number { if (!albCtx) return 0; const data = albCtx.getImageData(x, y, 1, 1).data; return ((data[3] << 24) | (data[0] << 16) | (data[1] << 8) | data[2]) >>> 0; }");
      Line ("function ALB_KEY(code: number): number { const k = code | 0; if (k === 4) return albKeyState(4) | albKeyState(80); if (k === 7) return albKeyState(7) | albKeyState(79); if (k === 22) return albKeyState(22) | albKeyState(81); if (k === 26) return albKeyState(26) | albKeyState(82); if (k === 44) return albKeyState(44) | albKeyState(40); return albKeyState(k); }");
      Line ("function ALB_MOUSE_X(): number { return albMouseX | 0; }");
      Line ("function ALB_MOUSE_Y(): number { return albMouseY | 0; }");
      Line ("function ALB_MOUSE_WHEEL(): number { return albMouseWheel | 0; }");
      Line ("function ALB_VMOUSE_X(): number { return albMouseX | 0; }");
      Line ("function ALB_VMOUSE_Y(): number { return albMouseY | 0; }");
      Line ("function ALB_MOUSE_CLICK(button: number): number { return albMouseButtons[button | 0] | 0; }");
      Line ("function ALB_SCREEN_WIDTH(): number { return albWindowWidth | 0; }");
      Line ("function ALB_SCREEN_HEIGHT(): number { return albWindowHeight | 0; }");
      Line ("function ALB_VIRTUAL_WIDTH(): number { return albVirtualWidth | 0; }");
      Line ("function ALB_VIRTUAL_HEIGHT(): number { return albVirtualHeight | 0; }");
      Line ("function ALB_RND(limit: number): number { const n = Math.max(1, limit | 0); return Math.floor(Math.random() * n); }");
      Line ("function ALB_COLLIDE_RECT(ax: number, ay: number, aw: number, ah: number, bx: number, by: number, bw: number, bh: number): number { return (ax < bx + bw && ax + aw > bx && ay < by + bh && ay + ah > by) ? 1 : 0; }");
      Line ("function ALB_SIN(deg: number): number { return Math.round(Math.sin((deg * Math.PI) / 180) * 1024); }");
      Line ("function ALB_COS(deg: number): number { return Math.round(Math.cos((deg * Math.PI) / 180) * 1024); }");
      Line ("function ALB_SQRT(v: number): number { return Math.trunc(Math.sqrt(Math.max(0, v))); }");
      Line ("function ALB_EXP(v: number): number { return Math.trunc(Math.exp(v)); }");
      Line ("function RND(limit: number): number { return ALB_RND(limit); }");
      Line ("function COLLIDE_RECT(ax: number, ay: number, aw: number, ah: number, bx: number, by: number, bw: number, bh: number): number { return ALB_COLLIDE_RECT(ax, ay, aw, ah, bx, by, bw, bh); }");
      Line ("function SIN(deg: number): number { return ALB_SIN(deg); }");
      Line ("function COS(deg: number): number { return ALB_COS(deg); }");
      Line ("function SQRT(v: number): number { return ALB_SQRT(v); }");
      Line ("function EXP(v: number): number { return ALB_EXP(v); }");
      Line ("function LEFT(s: ALBValue, n: ALBValue): string { const t = String(s); const c = Math.max(0, Number(n) | 0); return t.slice(0, c); }");
      Line ("function RIGHT(s: ALBValue, n: ALBValue): string { const t = String(s); const c = Math.max(0, Number(n) | 0); return c >= t.length ? t : t.slice(t.length - c); }");
      Line ("function MID(s: ALBValue, startAt: ALBValue, n: ALBValue): string { const t = String(s); const startIx = Math.max(0, (Number(startAt) | 0) - 1); const c = Math.max(0, Number(n) | 0); return t.slice(startIx, startIx + c); }");
      Line ("function LEN(v: ALBValue): number { return String(v).length; }");
      Line ("function CHR(v: ALBValue): string { const c = Number(v); return c >= 0 && c <= 0xffff ? String.fromCharCode(c) : (c > 0xffff && c <= 0x10ffff ? String.fromCodePoint(c) : String.fromCharCode(c & 255)); }");
      Line ("function ASC(v: ALBValue): number { const t = String(v); return t.length > 0 ? t.charCodeAt(0) & 255 : 0; }");
      Line ("function CONCAT(a: ALBValue, b: ALBValue): string { return String(a) + String(b); }");
      Line ("function ALB_CAT(a: ALBValue, b: ALBValue): string { const s = String(a) + String(b); albArenaUsed += s.length; return s; }");
      Line ("function ALB_ROL(v: ALBValue, k: ALBValue, w: ALBValue): number { const width = Number(w); let kk = ((Number(k) % width) + width) % width; const mask = Math.pow(2, width) - 1; let x = Number(v) - Math.floor(Number(v) / Math.pow(2, width)) * Math.pow(2, width); if (width <= 32) { return (((x << kk) | (x >>> (width - kk))) >>> 0) & mask; } const low = (x * Math.pow(2, kk)) % Math.pow(2, width); const high = Math.floor(x / Math.pow(2, width - kk)); return (low + high) % Math.pow(2, width); }");
      Line ("function ALB_ROR(v: ALBValue, k: ALBValue, w: ALBValue): number { const width = Number(w); let kk = ((Number(k) % width) + width) % width; return ALB_ROL(v, width - kk, width); }");
      Line ("function ALB_BSET(v: ALBValue, b: ALBValue): number { const bit = Number(b); if (bit < 31) return (Number(v) | (1 << bit)) >>> 0; return Number(v) + Math.pow(2, bit) * (1 - ALB_BTST(v, b)); }");
      Line ("function ALB_BCLR(v: ALBValue, b: ALBValue): number { const bit = Number(b); if (bit < 31) return (Number(v) & ~(1 << bit)) >>> 0; return Number(v) - Math.pow(2, bit) * ALB_BTST(v, b); }");
      Line ("function ALB_BTST(v: ALBValue, b: ALBValue): number { const bit = Number(b); if (bit < 31) return (Number(v) >>> bit) & 1; return Math.floor(Number(v) / Math.pow(2, bit)) % 2; }");
      Line ("function UCASE(v: ALBValue): string { return String(v).toUpperCase(); }");
      Line ("function LCASE(v: ALBValue): string { return String(v).toLowerCase(); }");
      Line ("function TRIM(v: ALBValue): string { return String(v).trim(); }");
      Line ("function SPC(n: ALBValue): string { return ' '.repeat(Math.max(0, Number(n) | 0)); }");
      Line ("function ALB_FText(v: ALBValue): string { const n = Number(v); if (Number.isNaN(n)) return 'nan'; if (!Number.isFinite(n)) return n < 0 ? '-inf' : 'inf'; const neg = n < 0; const a = Math.abs(n); const ip = Math.trunc(a); let frac = a - ip; let s = (neg ? '-' : '') + ip.toString() + '.'; for (let i = 0; i < 6; i++) { frac *= 10.0; const d = Math.trunc(frac); s += String.fromCharCode(48 + d); frac -= d; } return s; }");
      Line ("function ALB_Val(v: ALBValue): number { const n = Number.parseFloat(String(v).trim()); return Number.isFinite(n) ? n : 0; }");
      Line ("function ALB_ROUND(v: ALBValue): number { const n = Number(v); return Math.sign(n) * Math.round(Math.abs(n)); }");
      Line ("function ALB_Instr(hay: ALBValue, needle: ALBValue, startAt: ALBValue = 1): number { const h = String(hay); const ix = h.indexOf(String(needle), Math.max(0, (Number(startAt) | 0) - 1)); return ix < 0 ? 0 : ix + 1; }");
      Line ("function ALB_Choose(cond: ALBValue, a: ALBValue, b: ALBValue): ALBValue { return Boolean(cond) ? a : b; }");
      Line ("function ALB_Time_Str(): string { return new Date().toTimeString().slice(0, 8); }");
      Line ("function ALB_Date_Str(): string { return new Date().toISOString().slice(0, 10); }");
      Line ("function ALB_Timer(): number { return performance.now() / 1000; }");
      Line ("function ALB_Env(name: ALBValue): string { const g = globalThis as { [key: string]: unknown }; const nodeProcess = g['process'] as { env?: { [key: string]: string | undefined } } | undefined; if (nodeProcess && nodeProcess.env) return nodeProcess.env[String(name)] ?? ''; return ''; }");
      Line ("function ALB_Argc(): number { const g = globalThis as { [key: string]: unknown }; const nodeProcess = g['process'] as { argv?: string[] } | undefined; if (nodeProcess && nodeProcess.argv) return Math.max(0, nodeProcess.argv.length - 1); return 0; }");
      Line ("function ALB_Argv(i: ALBValue): string { const g = globalThis as { [key: string]: unknown }; const nodeProcess = g['process'] as { argv?: string[] } | undefined; if (nodeProcess && nodeProcess.argv) return String(nodeProcess.argv[Number(i) + 1] ?? ''); return ''; }");
      Line ("function ALB_Shell(cmd: ALBValue): number { const g = globalThis as { [key: string]: unknown }; const nodeProcess = g['process'] as { versions?: { node?: unknown } } | undefined; if (nodeProcess && nodeProcess.versions && nodeProcess.versions.node) { try { const req = eval('require') as (name: string) => { execSync(c: string, o: { stdio: string }): unknown }; req('child_process').execSync(String(cmd), { stdio: 'inherit' }); return 0; } catch (e) { const st = (e as { status?: number }).status; return typeof st === 'number' ? st : 1; } } return 0; }");
      Line ("function ALB_Dir(pattern: ALBValue): string { const g = globalThis as { [key: string]: unknown }; const nodeProcess = g['process'] as { versions?: { node?: unknown } } | undefined; if (nodeProcess && nodeProcess.versions && nodeProcess.versions.node) { try { const req = eval('require') as (name: string) => { readdirSync(p: string): string[] }; const names = req('fs').readdirSync('.'); const pat = String(pattern); if (pat === '*' || pat === '*.*') return names.join('\n'); const rx = new RegExp('^' + pat.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/[*]/g, '.*').replace(/[?]/g, '.') + '$'); return names.filter((n: string) => rx.test(n)).join('\n'); } catch { return ''; } } return ''; }");
      Line ("function ALB_Kill(path: ALBValue): number { const g = globalThis as { [key: string]: unknown }; const nodeProcess = g['process'] as { versions?: { node?: unknown } } | undefined; if (nodeProcess && nodeProcess.versions && nodeProcess.versions.node) { try { const req = eval('require') as (name: string) => { unlinkSync(p: string): void }; req('fs').unlinkSync(String(path)); return 1; } catch { return 0; } } delete albSaveStore[String(path)]; return 1; }");
      Line ("function ALB_MemUsed(): number { return albArenaUsed; }");
      Line ("function ALB_MemFree(): number { return albArenaCap - albArenaUsed; }");
      Line ("function PRINT_PURE(v: ALBValue): void { ALB_PRINT(v); }");
      Line ("function ALB_GetTickCount(): number { return Math.trunc(performance.now()); }");
      Line ("function ALB_PRED(name: string, a?: ALBValue, b?: ALBValue, c?: ALBValue, d?: ALBValue): string { let s = name + '('; let first = true; const add = (v: ALBValue | undefined) => { if (v === undefined) return; if (!first) s += ','; s += String(v); first = false; }; add(a); add(b); add(c); add(d); return s + ')'; }");
      Line ("function ALB_PLAY_SOUND(path: string): void { const a = new Audio(path); void a.play(); }");
      Line ("function ALB_PLAY_MUSIC(mml: string): void { const ctx = albEnsureAudio(); albStopMusicVoices(); let tempo = 120; let octave = 4; let defLen = 4; let t = Math.max(ctx.currentTime, 0); const freq = (note: number, oct: number) => 440 * Math.pow(2, (note - 9 + (oct - 4) * 12) / 12); const noteMap: Record<string, number> = { C: 0, D: 2, E: 4, F: 5, G: 7, A: 9, B: 11 }; for (let i = 0; i < mml.length; i++) { const ch = mml[i].toUpperCase(); if (ch === ' ' || ch === ',') continue; if (ch === 'T') { let n = ''; while (++i < mml.length && /[0-9]/.test(mml[i])) n += mml[i]; i -= 1; if (n) tempo = Math.max(1, parseInt(n, 10)); continue; } if (ch === 'O') { let n = ''; while (++i < mml.length && /[0-9]/.test(mml[i])) n += mml[i]; i -= 1; if (n) octave = parseInt(n, 10); continue; } if (ch === 'L') { let n = ''; while (++i < mml.length && /[0-9]/.test(mml[i])) n += mml[i]; i -= 1; if (n) defLen = Math.max(1, parseInt(n, 10)); continue; } if (ch === '>') { octave += 1; continue; } if (ch === '<') { octave -= 1; continue; } if (ch === 'P' || ch === 'R') { let n = ''; while (i + 1 < mml.length && /[0-9]/.test(mml[i + 1])) { i += 1; n += mml[i]; } const length = n ? Math.max(1, parseInt(n, 10)) : defLen; t += 60 / tempo * (4 / length); continue; } if (ch in noteMap) { let note = noteMap[ch]; if (i + 1 < mml.length && (mml[i + 1] === '#' || mml[i + 1] === '+')) { note += 1; i += 1; } else if (i + 1 < mml.length && mml[i + 1] === '-') { note -= 1; i += 1; } let n = ''; while (i + 1 < mml.length && /[0-9]/.test(mml[i + 1])) { i += 1; n += mml[i]; } const length = n ? Math.max(1, parseInt(n, 10)) : defLen; const dur = 60 / tempo * (4 / length); albPcSpeakerTone(ctx, freq(note, octave), t, dur); t += dur; } } }");
      Line ("async function ALB_PLAY_MUSIC_FROM(path: string): Promise<void> { const txt = await fetch(path).then((r) => r.text()); ALB_PLAY_MUSIC(txt); }");
      Line ("function ALB_MSG_BOX(msg: ALBValue, title: ALBValue = ''): void { window.alert((title ? `${title}\\n\\n` : '') + String(msg)); }");
      Line ("function ALB_Delay(ms: number): void { albDelayUntil = performance.now() + Math.max(0, ms | 0); }");
      Line ("function ALB_CEASE(): void { albRunning = false; ALB_ProgramShutdown(); }");
      Line ("function albGcDec(handle: number): void { if (handle > 0 && handle < albGcRefs.length && albGcRefs[handle] > 0) albGcRefs[handle] -= 1; }");
      Line ("function albGcClearChildren(parent: number): void { const a = albGcChildA[parent] | 0; const b = albGcChildB[parent] | 0; const c = albGcChildC[parent] | 0; const d = albGcChildD[parent] | 0; if (a) albGcDec(a); if (b) albGcDec(b); if (c) albGcDec(c); if (d) albGcDec(d); albGcChildA[parent] = 0; albGcChildB[parent] = 0; albGcChildC[parent] = 0; albGcChildD[parent] = 0; }");
      Line ("function ALB_CLAIM(): number { for (let i = 1; i < albGcAlive.length; i++) { if (!albGcAlive[i]) { albGcAlive[i] = 1; albGcRefs[i] = 1; albGcChildA[i] = 0; albGcChildB[i] = 0; albGcChildC[i] = 0; albGcChildD[i] = 0; albArenaMark[i] = albArenaUsed; return i; } } return 0; }");
      Line ("function ALB_BIND(parent: number, child1: number = 0, child2: number = 0, child3: number = 0, child4: number = 0): void { if (!parent || parent <= 0 || parent >= albGcAlive.length || !albGcAlive[parent]) return; albGcClearChildren(parent); if (child1 > 0 && child1 < albGcRefs.length) { albGcChildA[parent] = child1; albGcRefs[child1] += 1; } if (child2 > 0 && child2 < albGcRefs.length) { albGcChildB[parent] = child2; albGcRefs[child2] += 1; } if (child3 > 0 && child3 < albGcRefs.length) { albGcChildC[parent] = child3; albGcRefs[child3] += 1; } if (child4 > 0 && child4 < albGcRefs.length) { albGcChildD[parent] = child4; albGcRefs[child4] += 1; } }");
      Line ("function ALB_DROP(handle: number): void { albGcDec(handle | 0); }");
      Line ("function ALB_SWEEP(chunk: number): void { const id = chunk | 0; if (id > 0 && id < albArenaMark.length && albGcAlive[id]) { albArenaUsed = albArenaMark[id]; } else if (id <= 0) { albArenaUsed = 0; } let budget = (chunk | 0) > 0 ? (chunk | 0) : albGcAlive.length; let changed = 1; while (changed && budget > 0) { changed = 0; for (let i = 1; i < albGcAlive.length && budget > 0; i++) { if (albGcAlive[i] && albGcRefs[i] === 0) { albGcAlive[i] = 0; albGcClearChildren(i); changed = 1; budget -= 1; } } } }");
      Line ("function ALB_KNOWS_SET(key: string, value: ALBValue): void { for (let i = 0; i < albFactLive.length; i++) { if (albFactLive[i] && albFactKey[i] === key) { albFactValue[i] = value; return; } } for (let i = 0; i < albFactLive.length; i++) { if (!albFactLive[i]) { albFactLive[i] = 1; albFactKey[i] = key; albFactValue[i] = value; return; } } }");
      Line ("function ALB_KNOWS_GET(key: string): ALBValue { for (let i = 0; i < albFactLive.length; i++) if (albFactLive[i] && albFactKey[i] === key) return albFactValue[i]; return 0; }");
      Line ("function ALB_KNOWS_HAS(key: string): number { for (let i = 0; i < albFactLive.length; i++) if (albFactLive[i] && albFactKey[i] === key) return 1; return 0; }");
      Line ("let ALB_NOTIFY_KNOWS_CHANGE = (_pred: number, _arg1: number, _arg2: number, _arg3: number, _arg4: number): void => {};");
      Line ("function ALB_REL_FACT_MATCH(slot: number, pred: number, arity: number, arg1: number, arg2: number, arg3: number, arg4: number): boolean { return !!albRelLive[slot] && albRelPred[slot] === pred && albRelArity[slot] === arity && albRelArg1[slot] === (arg1 | 0) && albRelArg2[slot] === (arg2 | 0) && albRelArg3[slot] === (arg3 | 0) && albRelArg4[slot] === (arg4 | 0); }");
      Line ("function ALB_REL_FACT_HAS(pred: number, arity: number, arg1: number, arg2: number, arg3: number, arg4: number): number { for (let i = 0; i < albRelLive.length; i++) if (ALB_REL_FACT_MATCH(i, pred, arity, arg1, arg2, arg3, arg4)) return 1; return 0; }");
      --  Clause-commitment cut: once every term BEFORE the cut matched
      --  (failure index j >= albRuleCutPos), the rule is committed —
      --  later rules for the same head are never tried.
      Line ("function ALB_REL_RULE_HAS(pred: number, arg1: number): number { for (let r = 0; r < albRuleCount; r++) { if (albRuleHeadPred[r] !== pred) continue; let ok = 1; let j = 0; const base = r * 16; const cut = albRuleCutPos[r] | 0; for (; j < albRuleBodyLen[r]; j += 1) { const ix = base + j; const bodyPred = albRuleBodyPred[ix]; const mode = albRuleBodyArgMode[ix]; const want = mode === 1 ? (arg1 | 0) : albRuleBodyArgConst[ix]; if (!ALB_REL_FACT_HAS(bodyPred, 1, want, 0, 0, 0)) { ok = 0; break; } } if (ok) return 1; if (cut >= 0 && j >= cut) return 0; } return 0; }");
      Line ("function ALB_REL_HAS(pred: number, arity: number, arg1: number, arg2: number, arg3: number, arg4: number): number { if (ALB_REL_FACT_HAS(pred, arity, arg1, arg2, arg3, arg4)) return 1; if ((arity | 0) === 1) return ALB_REL_RULE_HAS(pred, arg1); return 0; }");
      Line ("function ALB_REL_SET(pred: number, arity: number, arg1: number, arg2: number, arg3: number, arg4: number, value: number): void { for (let i = 0; i < albRelLive.length; i++) { if (ALB_REL_FACT_MATCH(i, pred, arity, arg1, arg2, arg3, arg4)) { albRelValue[i] = value | 0; ALB_NOTIFY_KNOWS_CHANGE(pred, arg1, arg2, arg3, arg4); return; } } for (let i = 0; i < albRelLive.length; i++) { if (!albRelLive[i]) { albRelLive[i] = 1; albRelPred[i] = pred; albRelArity[i] = arity; albRelArg1[i] = arg1 | 0; albRelArg2[i] = arg2 | 0; albRelArg3[i] = arg3 | 0; albRelArg4[i] = arg4 | 0; albRelValue[i] = value | 0; ALB_NOTIFY_KNOWS_CHANGE(pred, arg1, arg2, arg3, arg4); return; } } }");
      Line ("function ALB_REL_RETRACT(pred: number, arity: number, arg1: number, arg2: number, arg3: number, arg4: number): void { for (let i = 0; i < albRelLive.length; i++) { if (ALB_REL_FACT_MATCH(i, pred, arity, arg1, arg2, arg3, arg4)) { albRelLive[i] = 0; albRelPred[i] = 0; albRelArity[i] = 0; albRelArg1[i] = 0; albRelArg2[i] = 0; albRelArg3[i] = 0; albRelArg4[i] = 0; albRelValue[i] = 0; ALB_NOTIFY_KNOWS_CHANGE(pred, arg1, arg2, arg3, arg4); } } }");
      Line ("function ALB_REL_GET_VALUE(pred: number, arity: number, arg1: number, arg2: number, arg3: number, arg4: number): number { for (let i = 0; i < albRelLive.length; i++) if (ALB_REL_FACT_MATCH(i, pred, arity, arg1, arg2, arg3, arg4)) return albRelValue[i] | 0; return ALB_REL_HAS(pred, arity, arg1, arg2, arg3, arg4); }");
      Line ("function ALB_REL_FIND1(pred: number): number { for (let i = 0; i < albRelLive.length; i++) if (albRelLive[i] && albRelPred[i] === pred) return albRelArg1[i] | 0; return 0; }");
      Line ("function ALB_REL_FINDALL1(pred: number, target: any): number { const big = target instanceof BigInt64Array || target instanceof BigUint64Array; let out = 0; for (let i = 0; i < target.length; i++) target[i] = big ? 0n : 0; for (let i = 0; i < albRelLive.length && out < target.length; i++) { if (albRelLive[i] && albRelPred[i] === pred) { target[out] = big ? BigInt(albRelArg1[i] | 0) : albRelArg1[i]; out += 1; } } return out; }");
      Line ("function ALB_ASSERT(key: string, value: ALBValue): void { ALB_KNOWS_SET(key, value); }");
      Line ("function ALB_RETRACT(key: string): void { for (let i = 0; i < albFactLive.length; i++) if (albFactLive[i] && albFactKey[i] === key) { albFactLive[i] = 0; albFactKey[i] = ''; albFactValue[i] = 0; } }");
      Line ("function ALB_UPDATE(key: string, value: ALBValue): void { ALB_KNOWS_SET(key, value); }");
      Line ("function ALB_PROVE(key: string): number { return ALB_KNOWS_HAS(key); }");
      Line ("function ALB_Open(path: string, mode: string): number { const m = String(mode); if (m.indexOf('w') < 0 && m.indexOf('a') < 0) { let exists = Object.prototype.hasOwnProperty.call(albSaveStore, path); if (!exists) { const g = globalThis as { [key: string]: unknown }; const nodeProcess = g['process'] as { versions?: { node?: unknown } } | undefined; if (nodeProcess && nodeProcess.versions && nodeProcess.versions.node) { try { const req = eval('require') as (name: string) => { statSync(p: string): unknown }; req('fs').statSync(path); exists = true; } catch {} } } if (!exists) return 0; } for (let i = 1; i < albFileLive.length; i++) { if (!albFileLive[i]) { albFileLive[i] = 1; albFileMode[i] = mode; albFileName[i] = path; albFileCursor[i] = 0; let buf = albSaveStore[path] ?? ''; if (!buf) { const g = globalThis as { [key: string]: unknown }; const nodeProcess = g['process'] as { versions?: { node?: unknown } } | undefined; if (nodeProcess && nodeProcess.versions && nodeProcess.versions.node) { try { const req = eval('require') as (name: string) => { readFileSync(path: string, enc: string): string }; buf = req('fs').readFileSync(path, 'latin1'); albSaveStore[path] = buf; } catch {} } } if (String(mode).indexOf('w') >= 0) buf = ''; albFileBuffer[i] = buf; return i; } } return 0; }");
      Line ("function ALB_FileLen(path: string): number { const g = globalThis as { [key: string]: unknown }; const nodeProcess = g['process'] as { versions?: { node?: unknown } } | undefined; if (nodeProcess && nodeProcess.versions && nodeProcess.versions.node) { try { const req = eval('require') as (name: string) => { statSync(path: string): { size: number } }; return req('fs').statSync(path).size; } catch { return 0; } } const t = albSaveStore[path] ?? ''; return t.length; }");
      Line ("function ALB_Seek(handle: number, offset: number): number { if (!albFileLive[handle]) return 0; albFileCursor[handle] = Math.max(0, Number(offset) | 0); return albFileCursor[handle]; }");
      Line ("function ALB_Read(handle: number, count: number = 0): string { if (!albFileLive[handle]) return ''; if (count <= 0) return albFileBuffer[handle]; const start = albFileCursor[handle] | 0; const chunk = albFileBuffer[handle].slice(start, start + count); albFileCursor[handle] = start + chunk.length; return chunk; }");
      Line ("function ALB_Write(handle: number, data: ALBValue): void { if (!albFileLive[handle]) return; albFileBuffer[handle] += String(data); }");
      Line ("function ALB_Close(handle: number): void { if (!albFileLive[handle]) return; const name = albFileName[handle]; const data = albFileBuffer[handle]; const mode = String(albFileMode[handle] ?? ''); if (mode.indexOf('r') < 0 || mode.indexOf('w') >= 0 || mode.indexOf('a') >= 0) { albSaveStore[name] = data; const g = globalThis as { [key: string]: unknown }; const nodeProcess = g['process'] as { versions?: { node?: unknown } } | undefined; if (nodeProcess && nodeProcess.versions && nodeProcess.versions.node) { try { const req = eval('require') as (name: string) => { writeFileSync(p: string, d: string, enc: string): void }; req('fs').writeFileSync(name, data, 'latin1'); } catch {} } } albFileLive[handle] = 0; albFileName[handle] = ''; albFileBuffer[handle] = ''; albFileCursor[handle] = 0; }");
      Line ("function ALB_LoadTextBuffer(path: string): string { if (Object.prototype.hasOwnProperty.call(albSaveStore, path)) return albSaveStore[path] ?? ''; const g = globalThis as { [key: string]: unknown }; const nodeProcess = g['process'] as { versions?: { node?: unknown } } | undefined; if (nodeProcess && nodeProcess.versions && nodeProcess.versions.node) { try { const req = eval('require') as (name: string) => { readFileSync(path: string, enc: string): string }; const text = req('fs').readFileSync(path, 'utf8'); albSaveStore[path] = text; return text; } catch {} } return ''; }");
      Line ("function ALB_LoadBuffer(path: string, target: Int8Array | Uint8Array | Int16Array | Uint16Array | Int32Array | Uint32Array): void { const raw = ALB_LoadTextBuffer(path); if (!raw) return; const items = raw.split(','); for (let i = 0; i < target.length && i < items.length; i++) target[i] = Number(items[i]) as never; }");
      Line ("function ALB_FlushBuffer(target: ArrayLike<number> | string, path: string, byteCount?: number): void { if (typeof target !== 'string' && byteCount !== undefined) { const count = Math.max(0, Number(byteCount) | 0); const bytes = new Uint8Array(count); for (let i = 0; i < count; i += 1) bytes[i] = Number((target as ArrayLike<number>)[i] ?? 0) & 255; albSaveStore[path] = String.fromCharCode(...Array.from(bytes)); const ext = path.split('.').pop()?.toLowerCase() ?? ''; const mime = ext === 'png' ? 'image/png' : ext === 'bmp' ? 'image/bmp' : ext === 'ppm' ? 'image/x-portable-pixmap' : ext === 'fits' ? 'application/fits' : 'application/octet-stream'; const g = globalThis as { [key: string]: unknown }; const nodeProcess = g['process'] as { versions?: { node?: unknown } } | undefined; if (nodeProcess && nodeProcess.versions && nodeProcess.versions.node) { try { const req = eval('require') as (name: string) => { writeFileSync(path: string, data: Uint8Array): void }; req('fs').writeFileSync(path, bytes); return; } catch {} } if (typeof document !== 'undefined' && typeof Blob !== 'undefined' && typeof URL !== 'undefined' && document.body) { try { const blob = new Blob([bytes], { type: mime }); const link = document.createElement('a'); link.href = URL.createObjectURL(blob); link.download = path.split(/[/\\\\]/).pop() || path; link.style.display = 'none'; document.body.appendChild(link); link.click(); setTimeout(() => { URL.revokeObjectURL(link.href); link.remove(); }, 0); } catch {} } return; } if (typeof target === 'string') { albSaveStore[path] = target; const g = globalThis as { [key: string]: unknown }; const nodeProcess = g['process'] as { versions?: { node?: unknown } } | undefined; if (nodeProcess && nodeProcess.versions && nodeProcess.versions.node) { try { const req = eval('require') as (name: string) => { writeFileSync(path: string, data: string, enc: string): void }; req('fs').writeFileSync(path, target, 'utf8'); return; } catch {} } if (typeof document !== 'undefined' && typeof Blob !== 'undefined' && typeof URL !== 'undefined' && document.body) { try { const blob = new Blob([target], { type: 'text/plain;charset=utf-8' }); const link = document.createElement('a'); link.href = URL.createObjectURL(blob); link.download = path.split(/[/\\\\]/).pop() || path; link.style.display = 'none'; document.body.appendChild(link); link.click(); setTimeout(() => { URL.revokeObjectURL(link.href); link.remove(); }, 0); } catch {} } return; } albSaveStore[path] = Array.from(target as ArrayLike<number>).join(','); }");
      Line ("function albFirewallCurrent(): any | null { return albFirewallStack.length > 0 ? albFirewallStack[albFirewallStack.length - 1] : null; }");
      Line ("function albFirewallAllows(kind: 'read' | 'write', name: string): boolean { const fw = albFirewallCurrent(); if (!fw || !fw.denyAll || !name) return true; const table = kind === 'write' ? fw.write : fw.read; return !!table && typeof table.has === 'function' ? !!table.has(name) : true; }");
      Line ("function ALB_FIREWALL_TOUCH_READ(name: string): void { if (!albFirewallAllows('read', name)) ALB_FATAL(`MEMORY_FIREWALL read blocked: ${name}`); }");
      Line ("function ALB_FIREWALL_TOUCH_WRITE(name: string): void { if (!albFirewallAllows('write', name)) ALB_FATAL(`MEMORY_FIREWALL write blocked: ${name}`); }");
      Line ("function ALB_FIREWALL_READ<T>(name: string, value: T): T { ALB_FIREWALL_TOUCH_READ(name); return value; }");
      Line ("function ALB_FIREWALL_WRITE<T>(name: string, value: T): T { ALB_FIREWALL_TOUCH_WRITE(name); return value; }");
      Line ("function ALB_FIREWALL_ENTER(fw: any): void { albFirewallStack.push(fw ?? null); }");
      Line ("function ALB_FIREWALL_LEAVE(): void { if (albFirewallStack.length > 0) albFirewallStack.pop(); }");
      Line ("function ALB_CSTR_AT(addr: number): string { let s = ''; for (let i = 0; i < 1048576; i++) { const c = Number(ALB_PEEK((addr | 0) + i)) | 0; if (c === 0) break; s += String.fromCharCode(c & 255); } return s; }");
      Line ("function ALB_COMPAT_FSCALL(op: string, path: string, path2?: string): number { const g = globalThis as { [key: string]: unknown }; const nodeProcess = g['process'] as { versions?: { node?: unknown } } | undefined; if (nodeProcess && nodeProcess.versions && nodeProcess.versions.node) { try { const req = eval('require') as (name: string) => { unlinkSync(p: string): void; renameSync(a: string, b: string): void; mkdirSync(p: string, o?: unknown): void; statSync(p: string): { isDirectory(): boolean; isFile(): boolean; readonly?: boolean } }; const fs = req('fs'); if (op === 'del') { fs.unlinkSync(path); delete albSaveStore[path]; return 1; } if (op === 'ren') { fs.renameSync(path, String(path2 ?? '')); if (Object.prototype.hasOwnProperty.call(albSaveStore, path)) { albSaveStore[String(path2 ?? '')] = albSaveStore[path]; delete albSaveStore[path]; } return 1; } if (op === 'mkdir') { fs.mkdirSync(path); return 1; } if (op === 'attr') { const st = fs.statSync(path); let bits = 0; if (st.isDirectory()) bits |= 16; else if (st.isFile()) bits |= 32; if (st.readonly) bits |= 1; return bits; } } catch { return op === 'attr' ? 0xFFFFFFFF : 0; } } if (op === 'del') { if (Object.prototype.hasOwnProperty.call(albSaveStore, path)) { delete albSaveStore[path]; return 1; } return 0; } if (op === 'ren') { if (Object.prototype.hasOwnProperty.call(albSaveStore, path)) { albSaveStore[String(path2 ?? '')] = albSaveStore[path]; delete albSaveStore[path]; return 1; } return 0; } return 0; }");
      Line ("function ALB_COMPAT_IMPORT(lib: string, symbol: string, ...args: any[]): any { const key = symbol.toUpperCase(); if (key === 'GETTICKCOUNT64' || key === 'GETTICKCOUNT') { albCompatTick += 16; return albCompatTick >>> 0; } if (key === 'MESSAGEBEEP') return 1; if (key === 'GETCURRENTPROCESSID') { const g = globalThis as { [key: string]: unknown }; const p = g['process'] as { pid?: number } | undefined; return p && p.pid ? p.pid : 1; } if (key === 'GETSTDHANDLE') return 1; if (key === 'GETCONSOLEMODE') return 0; if (key === 'SLEEP') return 0; if (key === 'HYPOT') return Math.hypot(Number(args[0] ?? 0), Number(args[1] ?? 0)); if (key === 'DELETEFILEA' || key === 'DELETEFILEW') return ALB_COMPAT_FSCALL('del', ALB_CSTR_AT(Number(args[0] ?? 0))); if (key === 'MOVEFILEA' || key === 'MOVEFILEW') return ALB_COMPAT_FSCALL('ren', ALB_CSTR_AT(Number(args[0] ?? 0)), ALB_CSTR_AT(Number(args[1] ?? 0))); if (key === 'CREATEDIRECTORYA' || key === 'CREATEDIRECTORYW') return ALB_COMPAT_FSCALL('mkdir', ALB_CSTR_AT(Number(args[0] ?? 0))); if (key === 'GETFILEATTRIBUTESA' || key === 'GETFILEATTRIBUTESW') return ALB_COMPAT_FSCALL('attr', ALB_CSTR_AT(Number(args[0] ?? 0))); if (key.indexOf('SQUADCOLOR') >= 0) return (((Number(args[0] ?? 0) * 73) + (Number(args[1] ?? 0) * 41) + 0x224466) >>> 0); if (key.indexOf('SQUADBIAS') >= 0) return (((Number(args[0] ?? 0) * 5) - (Number(args[1] ?? 0) * 3)) | 0); if (key.indexOf('SQUADTRAININGBOOST') >= 0) return ((Number(args[0] ?? 0) + Number(args[1] ?? 0) + 1) & 255); if (key.indexOf('CLOCK') >= 0) { albCompatTick += 17; return albCompatTick >>> 0; } return 0; }");
      Line ("function ALB_MAKE_CELL(initialValue: number = 0): any { return { value: initialValue | 0, valueOf() { return this.value | 0; }, toString() { return String(this.value | 0); } }; }");
      Line ("function ALB_BUFFER_BYTE(buf: ArrayLike<number>, index: number): number { return Number((buf as any)[index | 0] ?? 0) & 255; }");
      Line ("function ALB_BUFFER_PACK_LE(buf: ArrayLike<number>, start: number, size: number): number { let value = 0; let scale = 1; for (let i = 0; i < (size | 0); i += 1) { value += ALB_BUFFER_BYTE(buf, (start | 0) + i) * scale; scale *= 256; } return Math.trunc(value); }");
      Line ("function ALB_DEFINE_SYSTEM_FONT(name: string, size: number, weight: string, antiAlias: boolean, charsetStart: number, charsetEnd: number): any { const family = name && name.length > 0 ? name : 'sans-serif'; const px = Math.max(1, size | 0); const weightText = weight && weight.length > 0 ? weight : 'normal'; return { kind: 'systemFont', name: family, size: px, weight: weightText, antiAlias, charsetStart: charsetStart | 0, charsetEnd: charsetEnd | 0, css: `${weightText} ${px}px ${family}` }; }");
      Line ("function ALB_DEFINE_BITMAP_FONT(name: string, source: string, format: string, glyphWidth: number, glyphHeight: number, firstChar: number, spacing: number): any { const px = Math.max(1, glyphHeight | 0); return { kind: 'bitmapFont', name, source, format, glyphWidth: Math.max(1, glyphWidth | 0), glyphHeight: px, firstChar: firstChar | 0, spacing: spacing | 0, css: `${px}px monospace`, antiAlias: false }; }");
      Line ("function ALB_SET_FONT(font: any): void { if (!font) return; if (font.kind === 'bitmapFont') ALB_WARN_ONCE('bitmap-font-approx', 'BITMAP_FONT uses browser text approximation on ALBW'); albCurrentFont = String(font.css ?? albCurrentFont); if (albCtx) { albCtx.imageSmoothingEnabled = !!font.antiAlias; albApplyCurrentFont(); } }");
      Line ("function ALB_INI_BIND(path: string, embeddedText: string | null, table: Array<{ key: string; apply: (value: number) => void }>): number { const source = (embeddedText && embeddedText.length > 0) ? embeddedText : (albSaveStore[path] ?? ''); if (!source || source.length === 0) return 0; const rows = source.split(/\\r?\\n/u); let matched = 0; for (const rawLine of rows) { const line = rawLine.trim(); if (!line || line.startsWith('#') || line.startsWith(';') || line.startsWith('[')) continue; const eq = line.indexOf('='); if (eq < 0) continue; const key = line.slice(0, eq).trim().toLowerCase(); const valueText = line.slice(eq + 1).trim(); const value = Number.parseInt(valueText, 10); if (!Number.isFinite(value)) continue; for (const row of table) { if (row.key === key) { row.apply(value | 0); matched += 1; break; } } } return matched > 0 ? 1 : 0; }");
      Line ("function ALB_EXPORT_PPM(surface: any, path: string, format: string): number { if (!surface || !surface.pixels || !surface.width || !surface.height) return 0; const fmt = format.toUpperCase(); if (fmt !== 'P6') ALB_WARN_ONCE('export-ppm-format', `EXPORT_PPM format ${format} is approximated as P6 on ALBW`); const width = Math.max(1, Number(surface.width) | 0); const height = Math.max(1, Number(surface.height) | 0); let out = `P6\\n${width} ${height}\\n255\\n`; for (let i = 0; i < width * height; i += 1) { const rgb565 = Number(surface.pixels[i] ?? 0) & 0xffff; const r = ((rgb565 >> 11) & 31) * 255 / 31; const g = ((rgb565 >> 5) & 63) * 255 / 63; const b = (rgb565 & 31) * 255 / 31; out += String.fromCharCode(r | 0, g | 0, b | 0); } albSaveStore[path] = out; return 1; }");
      Line ("function ALB_SNIFFER_DEFINE(interfaceName: string, protocol: number, port: number, bufferSize: number): any { const handle = albNextSnifferHandle++; const sniffer = { kind: 'sniffer', handle, interfaceName, protocol: protocol | 0, port: port | 0, bufferSize: Math.max(64, bufferSize | 0), sample: 0, value: 0, errorCell: ALB_MAKE_CELL(0), valueOf() { return this.value | 0; }, toString() { return String(this.value | 0); } }; albSnifferTable[handle] = sniffer; return sniffer; }");
      Line ("function ALB_SNIFFER_CAPTURE(sniffer: any, dest: ALBNumericArray): number { if (!sniffer || !dest) return 0; sniffer.sample = (Number(sniffer.sample ?? 0) | 0) + 1; sniffer.errorCell.value = 0; const total = Math.min(dest.length, Math.max(54, Number(sniffer.bufferSize) | 0)); for (let i = 0; i < dest.length; i += 1) (dest as any)[i] = 0; const bytes = [0x10,0x20,0x30,0x40,0x50,0x60,0xaa,0xbb,0xcc,0xdd,0xee,0xff,0x08,0x00,0x45,0x00,0x28,0x00,0x00,0x00,0x00,0x00,0x40,0x06,0x00,0x00,0x01,0x00,0x00,0x0a,0x02,0x00,0x00,0x0a,0x50,0x00,0x01,0xbb,0x78,0x56,0x34,0x12,0x21,0x43,0x65,0x87,0x50,0x18,0x20,0x00,0x00,0x00,0x00,0x00]; for (let i = 0; i < total && i < bytes.length; i += 1) (dest as any)[i] = bytes[i]; sniffer.value = Math.min(total, bytes.length) | 0; return sniffer.value | 0; }");
      Line ("function ALB_STATIC_RGB565(rgb: number): number { const v = rgb >>> 0; return (((((v >> 16) & 255) >> 3) << 11) | ((((v >> 8) & 255) >> 2) << 5) | ((v & 255) >> 3)) & 0xffff; }");
      Line ("function ALB_STATIC_SURFACE(width: number, height: number): any { const w = Math.max(1, width | 0); const h = Math.max(1, height | 0); return { kind: 'surface', width: w, height: h, pitch: w * 2, pixels: new Uint16Array(w * h) }; }");
      Line ("function ALB_STATIC_VIEWPORT(x: number, y: number, width: number, height: number): any { return { kind: 'viewport', x: x | 0, y: y | 0, width: Math.max(1, width | 0), height: Math.max(1, height | 0) }; }");
      Line ("function ALB_STATIC_EMPTY_SPRITE(frameWidth: number, frameHeight: number, frames: number): any { const fw = Math.max(1, frameWidth | 0); const fh = Math.max(1, frameHeight | 0); const count = Math.max(1, frames | 0); return { kind: 'sprite', pixels: new Uint8Array(fw * fh * count), palette: new Uint32Array(256), frameWidth: fw, frameHeight: fh, frames: count, sheetWidth: fw * count, sheetHeight: fh }; }");
      Line ("function ALB_STATIC_SPRITE_FROM_BMP(bytes: Uint8Array, frameWidth: number, frameHeight: number, frames: number): any { if (bytes.length < 54 || bytes[0] !== 0x42 || bytes[1] !== 0x4d) { ALB_WARN_ONCE('static-sprite-payload', 'STATIC_SPRITE source is not a usable BMP on ALBW; using a blank sprite'); return ALB_STATIC_EMPTY_SPRITE(frameWidth, frameHeight, frames); } const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength); const pixelOffset = view.getUint32(10, true); const dibSize = view.getUint32(14, true); const bmpWidth = view.getInt32(18, true); const bmpHeight = view.getInt32(22, true); const planes = view.getUint16(26, true); const bits = view.getUint16(28, true); const compression = view.getUint32(30, true); if (planes !== 1 || bits !== 8 || compression !== 0) { ALB_WARN_ONCE('static-sprite-format', 'STATIC_SPRITE currently approximates unsupported BMP layouts as a blank sprite on ALBW'); return ALB_STATIC_EMPTY_SPRITE(frameWidth, frameHeight, frames); } const width = Math.max(1, Math.abs(bmpWidth) | 0); const height = Math.max(1, Math.abs(bmpHeight) | 0); const bottomUp = bmpHeight > 0; const paletteOffset = 14 + (dibSize | 0); const rowStride = ((width + 3) & ~3); const palette = new Uint32Array(256); for (let i = 0; i < 256; i += 1) { const off = paletteOffset + i * 4; if (off + 3 < bytes.length) palette[i] = ((bytes[off + 2] << 16) | (bytes[off + 1] << 8) | bytes[off]) >>> 0; } const pixels = new Uint8Array(width * height); for (let row = 0; row < height; row += 1) { const srcRow = bottomUp ? (height - 1 - row) : row; const src = pixelOffset + srcRow * rowStride; const dst = row * width; for (let col = 0; col < width; col += 1) pixels[dst + col] = bytes[src + col] ?? 0; } return { kind: 'sprite', pixels, palette, frameWidth: Math.max(1, frameWidth | 0), frameHeight: Math.max(1, frameHeight | 0), frames: Math.max(1, frames | 0), sheetWidth: width, sheetHeight: height }; }");
      Line ("function ALB_STATIC_APPLY_LUT(lut: Uint32Array, visual: unknown, context: unknown, contextUsed: boolean): void { ALB_STATIC_Active_Lut = lut; ALB_STATIC_Active_Visual = visual; ALB_STATIC_Active_Context = context; ALB_STATIC_Active_Context_Used = contextUsed; }");
      Line ("function ALB_STATIC_RESOLVE_VISUAL(visual: any, context: unknown): { sprite: any; frame: number } { if (visual && typeof visual === 'object' && visual.kind === 'visualRule' && typeof visual.resolve === 'function') return visual.resolve(context); return { sprite: visual, frame: 0 }; }");
      Line ("function ALB_STATIC_SPRITE_TO_CANVAS(sprite: any, frame: number, palette: Uint32Array, frameW: number, frameH: number, sheetW: number, alphaMask: boolean): HTMLCanvasElement { const keyFrame = frame | 0; if (sprite && sprite._albBlitCanvas && sprite._albBlitPal === palette && sprite._albBlitFrame === keyFrame && sprite._albBlitMask === alphaMask && sprite._albBlitW === frameW && sprite._albBlitH === frameH) return sprite._albBlitCanvas; const canvas = document.createElement('canvas'); canvas.width = Math.max(1, frameW | 0); canvas.height = Math.max(1, frameH | 0); const ctx = canvas.getContext('2d', { alpha: true }); if (ctx && sprite && sprite.pixels) { const img = ctx.createImageData(canvas.width, canvas.height); const data = img.data; for (let row = 0; row < canvas.height; row += 1) { for (let col = 0; col < canvas.width; col += 1) { const src = (keyFrame * canvas.width) + col + (row * sheetW); const index = sprite.pixels[src] | 0; const o = ((row * canvas.width) + col) * 4; if (alphaMask && index === 0) { data[o + 3] = 0; continue; } const rgb = (palette ? palette[index] : 0) >>> 0; data[o] = (rgb >> 16) & 255; data[o + 1] = (rgb >> 8) & 255; data[o + 2] = rgb & 255; data[o + 3] = 255; } } ctx.putImageData(img, 0, 0); } if (sprite) { sprite._albBlitCanvas = canvas; sprite._albBlitPal = palette; sprite._albBlitFrame = keyFrame; sprite._albBlitMask = alphaMask; sprite._albBlitW = frameW; sprite._albBlitH = frameH; } return canvas; }");
      Line ("function ALB_STATIC_BLIT(visual: any, context: unknown, contextUsed: boolean, target: any, x: number, y: number, viewport: any, alphaMask: boolean): void { const resolved = ALB_STATIC_RESOLVE_VISUAL(visual, contextUsed ? context : undefined); const sprite = resolved?.sprite; if (!sprite || !target || !target.pixels) ALB_FATAL('ALB STATIC BLIT FAILED'); const frameW = Math.max(1, Number(sprite.frameWidth) | 0); const frameH = Math.max(1, Number(sprite.frameHeight) | 0); const sheetW = Math.max(frameW, Number(sprite.sheetWidth) | 0); const totalFrames = Math.max(1, Number(sprite.frames) | 0); const frame = ((Number(resolved?.frame ?? 0) | 0) % totalFrames + totalFrames) % totalFrames; const useActive = ALB_STATIC_Active_Visual === visual && ALB_STATIC_Active_Context_Used === contextUsed && (!contextUsed || ALB_STATIC_Active_Context === context); const palette = (useActive && ALB_STATIC_Active_Lut) ? ALB_STATIC_Active_Lut : sprite.palette; for (let row = 0; row < frameH; row += 1) { for (let col = 0; col < frameW; col += 1) { const dx = (x | 0) + col; const dy = (y | 0) + row; if (dx < 0 || dy < 0 || dx >= target.width || dy >= target.height) continue; if (viewport) { const vr = (viewport.x | 0) + (viewport.width | 0); const vb = (viewport.y | 0) + (viewport.height | 0); if (dx < (viewport.x | 0) || dy < (viewport.y | 0) || dx >= vr || dy >= vb) continue; } const src = frame * frameW + col + row * sheetW; const index = sprite.pixels[src] | 0; if (alphaMask && index === 0) continue; const rgb = palette[index] >>> 0; target.pixels[dy * target.width + dx] = ALB_STATIC_RGB565(rgb); } } if (albCtx) { const blitCanvas = ALB_STATIC_SPRITE_TO_CANVAS(sprite, frame, palette, frameW, frameH, sheetW, alphaMask); albCtx.save(); if (viewport) { albCtx.beginPath(); albCtx.rect(viewport.x | 0, viewport.y | 0, viewport.width | 0, viewport.height | 0); albCtx.clip(); } albCtx.imageSmoothingEnabled = false; albCtx.drawImage(blitCanvas, x | 0, y | 0); albCtx.restore(); } }");
      --  FASM parity: 1-based states; -1 for invalid model/state, argmax
      --  over the current row (strict >, lowest col wins ties).
      Line ("function ALB_MARKOV_PREDICT(model: any, currentState: number): number { if (!model || !model.states || !model.matrix) return -1; const states = model.states | 0; const cur = currentState | 0; if (states <= 0 || cur < 1 || cur > states) return -1; const row = (cur - 1) * states; let bestCol = 0; let bestWeight = Number(model.matrix[row] ?? 0); for (let col = 1; col < states; col += 1) { const weight = Number(model.matrix[row + col] ?? 0); if (weight > bestWeight) { bestWeight = weight; bestCol = col; } } return bestCol + 1; }");
      --  Soft emotion bias (FASM ALB_Markov_Predict_Emotion):
      --  weight'[col] = weight[col] + emotion[col] for col < 8.
      Line ("function ALB_MARKOV_PREDICT_E(model: any, currentState: number, emo: Uint8Array): number { if (!model || !model.states || !model.matrix) return -1; const states = model.states | 0; const cur = currentState | 0; if (states <= 0 || cur < 1 || cur > states) return -1; const row = (cur - 1) * states; let bestCol = 0; let bestWeight = Number(model.matrix[row] ?? 0) + (emo ? (emo[0] | 0) : 0); for (let col = 1; col < states; col += 1) { let weight = Number(model.matrix[row + col] ?? 0); if (col < 8 && emo) weight += emo[col] | 0; if (weight > bestWeight) { bestWeight = weight; bestCol = col; } } return bestCol + 1; }");
      --  EMOTION engine: fixed U8 axes (saturating 0..255), max 8 per
      --  emotion — flat globals ALB_EMOTION_<name>, helpers mirror the
      --  FASM runtime loops bit-for-bit.
      Line ("function ALB_EMO_BLEND(axes: Uint8Array, count: number, target: number, amt: number): void { const a = amt | 0; for (let i = 0; i < count; i += 1) { const v = axes[i] | 0; axes[i] = (i === target ? Math.min(255, v + a) : Math.max(0, v - a)); } }");
      Line ("function ALB_EMO_DECAY(axes: Uint8Array, count: number, amt: number): void { const a = amt | 0; for (let i = 0; i < count; i += 1) axes[i] = Math.max(0, (axes[i] | 0) - a); }");
      Line ("function ALB_EMO_DOMINANT(axes: Uint8Array, count: number): number { if (count <= 0) return 0; let best = axes[0] | 0; let idx = 0; for (let i = 1; i < count; i += 1) { const v = axes[i] | 0; if (v > best) { best = v; idx = i; } } return idx + 1; }");
      Line ("function ALB_EMO_BIAS_INPUTS(inputs: any, count: number, axes: Uint8Array): void { const n = Math.min(count, axes ? axes.length : 0, 8); const m = Math.min(n, inputs ? (inputs.length ?? 0) : 0); const big = inputs instanceof BigInt64Array || inputs instanceof BigUint64Array; for (let i = 0; i < m; i += 1) { const v = Number(inputs[i] ?? 0) + (axes[i] | 0); inputs[i] = big ? BigInt(Math.trunc(v)) : v; } }");
      --  FASM parity: TANH hard-clamps to +/-1 (was x*8 clamp +/-1024).
      Line ("function ALB_NN_ACT(code: number, value: number): number { switch (code | 0) { case 1: return value > 0 ? value : 0; case 2: return value > 0 ? 1 : 0; case 3: if (value > 1) return 1; if (value < -1) return -1; return value; default: return value; } }");
      Line ("function ALB_NN_SEED(prevSize: number, currSize: number, neuronIndex: number, inputIndex: number): number { if (prevSize <= 0 || currSize <= 0) return 0; if (currSize === prevSize) return inputIndex === neuronIndex ? 256 : 0; if (prevSize === currSize * 2) { if (inputIndex === neuronIndex * 2) return 256; if (inputIndex === (neuronIndex * 2) + 1) return -256; return 0; } if (currSize > prevSize) return inputIndex === (neuronIndex % prevSize) ? 256 : 0; const inputSpan = Math.max(1, Math.trunc(prevSize / currSize)); const baseInput = neuronIndex * inputSpan; const positiveIn = Math.min(prevSize - 1, baseInput); const negativeIn = Math.min(prevSize - 1, baseInput + 1); if (inputSpan >= 2) { if (inputIndex === positiveIn) return 256; if (inputIndex === negativeIn) return -128; return 0; } return inputIndex === positiveIn ? 256 : 0; }");
      Line ("function ALB_NN_CREATE(name: string, sizes: number[], acts: number[]): any { const weights: Int32Array[] = []; const biases: Int32Array[] = []; for (let layer = 1; layer < sizes.length; layer += 1) { const prev = Math.max(1, sizes[layer - 1] | 0); const curr = Math.max(1, sizes[layer] | 0); const w = new Int32Array(prev * curr); const b = new Int32Array(curr); for (let neuron = 0; neuron < curr; neuron += 1) for (let inputIndex = 0; inputIndex < prev; inputIndex += 1) w[(neuron * prev) + inputIndex] = ALB_NN_SEED(prev, curr, neuron, inputIndex); weights.push(w); biases.push(b); } return { name, sizes, activations: acts, weights, biases, state: sizes.map((n) => new Float64Array(Math.max(1, n | 0))) }; }");
      Line ("function ALB_NN_INFER(model: any, input: ArrayLike<number>, output: ALBNumericArray): void { if (!model || !model.state) return; const state = model.state as Float64Array[]; for (let i = 0; i < state[0].length; i += 1) state[0][i] = Number(input[i] ?? 0); for (let layer = 1; layer < state.length; layer += 1) { const prev = state[layer - 1]; const curr = state[layer]; const weights = model.weights[layer - 1] as Int32Array; const biases = model.biases[layer - 1] as Int32Array; for (let i = 0; i < curr.length; i += 1) { let acc = Number(biases[i] ?? 0); for (let j = 0; j < prev.length; j += 1) acc += prev[j] * Number(weights[i * prev.length + j] ?? 0); curr[i] = ALB_NN_ACT(Number(model.activations[layer] ?? 0), acc); } } const out = state[state.length - 1]; const big = output instanceof BigInt64Array || output instanceof BigUint64Array; for (let i = 0; i < output.length; i += 1) { const v = i < out.length ? Math.round(out[i]) : 0; (output as any)[i] = big ? BigInt(v) : v; } }");
      Line ("function ALB_NN_TRAIN(model: any, trainData: ArrayLike<number>, expectData: ArrayLike<number>, epochs: number): void { if (!model || !model.weights || model.weights.length === 0) return; const outSize = Math.max(1, model.sizes[model.sizes.length - 1] | 0); const prevSize = Math.max(1, model.sizes[model.sizes.length - 2] | 0); const output = new Float64Array(outSize); for (let epoch = 0; epoch < Math.max(1, epochs | 0); epoch += 1) { ALB_NN_INFER(model, trainData, output as unknown as ALBNumericArray); const prev = model.state[model.state.length - 2] as Float64Array; const weights = model.weights[model.weights.length - 1] as Int32Array; const biases = model.biases[model.biases.length - 1] as Int32Array; for (let i = 0; i < outSize; i += 1) { const got = Math.round(Number(output[i] ?? 0)); const want = Math.round(Number(expectData[i] ?? 0)); const delta = got > want ? -1 : (got < want ? 1 : 0); biases[i] = (biases[i] | 0) + delta; for (let j = 0; j < prevSize; j += 1) if (Math.round(prev[j]) !== 0) weights[i * prevSize + j] = (weights[i * prevSize + j] | 0) + delta; } } }");
      Line ("function albNetChannelKey(sock: any): string { return `ALB_NET_${sock.protocol | 0}_${sock.port | 0}`; }");
      Line ("function albNetEnsure(sock: any): void { if (!sock.queue) sock.queue = []; if (typeof BroadcastChannel !== 'undefined' && !sock.channel) { sock.channel = new BroadcastChannel(albNetChannelKey(sock)); sock.channel.onmessage = (ev: MessageEvent) => { const raw = (ev as any).data; let packet: Uint8Array | null = null; if (raw instanceof Uint8Array) packet = raw; else if (raw && Array.isArray(raw.payload)) packet = Uint8Array.from(raw.payload.map((v: any) => Number(v) & 255)); else if (Array.isArray(raw)) packet = Uint8Array.from(raw.map((v: any) => Number(v) & 255)); if (packet) sock.queue.push(packet); }; } }");
      Line ("function albNetPull(sock: any): Uint8Array | null { albNetEnsure(sock); if (sock.queue && sock.queue.length > 0) return sock.queue.shift() ?? null; if (!sock.channel) { const key = albNetChannelKey(sock); const bus = albNetworkBus[key]; if (bus && bus.length > 0) return bus.shift() ?? null; } return null; }");
      Line ("function ALB_NET_DEFINE(protocol: number, port: number, bufferSize: number): number { const handle = albNextNetworkHandle++; const size = Math.max(1, bufferSize | 0); albNetworkTable[handle] = { handle, protocol, port, bufferSize: size, listening: false, open: true, queue: [], channel: null, lastSent: new Uint8Array(size), lastReceived: new Uint8Array(size) }; return handle; }");
      Line ("function ALB_NET_LISTEN(handle: number): void { const sock = albNetworkTable[handle | 0]; if (!sock) ALB_FATAL('NETWORK_LISTEN on unknown socket'); sock.listening = true; sock.open = true; albNetEnsure(sock); }");
      Line ("function ALB_NET_ACCEPT(handle: number): number { const sock = albNetworkTable[handle | 0]; if (!sock) ALB_FATAL('NETWORK_ACCEPT on unknown socket'); const child = albNextNetworkHandle++; albNetworkTable[child] = { handle: child, protocol: sock.protocol, port: sock.port, bufferSize: sock.bufferSize, listening: sock.listening, open: true, queue: [], channel: null, parent: handle | 0, lastSent: new Uint8Array(sock.bufferSize), lastReceived: new Uint8Array(sock.bufferSize) }; if (sock.listening) albNetEnsure(albNetworkTable[child]); return child; }");
      Line ("function ALB_NET_RECEIVE(handle: number, dest: ALBNumericArray): void { const sock = albNetworkTable[handle | 0]; if (!sock || !sock.open) ALB_FATAL('NETWORK_RECEIVE on closed socket'); const packet = albNetPull(sock) ?? sock.lastReceived ?? new Uint8Array(sock.bufferSize); sock.lastReceived = Uint8Array.from(packet); for (let i = 0; i < dest.length; i += 1) (dest as any)[i] = Number(packet[i] ?? 0) & 255; }");
      Line ("function ALB_NET_SEND(handle: number, src: ALBNumericArray): void { const sock = albNetworkTable[handle | 0]; if (!sock || !sock.open) ALB_FATAL('NETWORK_SEND on closed socket'); const payload = Uint8Array.from(Array.from(src as ArrayLike<number>, (v) => Number(v) & 255)); sock.lastSent = payload; albNetEnsure(sock); if (sock.channel) sock.channel.postMessage({ payload: Array.from(payload) }); else { const key = albNetChannelKey(sock); if (!albNetworkBus[key]) albNetworkBus[key] = []; albNetworkBus[key].push(payload); } }");
      Line ("function ALB_NET_CLOSE(handle: number): void { const sock = albNetworkTable[handle | 0]; if (!sock) return; sock.open = false; sock.listening = false; if (sock.channel) { sock.channel.close(); sock.channel = null; } sock.queue = []; }");
      Line ("function ALB_PROCESS_DEFINE(image: string, rights: string[], pid: number = 0): number { const handle = albNextProcessHandle++; albProcessTable[handle] = { handle, image, rights, pid: pid | 0, alive: true, elevated: false, mode: 'self' }; return handle; }");
      Line ("function ALB_PROCESS_CREATE(image: string, args: string): number { const handle = albNextProcessHandle++; albProcessTable[handle] = { handle, image, args, alive: true, elevated: false, mode: 'child' }; return handle; }");
      Line ("function ALB_PROCESS_READ_SCALAR(handle: number, addr: number): number { const proc = albProcessTable[handle | 0]; if (!proc || !proc.alive) return 0; return Number(ALB_PEEK(addr | 0)) || 0; }");
      Line ("function ALB_PROCESS_WRITE_SCALAR(handle: number, addr: number, value: ALBValue): void { const proc = albProcessTable[handle | 0]; if (!proc || !proc.alive) ALB_FATAL('WRITE_PROCESS_MEMORY on invalid handle'); ALB_POKE(addr | 0, value); }");
      Line ("function ALB_PROCESS_READ_BUFFER(handle: number, addr: number, target: ALBNumericArray): void { const value = ALB_PROCESS_READ_SCALAR(handle, addr); let whole = BigInt(Math.max(0, Math.trunc(Number(value)))); for (let i = 0; i < target.length; i += 1) { (target as any)[i] = Number(whole & 255n); whole = whole >> 8n; } }");
      Line ("function ALB_PROCESS_MONITOR(handle: number, addr: number, outTarget: { value: number }, changed: { value: number }): void { const key = `${handle | 0}:${addr | 0}`; const value = ALB_PROCESS_READ_SCALAR(handle, addr); changed.value = Object.prototype.hasOwnProperty.call(albProcessMonitor, key) && albProcessMonitor[key] !== value ? 1 : 0; albProcessMonitor[key] = value; outTarget.value = value; }");
      Line ("function ALB_PROCESS_DUMP(handle: number, addr: number, size: number, outPath: string): void { const bytes = new Uint8Array(Math.max(1, size | 0)); ALB_PROCESS_READ_BUFFER(handle, addr, bytes); albSaveStore[outPath] = Array.from(bytes).join(','); }");
      Line ("function ALB_FILE_XOR(sourcePath: string, key: string, outPath: string): void { const src = albSaveStore[sourcePath] ?? ''; const keyText = key.length > 0 ? key : '0'; let out = ''; for (let i = 0; i < src.length; i += 1) out += String.fromCharCode(src.charCodeAt(i) ^ keyText.charCodeAt(i % keyText.length)); albSaveStore[outPath] = out; }");
      Line ("function ALB_PROCESS_ELEVATE(handle: number): void { const proc = albProcessTable[handle | 0]; if (proc) proc.elevated = true; }");
      Line ("function ALB_PROCESS_SNIFF(source: ALBValue, target: ALBNumericArray): void { const seed = String(source); for (let i = 0; i < target.length; i += 1) (target as any)[i] = i < seed.length ? seed.charCodeAt(i) & 255 : 0; }");
      Line ("function ALB_RunFrame(now: number): void { if (!albRunning) { ALB_ProgramShutdown(); return; } requestAnimationFrame(ALB_RunFrame); if (now < albDelayUntil) return; if (now - albLastFrame < albFrameInterval) return; albLastFrame = now; try { ALB_PREPARE_FRAME(); ALB_ON_TICK(); albMouseWheel = 0; ALB_ON_PAINT(); } catch (err) { ALB_FATAL(err); } }");
      New_Line_Emit;

      if Need_Mcp_Runtime then
         Emit_Mcp_Runtime;
      end if;

      Rt_End := Out_Line_N + 1;
   end Emit_Runtime;

   function JSImport_Alias (Binding : Foreign_Binding_Record) return String is
   begin
      return "__alb_imp_" & Safe_JS_Name (To_String (Binding.JS_Name));
   end JSImport_Alias;

   procedure Emit_Module_Imports is
      Any_Emitted : Boolean := False;
   begin
      for I in 1 .. Foreign_Import_Count loop
         if Foreign_Imports (I).Active
           and then Foreign_Imports (I).Link_Kind = Foreign_Compat
         then
            --  OS FFI (IMPORTDLL/IMPORTSO): JS can't call into kernel32/
            --  msvcrt — route through the compat shim, which implements
            --  the small deterministic subset the suite needs.
            Line ("function " & To_String (Foreign_Imports (I).JS_Name) &
                  "(...args: any[]): any { return ALB_COMPAT_IMPORT(" &
                  Escape_TS_String (To_String (Foreign_Imports (I).Path)) &
                  ", " &
                  Escape_TS_String (To_String (Foreign_Imports (I).Name)) &
                  ", ...args); }");
            Any_Emitted := True;
         end if;
      end loop;

      if Need_Module_Support then
         for I in 1 .. Foreign_Import_Count loop
            if Foreign_Imports (I).Active
              and then Foreign_Imports (I).Link_Kind = Foreign_ES
            then
               Line ("import { " & To_String (Foreign_Imports (I).Name) &
                     " as " & JSImport_Alias (Foreign_Imports (I)) &
                     " } from " &
                     Escape_TS_String (JSImport_Specifier (To_String (Foreign_Imports (I).Path))) &
                     ";");
               Any_Emitted := True;
            end if;
         end loop;
      end if;

      if Any_Emitted then
         New_Line_Emit;
      end if;
   end Emit_Module_Imports;

   procedure Emit_Foreign_Loaders is
   begin
      if not Need_Wasm_Loaders then
         return;
      end if;

      for I in 1 .. Foreign_Import_Count loop
         if Foreign_Imports (I).Active and then Foreign_Imports (I).Link_Kind = Foreign_WASM then
            Line ("albWasmLoaders.push((async () => {");
            Indent_Level := Indent_Level + 1;
            Line ("const response = await fetch(" &
                  Escape_TS_String (JSImport_Specifier (To_String (Foreign_Imports (I).Path))) &
                  ");");
            Line ("if (!response.ok) ALB_FATAL(`WASM fetch failed for " &
                  To_String (Foreign_Imports (I).Name) & ": ${response.status}`);");
            Line ("const bytes = await response.arrayBuffer();");
            Line ("const result = await WebAssembly.instantiate(bytes, ALB_WASM_HOST_IMPORTS as WebAssembly.Imports);");
            Line ("const exportsTable = result.instance.exports as Record<string, unknown>;");
            Line ("const fn = exportsTable[" &
                  Escape_TS_String (To_String (Foreign_Imports (I).Name)) & "];");
            Line ("if (typeof fn !== 'function') ALB_FATAL('Missing WASM export: " &
                  To_String (Foreign_Imports (I).Name) & "');");
            Line ("albWasmBindings[" &
                  Escape_TS_String (To_String (Foreign_Imports (I).JS_Name)) &
                  "] = fn as (...args: any[]) => any;");
            Indent_Level := Indent_Level - 1;
            Line ("})());");
         end if;
      end loop;

      New_Line_Emit;
   end Emit_Foreign_Loaders;

   procedure Emit_Module_Exports is
      Any_ES_Exports     : Boolean := False;
      Any_WASM_Exports   : Boolean := False;
      Any_Compat_Exports : Boolean := False;
   begin
      for I in 1 .. Foreign_Export_Count loop
         if Foreign_Exports (I).Active then
            case Foreign_Exports (I).Link_Kind is
               when Foreign_ES =>
                  Any_ES_Exports := True;
               when Foreign_WASM =>
                  Any_WASM_Exports := True;
               when Foreign_Compat =>
                  Any_Compat_Exports := True;
               when others =>
                  null;
            end case;
         end if;
      end loop;

      if Any_WASM_Exports then
         for I in 1 .. Foreign_Export_Count loop
            if Foreign_Exports (I).Active and then Foreign_Exports (I).Link_Kind = Foreign_WASM then
               Line ("ALB_WASM_HOST_IMPORTS.alb[" &
                     Escape_TS_String (To_String (Foreign_Exports (I).Name)) &
                     "] = (...args: any[]) => (" &
                     To_String (Foreign_Exports (I).JS_Name) &
                     " as any)(...args);");
            end if;
         end loop;
         Line ("export { ALB_WASM_HOST_IMPORTS };");
         New_Line_Emit;
      end if;

      if Any_Compat_Exports then
         for I in 1 .. Foreign_Export_Count loop
            if Foreign_Exports (I).Active and then Foreign_Exports (I).Link_Kind = Foreign_Compat then
               Line ("albCompatExports[" &
                     Escape_TS_String (To_String (Foreign_Exports (I).Name)) &
                     "] = (...args: any[]) => (" &
                     To_String (Foreign_Exports (I).JS_Name) &
                     " as any)(...args);");
            end if;
         end loop;
         Line ("Object.assign(globalThis as Record<string, unknown>, albCompatExports);");
         New_Line_Emit;
      end if;

      if Any_ES_Exports then
         --  Emit one export per line so full-engine libraries (~1k+ symbols)
         --  do not produce a single multi-megabyte export { … } statement.
         for I in 1 .. Foreign_Export_Count loop
            if Foreign_Exports (I).Active and then Foreign_Exports (I).Link_Kind = Foreign_ES then
               Line ("export { " &
                     To_String (Foreign_Exports (I).JS_Name) & " as " &
                     To_String (Foreign_Exports (I).Name) & " };");
            end if;
         end loop;
         New_Line_Emit;
      end if;
   end Emit_Module_Exports;

   procedure Emit_Foreign_Import_Node (Index : Node_Index) is
      Binding   : Foreign_Binding_Record;
      Decl_Node : constant Node_Index := Tree (Index).Left_Child;
      Name_Node : constant Node_Index := (if Decl_Node > 0 then Tree (Decl_Node).Left_Child else 0);
      List_Node : constant Node_Index := (if Name_Node > 0 then Tree (Name_Node).Right_Child else 0);
      Param_Node : Node_Index := 0;
      First     : Boolean := True;
      Has_Out   : Boolean := False;
   begin
      for I in 1 .. Foreign_Import_Count loop
         if Foreign_Imports (I).Active and then Foreign_Imports (I).Node = Index then
            Binding := Foreign_Imports (I);
            exit;
         end if;
      end loop;

      if not Binding.Active or else Name_Node = 0 then
         return;
      end if;

      Emit_Indent;
      Emit ("function " & To_String (Binding.JS_Name) & "(");
      if List_Node > 0 and then Tree (List_Node).Kind = AST_Arg_List then
         Param_Node := Tree (List_Node).Left_Child;
         while Param_Node > 0 loop
            if Tree (Param_Node).Kind = AST_Param_Decl then
               declare
                  Param_Name : constant String := Safe_JS_Name (Raw_Lexeme (Tree (Tree (Param_Node).Left_Child).Token_Index));
                  Param_Tag  : constant Value_Kind :=
                    (if Tree (Param_Node).Right_Child > 0
                     then Type_From_Token (Tree (Tree (Param_Node).Right_Child).Token_Index)
                     else VK_Number);
                  Mode_Tok   : constant Natural := Tree (Param_Node).Token_Index;
               begin
                  if not First then
                     Emit (", ");
                  end if;
                  if Mode_Tok > 0 and then Tokens (Mode_Tok).Kind = Tok_Out then
                     Emit (Param_Name & ": { value: " & Primitive_TS_Type (Param_Tag) & " }");
                     Has_Out := True;
                  else
                     Emit (Param_Name & ": " & Primitive_TS_Type (Param_Tag));
                  end if;
                  First := False;
               end;
            end if;
            Param_Node := Tree (Param_Node).Next_Sibling;
         end loop;
      end if;

      if Binding.Is_Function then
         Emit ("): " & Primitive_TS_Type (Binding.Return_Tag) & " {");
      else
         Emit ("): void {");
      end if;
      New_Line_Emit;
      Indent_Level := Indent_Level + 1;

      declare
         Call_Args : Unbounded_String := U ("");
      begin
         if List_Node > 0 and then Tree (List_Node).Kind = AST_Arg_List then
            Param_Node := Tree (List_Node).Left_Child;
            First := True;
            while Param_Node > 0 loop
               if Tree (Param_Node).Kind = AST_Param_Decl then
                  if not First then
                     Append (Call_Args, ", ");
                  end if;
                  Append (Call_Args,
                          Safe_JS_Name (Raw_Lexeme (Tree (Tree (Param_Node).Left_Child).Token_Index)));
                  First := False;
               end if;
               Param_Node := Tree (Param_Node).Next_Sibling;
            end loop;
         end if;

         if Has_Out then
            Line ("ALB_WARN_ONCE(" &
                  Escape_TS_String ("foreign-out-" & To_String (Binding.Name)) & ", " &
                  Escape_TS_String ("ALBW passes OUT parameters to foreign imports as { value } boxes; the callee must mutate .value to write back") &
                  ");");
         end if;

         if Binding.Link_Kind = Foreign_ES then
            if Binding.Is_Function then
               Line ("return " & Cast_Expr (Binding.Return_Tag,
                     JSImport_Alias (Binding) & "(" & To_String (Call_Args) & ")") & ";");
            else
               Line (JSImport_Alias (Binding) & "(" & To_String (Call_Args) & ");");
            end if;
         elsif Binding.Link_Kind = Foreign_WASM then
            Line ("const __alb_wasm_fn = albWasmBindings[" &
                  Escape_TS_String (To_String (Binding.JS_Name)) & "];");
            Line ("if (typeof __alb_wasm_fn !== 'function') ALB_FATAL('WASM import not ready: " &
                  To_String (Binding.Name) & "');");
            if Binding.Is_Function then
               Line ("return " & Cast_Expr (Binding.Return_Tag,
                     "__alb_wasm_fn(" & To_String (Call_Args) & ")") & ";");
            else
               Line ("__alb_wasm_fn(" & To_String (Call_Args) & ");");
            end if;
         else
            if Binding.Is_Function then
               Line ("return " & Cast_Expr (Binding.Return_Tag,
                     "ALB_COMPAT_IMPORT(" &
                     Escape_TS_String (To_String (Binding.Path)) & ", " &
                     Escape_TS_String (To_String (Binding.Name)) &
                     (if Length (Call_Args) > 0 then ", " & To_String (Call_Args) else "") &
                     ")") & ";");
            else
               Line ("ALB_COMPAT_IMPORT(" &
                     Escape_TS_String (To_String (Binding.Path)) & ", " &
                     Escape_TS_String (To_String (Binding.Name)) &
                     (if Length (Call_Args) > 0 then ", " & To_String (Call_Args) else "") &
                     ");");
            end if;
         end if;
      end;

      if not Binding.Is_Function then
         Line ("return;");
      end if;

      Indent_Level := Indent_Level - 1;
      Line ("}");
      New_Line_Emit;
   end Emit_Foreign_Import_Node;

   function Raw_Feature_Atom (Index : Node_Index) return String is
   begin
      if Index = 0 then
         return "";
      elsif Tree (Index).Kind = AST_String_Expr then
         return Strip_String_Node (Index);
      elsif Tree (Index).Token_Index > 0 then
         return Raw_Lexeme (Tree (Index).Token_Index);
      else
         return "";
      end if;
   end Raw_Feature_Atom;

   function Activation_Code (Text : String) return String is
      Upper : constant String := Upper_Text (Text);
   begin
      if Upper = "RELU" then
         return "1";
      elsif Upper = "SIGMOID" then
         return "2";
      elsif Upper = "TANH" then
         return "3";
      else
         return "0";
      end if;
   end Activation_Code;

   function Network_Protocol_Code (Text : String) return String is
      Upper : constant String := Upper_Text (Text);
   begin
      if Upper = "UDP" then
         return "2";
      else
         return "1";
      end if;
   end Network_Protocol_Code;

   procedure Emit_Embedded_File_Bytes
     (Const_Name : String;
      File_Path  : String) is
      use type Ada.Streams.Stream_IO.Count;
      use type Ada.Streams.Stream_Element_Offset;

      File_Handle : Ada.Streams.Stream_IO.File_Type;
   begin
      Ada.Streams.Stream_IO.Open
        (File_Handle,
         Ada.Streams.Stream_IO.In_File,
         File_Path);

      declare
         File_Size_Count : constant Ada.Streams.Stream_IO.Count :=
           Ada.Streams.Stream_IO.Size (File_Handle);
      begin
         if File_Size_Count = 0 then
            Ada.Streams.Stream_IO.Close (File_Handle);
            Line ("const " & Const_Name & " = new Uint8Array([0]);");
            return;
         end if;

         declare
            File_Size : constant Natural := Natural (File_Size_Count);
            Buffer    : Ada.Streams.Stream_Element_Array
              (1 .. Ada.Streams.Stream_Element_Offset (File_Size));
            Last      : Ada.Streams.Stream_Element_Offset := 0;
         begin
            Ada.Streams.Stream_IO.Read (File_Handle, Buffer, Last);
            Ada.Streams.Stream_IO.Close (File_Handle);

            Emit_Indent;
            Emit ("const " & Const_Name & " = new Uint8Array([");
            for I in Buffer'First .. Last loop
               if I > Buffer'First then
                  Emit (", ");
               end if;
               Emit (Trim_Image (Integer (Buffer (I))));
               if ((Integer (I) - Integer (Buffer'First) + 1) mod 24) = 0
                 and then I < Last
               then
                  New_Line_Emit;
                  Emit_Indent;
                  Emit ("    ");
               end if;
            end loop;
            Emit ("]);");
            New_Line_Emit;
         end;
      end;
   exception
      when others =>
         begin
            Ada.Streams.Stream_IO.Close (File_Handle);
         exception
            when others =>
               null;
         end;
         Line ("const " & Const_Name & " = new Uint8Array([0]);");
   end Emit_Embedded_File_Bytes;

   procedure Emit_Embedded_Text_File
     (Const_Name : String;
      File_Path  : String) is
      File_Handle : Ada.Text_IO.File_Type;
      Content     : Unbounded_String := U ("");
   begin
      Ada.Text_IO.Open (File_Handle, Ada.Text_IO.In_File, File_Path);
      while not Ada.Text_IO.End_Of_File (File_Handle) loop
         declare
            Line_Text : constant String := Ada.Text_IO.Get_Line (File_Handle);
         begin
            Append (Content, Line_Text);
            if not Ada.Text_IO.End_Of_File (File_Handle) then
               Append (Content, ASCII.LF);
            end if;
         end;
      end loop;
      Ada.Text_IO.Close (File_Handle);
      Line ("const " & Const_Name & " = " &
            Escape_TS_String (To_String (Content)) & ";");
   exception
      when others =>
         begin
            if Ada.Text_IO.Is_Open (File_Handle) then
               Ada.Text_IO.Close (File_Handle);
            end if;
         exception
            when others =>
               null;
         end;
         Line ("const " & Const_Name & " = """";");
   end Emit_Embedded_Text_File;

   function Statement_Target_Name
     (Target_Node : Node_Index;
      Assign_Kind : Value_Kind := VK_Unknown) return String is
      Node : constant AST_Node := Tree (Target_Node);
      Raw  : constant String := (if Node.Token_Index > 0 then Raw_Lexeme (Node.Token_Index) else "");
      Sym  : constant Symbol_Record :=
        Resolve_Symbol_Shaped
          (Raw,
           Want_Array => Node.Kind = AST_Var_Expr
                         and then Node.Left_Child > 0,
           Strict     => Node.Kind = AST_Var_Expr
                         and then Node.Left_Child = 0);
   begin
      if Target_Node = 0 then
         return "alb_missing_target";
      elsif Node.Kind = AST_Var_Expr then
         if Node.Left_Child > 0
           and then Sym.Active
           and then Sym.Kind in Sym_Strict_Array | Sym_Slide_Array
         then
            return To_String (Sym.JS_Name) &
              "[" & Build_Array_Index (Sym.Dims, Sym.Rank, Node.Left_Child) & "]";
         else
            return Resolve_Var_Name (Raw);
         end if;
      elsif Node.Kind = AST_Member_Expr then
         declare
            Left_Node  : constant AST_Node := Tree (Node.Left_Child);
            Right_Node : constant AST_Node := Tree (Node.Right_Child);
            Left_Name  : constant String := (if Left_Node.Token_Index > 0 then Raw_Lexeme (Left_Node.Token_Index) else "");
            Right_Name : constant String := (if Right_Node.Token_Index > 0 then Raw_Lexeme (Right_Node.Token_Index) else "");
            Group_Sym  : constant Symbol_Record := Resolve_Symbol (Left_Name & "." & Right_Name);
            Left_Sym   : constant Symbol_Record := Resolve_Symbol (Left_Name);
         begin
            if Left_Node.Kind = AST_Var_Expr and then Left_Node.Left_Child > 0 then
               declare
                  Scoped_Field : constant String := Scoped_Name (Left_Name) & "." & Right_Name;
                  Field_Sym_Id : Natural :=
                    Find_Symbol_Shaped ("", Scoped_Field, Want_Array => True);
               begin
                  if Field_Sym_Id = 0 then
                     Field_Sym_Id := Find_Symbol_Shaped
                       ("", Left_Name & "." & Right_Name, Want_Array => True);
                  end if;

                  if Field_Sym_Id /= 0 then
                     return To_String (Symbols (Field_Sym_Id).JS_Name) &
                       "[" &
                       Build_Array_Index
                         (Symbols (Field_Sym_Id).Dims,
                          Symbols (Field_Sym_Id).Rank,
                          Left_Node.Left_Child) &
                       "]";
                  end if;
               end;
            end if;

            if Right_Node.Kind = AST_Var_Expr
              and then Right_Node.Left_Child > 0
              and then Group_Sym.Active
              and then Group_Sym.Kind in Sym_Strict_Array | Sym_Slide_Array | Sym_Parallel_Field
            then
               return To_String (Group_Sym.JS_Name) &
                 "[" & Build_Array_Index (Group_Sym.Dims, Group_Sym.Rank, Right_Node.Left_Child) & "]";
            end if;

            if Left_Sym.Active and then Left_Sym.Kind = Sym_Struct_Var then
               return To_String (Left_Sym.JS_Name) & "." & Safe_JS_Name (Right_Name);
            elsif Group_Sym.Active then
               return To_String (Group_Sym.JS_Name);
            else
               return Collect_Module_Member_Name (Target_Node);
            end if;
         end;
      else
         return Expr (Target_Node);
      end if;
   end Statement_Target_Name;

   function Firewall_Key_For_Node (Target_Node : Node_Index) return String is
      function Firewall_Key_For_Symbol
        (Sym      : Symbol_Record;
         Fallback : String := "") return String
      is
      begin
         if not Sym.Active then
            return Fallback;
         elsif Sym.Kind = Sym_Param or else To_String (Sym.Scope) /= "" then
            return "";
         else
            return To_String (Sym.JS_Name);
         end if;
      end Firewall_Key_For_Symbol;
   begin
      if Target_Node = 0 then
         return "";
      end if;
      declare
         Node : constant AST_Node := Tree (Target_Node);
      begin
      if Node.Kind = AST_Var_Expr then
         declare
            Raw : constant String :=
              (if Node.Token_Index > 0 then Raw_Lexeme (Node.Token_Index) else "");
            Sym : constant Symbol_Record :=
              Resolve_Symbol_Shaped
                (Raw,
                 Want_Array => Node.Left_Child > 0,
                 Strict     => Node.Left_Child = 0);
         begin
            if Node.Left_Child > 0
              and then Sym.Active
              and then Sym.Kind in Sym_Strict_Array | Sym_Slide_Array
            then
               return Firewall_Key_For_Symbol (Sym, To_String (Sym.JS_Name));
            else
               return Firewall_Key_For_Symbol (Sym, Resolve_Var_Name (Raw));
            end if;
         end;
      elsif Node.Kind = AST_Member_Expr then
         declare
            Left_Node  : constant AST_Node := Tree (Node.Left_Child);
            Right_Node : constant AST_Node := Tree (Node.Right_Child);
            Left_Name  : constant String :=
              (if Left_Node.Token_Index > 0 then Raw_Lexeme (Left_Node.Token_Index) else "");
            Right_Name : constant String :=
              (if Right_Node.Token_Index > 0 then Raw_Lexeme (Right_Node.Token_Index) else "");
            Group_Sym  : constant Symbol_Record := Resolve_Symbol (Left_Name & "." & Right_Name);
            Left_Sym   : constant Symbol_Record := Resolve_Symbol (Left_Name);
         begin
            if Group_Sym.Active then
               return Firewall_Key_For_Symbol (Group_Sym, To_String (Group_Sym.JS_Name));
            elsif Left_Sym.Active and then Left_Sym.Kind = Sym_Struct_Var then
               if To_String (Left_Sym.Scope) /= "" then
                  return "";
               else
                  return To_String (Left_Sym.JS_Name) & "." & Safe_JS_Name (Right_Name);
               end if;
            else
               return "";
            end if;
         end;
      else
         return "";
      end if;
      end;
   end Firewall_Key_For_Node;

   function Wrap_Firewall_Read
     (Node_Index_Value : Node_Index;
      Value_Text       : String) return String
   is
      Key : constant String := Firewall_Key_For_Node (Node_Index_Value);
   begin
      if Key'Length = 0 then
         return Value_Text;
      else
         return "ALB_FIREWALL_READ(" & Escape_TS_String (Key) & ", " & Value_Text & ")";
      end if;
   end Wrap_Firewall_Read;

   function Wrap_Firewall_Write
     (Node_Index_Value : Node_Index;
      Value_Text       : String) return String
   is
      Key : constant String := Firewall_Key_For_Node (Node_Index_Value);
   begin
      if Key'Length = 0 then
         return Value_Text;
      else
         return "ALB_FIREWALL_WRITE(" & Escape_TS_String (Key) & ", " & Value_Text & ")";
      end if;
   end Wrap_Firewall_Write;

   procedure Emit_Firewall_Touch
     (Node_Index_Value : Node_Index;
      Need_Read        : Boolean;
      Need_Write       : Boolean) is
      Key : constant String := Firewall_Key_For_Node (Node_Index_Value);
   begin
      if Key'Length = 0 then
         return;
      end if;

      if Need_Read then
         Line ("ALB_FIREWALL_TOUCH_READ(" & Escape_TS_String (Key) & ");");
      end if;

      if Need_Write then
         Line ("ALB_FIREWALL_TOUCH_WRITE(" & Escape_TS_String (Key) & ");");
      end if;
   end Emit_Firewall_Touch;

   procedure Emit_Node (Index : Node_Index);

   procedure Remember_Event_Block
     (Event_Kind : Token_Kind;
      Block_Node : Node_Index) is
   begin
      case Event_Kind is
         when Tok_Tick =>
            if Tick_Block_Count < Max_Event_Blocks then
               Tick_Block_Count := Tick_Block_Count + 1;
               Tick_Blocks (Tick_Block_Count) := Block_Node;
            end if;
         when Tok_Paint =>
            if Paint_Block_Count < Max_Event_Blocks then
               Paint_Block_Count := Paint_Block_Count + 1;
               Paint_Blocks (Paint_Block_Count) := Block_Node;
            end if;
         when Tok_Key =>
            if Key_Block_Count < Max_Event_Blocks then
               Key_Block_Count := Key_Block_Count + 1;
               Key_Blocks (Key_Block_Count) := Block_Node;
            end if;
         when others =>
            null;
      end case;
   end Remember_Event_Block;

   procedure Emit_Event_Handler
     (Name   : String;
      Blocks : Node_Index_List;
      Count  : Natural) is
      Old_Routine : constant Unbounded_String := Current_Routine;
   begin
      if Count = 0 then
         return;
      end if;

      Current_Routine := U (Name);
      Line (Name & " = (): void => {");
      Indent_Level := Indent_Level + 1;
      for I in 1 .. Count loop
         Emit_Block (Blocks (I));
      end loop;
      Indent_Level := Indent_Level - 1;
      Line ("};");
      New_Line_Emit;
      Current_Routine := Old_Routine;
   end Emit_Event_Handler;

   procedure Emit_Address_Routines is
      procedure Emit_Struct_Field_Cases
        (Base_JS      : String;
         Struct_Name  : String;
         Base_Offset  : Integer;
         For_Write    : Boolean) is
      begin
         for I in 1 .. Field_Count loop
            if Fields (I).Active
              and then To_String (Fields (I).Struct_Name) = Struct_Name
            then
               if For_Write then
                  Line ("if (a === " &
                        Trim_Image (Base_Offset + Fields (I).Offset_Bytes) & ") { " &
                        Field_Write_Expr (Base_JS, I, Cast_Expr (Fields (I).Tag, "value")) &
                        "; return; }");
               else
                  Line ("if (a === " &
                        Trim_Image (Base_Offset + Fields (I).Offset_Bytes) & ") return " &
                        Field_Read_Expr (Base_JS, I) & ";");
               end if;
            end if;
         end loop;
      end Emit_Struct_Field_Cases;
   begin
      New_Line_Emit;
      Line ("function ALB_PEEK(addr: number): ALBValue {");
      Indent_Level := Indent_Level + 1;
      Line ("const a = addr | 0;");
      for I in 1 .. Symbol_Count loop
         if Symbols (I).Active
           and then To_String (Symbols (I).Scope) = ""
           and then Symbols (I).Offset_Bytes > 0
         then
            declare
               Base_JS  : constant String := To_String (Symbols (I).JS_Name);
               Base_Off : constant Integer := Symbols (I).Offset_Bytes;
               Elem     : constant Integer := Element_Bytes (Symbols (I).Tag);
               Span     : constant Integer := Integer'Max (1, Symbols (I).Capacity) * Elem;
            begin
               case Symbols (I).Kind is
                  when Sym_Scalar =>
                     Line ("if (a === " & Trim_Image (Base_Off) & ") return " & Base_JS & ";");
                  when Sym_Strict_Array | Sym_Slide_Array | Sym_Parallel_Field =>
                     Line ("if (a >= " & Trim_Image (Base_Off) & " && a < " &
                           Trim_Image (Base_Off + Span) & " && ((a - " &
                           Trim_Image (Base_Off) & ") % " & Trim_Image (Elem) &
                           ") === 0) return " & Base_JS & "[Math.trunc((a - " &
                           Trim_Image (Base_Off) & ") / " & Trim_Image (Elem) & ")];");
                  when Sym_Temporal =>
                     Line ("if (a === " & Trim_Image (Base_Off) & ") return " & Base_JS & ";");
                     if Symbols (I).Aux_Offset > 0 and then Symbols (I).History_Size > 0 then
                        Line ("if (a >= " & Trim_Image (Symbols (I).Aux_Offset) & " && a < " &
                              Trim_Image (Symbols (I).Aux_Offset + Symbols (I).History_Size * Elem) &
                              " && ((a - " & Trim_Image (Symbols (I).Aux_Offset) & ") % " &
                              Trim_Image (Elem) & ") === 0) return " & Base_JS &
                              "_history[Math.trunc((a - " & Trim_Image (Symbols (I).Aux_Offset) &
                              ") / " & Trim_Image (Elem) & ")];");
                     end if;
                  when Sym_Struct_Var =>
                     Emit_Struct_Field_Cases
                       (Base_JS,
                        Safe_JS_Name (To_String (Symbols (I).Struct_Name)),
                        Base_Off,
                        False);
                  when others =>
                     null;
               end case;
            end;
         end if;
      end loop;
      Line ("return 0;");
      Indent_Level := Indent_Level - 1;
      Line ("}");
      Line ("function ALB_DEREF(addr: number): ALBValue { return ALB_PEEK(addr); }");
      Line ("function ALB_POKE(addr: number, value: ALBValue): void {");
      Indent_Level := Indent_Level + 1;
      Line ("const a = addr | 0;");
      for I in 1 .. Symbol_Count loop
         if Symbols (I).Active
           and then To_String (Symbols (I).Scope) = ""
           and then Symbols (I).Offset_Bytes > 0
         then
            declare
               Base_JS  : constant String := To_String (Symbols (I).JS_Name);
               Base_Off : constant Integer := Symbols (I).Offset_Bytes;
               Elem     : constant Integer := Element_Bytes (Symbols (I).Tag);
               Span     : constant Integer := Integer'Max (1, Symbols (I).Capacity) * Elem;
            begin
               case Symbols (I).Kind is
                  when Sym_Scalar =>
                     Line ("if (a === " & Trim_Image (Base_Off) & ") { " & Base_JS & " = " &
                           Cast_Expr (Symbols (I).Tag, "value") & "; return; }");
                  when Sym_Strict_Array | Sym_Slide_Array | Sym_Parallel_Field =>
                     Line ("if (a >= " & Trim_Image (Base_Off) & " && a < " &
                           Trim_Image (Base_Off + Span) & " && ((a - " &
                           Trim_Image (Base_Off) & ") % " & Trim_Image (Elem) &
                           ") === 0) { " & Base_JS & "[Math.trunc((a - " &
                           Trim_Image (Base_Off) & ") / " & Trim_Image (Elem) &
                           ")] = " & Cast_Expr (Symbols (I).Tag, "value") & " as never; return; }");
                  when Sym_Temporal =>
                     Line ("if (a === " & Trim_Image (Base_Off) & ") { " & Base_JS & " = " &
                           Cast_Expr (Symbols (I).Tag, "value") & "; return; }");
                     if Symbols (I).Aux_Offset > 0 and then Symbols (I).History_Size > 0 then
                        Line ("if (a >= " & Trim_Image (Symbols (I).Aux_Offset) & " && a < " &
                              Trim_Image (Symbols (I).Aux_Offset + Symbols (I).History_Size * Elem) &
                              " && ((a - " & Trim_Image (Symbols (I).Aux_Offset) & ") % " &
                              Trim_Image (Elem) & ") === 0) { " & Base_JS &
                              "_history[Math.trunc((a - " & Trim_Image (Symbols (I).Aux_Offset) &
                              ") / " & Trim_Image (Elem) & ")] = " &
                              Cast_Expr (Symbols (I).Tag, "value") & " as never; return; }");
                     end if;
                  when Sym_Struct_Var =>
                     Emit_Struct_Field_Cases
                       (Base_JS,
                        Safe_JS_Name (To_String (Symbols (I).Struct_Name)),
                        Base_Off,
                        True);
                  when others =>
                     null;
               end case;
            end;
         end if;
      end loop;
      Indent_Level := Indent_Level - 1;
      Line ("}");
      New_Line_Emit;
   end Emit_Address_Routines;

   procedure Emit_State_Routines is
      procedure Emit_String_Array_Load
        (Target_Name : String;
         Source_Expr : String) is
      begin
         Line ("if (" & Source_Expr & ") { for (let i = 0; i < " & Target_Name &
               ".length && i < " & Source_Expr &
               ".length; i++) " & Target_Name & "[i] = String(" & Source_Expr &
               "[i] ?? """"); }");
      end Emit_String_Array_Load;
   begin
      New_Line_Emit;
      Line ("function ALB_SAVE_STATE(): void {");
      Indent_Level := Indent_Level + 1;
      Line ("const state: any = {");
      Indent_Level := Indent_Level + 1;
      Line ("vas: Array.from(albVas),");
      Line ("gcAlive: Array.from(albGcAlive),");
      Line ("gcRefs: Array.from(albGcRefs),");
      Line ("gcChildA: Array.from(albGcChildA),");
      Line ("gcChildB: Array.from(albGcChildB),");
      Line ("gcChildC: Array.from(albGcChildC),");
      Line ("gcChildD: Array.from(albGcChildD),");
      Line ("factLive: Array.from(albFactLive),");
      Line ("factKey: albFactKey.slice(),");
      Line ("factValue: albFactValue.slice(),");
      Line ("relLive: Array.from(albRelLive),");
      Line ("relPred: Array.from(albRelPred),");
      Line ("relArity: Array.from(albRelArity),");
      Line ("relArg1: Array.from(albRelArg1),");
      Line ("relArg2: Array.from(albRelArg2),");
      Line ("relArg3: Array.from(albRelArg3),");
      Line ("relArg4: Array.from(albRelArg4),");
      Line ("relValue: Array.from(albRelValue),");
      for I in 1 .. Symbol_Count loop
         if Symbols (I).Active
           and then To_String (Symbols (I).Scope) = ""
           and then Symbols (I).Kind not in Sym_Const | Sym_Param
         then
            declare
               Name : constant String := To_String (Symbols (I).JS_Name);
            begin
               case Symbols (I).Kind is
                  when Sym_Scalar =>
                     Line (Name & ": " & Name & ",");
                  when Sym_Strict_Array | Sym_Slide_Array | Sym_Parallel_Field =>
                     if Symbols (I).Tag in VK_String | VK_Binary then
                        Line (Name & ": " & Name & ".slice(),");
                     else
                        Line (Name & ": Array.from(" & Name & "),");
                     end if;
                     if Symbols (I).Kind = Sym_Slide_Array then
                        Line (Name & "_active: " & Name & "_active,");
                     end if;
                  when Sym_Temporal =>
                     Line (Name & ": " & Name & ",");
                     if Symbols (I).Tag in VK_String | VK_Binary then
                        Line (Name & "_history: " & Name & "_history.slice(),");
                     else
                        Line (Name & "_history: Array.from(" & Name & "_history),");
                     end if;
                     Line (Name & "_head: " & Name & "_head,");
                  when Sym_Struct_Var =>
                     Line (Name & ": " & Name & ",");
                  when others =>
                     null;
               end case;
            end;
         end if;
      end loop;
      Indent_Level := Indent_Level - 1;
      Line ("};");
      Line ("albSaveStore['alb_state'] = JSON.stringify(state);");
      Indent_Level := Indent_Level - 1;
      Line ("}");

      Line ("function ALB_LOAD_STATE(): void {");
      Indent_Level := Indent_Level + 1;
      Line ("const raw = albSaveStore['alb_state'];");
      Line ("if (!raw) return;");
      Line ("const state: any = JSON.parse(raw);");
      Line ("if (state.vas) albVas.set(state.vas as ArrayLike<number>);");
      Line ("if (state.gcAlive) albGcAlive.set(state.gcAlive as ArrayLike<number>);");
      Line ("if (state.gcRefs) albGcRefs.set(state.gcRefs as ArrayLike<number>);");
      Line ("if (state.gcChildA) albGcChildA.set(state.gcChildA as ArrayLike<number>);");
      Line ("if (state.gcChildB) albGcChildB.set(state.gcChildB as ArrayLike<number>);");
      Line ("if (state.gcChildC) albGcChildC.set(state.gcChildC as ArrayLike<number>);");
      Line ("if (state.gcChildD) albGcChildD.set(state.gcChildD as ArrayLike<number>);");
      Line ("if (state.factLive) albFactLive.set(state.factLive as ArrayLike<number>);");
      Emit_String_Array_Load ("albFactKey", "state.factKey");
      Line ("if (state.factValue) { for (let i = 0; i < albFactValue.length && i < state.factValue.length; i++) albFactValue[i] = state.factValue[i] as ALBValue; }");
      Line ("if (state.relLive) albRelLive.set(state.relLive as ArrayLike<number>);");
      Line ("if (state.relPred) albRelPred.set(state.relPred as ArrayLike<number>);");
      Line ("if (state.relArity) albRelArity.set(state.relArity as ArrayLike<number>);");
      Line ("if (state.relArg1) albRelArg1.set(state.relArg1 as ArrayLike<number>);");
      Line ("if (state.relArg2) albRelArg2.set(state.relArg2 as ArrayLike<number>);");
      Line ("if (state.relArg3) albRelArg3.set(state.relArg3 as ArrayLike<number>);");
      Line ("if (state.relArg4) albRelArg4.set(state.relArg4 as ArrayLike<number>);");
      Line ("if (state.relValue) albRelValue.set(state.relValue as ArrayLike<number>);");
      for I in 1 .. Symbol_Count loop
         if Symbols (I).Active
           and then To_String (Symbols (I).Scope) = ""
           and then Symbols (I).Kind not in Sym_Const | Sym_Param
         then
            declare
               Name : constant String := To_String (Symbols (I).JS_Name);
               Hist : constant String := Trim_Image (Integer'Max (1, Symbols (I).History_Size));
            begin
               case Symbols (I).Kind is
                  when Sym_Scalar =>
                     if Symbols (I).Tag in VK_String | VK_Binary then
                        Line ("if (state." & Name & " !== undefined) " & Name & " = String(state." & Name & ");");
                     elsif Symbols (I).Tag = VK_Boolean then
                        Line ("if (state." & Name & " !== undefined) " & Name & " = Boolean(state." & Name & ");");
                     else
                        Line ("if (state." & Name & " !== undefined) " & Name & " = " &
                              Cast_Expr (Symbols (I).Tag, "state." & Name) & ";");
                     end if;
                  when Sym_Strict_Array | Sym_Slide_Array | Sym_Parallel_Field =>
                     if Symbols (I).Tag in VK_String | VK_Binary then
                        Emit_String_Array_Load (Name, "state." & Name);
                     else
                        Line ("if (state." & Name & ") " & Name &
                              ".set(state." & Name & " as ArrayLike<number>);");
                     end if;
                     if Symbols (I).Kind = Sym_Slide_Array then
                        Line ("if (state." & Name & "_active !== undefined) " & Name &
                              "_active = state." & Name & "_active | 0;");
                     end if;
                  when Sym_Temporal =>
                     if Symbols (I).Tag in VK_String | VK_Binary then
                        Line ("if (state." & Name & " !== undefined) " & Name & " = String(state." & Name & ");");
                        Emit_String_Array_Load (Name & "_history", "state." & Name & "_history");
                     elsif Symbols (I).Tag = VK_Boolean then
                        Line ("if (state." & Name & " !== undefined) " & Name & " = Boolean(state." & Name & ");");
                        Line ("if (state." & Name & "_history) " & Name &
                              "_history.set((state." & Name & "_history as ArrayLike<number>));");
                     else
                        Line ("if (state." & Name & " !== undefined) " & Name & " = " &
                              Cast_Expr (Symbols (I).Tag, "state." & Name) & ";");
                        Line ("if (state." & Name & "_history) " & Name &
                              "_history.set((state." & Name & "_history as ArrayLike<number>));");
                     end if;
                     Line ("if (state." & Name & "_head !== undefined) " & Name &
                           "_head = ((state." & Name & "_head | 0) % " & Hist & " + " & Hist & ") % " & Hist & ";");
                  when Sym_Struct_Var =>
                     Line ("if (state." & Name & " !== undefined) " & Name &
                           " = state." & Name & " as typeof " & Name & ";");
                  when others =>
                     null;
               end case;
            end;
         end if;
      end loop;
      Indent_Level := Indent_Level - 1;
      Line ("}");
      New_Line_Emit;
   end Emit_State_Routines;

   procedure Emit_Logic_Setup is
   begin
      if Rule_Node_Count = 0 and Watch_Node_Count = 0 then
         return;
      end if;

      Line ("function ALB_INIT_LOGIC(): void {");
      Indent_Level := Indent_Level + 1;
      Line ("albRuleCount = 0;");

      for I in 1 .. Rule_Node_Count loop
         declare
            Rule_Node    : constant Node_Index := Rule_Nodes (I);
            Rule_AST     : constant AST_Node := Tree (Rule_Node);
            Head_Node    : constant Node_Index := Rule_AST.Left_Child;
            Body_Query   : constant Node_Index := Rule_AST.Right_Child;
            Curr_Body    : Node_Index :=
              (if Body_Query > 0 then Tree (Body_Query).Left_Child else 0);
            Rule_Offset  : constant Integer := Integer (I - 1);
            Head_Var     : constant String := Upper_Text (Logic_Var_Name_From_Node (Head_Node));
            Body_Count   : Natural := 0;
            Cut_Pos      : Integer := -1;
            Base_Index   : Integer := 0;
            Body_Arg     : Node_Index := 0;
            Mode_Value   : Integer := 0;
            Body_Arg_Name : Unbounded_String := U ("");
         begin
            Line ("albRuleHeadPred[" & Trim_Image (Rule_Offset) & "] = " &
                  Predicate_Id_Expr (Head_Node) & ";");
            Line ("albRuleFlags[" & Trim_Image (Rule_Offset) & "] = " &
                  (if Rule_AST.Kind = AST_Constraint_Decl then "1" else "0") & ";");

            while Curr_Body > 0 and then Body_Count < Max_Rule_Body_Terms loop
               if Tree (Curr_Body).Kind = AST_Cut_Stmt then
                  --  Clause-commitment barrier: once every term before
                  --  the cut matches, this rule is committed and later
                  --  rules for the same head are never tried.
                  Cut_Pos := Integer (Body_Count);
               else
                  Base_Index := Rule_Offset * Integer (Max_Rule_Body_Terms) + Integer (Body_Count);
                  Body_Arg := Predicate_First_Arg_Node (Curr_Body);
                  Body_Arg_Name := U ("");
                  if Body_Arg > 0 and then Tree (Body_Arg).Token_Index > 0 then
                     Body_Arg_Name := U (Upper_Text (Raw_Lexeme (Tree (Body_Arg).Token_Index)));
                  end if;
                  if Body_Arg > 0
                    and then
                      (Tree (Body_Arg).Kind = AST_Logic_Var
                       or else (Head_Var'Length > 0 and then To_String (Body_Arg_Name) = Head_Var))
                  then
                     Mode_Value := 1;
                  else
                     Mode_Value := 0;
                  end if;

                  Line ("albRuleBodyPred[" & Trim_Image (Base_Index) & "] = " &
                        Predicate_Id_Expr (Curr_Body) & ";");
                  Line ("albRuleBodyArgMode[" & Trim_Image (Base_Index) & "] = " &
                        Trim_Image (Mode_Value) & ";");
                  Line ("albRuleBodyArgConst[" & Trim_Image (Base_Index) & "] = " &
                        (if Body_Arg > 0 and then Mode_Value = 0 then Expr (Body_Arg) else "0") & ";");

                  Body_Count := Body_Count + 1;
               end if;
               Curr_Body := Tree (Curr_Body).Next_Sibling;
            end loop;

            Line ("albRuleBodyLen[" & Trim_Image (Rule_Offset) & "] = " &
                  Trim_Image (Integer (Body_Count)) & ";");
            Line ("albRuleCutPos[" & Trim_Image (Rule_Offset) & "] = " &
                  Trim_Image (Cut_Pos) & ";");
            Line ("albRuleCount = " & Trim_Image (Integer (I)) & ";");
         end;
      end loop;

      Indent_Level := Indent_Level - 1;
      Line ("}");
      New_Line_Emit;

      --  Hoisted function decl so the early wiring (before main code)
      --  can reference it even though it's emitted post-traversal.
      Line ("function ALB_WATCH_DISPATCH(pred: number, arg1: number, arg2: number, arg3: number, arg4: number): void {");
      Indent_Level := Indent_Level + 1;

      if Watch_Node_Count = 0 then
         Line ("return;");
      else
         Line ("switch (pred) {");
         Indent_Level := Indent_Level + 1;

         for I in 1 .. Watch_Node_Count loop
            declare
               Watch_Node : constant Node_Index := Watch_Nodes (I);
               Watch_AST  : constant AST_Node := Tree (Watch_Node);
               Pred_Node  : constant Node_Index := Watch_AST.Right_Child;
               Body_Node  : constant Node_Index := Watch_AST.Left_Child;
               Var_Name   : constant String := Logic_Var_Name_From_Node (Pred_Node);
               Var_JS     : constant String := Safe_JS_Name (Var_Name);
               Shadow_Id  : Natural := 0;
            begin
               Line ("case " & Predicate_Id_Expr (Pred_Node) & ": {");
               Indent_Level := Indent_Level + 1;
               if Var_Name'Length > 0 then
                  Line ("const " & Var_JS & " = arg1 | 0;");
                  Shadow_Id :=
                    Push_Shadow_Symbol
                      (Scope   => "",
                       Name    => Var_Name,
                       JS_Name => Var_JS,
                       Tag     => VK_Number);
               end if;
               Emit_Block (Body_Node);
               if Shadow_Id > 0 then
                  Pop_Shadow_Symbol (Shadow_Id);
               end if;
               Line ("break;");
               Indent_Level := Indent_Level - 1;
               Line ("}");
            end;
         end loop;

         Line ("default:");
         Indent_Level := Indent_Level + 1;
         Line ("break;");
         Indent_Level := Indent_Level - 1;
         Indent_Level := Indent_Level - 1;
         Line ("}");
      end if;

      Indent_Level := Indent_Level - 1;
      Line ("}");
      New_Line_Emit;
   end Emit_Logic_Setup;

   procedure Emit_Switch_Stmt
     (Expr_Node      : Node_Index;
      First_Case     : Node_Index) is
      Switch_Value : constant String := Next_Temp_Name ("switch_value");
      Curr_Case    : Node_Index := First_Case;
   begin
      Line ("{");
      Indent_Level := Indent_Level + 1;
      Line ("const " & Switch_Value & " = " & Expr (Expr_Node) & ";");
      Line ("switch (" & Switch_Value & ") {");
      Indent_Level := Indent_Level + 1;

      while Curr_Case > 0 loop
         if Tree (Curr_Case).Left_Child = 0 then
            Line ("default:");
         else
            Line ("case " & Expr (Tree (Curr_Case).Left_Child) & ":");
         end if;
         Indent_Level := Indent_Level + 1;
         Emit_Block (Tree (Curr_Case).Right_Child);
         Line ("break;");
         Indent_Level := Indent_Level - 1;
         Curr_Case := Tree (Curr_Case).Next_Sibling;
      end loop;

      Indent_Level := Indent_Level - 1;
      Line ("}");
      Indent_Level := Indent_Level - 1;
      Line ("}");
   end Emit_Switch_Stmt;

   procedure Emit_SwapPop
     (Target_Node : Node_Index;
      Count_Node  : Node_Index) is
      Target_AST    : constant AST_Node := Tree (Target_Node);
      Raw_Name      : constant String :=
        (if Target_AST.Token_Index > 0 then Raw_Lexeme (Target_AST.Token_Index) else "");
      Scoped_Group  : constant String := Scoped_Name (Raw_Name);
      Target_Sym    : constant Symbol_Record := Resolve_Symbol (Raw_Name);
      Count_Name    : constant String := Statement_Target_Name (Count_Node);
      Target_Index  : constant String :=
        (if Target_AST.Left_Child > 0
         then Build_Array_Index ((others => 0), 1, Target_AST.Left_Child)
         else "0");
      Swap_Index    : constant String := Next_Temp_Name ("swap_ix");
      Last_Index    : constant String := Next_Temp_Name ("last_ix");
      Found_Field   : Boolean := False;
   begin
      Line ("if (" & Count_Name & " > 0) {");
      Indent_Level := Indent_Level + 1;
      Line ("const " & Swap_Index & " = " & Target_Index & ";");
      Line ("const " & Last_Index & " = (" & Count_Name & " - 1);");
      Line ("if (" & Swap_Index & " !== " & Last_Index & ") {");
      Indent_Level := Indent_Level + 1;

      if Target_AST.Kind = AST_Var_Expr and then Target_AST.Left_Child > 0 then
         if Target_Sym.Active
           and then Target_Sym.Kind in Sym_Strict_Array | Sym_Slide_Array
         then
            Line (To_String (Target_Sym.JS_Name) & "[" & Swap_Index & "] = " &
                  To_String (Target_Sym.JS_Name) & "[" & Last_Index & "];");
            Found_Field := True;
         else
            for I in 1 .. Symbol_Count loop
               if Symbols (I).Active
                 and then Symbols (I).Kind = Sym_Parallel_Field
                 and then
                   (Starts_With (To_String (Symbols (I).Name), Scoped_Group & ".")
                    or else Starts_With (To_String (Symbols (I).Name), Raw_Name & "."))
               then
                  Line (To_String (Symbols (I).JS_Name) & "[" & Swap_Index & "] = " &
                        To_String (Symbols (I).JS_Name) & "[" & Last_Index & "];");
                  Found_Field := True;
               end if;
            end loop;
         end if;
      end if;

      if not Found_Field then
         Line ("/* SWAPPOP target could not be resolved statically */");
      end if;

      Indent_Level := Indent_Level - 1;
      Line ("}");
      Line (Count_Name & " -= 1;");
      Indent_Level := Indent_Level - 1;
      Line ("}");
   end Emit_SwapPop;

   procedure Emit_Assignment
     (Target_Node : Node_Index;
      Value_Node  : Node_Index;
      Decl_Tag    : Value_Kind;
      Declare_New : Boolean) is
      Target_Name : constant String := Statement_Target_Name (Target_Node, Decl_Tag);
      Target_Sym  : constant Symbol_Record := Target_Symbol (Target_Node);
      --  BigInt-array stores emit the value through Big_Expr so masks past
      --  2^53 keep their low bits — the BigInt64Array store itself applies
      --  the i64/u64 wrap. Fall back to albBig when the value embeds an
      --  OUT-call (Big_Expr can't route those) or is non-integer.
      Base_Value_Text : constant String :=
        (if Target_Sym.Is_Bigint
            and then Find_Func_Call_In_Expr (Value_Node) = 0
            and then Int_Kind (Infer_Expr_Kind (Value_Node))
         then Big_Expr (Value_Node)
         elsif Target_Sym.Is_Bigint
         then "albBig(" & Emit_Value_Expr_With_Out (Value_Node) & ")"
         else Cast_Expr (Decl_Tag, Emit_Value_Expr_With_Out (Value_Node)));
      Value_Text      : constant String :=
        Wrap_Firewall_Write (Target_Node, Base_Value_Text);
   begin
      if Target_Node > 0 and then Tree (Target_Node).Kind = AST_Member_Expr then
         declare
            MNode      : constant AST_Node := Tree (Target_Node);
            Left_Node  : constant AST_Node := Tree (MNode.Left_Child);
            Right_Node : constant AST_Node := Tree (MNode.Right_Child);
            Left_Sym   : constant Symbol_Record :=
              (if Left_Node.Token_Index > 0
               then Resolve_Symbol_Shaped
                      (Raw_Lexeme (Left_Node.Token_Index),
                       Want_Array => Left_Node.Left_Child > 0,
                       Strict     => Left_Node.Left_Child = 0)
               else (others => <>));
            Field_Id   : constant Natural :=
              (if Left_Sym.Active and then Left_Sym.Kind = Sym_Struct_Var and then Right_Node.Token_Index > 0
               then Find_Field (To_String (Left_Sym.Struct_Name), Safe_JS_Name (Raw_Lexeme (Right_Node.Token_Index)))
               else 0);
         begin
            if Field_Id /= 0 then
               --  LAMBDA bound to a field: strict signature check against
               --  the field's declared ROUTINE type.
               if Tree (Value_Node).Kind = AST_Lambda_Expr then
                  Check_Lambda_Bind
                    (Value_Node, To_String (Fields (Field_Id).Type_Name));
                  --  Self-recursion ban for field targets: member access
                  --  resolves as the composite "h.check", so stamping
                  --  that name seals `h.check(...)` self-calls while
                  --  leaving plain `h` legal.
                  if Lambda_Count > 0 then
                     Lambda_Bound_Queue (Lambda_Count) :=
                       To_Unbounded_String
                         (Raw_Lexeme (Left_Node.Token_Index) & "." &
                          Raw_Lexeme (Right_Node.Token_Index));
                  end if;
               end if;
               --  Cast at the FIELD's tag, not the caller's: routine-typed
               --  fields (check AS Cmp) must not get a numeric cast.
               Line (Field_Write_Expr
                       (To_String (Left_Sym.JS_Name), Field_Id,
                        Wrap_Firewall_Write
                          (Target_Node,
                           Cast_Expr
                             (Fields (Field_Id).Tag,
                              Emit_Value_Expr_With_Out (Value_Node)))) & ";");
               return;
            end if;
         end;
      end if;

      --  LAMBDA bound to a plain var: strict signature check against the
      --  ROUTINE alias the var was declared with (recorded at LET time).
      --  NOTE: Value_Text already elaborated in the declarative part, so
      --  the RHS lambda is already queued — stamp the bound name onto the
      --  slot it just took (self-recursion ban) rather than a pre-set.
      if Value_Node > 0 and then Tree (Value_Node).Kind = AST_Lambda_Expr then
         Check_Lambda_Bind (Value_Node, To_String (Target_Sym.Routine_Alias));
         if Lambda_Count > 0 then
            Lambda_Bound_Queue (Lambda_Count) := Target_Sym.Name;
         end if;
      end if;

      --  Whole-struct assignment (`q = p` on struct vars): JS `=` aliases
      --  the object, so emit a shallow field copy instead.
      if Target_Node > 0 and then Tree (Target_Node).Kind = AST_Var_Expr
        and then Tree (Target_Node).Left_Child = 0
        and then Tree (Target_Node).Token_Index > 0
      then
         declare
            T_Sym : constant Symbol_Record :=
              Resolve_Symbol_Shaped
                (Raw_Lexeme (Tree (Target_Node).Token_Index),
                 Want_Array => False, Strict => True);
         begin
            if T_Sym.Active and then T_Sym.Kind = Sym_Struct_Var then
               if Declare_New then
                  Line ("var " & Target_Name & ": " & Primitive_TS_Type (Decl_Tag) &
                        " = { ...(" & Value_Text & ") };");
               else
                  Line (Target_Name & " = { ...(" & Value_Text & ") };");
               end if;
               return;
            end if;
         end;
      end if;

      if Declare_New then
         --  ALB variables are routine-scoped, so emit function-scoped JS
         --  declarations here instead of block-scoped `let`.
         Line ("var " & Target_Name & ": " & Primitive_TS_Type (Decl_Tag) & " = " & Value_Text & ";");
      else
         Line (Target_Name & " = " & Value_Text & ";");
      end if;
   end Emit_Assignment;

   procedure Emit_Block (Block_Node : Node_Index) is
      Curr : Node_Index := 0;
   begin
      if Block_Node = 0 then
         return;
      end if;

      if Tree (Block_Node).Kind = AST_Block_Stmt then
         Curr := Tree (Block_Node).Left_Child;
      else
         Curr := Block_Node;
      end if;

      while Curr > 0 loop
         Emit_Node (Curr);
         Curr := Tree (Curr).Next_Sibling;
      end loop;
   end Emit_Block;

   procedure Register_Struct_From_Node (Index : Node_Index) is
      Node        : constant AST_Node := Tree (Index);
      Name_Node   : constant Node_Index := Node.Left_Child;
      Block_Node  : constant Node_Index := Node.Right_Child;
      Struct_Name : constant String := Safe_JS_Name (Raw_Lexeme (Tree (Name_Node).Token_Index));
      Curr        : Node_Index := 0;
      Offset      : Integer := 0;
      Bit_Shift   : Integer := 0;
   begin
      if Name_Node = 0 or else Find_Struct (Struct_Name) /= 0 then
         return;
      end if;

      if Struct_Count < Max_Structs then
         Struct_Count := Struct_Count + 1;
         Structs (Struct_Count).Active := True;
         Structs (Struct_Count).Name := U (Struct_Name);
      end if;

      if Block_Node > 0 then
         Curr := Tree (Block_Node).Left_Child;
         while Curr > 0 loop
            declare
               Field_Node : constant AST_Node := Tree (Curr);
               Kind       : Value_Kind := VK_Number;
               Field_Name : Unbounded_String := U ("");
               Width      : Integer := 0;
               Shift      : Integer := 0;
            begin
               if Field_Node.Kind = AST_Bitfield_Decl then
                  if Field_Node.Left_Child > 0 then
                     Field_Name := U (Safe_JS_Name (Raw_Lexeme (Tree (Field_Node.Left_Child).Token_Index)));
                  end if;
                  Width := Integer'Max (1, Eval_Static_Int (Field_Node.Right_Child));
                  Shift := Bit_Shift;
                  Kind := VK_U32;
               else
                  declare
                     Field_Name_Node : constant Node_Index := Field_Node.Left_Child;
                  begin
                     if Bit_Shift > 0 then
                        Offset := Offset + 1;
                        Bit_Shift := 0;
                     end if;
                     if Field_Name_Node > 0 then
                        Field_Name := U (Safe_JS_Name (Raw_Lexeme (Tree (Field_Name_Node).Token_Index)));
                     end if;
                     if Field_Node.Token_Index > 0 then
                        Kind := Type_From_Name (Raw_Lexeme (Field_Node.Token_Index));
                     end if;
                  end;
               end if;

               if Field_Count < Max_Fields then
                  Field_Count := Field_Count + 1;
                  Fields (Field_Count).Active := True;
                  Fields (Field_Count).Struct_Name := U (Struct_Name);
                  Fields (Field_Count).Field_Name := Field_Name;
                  Fields (Field_Count).JS_Field := Field_Name;
                  Fields (Field_Count).Type_Name :=
                    (if Field_Node.Token_Index > 0
                     then U (Raw_Lexeme (Field_Node.Token_Index))
                     else U (""));
                  Fields (Field_Count).Tag := Kind;
                  Fields (Field_Count).Offset_Bytes := Offset;
                  Fields (Field_Count).Bit_Width := Width;
                  Fields (Field_Count).Bit_Shift := Shift;
               end if;

               if Width > 0 then
                  Bit_Shift := Bit_Shift + Width;
                  while Bit_Shift >= 8 loop
                     Bit_Shift := Bit_Shift - 8;
                     Offset := Offset + 1;
                  end loop;
               else
                  Offset := Offset + Element_Bytes (Kind);
               end if;
            end;
            Curr := Tree (Curr).Next_Sibling;
         end loop;
      end if;

      if Bit_Shift > 0 then
         Offset := Offset + 1;
      end if;
      Structs (Struct_Count).Size_Bytes := Offset;
   end Register_Struct_From_Node;

   procedure Register_Routine_Signature (Index : Node_Index) is
      Node        : constant AST_Node := Tree (Index);
      Name_Node   : constant Node_Index := Node.Left_Child;
      Param_Count : Natural := 0;
      Modes       : Param_Mode_List := (others => Param_In);
      Curr_Param  : Node_Index := 0;
      List_Node   : Node_Index := 0;
   begin
      if Name_Node = 0 or else Tree (Name_Node).Token_Index = 0 then
         return;
      end if;

      List_Node := Tree (Name_Node).Right_Child;
      if List_Node > 0 and then Tree (List_Node).Kind = AST_Arg_List then
         Curr_Param := Tree (List_Node).Left_Child;
         while Curr_Param > 0 loop
            if Tree (Curr_Param).Kind = AST_Param_Decl then
               Param_Count := Param_Count + 1;
               if Param_Count <= Max_Params
                 and then Tree (Curr_Param).Token_Index > 0
                 and then Tokens (Tree (Curr_Param).Token_Index).Kind = Tok_Out
               then
                  Modes (Param_Count) := Param_Out;
               end if;
            end if;
            Curr_Param := Tree (Curr_Param).Next_Sibling;
         end loop;
      end if;

      declare
         Func_Name : constant String := Raw_Lexeme (Tree (Name_Node).Token_Index);
         JS_Name   : constant String :=
           (if Upper_Text (Func_Name) = "GETTICKCOUNT"
            then "ALB_User_GetTickCount"
            else Scoped_Name (Func_Name));
         Ret_Kind  : constant Value_Kind := Type_From_Token (Node.Token_Index);
      begin
         Register_Routine (Func_Name, JS_Name, Param_Count, Modes,
                           Return_Kind => Ret_Kind);
      end;
   end Register_Routine_Signature;

   procedure Pre_Register_Routines (First : Node_Index) is
      Curr : Node_Index := First;
   begin
      while Curr > 0 loop
         case Tree (Curr).Kind is
            when AST_Program | AST_Block_Stmt =>
               Pre_Register_Routines (Tree (Curr).Left_Child);

            when AST_Module | AST_DeclareModule =>
               declare
                  Name_Node    : constant Node_Index := Tree (Curr).Left_Child;
                  Saved_Module : constant Unbounded_String := Current_Module;
               begin
                  if Name_Node > 0 and then Tree (Name_Node).Token_Index > 0 then
                     Current_Module := U (Safe_JS_Name (Raw_Lexeme (Tree (Name_Node).Token_Index)));
                  end if;
                  Pre_Register_Routines (Tree (Curr).Right_Child);
                  Current_Module := Saved_Module;
               end;

            when AST_Procedure_Decl | AST_Function_Decl =>
               Register_Routine_Signature (Curr);
               Pre_Register_Routines (Tree (Curr).Right_Child);

            when AST_Range_Type_Decl =>
               if Tree (Curr).Left_Child > 0
                 and then Tree (Curr).Right_Child > 0
               then
                  Register_Type_Alias
                    (Raw_Lexeme (Tree (Tree (Curr).Left_Child).Token_Index),
                     Raw_Lexeme (Tree (Tree (Curr).Right_Child).Token_Index),
                     False);
               end if;

            when AST_Routine_Type_Decl =>
               if Tree (Curr).Left_Child > 0 then
                  Register_Type_Alias
                    (Raw_Lexeme (Tree (Tree (Curr).Left_Child).Token_Index),
                     "", True, Curr);
               end if;

            when others =>
               if Tree (Curr).Left_Child > 0 then
                  Pre_Register_Routines (Tree (Curr).Left_Child);
               end if;
               if Tree (Curr).Right_Child > 0 then
                  Pre_Register_Routines (Tree (Curr).Right_Child);
               end if;
         end case;
         Curr := Tree (Curr).Next_Sibling;
      end loop;
   end Pre_Register_Routines;

   procedure Pre_Scan_Implicit_Locals (Body_Node : Node_Index) is
      --  ALB vars are routine-scoped: a bare `s = s + x` first-assignment
      --  declares `s` implicitly and reads the zero value. Emitting
      --  `var s = s + x` inside a loop body reads `undefined` (hoisted
      --  var) or resets per iteration, so scan the body first and hoist
      --  `var name = <init>` to the routine top. Typed LETs, params and
      --  FOR vars are already declared elsewhere; nested routine bodies
      --  are separate scopes and skipped.
      Max_Imp : constant := 256;
      Declared_Names : array (1 .. Max_Imp) of Unbounded_String;
      Implicit_Names : array (1 .. Max_Imp) of Unbounded_String;
      Implicit_Value : array (1 .. Max_Imp) of Node_Index;
      D_Count : Natural := 0;
      I_Count : Natural := 0;

      function Listed (Set : Natural; Name : String) return Boolean is
      begin
         if Set = 1 then
            for I in 1 .. D_Count loop
               if To_String (Declared_Names (I)) = Name then
                  return True;
               end if;
            end loop;
         else
            for I in 1 .. I_Count loop
               if To_String (Implicit_Names (I)) = Name then
                  return True;
               end if;
            end loop;
         end if;
         return False;
      end Listed;

      procedure Walk (N : Node_Index) is
         Idx : Node_Index := N;
         NN  : AST_Node;
      begin
         while Idx > 0 loop
            NN := Tree (Idx);
            if NN.Kind = AST_Function_Decl or else NN.Kind = AST_Procedure_Decl then
               null; -- nested routine: separate scope
            else
               if NN.Kind = AST_Let_Stmt
                 and then NN.Left_Child > 0
                 and then Tree (NN.Left_Child).Kind = AST_Var_Expr
                 and then Tree (NN.Left_Child).Left_Child = 0
                 and then Tree (NN.Left_Child).Token_Index > 0
               then
                  declare
                     VN : constant String := Raw_Lexeme (Tree (NN.Left_Child).Token_Index);
                  begin
                     if NN.Token_Index > 0
                       and then Type_From_Token (NN.Token_Index) /= VK_Unknown
                     then
                        if D_Count < Max_Imp and then not Listed (1, VN) then
                           D_Count := D_Count + 1;
                           Declared_Names (D_Count) := U (VN);
                        end if;
                     else
                        if I_Count < Max_Imp and then not Listed (2, VN) then
                           I_Count := I_Count + 1;
                           Implicit_Names (I_Count) := U (VN);
                           Implicit_Value (I_Count) := NN.Right_Child;
                        end if;
                     end if;
                  end;
               elsif NN.Kind = AST_For_Stmt and then NN.Token_Index > 0 then
                  declare
                     VN : constant String := Raw_Lexeme (NN.Token_Index);
                  begin
                     if D_Count < Max_Imp and then not Listed (1, VN) then
                        D_Count := D_Count + 1;
                        Declared_Names (D_Count) := U (VN);
                     end if;
                  end;
               end if;
               Walk (NN.Left_Child);
               Walk (NN.Right_Child);
            end if;
            Idx := NN.Next_Sibling;
         end loop;
      end Walk;

   begin
      if Body_Node = 0 then
         return;
      end if;
      Walk (Body_Node);
      for I in 1 .. I_Count loop
         declare
            VN : constant String := To_String (Implicit_Names (I));
         begin
            if not Listed (1, VN)
              and then Find_Symbol_Shaped
                         (To_String (Current_Routine), VN,
                          Want_Array => False, Strict => True) = 0
              and then Find_Symbol_Shaped
                         ("", Scoped_Name (VN),
                          Want_Array => False, Strict => True) = 0
              and then Find_Symbol_Shaped
                         ("", Safe_JS_Name (VN),
                          Want_Array => False, Strict => True) = 0
            then
               declare
                  Init_Kind : constant Value_Kind :=
                    Infer_Expr_Kind (Implicit_Value (I));
               begin
                  Register_Symbol
                    (To_String (Current_Routine), VN, Safe_JS_Name (VN),
                     (if Init_Kind = VK_Unknown then VK_Number else Init_Kind),
                     Sym_Scalar);
                  Line ("var " & Safe_JS_Name (VN) & " = " &
                    (if Init_Kind in VK_String | VK_Binary then """"""
                     elsif Init_Kind = VK_Boolean then "false"
                     else "0") & ";");
               end;
            end if;
         end;
      end loop;
   end Pre_Scan_Implicit_Locals;

   procedure Emit_Function_Decl
     (Index       : Node_Index;
      Is_Function : Boolean) is
      Node         : constant AST_Node := Tree (Index);
      Name_Node    : constant Node_Index := Node.Left_Child;
      Body_Node    : constant Node_Index := Node.Right_Child;
      Func_Name    : constant String := Raw_Lexeme (Tree (Name_Node).Token_Index);
      JS_Name      : constant String :=
        (if Upper_Text (Func_Name) = "GETTICKCOUNT"
         then "ALB_User_GetTickCount"
         else Scoped_Name (Func_Name));
      Old_Routine  : constant Unbounded_String := Current_Routine;
      Param_Count  : Natural := 0;
      Modes        : Param_Mode_List := (others => Param_In);
      Curr_Param   : Node_Index := 0;
      First_Param  : Boolean := True;
      List_Node    : Node_Index := 0;
      Return_Type  : Value_Kind := VK_Number;
      Bound_Node   : Node_Index := 0;
   begin
      if Name_Node = 0 then
         return;
      end if;

      Current_Routine := U (JS_Name);
      Current_Routine_Out_Count := 0;

      if Is_Function and then Node.Token_Index > 0 then
         Return_Type := Type_From_Token (Node.Token_Index);
         if Return_Type = VK_Unknown then
            Return_Type := VK_Number;
         end if;
      end if;

      Emit_Indent;
      Emit ("function " & JS_Name & "(");

      List_Node := Tree (Name_Node).Right_Child;
      if List_Node > 0 and then Tree (List_Node).Kind = AST_Arg_List then
         Curr_Param := Tree (List_Node).Left_Child;
         while Curr_Param > 0 loop
            if Tree (Curr_Param).Kind = AST_Param_Decl then
               declare
                  Mode_Tok : constant Natural := Tree (Curr_Param).Token_Index;
                  Param_Name_Node : constant Node_Index := Tree (Curr_Param).Left_Child;
                  Type_Node       : constant Node_Index := Tree (Curr_Param).Right_Child;
                  Param_Name      : constant String :=
                    Raw_Lexeme (Tree (Param_Name_Node).Token_Index);
                  Param_Kind      : constant Value_Kind :=
                    (if Type_Node > 0
                     then Type_From_Name (Raw_Lexeme (Tree (Type_Node).Token_Index))
                     else VK_Number);
                  Mode            : constant Param_Mode_Kind :=
                    (if Mode_Tok > 0 and then Tokens (Mode_Tok).Kind = Tok_Out
                     then Param_Out
                     else Param_In);
                  Decl_Name       : constant String :=
                    (if Mode = Param_Out
                     then "__out_" & Safe_JS_Name (Param_Name)
                     else Safe_JS_Name (Param_Name));
               begin
                  if not First_Param then
                     Emit (", ");
                  end if;
                  if Mode = Param_Out then
                     Emit (Decl_Name & ": { value: " & Primitive_TS_Type (Param_Kind) & " }");
                     if Current_Routine_Out_Count < Max_Params then
                        Current_Routine_Out_Count := Current_Routine_Out_Count + 1;
                        Current_Routine_Out_Names (Current_Routine_Out_Count) :=
                          U (Safe_JS_Name (Param_Name));
                     end if;
                  else
                     Emit (Decl_Name & ": " & Primitive_TS_Type (Param_Kind));
                  end if;
                  First_Param := False;
                  Param_Count := Param_Count + 1;
                  if Param_Count <= Max_Params then
                     Modes (Param_Count) := Mode;
                  end if;
               end;
            end if;
            Curr_Param := Tree (Curr_Param).Next_Sibling;
         end loop;
      end if;

      if Is_Function then
         Emit ("): " & Primitive_TS_Type (Return_Type) & " {");
      else
         Emit ("): void {");
      end if;
      New_Line_Emit;
      Indent_Level := Indent_Level + 1;

      Register_Routine (Func_Name, JS_Name, Param_Count, Modes);

      if List_Node > 0 and then Tree (List_Node).Kind = AST_Arg_List then
         Curr_Param := Tree (List_Node).Left_Child;
         while Curr_Param > 0 loop
            if Tree (Curr_Param).Kind = AST_Param_Decl then
               declare
                  Mode_Tok : constant Natural := Tree (Curr_Param).Token_Index;
                  Param_Name_Node : constant Node_Index := Tree (Curr_Param).Left_Child;
                  Type_Node       : constant Node_Index := Tree (Curr_Param).Right_Child;
                  Param_Name      : constant String :=
                    Raw_Lexeme (Tree (Param_Name_Node).Token_Index);
                  Param_Kind      : constant Value_Kind :=
                    (if Type_Node > 0
                     then Type_From_Name (Raw_Lexeme (Tree (Type_Node).Token_Index))
                     else VK_Number);
                  Mode            : constant Param_Mode_Kind :=
                    (if Mode_Tok > 0 and then Tokens (Mode_Tok).Kind = Tok_Out
                     then Param_Out
                     else Param_In);
                  Decl_Name       : constant String := Safe_JS_Name (Param_Name);
               begin
                  Register_Symbol
                    (Scope => JS_Name,
                     Name => Param_Name,
                     JS_Name => Decl_Name,
                     Tag => Param_Kind,
                     Kind => Sym_Param);
                  if Mode = Param_Out then
                     Line ("let " & Decl_Name & ": " & Primitive_TS_Type (Param_Kind) &
                           " = __out_" & Decl_Name & ".value;");
                  end if;
               end;
            elsif Tree (Curr_Param).Kind = AST_Require_Clause then
               Line ("if (!Boolean(" & Expr (Tree (Curr_Param).Left_Child) &
                     ")) { ALB_FATAL('REQUIRE failed'); }");
            elsif Tree (Curr_Param).Kind = AST_Bound_To_Clause then
               Bound_Node := Curr_Param;
            end if;
            Curr_Param := Tree (Curr_Param).Next_Sibling;
         end loop;
      end if;

      if Bound_Node > 0 and then Tree (Bound_Node).Left_Child > 0 then
         Line ("ALB_FIREWALL_ENTER(" & Expr (Tree (Bound_Node).Left_Child) & ");");
         Line ("try {");
         Indent_Level := Indent_Level + 1;
      end if;

      Pre_Scan_Implicit_Locals (Body_Node);
      Emit_Block (Body_Node);

      if Param_Count > 0 then
         Curr_Param := Tree (List_Node).Left_Child;
         while Curr_Param > 0 loop
            if Tree (Curr_Param).Kind = AST_Param_Decl then
               declare
                  Mode_Tok : constant Natural := Tree (Curr_Param).Token_Index;
                  Param_Name_Node : constant Node_Index := Tree (Curr_Param).Left_Child;
                  Param_Name : constant String := Safe_JS_Name (Raw_Lexeme (Tree (Param_Name_Node).Token_Index));
               begin
                  if Mode_Tok > 0 and then Tokens (Mode_Tok).Kind = Tok_Out then
                     Line ("__out_" & Param_Name & ".value = " & Param_Name & ";");
                  end if;
               end;
            end if;
            Curr_Param := Tree (Curr_Param).Next_Sibling;
         end loop;
      end if;

      if not Is_Function then
         Line ("return;");
      end if;

      if Bound_Node > 0 and then Tree (Bound_Node).Left_Child > 0 then
         Indent_Level := Indent_Level - 1;
         Line ("} finally {");
         Indent_Level := Indent_Level + 1;
         Line ("ALB_FIREWALL_LEAVE();");
         Indent_Level := Indent_Level - 1;
         Line ("}");
      end if;

      Indent_Level := Indent_Level - 1;
      Line ("}");
      New_Line_Emit;

      Current_Routine := Old_Routine;
   end Emit_Function_Decl;

   -- =========================================================================
   -- LAMBDA support
   -- =========================================================================
   --  `LET f AS Cmp = LAMBDA(p AS T, ...) [AS r] ... END LAMBDA` hoists to
   --  a top-level `function __alb_lambda_N(...)`; the binding stores the
   --  name.  Globals + params only by design — emitting at file scope
   --  makes the no-capture rule self-enforcing (a routine-local reference
   --  inside a lambda simply resolves to nothing).

   --  Called at the top of the symbol resolvers: a lambda may never
   --  reference the variable it binds to (self-recursion is banned —
   --  recursion is disallowed language-wide to prevent runaway code).
   procedure Lambda_Bound_Guard (Raw : String) is
   begin
      if In_Lambda
        and then Length (Lambda_Bound) > 0
        and then Upper_Text (Raw) = Upper_Text (To_String (Lambda_Bound))
      then
         raise Program_Error with
           "LAMBDA cannot reference its own binding ('" & Raw &
           "' — recursion is not allowed)";
      end if;
   end Lambda_Bound_Guard;

   --  Called at resolver fallthrough (name resolved to nothing global or
   --  lambda-local): if the name only exists as a routine-local/param of
   --  some *other* routine, this lambda tried to capture it — hard error.
   --  Without this the reference emits bare and dies as a runtime
   --  ReferenceError instead of a compile-time diagnostic.
   procedure Lambda_Orphan_Guard (Raw : String) is
      Folded : constant String := Upper_Text (Raw);
   begin
      if not In_Lambda then
         return;
      end if;
      for I in 1 .. Symbol_Count loop
         if Symbols (I).Active
           and then To_String (Symbols (I).Scope) /= ""
           and then To_String (Symbols (I).Scope) /=
                    To_String (Current_Routine)
           and then Upper_Text (To_String (Symbols (I).Name)) = Folded
         then
            raise Program_Error with
              "LAMBDA cannot capture routine-local '" & Raw &
              "' (globals + own params only)";
         end if;
      end loop;
   end Lambda_Orphan_Guard;

   function Queue_Lambda (Index : Node_Index) return String is
   begin
      if Lambda_Count >= Max_Lambdas then
         raise Program_Error with
           "too many LAMBDA expressions (limit" &
           Integer'Image (Max_Lambdas) & ")";
      end if;
      Lambda_Count := Lambda_Count + 1;
      Lambda_Queue (Lambda_Count) := Index;
      --  Bound name is stamped by the bind site after queueing — the RHS
      --  lambda is always the most recent slot at that point.
      return "__alb_lambda_" & Trim_Image (Integer (Lambda_Count));
   end Queue_Lambda;

   --  Strict signature check: the LAMBDA's declared param/return types
   --  must exactly match the bound ROUTINE alias's declaration.
   procedure Check_Lambda_Bind
     (Lambda_Node : Node_Index;
      Alias_Name  : String) is
      Alias_Id : constant Natural := Find_Type_Alias (Alias_Name);
      Decl     : Node_Index;
      AList    : Node_Index;
      LList    : Node_Index;
      AP       : Node_Index;
      LP       : Node_Index;
      PNum     : Natural := 0;
   begin
      if Alias_Name'Length = 0 then
         raise Program_Error with
           "LAMBDA requires an explicit ROUTINE-typed binding " &
           "(declare the target AS a ROUTINE type)";
      end if;
      if Alias_Id = 0 or else not Type_Aliases (Alias_Id).Is_Routine then
         raise Program_Error with
           "LAMBDA requires a ROUTINE-typed binding (got '" &
           Alias_Name & "')";
      end if;
      Decl  := Type_Aliases (Alias_Id).Decl_Node;
      AList := (if Decl > 0 then Tree (Decl).Right_Child else 0);
      LList := (if Lambda_Node > 0 then Tree (Lambda_Node).Left_Child else 0);
      if AList = 0 or else Tree (AList).Kind /= AST_Arg_List
        or else LList = 0 or else Tree (LList).Kind /= AST_Arg_List
      then
         raise Program_Error with
           "LAMBDA signature check failed (malformed ROUTINE '" &
           Alias_Name & "' declaration)";
      end if;

      AP := Tree (AList).Left_Child;
      LP := Tree (LList).Left_Child;
      while AP > 0 or else LP > 0 loop
         if AP = 0 or else LP = 0 then
            raise Program_Error with
              "LAMBDA param count doesn't match ROUTINE '" &
              Alias_Name & "'";
         end if;
         declare
            AType : constant Node_Index := Tree (AP).Right_Child;
            LType : constant Node_Index := Tree (LP).Right_Child;
            ANam  : constant String :=
              (if AType > 0
               then Upper_Text (Raw_Lexeme (Tree (AType).Token_Index))
               else "");
            LNam  : constant String :=
              (if LType > 0
               then Upper_Text (Raw_Lexeme (Tree (LType).Token_Index))
               else "");
         begin
            PNum := PNum + 1;
            if ANam /= LNam then
               raise Program_Error with
                 "LAMBDA param" & Integer'Image (PNum) &
                 " type '" & LNam & "' doesn't match ROUTINE '" &
                 Alias_Name & "' (expected '" & ANam & "')";
            end if;
         end;
         AP := Tree (AP).Next_Sibling;
         LP := Tree (LP).Next_Sibling;
      end loop;

      declare
         ARet : constant Node_Index := Tree (AList).Right_Child;
         LRet : constant Node_Index := Tree (LList).Right_Child;
         ANam : constant String :=
           (if ARet > 0
            then Upper_Text (Raw_Lexeme (Tree (ARet).Token_Index))
            else "");
         LNam : constant String :=
           (if LRet > 0
            then Upper_Text (Raw_Lexeme (Tree (LRet).Token_Index))
            else "");
      begin
         if ANam /= LNam then
            raise Program_Error with
              "LAMBDA return type '" &
              (if LNam'Length = 0 then "void" else LNam) &
              "' doesn't match ROUTINE '" & Alias_Name &
              "' (expected '" &
              (if ANam'Length = 0 then "void" else ANam) & "')";
         end if;
      end;
   end Check_Lambda_Bind;

   --  Return the ROUTINE alias name a decl type token resolves to
   --  (`AS Cmp` -> "Cmp"), or "" for non-routine / missing types.
   function Routine_Alias_Of (Token_Idx : Natural) return String is
      AId : constant Natural :=
        (if Token_Idx > 0
         then Find_Type_Alias (Raw_Lexeme (Token_Idx))
         else 0);
   begin
      if AId /= 0 and then Type_Aliases (AId).Is_Routine then
         return Raw_Lexeme (Token_Idx);
      end if;
      return "";
   end Routine_Alias_Of;

   -- =========================================================================
   -- EMOTION support
   -- =========================================================================
   --  `EMOTION name AXES a b c END_EMOTION` registers a global U8 vector
   --  (FASM: ALB_EMOTION_<name> bytes + _COUNT). Ops resolve axis names
   --  to byte offsets at compile time; all values saturate to 0..255.

   function Find_Emotion (Name : String) return Natural is
      Folded : constant String := Upper_Text (Name);
   begin
      for I in 1 .. Emotion_Count loop
         if Emotions (I).Active
           and then Upper_Text (To_String (Emotions (I).Name)) = Folded
         then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Emotion;

   function Find_Emotion_Axis (E_Idx : Natural; Axis : String) return Natural is
      Folded : constant String := Upper_Text (Axis);
   begin
      if E_Idx = 0 then
         return 0;
      end if;
      for I in 1 .. Emotions (E_Idx).Axis_Count loop
         if Upper_Text (To_String (Emotions (E_Idx).Axes (I))) = Folded then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Emotion_Axis;

   --  Resolve an emotion/axis reference node to its name. The grammar
   --  accepts general expressions but lowering only supports plain names
   --  (matching the FASM backend's Raw_Lexeme lookup).
   function Emotion_Name_Of (Idx : Node_Index) return String is
   begin
      if Idx > 0 and then Tree (Idx).Token_Index > 0 then
         return Raw_Lexeme (Tree (Idx).Token_Index);
      end if;
      return "";
   end Emotion_Name_Of;

   --  Shared name/offset resolution + fatal-on-unknown. Returns the
   --  scoped JS array name via out param.
   procedure Resolve_Emotion_Axis
     (Emotion_Node : Node_Index;
      Axis_Node    : Node_Index;
      JS_Array     : out Unbounded_String;
      Axis_Off     : out Natural;
      What         : String) is
      E_Idx : constant Natural := Find_Emotion (Emotion_Name_Of (Emotion_Node));
   begin
      Axis_Off := Find_Emotion_Axis (E_Idx, Emotion_Name_Of (Axis_Node));
      if E_Idx = 0 or else Axis_Off = 0 then
         raise Program_Error with
           "EMOTION " & What & " needs a declared EMOTION name and a " &
           "declared axis (got '" & Emotion_Name_Of (Emotion_Node) &
           "' / '" & Emotion_Name_Of (Axis_Node) & "')";
      end if;
      JS_Array := U ("ALB_EMOTION_" &
                     Scoped_Name (Emotion_Name_Of (Emotion_Node)));
      Axis_Off := Axis_Off - 1;
   end Resolve_Emotion_Axis;

   procedure Emit_Emotion_Decl (Index : Node_Index) is
      Node      : constant AST_Node := Tree (Index);
      Axes_Node : constant Node_Index := Node.Right_Child;
      Axis_Node : Node_Index;
      Name      : constant String := Emotion_Name_Of (Node.Left_Child);
      Count     : Natural := 0;
   begin
      --  FASM parity: emotions are file-scope globals only.
      if Length (Current_Routine) > 0 then
         raise Program_Error with
           "EMOTION declarations must be at file scope (got '" &
           Name & "' inside a routine)";
      end if;
      if Find_Emotion (Name) /= 0 then
         raise Program_Error with "EMOTION '" & Name & "' already declared";
      end if;
      if Emotion_Count >= Max_Emotions then
         raise Program_Error with "too many EMOTION declarations";
      end if;

      Emotion_Count := Emotion_Count + 1;
      Emotions (Emotion_Count).Name := U (Name);
      Emotions (Emotion_Count).Active := True;

      if Axes_Node > 0 and then Tree (Axes_Node).Kind = AST_Emotion_Axes then
         Axis_Node := Tree (Axes_Node).Left_Child;
         while Axis_Node > 0 loop
            declare
               Ax : constant String := Emotion_Name_Of (Axis_Node);
            begin
               if Count >= Max_Emotion_Axes then
                  raise Program_Error with "EMOTION '" & Name & "' max 8 axes";
               end if;
               for J in 1 .. Count loop
                  if Upper_Text (To_String (Emotions (Emotion_Count).Axes (J)))
                    = Upper_Text (Ax)
                  then
                     raise Program_Error with
                       "EMOTION '" & Name & "' duplicate axis '" & Ax & "'";
                  end if;
               end loop;
               Count := Count + 1;
               Emotions (Emotion_Count).Axes (Count) := U (Ax);
            end;
            Axis_Node := Tree (Axis_Node).Next_Sibling;
         end loop;
      end if;
      Emotions (Emotion_Count).Axis_Count := Count;

      Line ("const ALB_EMOTION_" & Scoped_Name (Name) &
            " = new Uint8Array(8);");
      Line ("const ALB_EMOTION_" & Scoped_Name (Name) & "_COUNT = " &
            Trim_Image (Count) & ";");
   end Emit_Emotion_Decl;

   --  Emit one queued lambda as a top-level function.  Mirrors
   --  Emit_Function_Decl but reads the signature straight off the
   --  AST_Arg_List (Left = param chain, Right = ret type or 0).
   procedure Emit_Lambda_Decl
     (Index      : Node_Index;
      Lam_Name   : String;
      Bound_Name : String := "") is
      Node         : constant AST_Node := Tree (Index);
      List_Node    : constant Node_Index := Node.Left_Child;
      Body_Node    : constant Node_Index := Node.Right_Child;
      Old_Routine  : constant Unbounded_String := Current_Routine;
      Old_Out      : constant Natural := Current_Routine_Out_Count;
      Old_In_Lam   : constant Boolean := In_Lambda;
      Old_Bound    : constant Unbounded_String := Lambda_Bound;
      Curr_Param   : Node_Index := 0;
      First_Param  : Boolean := True;
      Ret_Node     : Node_Index := 0;
      Return_Type  : Value_Kind := VK_Unknown;
   begin
      Current_Routine := U (Lam_Name);
      Current_Routine_Out_Count := 0;
      In_Lambda := True;
      Lambda_Bound := U (Bound_Name);

      if List_Node > 0 and then Tree (List_Node).Kind = AST_Arg_List then
         Ret_Node := Tree (List_Node).Right_Child;
      end if;
      if Ret_Node > 0 then
         Return_Type :=
           Type_From_Name (Raw_Lexeme (Tree (Ret_Node).Token_Index));
         if Return_Type = VK_Unknown then
            Return_Type := VK_Number;
         end if;
      end if;

      Emit_Indent;
      Emit ("function " & Lam_Name & "(");

      if List_Node > 0 and then Tree (List_Node).Kind = AST_Arg_List then
         Curr_Param := Tree (List_Node).Left_Child;
         while Curr_Param > 0 loop
            if Tree (Curr_Param).Kind = AST_Param_Decl
              and then Tree (Curr_Param).Left_Child > 0
            then
               declare
                  Param_Name : constant String :=
                    Raw_Lexeme (Tree (Tree (Curr_Param).Left_Child).Token_Index);
                  Type_Node  : constant Node_Index := Tree (Curr_Param).Right_Child;
                  Param_Kind : constant Value_Kind :=
                    (if Type_Node > 0
                     then Type_From_Name (Raw_Lexeme (Tree (Type_Node).Token_Index))
                     else VK_Number);
               begin
                  if not First_Param then
                     Emit (", ");
                  end if;
                  Emit (Safe_JS_Name (Param_Name) & ": " &
                        Primitive_TS_Type (Param_Kind));
                  First_Param := False;
               end;
            end if;
            Curr_Param := Tree (Curr_Param).Next_Sibling;
         end loop;
      end if;

      if Ret_Node > 0 then
         Emit ("): " & Primitive_TS_Type (Return_Type) & " {");
      else
         Emit ("): void {");
      end if;
      New_Line_Emit;
      Indent_Level := Indent_Level + 1;

      --  Register params under the lambda's own scope so body lookups
      --  resolve them (locals/globals fall through the normal rules).
      if List_Node > 0 and then Tree (List_Node).Kind = AST_Arg_List then
         Curr_Param := Tree (List_Node).Left_Child;
         while Curr_Param > 0 loop
            if Tree (Curr_Param).Kind = AST_Param_Decl
              and then Tree (Curr_Param).Left_Child > 0
            then
               declare
                  Param_Name : constant String :=
                    Raw_Lexeme (Tree (Tree (Curr_Param).Left_Child).Token_Index);
                  Type_Node  : constant Node_Index := Tree (Curr_Param).Right_Child;
                  Param_Kind : constant Value_Kind :=
                    (if Type_Node > 0
                     then Type_From_Name (Raw_Lexeme (Tree (Type_Node).Token_Index))
                     else VK_Number);
               begin
                  Register_Symbol
                    (Scope   => Lam_Name,
                     Name    => Param_Name,
                     JS_Name => Safe_JS_Name (Param_Name),
                     Tag     => Param_Kind,
                     Kind    => Sym_Param);
               end;
            end if;
            Curr_Param := Tree (Curr_Param).Next_Sibling;
         end loop;
      end if;

      if Body_Node > 0 and then Tree (Body_Node).Kind = AST_Block_Stmt then
         Pre_Scan_Implicit_Locals (Body_Node);
         Emit_Block (Body_Node);
         if Ret_Node = 0 then
            Line ("return;");
         end if;
      elsif Body_Node > 0 then
         --  `=>` short form: the whole body is one return expression.
         Line ("return " & Expr (Body_Node) & ";");
      else
         if Ret_Node = 0 then
            Line ("return;");
         end if;
      end if;

      Indent_Level := Indent_Level - 1;
      Line ("}");
      New_Line_Emit;

      Current_Routine := Old_Routine;
      Current_Routine_Out_Count := Old_Out;
      In_Lambda := Old_In_Lam;
      Lambda_Bound := Old_Bound;
   end Emit_Lambda_Decl;

   --  Drain the queue — runs after all user code so nested lambdas
   --  (queued while emitting an outer lambda body) flush too.
   procedure Flush_Lambda_Decls is
      Saved_Indent : constant Integer := Indent_Level;
      I            : Natural := 0;
   begin
      while I < Lambda_Count loop
         I := I + 1;
         Indent_Level := 0;
         Emit_Lambda_Decl
           (Lambda_Queue (I),
            "__alb_lambda_" & Trim_Image (Integer (I)),
            To_String (Lambda_Bound_Queue (I)));
      end loop;
      Indent_Level := Saved_Indent;
   end Flush_Lambda_Decls;

   procedure Emit_Call_With_Out
     (Target_Name : String;
      Arg_List    : Node_Index) is
      Routine_Id : constant Natural := Find_Routine_For_Call (Target_Name);
      Curr       : Node_Index := 0;
      Param_No   : Natural := 0;
      Has_Out    : Boolean := False;
      Args       : array (1 .. Max_Params) of Unbounded_String := (others => U (""));
      Targets    : array (1 .. Max_Params) of Unbounded_String := (others => U (""));
   begin
       if Routine_Id = 0 then
          Line (Target_Name & "(" & Join_Arg_List (Arg_List) & ");");
          return;
      end if;

      Curr := Tree (Arg_List).Left_Child;
      while Curr > 0 and then Param_No < Max_Params loop
         Param_No := Param_No + 1;
         if Routines (Routine_Id).Param_Modes (Param_No) = Param_Out then
            Has_Out := True;
            Args (Param_No) := U ("__out_" & Trim_Image (Integer (Param_No)));
            Targets (Param_No) := U (Statement_Target_Name (Curr));
         else
            Args (Param_No) := U (Expr (Curr));
         end if;
         Curr := Tree (Curr).Next_Sibling;
      end loop;

      if not Has_Out then
         declare
            Call_Args : Unbounded_String := U ("");
         begin
            for I in 1 .. Param_No loop
               if I > 1 then
                  Append (Call_Args, ", ");
               end if;
               Append (Call_Args, To_String (Args (I)));
            end loop;
            Line (Target_Name & "(" & To_String (Call_Args) & ");");
         end;
         return;
      end if;

      Line ("{");
      Indent_Level := Indent_Level + 1;
      for I in 1 .. Param_No loop
         if Routines (Routine_Id).Param_Modes (I) = Param_Out then
            Line ("const __out_" & Trim_Image (Integer (I)) & " = { value: " &
                  To_String (Targets (I)) & " };");
         end if;
      end loop;

      declare
         Call_Args : Unbounded_String := U ("");
      begin
         for I in 1 .. Param_No loop
            if I > 1 then
               Append (Call_Args, ", ");
            end if;
            Append (Call_Args, To_String (Args (I)));
         end loop;
         Line (Target_Name & "(" & To_String (Call_Args) & ");");
      end;

      for I in 1 .. Param_No loop
         if Routines (Routine_Id).Param_Modes (I) = Param_Out then
            Line (To_String (Targets (I)) & " = __out_" & Trim_Image (Integer (I)) & ".value;");
         end if;
      end loop;
      Indent_Level := Indent_Level - 1;
      Line ("}");
   end Emit_Call_With_Out;

   procedure Emit_Node (Index : Node_Index) is
      Node : constant AST_Node := Tree (Index);
      Target_Node : Node_Index := 0;
      Value_Node  : Node_Index := 0;
      Raw_Name    : Unbounded_String := U ("");
      JS_Name     : Unbounded_String := U ("");
      Sym_Id      : Natural := 0;
      Tag         : Value_Kind := VK_Number;
      Dims        : Dim_List := (others => 0);
      Rank        : Natural := 0;
      Capacity    : Integer := 0;
   begin
      case Node.Kind is
         when AST_Program =>
            Emit_Block (Node.Left_Child);

         when AST_Block_Stmt =>
            Emit_Block (Index);

         when AST_Module =>
            declare
               Name_Node : constant Node_Index := Node.Left_Child;
               Body_Node : constant Node_Index := Node.Right_Child;
               Saved     : constant Unbounded_String := Current_Module;
            begin
               if Name_Node > 0 then
                  Current_Module := U (Safe_JS_Name (Raw_Lexeme (Tree (Name_Node).Token_Index)));
               end if;
               Emit_Block (Body_Node);
               Current_Module := Saved;
            end;

         when AST_DeclareModule | AST_Import | AST_Import_C | AST_Include_Stmt | AST_Version =>
            null;

         when AST_Range_Type_Decl =>
            if Node.Left_Child > 0 and then Node.Right_Child > 0 then
               Register_Type_Alias
                 (Raw_Lexeme (Tree (Node.Left_Child).Token_Index),
                  Raw_Lexeme (Tree (Node.Right_Child).Token_Index),
                  False);
            end if;

         when AST_Routine_Type_Decl =>
            if Node.Left_Child > 0 then
               Register_Type_Alias
                 (Raw_Lexeme (Tree (Node.Left_Child).Token_Index),
                  "", True, Index);
            end if;

         when AST_Import_DLL | AST_Import_SO | AST_Import_Dylib | AST_Import_Jar =>
            null;

         when AST_Mcp_Server | AST_Mcp_Tool | AST_Mcp_Resource =>
            --  registrations were consumed by Scan_Features
            null;

         when AST_Mcp_Pump =>
            Line ("albMcpPump();");

         when AST_Mcp_Listen =>
            Line ("albMcpListen();");

         when AST_Import_ES | AST_Import_WASM =>
            Emit_Foreign_Import_Node (Index);

         when AST_Export_DLL | AST_Export_SO | AST_Export_Dylib | AST_Export_Jar |
              AST_Export_ES | AST_Export_WASM =>
            null;

         when AST_Set_Shoebox_Stmt =>
            Shoebox_Root := U (Resolve_Static_Asset_Path (Strip_String_Node (Node.Left_Child)));

         when AST_Static_Sprite_Decl =>
            declare
               Name_Node    : constant Node_Index := Node.Left_Child;
               Sprite_Name  : constant String := Raw_Lexeme (Tree (Name_Node).Token_Index);
               Sprite_JS    : constant String := Scoped_Name (Sprite_Name);
               Setting      : Node_Index := Node.Right_Child;
               Source_Path  : Unbounded_String := U ("");
               Frame_Width  : Integer := 1;
               Frame_Height : Integer := 1;
               Frame_Count  : Integer := 1;
               Format_Text  : Unbounded_String := U ("INDEXED8BIT");
               Saw_Format   : Boolean := False;
               Embed_Name   : constant String := "__alb_bmp_" & Safe_JS_Name (Sprite_JS);
            begin
               while Setting > 0 loop
                  case Tree (Setting).Kind is
                     when AST_Static_Source =>
                        Source_Path := U (Resolve_Static_Asset_Path (Strip_String_Node (Tree (Setting).Left_Child)));
                     when AST_Static_Format =>
                        Format_Text := U (Upper_Text (Raw_Feature_Atom (Tree (Setting).Left_Child)));
                        Saw_Format := True;
                     when AST_Static_Width =>
                        Frame_Width := Integer'Max (1, Eval_Static_Int (Tree (Setting).Left_Child));
                     when AST_Static_Height =>
                        Frame_Height := Integer'Max (1, Eval_Static_Int (Tree (Setting).Left_Child));
                     when AST_Static_Frames =>
                        Frame_Count := Integer'Max (1, Eval_Static_Int (Tree (Setting).Left_Child));
                     when others =>
                        null;
                  end case;
                  Setting := Tree (Setting).Next_Sibling;
               end loop;

               Register_Symbol ("", Sprite_JS, Sprite_JS, VK_Number, Sym_Scalar);
               if not Saw_Format then
                  Emit_Warn_Once ("static-sprite-default-format",
                                  "STATIC_SPRITE without FORMAT defaults to INDEXED8BIT on ALBW");
               elsif To_String (Format_Text) /= "INDEXED8BIT" then
                  Emit_Warn_Once ("static-sprite-format-" & Safe_JS_Name (To_String (Format_Text)),
                                  "STATIC_SPRITE format " & To_String (Format_Text) &
                                  " is approximated as INDEXED8BIT on ALBW");
               end if;
               if Length (Source_Path) > 0 then
                  Emit_Embedded_File_Bytes (Embed_Name, To_String (Source_Path));
               else
                  Emit_Warn_Once ("static-sprite-missing-source-" & Safe_JS_Name (Sprite_JS),
                                  "STATIC_SPRITE without SOURCE becomes a blank sprite on ALBW");
                  Line ("const " & Embed_Name & " = new Uint8Array([0]);");
               end if;
               Line ("let " & Sprite_JS & ": any = ALB_STATIC_SPRITE_FROM_BMP(" &
                     Embed_Name & ", " & Trim_Image (Frame_Width) & ", " &
                     Trim_Image (Frame_Height) & ", " & Trim_Image (Frame_Count) & ");");
               New_Line_Emit;
            end;

         when AST_Static_Surface_Decl =>
            declare
               Name_Node   : constant Node_Index := Node.Left_Child;
               Surface_Name : constant String := Raw_Lexeme (Tree (Name_Node).Token_Index);
               Surface_JS   : constant String := Scoped_Name (Surface_Name);
               Setting      : Node_Index := Node.Right_Child;
               Width_Val    : Integer := 1;
               Height_Val   : Integer := 1;
               Format_Text  : Unbounded_String := U ("RGB565");
               Saw_Format   : Boolean := False;
            begin
               while Setting > 0 loop
                  case Tree (Setting).Kind is
                     when AST_Static_Format =>
                        Format_Text := U (Upper_Text (Raw_Feature_Atom (Tree (Setting).Left_Child)));
                        Saw_Format := True;
                     when AST_Static_Width =>
                        Width_Val := Integer'Max (1, Eval_Static_Int (Tree (Setting).Left_Child));
                     when AST_Static_Height =>
                        Height_Val := Integer'Max (1, Eval_Static_Int (Tree (Setting).Left_Child));
                     when others =>
                        null;
                  end case;
                  Setting := Tree (Setting).Next_Sibling;
               end loop;

               Register_Symbol ("", Surface_JS, Surface_JS, VK_Number, Sym_Scalar);
               if not Saw_Format then
                  Emit_Warn_Once ("static-surface-default-format",
                                  "STATIC_SURFACE without FORMAT defaults to RGB565 on ALBW");
               elsif To_String (Format_Text) /= "RGB565" then
                  Emit_Warn_Once ("static-surface-format-" & Safe_JS_Name (To_String (Format_Text)),
                                  "STATIC_SURFACE format " & To_String (Format_Text) &
                                  " is approximated as RGB565 on ALBW");
               end if;
               Line ("let " & Surface_JS & ": any = ALB_STATIC_SURFACE(" &
                     Trim_Image (Width_Val) & ", " & Trim_Image (Height_Val) & ");");
               New_Line_Emit;
            end;

         when AST_Color_Lut_Decl =>
            declare
               Name_Node : constant Node_Index := Node.Left_Child;
               LUT_Name  : constant String := Raw_Lexeme (Tree (Name_Node).Token_Index);
               LUT_JS    : constant String := Scoped_Name (LUT_Name);
               Entry_Node : Node_Index := Node.Right_Child;
               type LUT_Array is array (Natural range 0 .. 255) of Integer;
               Values : LUT_Array := (others => 0);
               First  : Boolean := True;
            begin
               while Entry_Node > 0 loop
                  if Tree (Entry_Node).Kind = AST_Color_Lut_Entry then
                     declare
                        Slot : constant Integer := Eval_Static_Int (Tree (Entry_Node).Left_Child);
                     begin
                        if Slot in Values'Range then
                           Values (Slot) := Eval_Static_Int (Tree (Entry_Node).Right_Child);
                        end if;
                     end;
                  end if;
                  Entry_Node := Tree (Entry_Node).Next_Sibling;
               end loop;

               Register_Symbol ("", LUT_JS, LUT_JS, VK_Number, Sym_Scalar);
               Emit_Indent;
               Emit ("let " & LUT_JS & ": any = new Uint32Array([");
               for I in Values'Range loop
                  if not First then
                     Emit (", ");
                  end if;
                  Emit (Trim_Image (Values (I)));
                  First := False;
               end loop;
               Emit ("]);");
               New_Line_Emit;
               New_Line_Emit;
            end;

         when AST_Visual_Rule_Decl =>
            declare
               Name_Node  : constant Node_Index := Node.Left_Child;
               Rule_Name  : constant String := Raw_Lexeme (Tree (Name_Node).Token_Index);
               Rule_JS    : constant String := Scoped_Name (Rule_Name);
               Param_List : constant Node_Index := Tree (Name_Node).Right_Child;
               Param_Node : constant Node_Index :=
                 (if Param_List > 0 and then Tree (Param_List).Kind = AST_Arg_List
                  then Tree (Param_List).Left_Child
                  else 0);
               Param_Name : constant String :=
                 (if Param_Node > 0 then Safe_JS_Name (Raw_Feature_Atom (Param_Node)) else "_alb_context");
               Clause     : Node_Index := Node.Right_Child;
            begin
               Register_Symbol ("", Rule_JS, Rule_JS, VK_Number, Sym_Scalar);
               Line ("let " & Rule_JS & ": any = {");
               Indent_Level := Indent_Level + 1;
               Line ("kind: 'visualRule',");
               Line ("name: " & Escape_TS_String (Rule_Name) & ",");
               Line ("resolve: (" & Param_Name & ": any) => {");
               Indent_Level := Indent_Level + 1;
               while Clause > 0 loop
                  if Tree (Clause).Kind = AST_Visual_When_Clause then
                     Line ("if (Boolean(" & Expr (Tree (Clause).Left_Child) & ")) {");
                     Indent_Level := Indent_Level + 1;
                     Line ("return { sprite: " & Expr (Tree (Clause).Right_Child) &
                           ", frame: " & Expr (Tree (Tree (Clause).Right_Child).Next_Sibling) & " };");
                     Indent_Level := Indent_Level - 1;
                     Line ("}");
                  elsif Tree (Clause).Kind = AST_Visual_Default_Clause then
                     Line ("return { sprite: " & Expr (Tree (Clause).Left_Child) &
                           ", frame: " & Expr (Tree (Clause).Right_Child) & " };");
                  end if;
                  Clause := Tree (Clause).Next_Sibling;
               end loop;
               Line ("return { sprite: 0, frame: 0 };");
               Indent_Level := Indent_Level - 1;
               Line ("}");
               Indent_Level := Indent_Level - 1;
               Line ("};");
               New_Line_Emit;
            end;

         when AST_Render_Viewport_Decl =>
            declare
               Name_Node : constant Node_Index := Node.Left_Child;
               View_Name : constant String := Raw_Lexeme (Tree (Name_Node).Token_Index);
               View_JS   : constant String := Scoped_Name (View_Name);
               Setting   : constant Node_Index := Node.Right_Child;
               X_Node    : constant Node_Index := Tree (Setting).Left_Child;
               Y_Node    : constant Node_Index := Tree (Setting).Right_Child;
               W_Node    : constant Node_Index := (if Y_Node > 0 then Tree (Y_Node).Next_Sibling else 0);
               H_Node    : constant Node_Index := (if W_Node > 0 then Tree (W_Node).Next_Sibling else 0);
            begin
               Register_Symbol ("", View_JS, View_JS, VK_Number, Sym_Scalar);
               Line ("let " & View_JS & ": any = ALB_STATIC_VIEWPORT(" &
                     Expr (X_Node) & ", " & Expr (Y_Node) & ", " &
                     Expr (W_Node) & ", " & Expr (H_Node) & ");");
               New_Line_Emit;
            end;

         when AST_Bitmap_Font_Decl =>
            declare
               Name_Node      : constant Node_Index := Node.Left_Child;
               Font_Name      : constant String := Raw_Lexeme (Tree (Name_Node).Token_Index);
               Font_JS        : constant String := Scoped_Name (Font_Name);
               Setting        : Node_Index := Node.Right_Child;
               Source_Text    : Unbounded_String := U ("");
               Descriptor_Text : Unbounded_String := U ("");
               Format_Text    : Unbounded_String := U ("INDEXED8BIT");
               Glyph_Width    : Unbounded_String := U ("8");
               Glyph_Height   : Unbounded_String := U ("8");
               First_Char     : Unbounded_String := U ("32");
               Spacing_Text   : Unbounded_String := U ("0");
            begin
               while Setting > 0 loop
                     case Tree (Setting).Kind is
                        when AST_Static_Source =>
                        Source_Text := U (As_Text_Expr (Tree (Setting).Left_Child));
                     when AST_Font_Descriptor =>
                        Descriptor_Text := U (As_Text_Expr (Tree (Setting).Left_Child));
                     when AST_Static_Format =>
                        Format_Text := U (Feature_Text_Expr (Tree (Setting).Left_Child));
                     when AST_Font_Glyph_Width =>
                        Glyph_Width := U (Expr (Tree (Setting).Left_Child));
                     when AST_Font_Glyph_Height =>
                        Glyph_Height := U (Expr (Tree (Setting).Left_Child));
                     when AST_Font_First_Char =>
                        First_Char := U (Expr (Tree (Setting).Left_Child));
                     when AST_Font_Spacing =>
                        Spacing_Text := U (Expr (Tree (Setting).Left_Child));
                     when others =>
                        null;
                  end case;
                  Setting := Tree (Setting).Next_Sibling;
               end loop;

               Register_Symbol ("", Font_JS, Font_JS, VK_U64, Sym_Scalar);
               if Length (Descriptor_Text) > 0 then
                  Emit_Warn_Once ("bitmap-font-descriptor-" & Safe_JS_Name (Font_JS),
                                  "BITMAP_FONT descriptor metadata is accepted but canvas text remains an approximation on ALBW");
               end if;
               Line ("let " & Font_JS & ": any = ALB_DEFINE_BITMAP_FONT(" &
                     Escape_TS_String (Font_Name) & ", " &
                     (if Length (Source_Text) > 0 then To_String (Source_Text) else Escape_TS_String ("")) & ", " &
                     To_String (Format_Text) & ", " &
                     To_String (Glyph_Width) & ", " &
                     To_String (Glyph_Height) & ", " &
                     To_String (First_Char) & ", " &
                     To_String (Spacing_Text) & ");");
               New_Line_Emit;
            end;

         when AST_System_Font_Decl =>
            declare
               Name_Node       : constant Node_Index := Node.Left_Child;
               Font_Name       : constant String := Raw_Lexeme (Tree (Name_Node).Token_Index);
               Font_JS         : constant String := Scoped_Name (Font_Name);
               Setting         : Node_Index := Node.Right_Child;
               Family_Text     : Unbounded_String := U (Escape_TS_String (Font_Name));
               Size_Text       : Unbounded_String := U ("16");
               Weight_Text     : Unbounded_String := U (Escape_TS_String ("normal"));
               Anti_Alias_Text : Unbounded_String := U ("1");
               Charset_Start   : Unbounded_String := U ("32");
               Charset_End     : Unbounded_String := U ("126");
            begin
               while Setting > 0 loop
                     case Tree (Setting).Kind is
                     when AST_Static_Source =>
                        Family_Text := U (As_Text_Expr (Tree (Setting).Left_Child));
                     when AST_Font_Size =>
                        Size_Text := U (Expr (Tree (Setting).Left_Child));
                     when AST_Font_Weight =>
                        Weight_Text := U (Feature_Text_Expr (Tree (Setting).Left_Child));
                     when AST_Font_Anti_Alias =>
                        Anti_Alias_Text := U (Expr (Tree (Setting).Left_Child));
                     when AST_Font_Character_Set =>
                        Charset_Start := U (Expr (Tree (Setting).Left_Child));
                        Charset_End := U ((if Tree (Setting).Right_Child > 0
                                           then Expr (Tree (Setting).Right_Child)
                                           else Expr (Tree (Setting).Left_Child)));
                     when others =>
                        null;
                  end case;
                  Setting := Tree (Setting).Next_Sibling;
               end loop;

               Register_Symbol ("", Font_JS, Font_JS, VK_U64, Sym_Scalar);
               Line ("let " & Font_JS & ": any = ALB_DEFINE_SYSTEM_FONT(" &
                     To_String (Family_Text) & ", " &
                     To_String (Size_Text) & ", " &
                     To_String (Weight_Text) & ", " &
                     "(Boolean(" & To_String (Anti_Alias_Text) & "))" & ", " &
                     To_String (Charset_Start) & ", " &
                     To_String (Charset_End) & ");");
               New_Line_Emit;
            end;

         when AST_Memory_Firewall_Decl =>
            declare
               Name_Node : constant Node_Index := Node.Left_Child;
               FW_JS     : constant String := Scoped_Name (Raw_Lexeme (Tree (Name_Node).Token_Index));
               Rule_Node : Node_Index := Node.Right_Child;
               Read_Text : Unbounded_String := U ("");
               Write_Text : Unbounded_String := U ("");
               First_Read : Boolean := True;
               First_Write : Boolean := True;
               Deny_All : Boolean := False;
            begin
               while Rule_Node > 0 loop
                  case Tree (Rule_Node).Kind is
                     when AST_Firewall_Permit_Read =>
                        declare
                           Key : constant String :=
                             Firewall_Key_For_Node (Tree (Rule_Node).Left_Child);
                        begin
                           if Key'Length > 0 then
                              if not First_Read then
                                 Append (Read_Text, ", ");
                              end if;
                              Append (Read_Text, Escape_TS_String (Key));
                              First_Read := False;
                           end if;
                        end;

                     when AST_Firewall_Permit_Write =>
                        declare
                           Key : constant String :=
                             Firewall_Key_For_Node (Tree (Rule_Node).Left_Child);
                        begin
                           if Key'Length > 0 then
                              if not First_Write then
                                 Append (Write_Text, ", ");
                              end if;
                              Append (Write_Text, Escape_TS_String (Key));
                              First_Write := False;
                           end if;
                        end;

                     when AST_Firewall_Deny_All =>
                        Deny_All := True;

                     when others =>
                        null;
                  end case;

                  Rule_Node := Tree (Rule_Node).Next_Sibling;
               end loop;

               Register_Symbol ("", FW_JS, FW_JS, VK_Number, Sym_Scalar);
               Line ("let " & FW_JS & ": any = { kind: 'firewall', name: " &
                     Escape_TS_String (Raw_Lexeme (Tree (Name_Node).Token_Index)) &
                     ", denyAll: " & (if Deny_All then "true" else "false") &
                     ", read: new Set<string>([" & To_String (Read_Text) &
                     "]), write: new Set<string>([" & To_String (Write_Text) & "]) };");
               New_Line_Emit;
            end;

         when AST_Process_Handle_Decl =>
            declare
               Name_Node : constant Node_Index := Node.Left_Child;
               Proc_JS   : constant String := Scoped_Name (Raw_Lexeme (Tree (Name_Node).Token_Index));
               Setting   : Node_Index := Node.Right_Child;
               Image_Text : Unbounded_String := U ("process");
               Rights_Text : Unbounded_String := U ("");
               Pid_Text    : Unbounded_String := U ("0");
               First_Right : Boolean := True;
            begin
               while Setting > 0 loop
                  case Tree (Setting).Kind is
                     when AST_Process_Pid =>
                        Pid_Text := U (Expr (Tree (Setting).Left_Child));
                     when AST_Process_Image =>
                        Image_Text := U (As_Text_Expr (Tree (Setting).Left_Child));
                     when AST_Process_Rights =>
                        declare
                           Right_Node : Node_Index := Tree (Setting).Left_Child;
                        begin
                           while Right_Node > 0 loop
                              if not First_Right then
                                 Append (Rights_Text, ", ");
                              end if;
                              Append (Rights_Text, Escape_TS_String (Raw_Feature_Atom (Right_Node)));
                              First_Right := False;
                              Right_Node := Tree (Right_Node).Next_Sibling;
                           end loop;
                        end;
                     when others =>
                        null;
                  end case;
                  Setting := Tree (Setting).Next_Sibling;
               end loop;

               Register_Symbol ("", Proc_JS, Proc_JS, VK_U64, Sym_Scalar);
               Line ("let " & Proc_JS & ": number = ALB_PROCESS_DEFINE(" &
                     To_String (Image_Text) & ", [" &
                     To_String (Rights_Text) & "], " & To_String (Pid_Text) & ");");
               New_Line_Emit;
            end;

         when AST_Network_Sniffer_Decl =>
            declare
               Name_Node      : constant Node_Index := Node.Left_Child;
               Sniffer_Name   : constant String := Raw_Lexeme (Tree (Name_Node).Token_Index);
               Sniffer_JS     : constant String := Scoped_Name (Sniffer_Name);
               Error_JS       : constant String := Scoped_Name (Sniffer_Name & "_ERROR");
               Setting        : Node_Index := Node.Right_Child;
               Interface_Text : Unbounded_String := U (Escape_TS_String ("any"));
               Protocol_Text  : Unbounded_String := U ("1");
               Port_Text      : Unbounded_String := U ("0");
               Buffer_Text    : Unbounded_String := U ("1514");
            begin
               while Setting > 0 loop
                  case Tree (Setting).Kind is
                     when AST_Sniffer_Interface =>
                        Interface_Text := U (As_Text_Expr (Tree (Setting).Left_Child));
                     when AST_Sniffer_Protocol =>
                        Protocol_Text := U (Network_Protocol_Code (Raw_Feature_Atom (Tree (Setting).Left_Child)));
                     when AST_Sniffer_Port =>
                        Port_Text := U (Expr (Tree (Setting).Left_Child));
                     when AST_Sniffer_Buffer_Size =>
                        Buffer_Text := U (Expr (Tree (Setting).Left_Child));
                     when others =>
                        null;
                  end case;
                  Setting := Tree (Setting).Next_Sibling;
               end loop;

               Register_Symbol ("", Sniffer_JS, Sniffer_JS, VK_U64, Sym_Scalar);
               Register_Symbol ("", Error_JS, Error_JS, VK_U64, Sym_Scalar);
               Emit_Warn_Once ("network-sniffer-albw",
                               "NETWORK_SNIFFER is simulated on ALBW with deterministic sample packets");
               Line ("let " & Error_JS & ": any = ALB_MAKE_CELL(0);");
               Line ("let " & Sniffer_JS & ": any = ALB_SNIFFER_DEFINE(" &
                     To_String (Interface_Text) & ", " &
                     To_String (Protocol_Text) & ", " &
                     To_String (Port_Text) & ", " &
                     To_String (Buffer_Text) & ");");
               Line (Sniffer_JS & ".errorCell = " & Error_JS & ";");
               New_Line_Emit;
            end;

         when AST_Network_Socket_Decl =>
            declare
               Name_Node    : constant Node_Index := Node.Left_Child;
               Socket_JS    : constant String := Scoped_Name (Raw_Lexeme (Tree (Name_Node).Token_Index));
               Setting      : Node_Index := Node.Right_Child;
               Protocol_Code : Unbounded_String := U ("1");
               Port_Val      : Unbounded_String := U ("0");
               Buffer_Val    : Unbounded_String := U ("64");
            begin
               while Setting > 0 loop
                  case Tree (Setting).Kind is
                     when AST_Network_Protocol =>
                        Protocol_Code := U (Network_Protocol_Code (Raw_Feature_Atom (Tree (Setting).Left_Child)));
                     when AST_Network_Port =>
                        Port_Val := U (Expr (Tree (Setting).Left_Child));
                     when AST_Network_Buffer_Size =>
                        Buffer_Val := U (Expr (Tree (Setting).Left_Child));
                     when others =>
                        null;
                  end case;
                  Setting := Tree (Setting).Next_Sibling;
               end loop;

               Register_Symbol ("", Socket_JS, Socket_JS, VK_U64, Sym_Scalar);
               Line ("let " & Socket_JS & ": number = ALB_NET_DEFINE(" &
                     To_String (Protocol_Code) & ", " & To_String (Port_Val) & ", " &
                     To_String (Buffer_Val) & ");");
               New_Line_Emit;
            end;

         when AST_Emotion_Decl =>
            Emit_Emotion_Decl (Index);

         when AST_Markov_Model_Decl =>
            declare
               Name_Node : constant Node_Index := Node.Left_Child;
               Model_JS  : constant String := Scoped_Name (Raw_Lexeme (Tree (Name_Node).Token_Index));
               Setting   : Node_Index := Node.Right_Child;
               States_Text : Unbounded_String := U ("0");
               Matrix_Node  : Node_Index := 0;
            begin
               while Setting > 0 loop
                  case Tree (Setting).Kind is
                     when AST_Markov_States =>
                        States_Text := U (Expr (Tree (Setting).Left_Child));
                     when AST_Markov_Transition_Matrix =>
                        Matrix_Node := Tree (Setting).Left_Child;
                     when others =>
                        null;
                  end case;
                  Setting := Tree (Setting).Next_Sibling;
               end loop;

               Register_Symbol ("", Model_JS, Model_JS, VK_Number, Sym_Scalar);
               Emit_Indent;
               Emit ("let " & Model_JS & ": any = { states: " & To_String (States_Text) & ", matrix: [");
               declare
                  Row_Node  : Node_Index := Matrix_Node;
                  Elem_Node : Node_Index := 0;
                  First     : Boolean := True;
               begin
                  while Row_Node > 0 loop
                     Elem_Node := Tree (Row_Node).Left_Child;
                     while Elem_Node > 0 loop
                        if not First then
                           Emit (", ");
                        end if;
                        Emit (Expr (Elem_Node));
                        First := False;
                        Elem_Node := Tree (Elem_Node).Next_Sibling;
                     end loop;
                     Row_Node := Tree (Row_Node).Next_Sibling;
                  end loop;
               end;
               Emit ("] };");
               New_Line_Emit;
               New_Line_Emit;
            end;

         when AST_Neural_Topology_Decl =>
            declare
               Name_Node : constant Node_Index := Node.Left_Child;
               Net_JS    : constant String := Scoped_Name (Raw_Lexeme (Tree (Name_Node).Token_Index));
               Layer_Node : Node_Index := Node.Right_Child;
               First     : Boolean := True;
               First_Act : Boolean := True;
            begin
               Register_Symbol ("", Net_JS, Net_JS, VK_Number, Sym_Scalar);
               Emit_Indent;
               Emit ("let " & Net_JS & ": any = ALB_NN_CREATE(" &
                     Escape_TS_String (Raw_Lexeme (Tree (Name_Node).Token_Index)) &
                     ", [");
               while Layer_Node > 0 loop
                  if not First then
                     Emit (", ");
                  end if;
                  Emit (Expr (Tree (Layer_Node).Left_Child));
                  First := False;
                  Layer_Node := Tree (Layer_Node).Next_Sibling;
               end loop;
               Emit ("], [");
               Layer_Node := Node.Right_Child;
               while Layer_Node > 0 loop
                  if not First_Act then
                     Emit (", ");
                  end if;
                  if Tree (Layer_Node).Right_Child > 0 then
                     Emit (Activation_Code (Raw_Feature_Atom (Tree (Layer_Node).Right_Child)));
                  else
                     Emit ("0");
                  end if;
                  First_Act := False;
                  Layer_Node := Tree (Layer_Node).Next_Sibling;
               end loop;
               Emit ("]);");
               New_Line_Emit;
               New_Line_Emit;
            end;

         when AST_Const_Decl =>
            Target_Node := Node.Left_Child;
            Value_Node := Node.Right_Child;
            if Target_Node > 0 then
               Raw_Name := U (Raw_Lexeme (Tree (Target_Node).Token_Index));
               declare
                  R : constant String := To_String (Raw_Name);
                  Existing : Natural;
               begin
                  JS_Name := U (Safe_JS_Name (R (R'First + 1 .. R'Last)));
                  Capacity := Eval_Static_Int (Value_Node);
                  Existing := Find_Symbol ("", To_String (JS_Name));
                  if Existing = 0 then
                     --  Use let so later #CONST redefinitions (common across
                     --  engine modules) can reassign under ES module mode.
                     Register_Symbol
                       ("", To_String (JS_Name), To_String (JS_Name),
                        VK_Number, Sym_Const, Capacity => Capacity);
                     Line ("let " & To_String (JS_Name) &
                           ": number = " & Expr (Value_Node) & ";");
                  else
                     Symbols (Existing).Capacity := Capacity;
                     Line (To_String (JS_Name) & " = " & Expr (Value_Node) & ";");
                  end if;
               end;
            end if;

         when AST_Enum_Decl =>
            declare
               Curr  : Node_Index := Node.Left_Child;
               Value : Integer := 0;
            begin
               while Curr > 0 loop
                  Raw_Name := U (Raw_Lexeme (Tree (Curr).Token_Index));
                  JS_Name := U (Safe_JS_Name (To_String (Raw_Name)));
                  declare
                     Existing : constant Natural :=
                       Find_Symbol ("", To_String (JS_Name));
                  begin
                     if Existing = 0 then
                        Register_Symbol
                          ("", To_String (JS_Name), To_String (JS_Name),
                           VK_Number, Sym_Const, Capacity => Value);
                        Line ("let " & To_String (JS_Name) &
                              ": number = " & Trim_Image (Value) & ";");
                     else
                        Symbols (Existing).Capacity := Value;
                        Line (To_String (JS_Name) & " = " &
                              Trim_Image (Value) & ";");
                     end if;
                  end;
                  Value := Value + 1;
                  Curr := Tree (Curr).Next_Sibling;
               end loop;
               New_Line_Emit;
            end;

         when AST_Struct_Decl =>
            Register_Struct_From_Node (Index);
            declare
               Struct_Name : constant String := Safe_JS_Name (Raw_Lexeme (Tree (Node.Left_Child).Token_Index));
               Curr        : Node_Index := Tree (Node.Right_Child).Left_Child;
               First       : Boolean := True;
            begin
               Emit_Indent;
               Emit ("type " & Struct_Name & " = {");
               while Curr > 0 loop
                  if not First then
                     Emit ("; ");
                  end if;
                  declare
                     Field_Name_Node : constant Node_Index := Tree (Curr).Left_Child;
                  begin
                     if Field_Name_Node > 0 then
                        Emit
                          (Safe_JS_Name (Raw_Lexeme (Tree (Field_Name_Node).Token_Index)) &
                           ": " &
                           (if Tree (Curr).Token_Index > 0
                            then Type_Annotation_From_Name (Raw_Lexeme (Tree (Curr).Token_Index))
                            else "number"));
                     else
                        Emit ("alb_missing_field: number");
                     end if;
                  end;
                  First := False;
                  Curr := Tree (Curr).Next_Sibling;
               end loop;
               Emit (" };");
               New_Line_Emit;
               New_Line_Emit;
            end;

         when AST_Strict_Stmt =>
            Target_Node := Node.Left_Child;
            if Target_Node > 0 then
               Raw_Name := U (Raw_Lexeme (Tree (Target_Node).Token_Index));
               JS_Name := U (Scoped_Name (To_String (Raw_Name)));
               Tag := (if Tree (Target_Node).Right_Child > 0
                       then Type_From_Name (Raw_Lexeme (Tree (Tree (Target_Node).Right_Child).Token_Index))
                       else VK_Number);
               declare
                  Curr : Node_Index := Node.Right_Child;
               begin
                  while Curr > 0 and then Rank < 4 loop
                     Rank := Rank + 1;
                     Dims (Rank) := Eval_Static_Int (Curr);
                     Curr := Tree (Curr).Next_Sibling;
                  end loop;
               end;
               Capacity := 1;
               for I in 1 .. Rank loop
                  Capacity := Capacity * (Integer'Max (1, Dims (I)) + 1);
               end loop;
               declare
                  Type_Lex  : constant String :=
                    (if Tree (Target_Node).Right_Child > 0
                     then Raw_Lexeme (Tree (Tree (Target_Node).Right_Child).Token_Index)
                     else "");
                  Struct_Id : constant Natural :=
                    (if Type_Lex'Length > 0 then Find_Struct (Type_Lex) else 0);
               begin
               if Struct_Id /= 0 then
                  --  STRICT a[N] AS Struct — struct-of-arrays lowering (same
                  --  contract as fasm16): a[i].f resolves to the parallel
                  --  field array a_f[i].  The strict array itself gets no
                  --  backing cell.
                  for F in 1 .. Field_Count loop
                     if Fields (F).Active
                       and then To_String (Fields (F).Struct_Name) = Type_Lex
                     then
                        declare
                           Field_JS  : constant String :=
                             To_String (JS_Name) & "_" & To_String (Fields (F).JS_Field);
                           Field_Tag : constant Value_Kind :=
                             (if Fields (F).Tag = VK_Unknown then VK_Number else Fields (F).Tag);
                        begin
                           Register_Symbol
                             ("", To_String (JS_Name) & "." & To_String (Fields (F).JS_Field),
                              Field_JS, Field_Tag, Sym_Parallel_Field, Rank, Dims, Capacity,
                              Offset_Bytes => Allocate_Address_Bytes (Capacity * Element_Bytes (Field_Tag)),
                              Is_Bigint => Is_Bigint_Type_Name (To_String (Fields (F).Type_Name)));
                           if Field_Tag in VK_String | VK_Binary then
                              Line ("const " & Field_JS & ": " & Primitive_TS_Type (Field_Tag) &
                                    "[] = new Array(" & Trim_Image (Capacity) & ").fill("""");");
                           elsif Is_Bigint_Type_Name (To_String (Fields (F).Type_Name)) then
                              Line ("const " & Field_JS & " = new " &
                                    (if Is_Unsigned_Bigint_Type_Name (To_String (Fields (F).Type_Name))
                                     then "BigUint64Array" else "BigInt64Array") &
                                    "(" & Trim_Image (Capacity) & ");");
                           else
                              Line ("const " & Field_JS & " = new " & Typed_Array_Name (Field_Tag) &
                                    "(" & Trim_Image (Capacity) & ");");
                           end if;
                        end;
                     end if;
                  end loop;
               else
                  declare
                     Big : constant Boolean := Is_Bigint_Type_Name (Type_Lex);
                  begin
                     Register_Symbol ("", To_String (JS_Name), To_String (JS_Name), Tag, Sym_Strict_Array, Rank, Dims, Capacity,
                                      Offset_Bytes => Allocate_Address_Bytes (Capacity * Element_Bytes (Tag)),
                                      Is_Bigint => Big);
                     if Tag in VK_String | VK_Binary then
                        Line ("const " & To_String (JS_Name) & ": " & Primitive_TS_Type (Tag) &
                              "[] = new Array(" & Trim_Image (Capacity) & ").fill("""");");
                     elsif Big then
                        Line ("const " & To_String (JS_Name) & " = new " &
                              (if Is_Unsigned_Bigint_Type_Name (Type_Lex)
                               then "BigUint64Array" else "BigInt64Array") &
                              "(" & Trim_Image (Capacity) & ");");
                     else
                        Line ("const " & To_String (JS_Name) & " = new " & Typed_Array_Name (Tag) &
                              "(" & Trim_Image (Capacity) & ");");
                     end if;
                  end;
               end if;
               end;
            end if;

         when AST_Slide_Stmt =>
            Target_Node := Node.Left_Child;
            if Target_Node > 0 then
               Raw_Name := U (Raw_Lexeme (Tree (Target_Node).Token_Index));
               JS_Name := U (Scoped_Name (To_String (Raw_Name)));
               Tag := (if Tree (Target_Node).Right_Child > 0
                       then Type_From_Name (Raw_Lexeme (Tree (Tree (Target_Node).Right_Child).Token_Index))
                       else VK_Number);
               Capacity := Eval_Static_Int (Node.Right_Child);
               Register_Symbol ("", To_String (JS_Name), To_String (JS_Name), Tag, Sym_Slide_Array, 1, (1 => Capacity, others => 0), Capacity + 1,
                                Active_Size => (if Tree (Node.Right_Child).Next_Sibling > 0 then Eval_Static_Int (Tree (Node.Right_Child).Next_Sibling) else Capacity),
                                Offset_Bytes => Allocate_Address_Bytes ((Capacity + 1) * Element_Bytes (Tag)));
               if Tag in VK_String | VK_Binary then
                  Line ("const " & To_String (JS_Name) & ": " & Primitive_TS_Type (Tag) &
                        "[] = new Array(" & Trim_Image (Capacity + 1) & ").fill("""");");
               else
                  Line ("const " & To_String (JS_Name) & " = new " & Typed_Array_Name (Tag) &
                        "(" & Trim_Image (Capacity + 1) & ");");
               end if;
               Line ("let " & To_String (JS_Name) & "_active = " &
                     Trim_Image ((if Tree (Node.Right_Child).Next_Sibling > 0
                                  then Eval_Static_Int (Tree (Node.Right_Child).Next_Sibling)
                                  else Capacity)) & ";");
            end if;

         when AST_Parallel_Decl =>
            Target_Node := Node.Left_Child;
            if Target_Node > 0 then
               Raw_Name := U (Raw_Lexeme (Tree (Target_Node).Token_Index));
               JS_Name := U (Scoped_Name (To_String (Raw_Name)));
               declare
                  Curr_Bound : Node_Index := Tree (Target_Node).Left_Child;
               begin
                  while Curr_Bound > 0 and then Rank < 4 loop
                     Rank := Rank + 1;
                     Dims (Rank) := Eval_Static_Int (Curr_Bound);
                     Curr_Bound := Tree (Curr_Bound).Next_Sibling;
                  end loop;
               end;
               Capacity := 1;
               for I in 1 .. Rank loop
                  Capacity := Capacity * (Integer'Max (1, Dims (I)) + 1);
               end loop;
               declare
                  Curr_Field : Node_Index := Node.Right_Child;
               begin
                  while Curr_Field > 0 loop
                     declare
                        Field_Name_Node : constant Node_Index := Tree (Curr_Field).Left_Child;
                        Field_Name      : constant String := Raw_Lexeme (Tree (Field_Name_Node).Token_Index);
                        Field_JS        : constant String := Safe_JS_Name (To_String (Raw_Name) & "_" & Field_Name);
                        Field_Tag       : constant Value_Kind :=
                          (if Tree (Field_Name_Node).Right_Child > 0
                           then Type_From_Name (Raw_Lexeme (Tree (Tree (Field_Name_Node).Right_Child).Token_Index))
                           else VK_Number);
                     begin
                        Register_Symbol ("", To_String (JS_Name) & "." & Field_Name, Field_JS, Field_Tag,
                                         Sym_Parallel_Field, Rank, Dims, Capacity,
                                         Offset_Bytes => Allocate_Address_Bytes (Capacity * Element_Bytes (Field_Tag)));
                        if Field_Tag in VK_String | VK_Binary then
                           Line ("const " & Field_JS & ": " & Primitive_TS_Type (Field_Tag) &
                                 "[] = new Array(" & Trim_Image (Capacity) & ").fill("""");");
                        else
                           Line ("const " & Field_JS & " = new " & Typed_Array_Name (Field_Tag) &
                                 "(" & Trim_Image (Capacity) & ");");
                        end if;
                     end;
                     Curr_Field := Tree (Curr_Field).Next_Sibling;
                  end loop;
               end;
               New_Line_Emit;
            end if;

         when AST_Temporal_Decl =>
            Target_Node := Node.Left_Child;
            if Target_Node > 0 then
               Raw_Name := U (Raw_Lexeme (Tree (Target_Node).Token_Index));
               JS_Name := U (Scoped_Name (To_String (Raw_Name)));
               Tag := Type_From_Token (Node.Token_Index);
               if Tag = VK_Unknown then
                  Tag := VK_Number;
               end if;
               Capacity := Eval_Static_Int (Node.Right_Child);
               Register_Symbol ("", To_String (JS_Name), To_String (JS_Name), Tag, Sym_Temporal,
                                History_Size => Capacity,
                                Offset_Bytes => Allocate_Address_Bytes (Element_Bytes (Tag)));
               declare
                  TId : constant Natural := Find_Symbol ("", To_String (JS_Name));
               begin
                  if TId /= 0 then
                     Symbols (TId).Aux_Offset := Allocate_Address_Bytes (Capacity * Element_Bytes (Tag));
                  end if;
               end;
               Line ("let " & To_String (JS_Name) & ": " & Primitive_TS_Type (Tag) & " = " &
                     Cast_Expr (Tag, Expr (Tree (Node.Right_Child).Next_Sibling)) & ";");
               if Tag in VK_String | VK_Binary then
                  Line ("const " & To_String (JS_Name) & "_history: " & Primitive_TS_Type (Tag) &
                        "[] = new Array(" & Trim_Image (Capacity) & ").fill(" & To_String (JS_Name) & ");");
               else
                  Line ("const " & To_String (JS_Name) & "_history = new " & Typed_Array_Name (Tag) &
                        "(" & Trim_Image (Capacity) & ");");
                  Line (To_String (JS_Name) & "_history.fill(" & To_String (JS_Name) & " as never);");
               end if;
               Line ("let " & To_String (JS_Name) & "_head = 0;");
            end if;

         when AST_Let_Stmt =>
            Target_Node := Node.Left_Child;
            Value_Node := Node.Right_Child;
            if Target_Node = 0 then
               null;
            elsif Value_Node = 0
              and then Node.Token_Index > 0
              and then Tokens (Node.Token_Index).Kind = Tok_U0
            then
               null;
            elsif Tree (Target_Node).Kind = AST_Var_Expr and then Tree (Target_Node).Left_Child = 0 then
               Raw_Name := U (Raw_Lexeme (Tree (Target_Node).Token_Index));
               Tag := Type_From_Token (Node.Token_Index);
               if Tag = VK_Unknown then
                  Tag := Infer_Expr_Kind (Value_Node);
                  if Tag = VK_Unknown then
                     Tag := VK_Number;
                  end if;
               end if;

               if Length (Current_Routine) > 0 then
                  Sym_Id := Find_Symbol_Shaped
                    (To_String (Current_Routine), To_String (Raw_Name),
                     Want_Array => False, Strict => True);
                  if Sym_Id = 0 then
                     declare
                        Global_Id : constant Natural :=
                          Find_Symbol_Shaped
                            ("", Scoped_Name (To_String (Raw_Name)),
                             Want_Array => False, Strict => True);
                        Plain_Id  : constant Natural :=
                          Find_Symbol_Shaped
                            ("", Safe_JS_Name (To_String (Raw_Name)),
                             Want_Array => False, Strict => True);
                     begin
                        if Global_Id /= 0 then
                           Emit_Assignment (Target_Node, Value_Node, Symbols (Global_Id).Tag, False);
                        elsif Plain_Id /= 0 then
                           Emit_Assignment (Target_Node, Value_Node, Symbols (Plain_Id).Tag, False);
                        elsif Tag = VK_Struct
                          and then Find_Struct (Safe_JS_Name (Raw_Lexeme (Node.Token_Index))) /= 0
                        then
                           declare
                              SName : constant String := Safe_JS_Name (Raw_Lexeme (Node.Token_Index));
                              SIdx  : constant Natural := Find_Struct (SName);
                           begin
                              Register_Symbol (To_String (Current_Routine), To_String (Raw_Name), Safe_JS_Name (To_String (Raw_Name)), Tag, Sym_Struct_Var,
                                               Struct_Name => Raw_Lexeme (Node.Token_Index),
                                               Offset_Bytes => (if SIdx /= 0 then Allocate_Address_Bytes (Structs (SIdx).Size_Bytes) else 0));
                              Line ("var " & Safe_JS_Name (To_String (Raw_Name)) &
                                    " = " &
                                    (if Value_Node > 0 then Expr (Value_Node)
                                     else Struct_Literal (SName)) & ";");
                           end;
                        else
                           Register_Symbol (To_String (Current_Routine), To_String (Raw_Name), Safe_JS_Name (To_String (Raw_Name)), Tag, Sym_Scalar,
                                            Routine_Alias => Routine_Alias_Of (Node.Token_Index));
                           Emit_Assignment (Target_Node, Value_Node, Tag, True);
                        end if;
                     end;
                  else
                     Emit_Assignment (Target_Node, Value_Node, Symbols (Sym_Id).Tag, False);
                  end if;
               else
                  Sym_Id := Find_Symbol_Shaped
                    ("", Scoped_Name (To_String (Raw_Name)),
                     Want_Array => False, Strict => True);
                  if Sym_Id = 0 then
                     if Tag = VK_Struct
                       and then Find_Struct (Safe_JS_Name (Raw_Lexeme (Node.Token_Index))) /= 0
                     then
                        declare
                           Struct_Name : constant String := Safe_JS_Name (Raw_Lexeme (Node.Token_Index));
                           SIdx : constant Natural := Find_Struct (Struct_Name);
                        begin
                           Register_Symbol ("", Scoped_Name (To_String (Raw_Name)), Scoped_Name (To_String (Raw_Name)), Tag, Sym_Struct_Var,
                                            Struct_Name => Raw_Lexeme (Node.Token_Index),
                                            Offset_Bytes => (if SIdx /= 0 then Allocate_Address_Bytes (Structs (SIdx).Size_Bytes) else 0));
                        end;
                        declare
                           Struct_Name : constant String := Safe_JS_Name (Raw_Lexeme (Node.Token_Index));
                           SIdx : constant Natural := Find_Struct (Struct_Name);
                           Curr : Natural := 1;
                           Field_Text : Unbounded_String := U ("");
                        begin
                           if SIdx /= 0 then
                              for I in 1 .. Field_Count loop
                                 if Fields (I).Active and then To_String (Fields (I).Struct_Name) = Struct_Name then
                                    if Curr > 1 then
                                       Append (Field_Text, ", ");
                                    end if;
                                    Append (Field_Text,
                                            To_String (Fields (I).JS_Field) & ": " &
                                            Default_Value
                                              (Fields (I).Tag,
                                               To_String (Fields (I).Type_Name)));
                                    Curr := Curr + 1;
                                 end if;
                              end loop;
                           end if;
                           if Value_Node > 0 then
                              Line
                                ("var " & Scoped_Name (To_String (Raw_Name)) &
                                 ": " & Type_Annotation_From_Name (Raw_Lexeme (Node.Token_Index)) &
                                 " = " & Expr (Value_Node) & ";");
                           else
                              Line
                                ("var " & Scoped_Name (To_String (Raw_Name)) &
                                 ": " & Type_Annotation_From_Name (Raw_Lexeme (Node.Token_Index)) &
                                 " = {" & To_String (Field_Text) & "};");
                           end if;
                        end;
                     else
                        Register_Symbol ("", Scoped_Name (To_String (Raw_Name)), Scoped_Name (To_String (Raw_Name)), Tag, Sym_Scalar,
                                         Offset_Bytes => Allocate_Address_Bytes (Element_Bytes (Tag)),
                                         Routine_Alias => Routine_Alias_Of (Node.Token_Index));
                        Emit_Assignment (Target_Node, Value_Node, Tag, True);
                     end if;
                  else
                     Emit_Assignment (Target_Node, Value_Node, Symbols (Sym_Id).Tag, False);
                  end if;
               end if;
            else
               declare
                  Assign_Tag : Value_Kind := VK_Unknown;
                  Tgt        : constant AST_Node := Tree (Target_Node);
                  Tgt_Sym    : Symbol_Record;
               begin
                  --  Indexed/member targets cast to the *element* kind, not
                  --  the value's — `pos[i] = MID$(s,i,1)` must stay a string.
                  if Tgt.Kind in AST_Var_Expr | AST_Temporal_Ref
                    and then Tgt.Token_Index > 0
                  then
                     Tgt_Sym := Resolve_Symbol (Raw_Lexeme (Tgt.Token_Index));
                     if Tgt_Sym.Active
                       and then Tgt_Sym.Kind in Sym_Strict_Array |
                         Sym_Slide_Array | Sym_Parallel_Field | Sym_Scalar
                     then
                        Assign_Tag := Tgt_Sym.Tag;
                     end if;
                  end if;
                  if Assign_Tag = VK_Unknown then
                     Assign_Tag := Infer_Expr_Kind (Value_Node);
                     if Assign_Tag = VK_Unknown then
                        Assign_Tag := VK_Number;
                     end if;
                  end if;
                  Emit_Assignment (Target_Node, Value_Node, Assign_Tag, False);
               end;
            end if;

         when AST_Procedure_Decl =>
            Emit_Function_Decl (Index, False);

         when AST_Function_Decl =>
            Emit_Function_Decl (Index, True);

         when AST_Private_Decl =>
            -- PRIVATE <decl> — module-private member. TypeScript has no
            -- visibility semantics for top-level functions; emit the
            -- wrapped decl so private helpers remain callable.
            if Node.Left_Child > 0 then
               Emit_Node (Node.Left_Child);
            end if;

         when AST_Return_Stmt =>
            if Current_Routine_Out_Count > 0 then
               Emit_Current_Out_Writebacks;
            end if;
            if Node.Left_Child > 0 then
               Line ("return " & Expr (Node.Left_Child) & ";");
            else
               Line ("return;");
            end if;

         when AST_Fallback_Block =>
            if Node.Left_Child > 0 then
               Emit_Block (Node.Left_Child);
            end if;

         when AST_Exact_Block =>
            Exact_Depth := Exact_Depth + 1;
            if Node.Left_Child > 0 then
               Emit_Block (Node.Left_Child);
            end if;
            Exact_Depth := Exact_Depth - 1;

         when AST_Symbolic_Block =>
            Symbolic_Depth := Symbolic_Depth + 1;
            if Node.Left_Child > 0 then
               Emit_Block (Node.Left_Child);
            end if;
            Symbolic_Depth := Symbolic_Depth - 1;

         when AST_Branchless_Predicate_Block =>
            declare
               Body_Node     : constant Node_Index := Node.Right_Child;
               Fallback_Node : constant Node_Index := (if Body_Node > 0 then Tree (Body_Node).Next_Sibling else 0);
            begin
               Line ("if (Boolean(" & Expr (Node.Left_Child) & ")) {");
               Indent_Level := Indent_Level + 1;
               Emit_Block (Body_Node);
               Indent_Level := Indent_Level - 1;
               if Fallback_Node > 0 then
                  Line ("} else {");
                  Indent_Level := Indent_Level + 1;
                  Emit_Fallback_Body (Fallback_Node);
                  Indent_Level := Indent_Level - 1;
                  Line ("}");
               else
                  Line ("}");
               end if;
            end;

         when AST_Stride_Block =>
            declare
               Body_Node : constant Node_Index := Node.Right_Child;
            begin
               if Stride_Depth < Max_Mode_Nesting then
                  Stride_Depth := Stride_Depth + 1;
                  Stride_Step_Stack (Stride_Depth) := U (Expr (Node.Left_Child));
                  Emit_Block (Body_Node);
                  Stride_Step_Stack (Stride_Depth) := U ("");
                  Stride_Depth := Stride_Depth - 1;
               else
                  Emit_Warn_Once ("stride-nesting-limit",
                                  "STRIDE nesting beyond 32 levels falls back to normal FOR stepping on ALBW");
                  Emit_Block (Body_Node);
               end if;
            end;

         when AST_Ratio_Space_Block =>
            Emit_Warn_Once ("ratio-space-albw",
                            "RATIO_SPACE pinning is approximated as ordinary JS evaluation on ALBW");
            if Node.Right_Child > 0 then
               Emit_Block (Node.Right_Child);
            end if;

         when AST_Morton_Tile_Block =>
            declare
               Size_Node      : constant Node_Index := Node.Right_Child;
               Body_Node      : constant Node_Index := (if Size_Node > 0 then Tree (Size_Node).Next_Sibling else 0);
               Width_Node     : constant Node_Index := (if Size_Node > 0 then Tree (Size_Node).Left_Child else 0);
               Height_Node    : constant Node_Index := (if Size_Node > 0 then Tree (Size_Node).Right_Child else 0);
               Width_Text     : Unbounded_String := U ("1");
               Height_Text    : Unbounded_String := U ("1");
               Width_Name     : constant String := Next_Temp_Name ("morton_w");
               Height_Name    : constant String := Next_Temp_Name ("morton_h");
               Limit_Name     : constant String := Next_Temp_Name ("morton_limit");
               Code_Name      : constant String := Next_Temp_Name ("morton_code");
               Seen_Name      : constant String := Next_Temp_Name ("morton_seen");
               X_Name         : constant String := Next_Temp_Name ("morton_x");
               Y_Name         : constant String := Next_Temp_Name ("morton_y");
               Bits_Name      : constant String := Next_Temp_Name ("morton_bits");
               Shift_Name     : constant String := Next_Temp_Name ("morton_shift");
               Size_Text      : constant String := (if Size_Node > 0 and then Tree (Size_Node).Token_Index > 0
                                                   then Raw_Lexeme (Tree (Size_Node).Token_Index)
                                                   else "");
            begin
               if Width_Node > 0 then
                  Width_Text := U (Expr (Width_Node));
               elsif Size_Text'Length > 2 then
                  declare
                     X_Pos : Natural := 0;
                  begin
                     for I in Size_Text'Range loop
                        if Size_Text (I) = 'x' or else Size_Text (I) = 'X' then
                           X_Pos := I;
                           exit;
                        end if;
                     end loop;
                     if X_Pos > Size_Text'First + 1 then
                        Width_Text := U (Size_Text (Size_Text'First + 1 .. X_Pos - 1));
                        if X_Pos < Size_Text'Last then
                           Height_Text := U (Size_Text (X_Pos + 1 .. Size_Text'Last));
                        end if;
                     end if;
                  end;
               end if;

               if Height_Node > 0 then
                  Height_Text := U (Expr (Height_Node));
               elsif Length (Height_Text) = 0 then
                  Height_Text := Width_Text;
               end if;

               Ensure_Special_Scalar ("MTX", VK_U64);
               Ensure_Special_Scalar ("MTY", VK_U64);
               Line ("{");
               Indent_Level := Indent_Level + 1;
               Line ("const " & Width_Name & " = Math.max(1, Number(" & To_String (Width_Text) & ") | 0);");
               Line ("const " & Height_Name & " = Math.max(1, Number(" & To_String (Height_Text) & ") | 0);");
               Line ("const " & Limit_Name & " = Math.max(" & Width_Name & ", " & Height_Name & ");");
               Line ("for (let " & Code_Name & " = 0, " & Seen_Name & " = 0; " &
                     Seen_Name & " < (" & Width_Name & " * " & Height_Name & "); " &
                     Code_Name & " += 1) {");
               Indent_Level := Indent_Level + 1;
               Line ("let " & X_Name & " = 0;");
               Line ("let " & Y_Name & " = 0;");
               Line ("let " & Bits_Name & " = " & Code_Name & ";");
               Line ("for (let " & Shift_Name & " = 0; " & Shift_Name & " < 16; " & Shift_Name & " += 1) {");
               Indent_Level := Indent_Level + 1;
               Line (X_Name & " |= (" & Bits_Name & " & 1) << " & Shift_Name & ";");
               Line (Bits_Name & " = " & Bits_Name & " >>> 1;");
               Line (Y_Name & " |= (" & Bits_Name & " & 1) << " & Shift_Name & ";");
               Line (Bits_Name & " = " & Bits_Name & " >>> 1;");
               Line ("if ((1 << (" & Shift_Name & " + 1)) > " & Limit_Name & " && " & Bits_Name & " === 0) break;");
               Indent_Level := Indent_Level - 1;
               Line ("}");
               Line ("if (" & X_Name & " >= " & Width_Name & " || " & Y_Name & " >= " & Height_Name & ") continue;");
               Line ("MTX = " & X_Name & ";");
               Line ("MTY = " & Y_Name & ";");
               Line (Seen_Name & " += 1;");
               Emit_Block (Body_Node);
               Indent_Level := Indent_Level - 1;
               Line ("}");
               Indent_Level := Indent_Level - 1;
               Line ("}");
            end;

         when AST_If_Stmt =>
            declare
               Then_Block : constant Node_Index := Node.Right_Child;
               Else_Block : constant Node_Index :=
                 (if Then_Block > 0
                     and then Tree (Then_Block).Kind = AST_Block_Stmt
                     and then Tree (Then_Block).Next_Sibling > 0
                     and then Tree (Tree (Then_Block).Next_Sibling).Kind = AST_Block_Stmt
                  then Tree (Then_Block).Next_Sibling
                  else 0);
            begin
               Line ("if (Boolean(" & Expr (Node.Left_Child) & ")) {");
               Indent_Level := Indent_Level + 1;
               Emit_Block (Then_Block);
               Indent_Level := Indent_Level - 1;
               if Else_Block > 0 then
                  Line ("} else {");
                  Indent_Level := Indent_Level + 1;
                  Emit_Block (Else_Block);
                  Indent_Level := Indent_Level - 1;
                  Line ("}");
               else
                  Line ("}");
               end if;
            end;

         when AST_While_Stmt =>
            declare
               Guard_Name : constant String := Next_Temp_Name ("guard");
            begin
               Line ("let " & Guard_Name & " = 0;");
               Line ("while (Boolean(" & Expr (Node.Left_Child) & ")) {");
               Indent_Level := Indent_Level + 1;
               Line ("if (++" & Guard_Name & " > 200000000) break; /* Browser thread safety bailout */");
               Emit_Block (Node.Right_Child);
               Indent_Level := Indent_Level - 1;
               Line ("}");
            end;

         when AST_For_Stmt =>
            declare
               Loop_Spec  : constant Node_Index := Node.Left_Child;
               Start_Node : constant Node_Index :=
                 (if Loop_Spec > 0 then Tree (Loop_Spec).Left_Child else 0);
               End_Node   : constant Node_Index :=
                 (if Loop_Spec > 0 and then Tree (Loop_Spec).Right_Child > 0
                  then
                    (if Tree (Tree (Loop_Spec).Right_Child).Kind = AST_Arg_List
                     then Tree (Tree (Loop_Spec).Right_Child).Left_Child
                     else Tree (Loop_Spec).Right_Child)
                  else 0);
               Step_Node  : constant Node_Index :=
                 (if Loop_Spec > 0 and then Tree (Loop_Spec).Right_Child > 0
                     and then Tree (Tree (Loop_Spec).Right_Child).Kind = AST_Arg_List
                     and then End_Node > 0
                  then Tree (End_Node).Next_Sibling
                  else 0);
               --  Loop bounds are scalar counters — coerce bigint-array
               --  element reads so mixed bigint/number compares don't throw.
               Start_Expr : constant String :=
                 (if Start_Node > 0 then Num_Op (Start_Node, Expr (Start_Node)) else "0");
               End_Expr   : constant String :=
                 (if End_Node > 0 then Num_Op (End_Node, Expr (End_Node)) else "0");
               Step_Expr  : constant String :=
                 (if Step_Node > 0
                  then Num_Op (Step_Node, Expr (Step_Node))
                  elsif Stride_Depth > 0 and then Length (Stride_Step_Stack (Stride_Depth)) > 0
                  then To_String (Stride_Step_Stack (Stride_Depth))
                  else "1");
               Var_Name   : constant String := Raw_Lexeme (Node.Token_Index);
               Var_JS     : constant String := Resolve_Var_Name (Var_Name);
               Step_Name  : constant String := Next_Temp_Name ("for_step");
               Idx_Name   : constant String := Next_Temp_Name ("for_idx");
            begin
               Raw_Name := U (Var_Name);
               if Find_Symbol_Shaped
                    (To_String (Current_Routine), To_String (Raw_Name),
                     Want_Array => False, Strict => True) = 0
                 and then Find_Symbol_Shaped
                            ("", Scoped_Name (To_String (Raw_Name)),
                             Want_Array => False, Strict => True) = 0
               then
                  if Length (Current_Routine) > 0 then
                     Register_Symbol (To_String (Current_Routine), To_String (Raw_Name), Safe_JS_Name (To_String (Raw_Name)), VK_Number, Sym_Scalar);
                     Line ("var " & Safe_JS_Name (To_String (Raw_Name)) & ": number = " & Cast_Expr (VK_Number, Start_Expr) & ";");
                  else
                     Register_Symbol ("", Scoped_Name (To_String (Raw_Name)), Scoped_Name (To_String (Raw_Name)), VK_Number, Sym_Scalar);
                     Line ("var " & Scoped_Name (To_String (Raw_Name)) & ": number = " & Cast_Expr (VK_Number, Start_Expr) & ";");
                  end if;
               end if;

               Line ("{");
               Indent_Level := Indent_Level + 1;
               Line ("const " & Step_Name & " = " & Step_Expr & ";");
               --  ALB FOR semantics: the loop variable is a read-only
               --  per-iteration value (Rust for-range style). Body writes to
               --  the variable do NOT affect iteration, so the counter must
               --  be a shadow index that copies into the var each pass.
               Line ("for (let " & Idx_Name & " = " & Start_Expr &
                     "; (" & Step_Name & " >= 0 ? " & Idx_Name & " <= " & End_Expr & " : " & Idx_Name & " >= " & End_Expr & ")" &
                     "; " & Idx_Name & " += " & Step_Name & ") {");
               Indent_Level := Indent_Level + 1;
               Line (Var_JS & " = Number(" & Idx_Name & ");");
               Emit_Block (Node.Right_Child);
               Indent_Level := Indent_Level - 1;
               Line ("}");
               Indent_Level := Indent_Level - 1;
               Line ("}");
            end;

         when AST_Foreach_Stmt =>
            declare
               Iterator_Raw  : constant String := Raw_Lexeme (Node.Token_Index);
               Iterator_JS   : constant String := Safe_JS_Name (Iterator_Raw);
               Iterator_Scope : constant String :=
                 (if Length (Current_Routine) > 0 then To_String (Current_Routine) else "");
               Seq_Name      : constant String := Next_Temp_Name ("foreach_seq");
               Index_Name    : constant String := Next_Temp_Name ("foreach_ix");
               Length_Name   : constant String := Next_Temp_Name ("foreach_len");
               Shadow_Id     : Natural := 0;
               Sequence_Node : constant Node_Index := Node.Left_Child;
               Sequence_AST  : constant AST_Node := Tree (Sequence_Node);
               Sequence_Raw  : constant String :=
                 (if Sequence_AST.Token_Index > 0 then Raw_Lexeme (Sequence_AST.Token_Index) else "");
               Sequence_Sym  : constant Symbol_Record := Resolve_Symbol (Sequence_Raw);
               Item_Tag      : constant Value_Kind :=
                 (if Sequence_Sym.Active then Sequence_Sym.Tag else VK_Number);
               Sequence_Len  : constant String :=
                 (if Sequence_Sym.Active and then Sequence_Sym.Kind = Sym_Slide_Array
                  then To_String (Sequence_Sym.JS_Name) & "_active"
                  else Seq_Name & ".length");
            begin
               Line ("{");
               Indent_Level := Indent_Level + 1;
               Line ("const " & Seq_Name & " = " & Expr (Sequence_Node) & ";");
               Line ("const " & Length_Name & " = " & Sequence_Len & ";");
               Line ("for (let " & Index_Name & " = 0; " & Index_Name & " < " & Length_Name &
                     "; " & Index_Name & " += 1) {");
               Indent_Level := Indent_Level + 1;
               Line ("let " & Iterator_JS & ": " & Primitive_TS_Type (Item_Tag) & " = " &
                     Cast_Expr (Item_Tag, Seq_Name & "[" & Index_Name & "]") & ";");
               Shadow_Id :=
                 Push_Shadow_Symbol
                   (Scope   => Iterator_Scope,
                    Name    => Iterator_Raw,
                    JS_Name => Iterator_JS,
                    Tag     => Item_Tag);
               Emit_Block (Node.Right_Child);
               Pop_Shadow_Symbol (Shadow_Id);
               Indent_Level := Indent_Level - 1;
               Line ("}");
               Indent_Level := Indent_Level - 1;
               Line ("}");
            end;

         when AST_Repeat_Stmt =>
            declare
               Guard_Name : constant String := Next_Temp_Name ("guard");
            begin
               Line ("let " & Guard_Name & " = 0;");
               Line ("do {");
               Indent_Level := Indent_Level + 1;
               Line ("if (++" & Guard_Name & " > 200000000) break; /* Browser thread safety bailout */");
               Emit_Block (Node.Left_Child);
               Indent_Level := Indent_Level - 1;
               Line ("} while (!Boolean(" & Expr (Node.Right_Child) & "));");
            end;

         when AST_Break_Stmt =>
            Line ("break;");

         when AST_Continue_Stmt =>
            Line ("continue;");

          when AST_Call_Stmt =>
             if Node.Left_Child > 0 and then Tree (Node.Left_Child).Kind = AST_Func_Call then
                declare
                   Call_Node : constant AST_Node := Tree (Node.Left_Child);
                   Target    : constant String :=
                     (if Tree (Call_Node.Left_Child).Kind = AST_Member_Expr
                      then Collect_Module_Member_Name (Call_Node.Left_Child)
                      else Resolve_Var_Name (Raw_Lexeme (Tree (Call_Node.Left_Child).Token_Index)));
                   RName     : constant String :=
                     (if Tree (Call_Node.Left_Child).Kind = AST_Member_Expr
                      then ""
                      else Resolve_Routine_Name (Raw_Lexeme (Tree (Call_Node.Left_Child).Token_Index)));
                begin
                   if RName'Length = 0
                     and then Find_Routine_For_Call (Target) = 0
                   then
                      --  No registered routine — a builtin statement call
                      --  (`KILL("f")`, `SHELL(...)` form). The expression
                      --  dispatcher maps builtin names to runtime helpers.
                      Line (Expr (Node.Left_Child) & ";");
                   else
                      Emit_Call_With_Out
                        ((if RName'Length > 0 then RName else Target),
                         Call_Node.Right_Child);
                   end if;
                end;
             else
                Line (Expr (Node.Left_Child) & ";");
             end if;

         when AST_On_Block =>
            if Node.Token_Index > 0 then
               Remember_Event_Block (Tokens (Node.Token_Index).Kind, Node.Left_Child);
               if Tokens (Node.Token_Index).Kind not in Tok_Tick | Tok_Paint | Tok_Key then
                  Line ("/* unsupported ON event for TS backend: " &
                        Token_Kind'Image (Tokens (Node.Token_Index).Kind) & " */");
               end if;
            end if;

         when AST_Match_Stmt =>
            Emit_Switch_Stmt (Node.Left_Child, Node.Right_Child);

         when AST_Select_Stmt =>
            Emit_Switch_Stmt (Node.Left_Child, Node.Right_Child);

         when AST_SwapPop_Stmt =>
            Emit_SwapPop (Node.Left_Child, Node.Right_Child);

         when AST_Comptime_Block =>
            Line ("/* COMPTIME lowered to eager module-initialization code */");
            Line ("{");
            Indent_Level := Indent_Level + 1;
            Emit_Block (Node.Left_Child);
            Indent_Level := Indent_Level - 1;
            Line ("}");

         when AST_Find_Query | AST_Query | AST_Knows_Query =>
            Line (Expr (Index) & ";");

         when AST_Create_Window =>
            Saw_Create := True;
            declare
               Title_Node : constant Node_Index := Node.Left_Child;
               Pair_Node  : constant Node_Index := Node.Right_Child;
            begin
               Line ("ALB_CREATE_WINDOW(" &
                     Expr (Title_Node) & ", " &
                     Expr (Tree (Pair_Node).Left_Child) & ", " &
                     Expr (Tree (Pair_Node).Right_Child) & ");");
            end;

         when AST_Set_Fullscreen =>
            Line ("ALB_SET_FULLSCREEN(Boolean(" & Expr (Node.Left_Child) & "));");

         when AST_Set_Resizable =>
            Line ("ALB_SET_RESIZABLE(Boolean(" & Expr (Node.Left_Child) & "));");

         when AST_Set_Stretchy =>
            Line ("ALB_SET_STRETCHY(Boolean(" & Expr (Node.Left_Child) & "));");

         when AST_Tick =>
            Line ("albFrameInterval = Math.max(1, " & Expr (Node.Left_Child) & ");");

         when AST_Color =>
            Line ("ALB_COLOR(" & Expr (Node.Left_Child) & ");");

         when AST_Clear =>
            Line ("ALB_CLEAR(" & Expr (Node.Left_Child) & ");");

         when AST_Use_Font_Stmt =>
            Line ("ALB_SET_FONT(" & Expr (Node.Left_Child) & ");");

         when AST_Apply_Lut_Stmt =>
            declare
               Visual_Node : constant Node_Index := Node.Right_Child;
               With_Node   : constant Node_Index :=
                 (if Visual_Node > 0 and then Tree (Visual_Node).Next_Sibling > 0
                  and then Tree (Tree (Visual_Node).Next_Sibling).Kind = AST_With_Clause
                  then Tree (Visual_Node).Next_Sibling
                  else 0);
            begin
               Line ("ALB_STATIC_APPLY_LUT(" &
                     Expr (Node.Left_Child) & ", " &
                     Expr (Visual_Node) & ", " &
                     (if With_Node > 0 then Expr (Tree (With_Node).Left_Child) else "0") & ", " &
                     (if With_Node > 0 then "true" else "false") & ");");
            end;

         when AST_Blit_Safe_Stmt =>
            declare
               Visual_Node : constant Node_Index := Node.Left_Child;
               Visual_With : constant Node_Index :=
                 (if Visual_Node > 0 and then Tree (Visual_Node).Next_Sibling > 0
                  and then Tree (Tree (Visual_Node).Next_Sibling).Kind = AST_With_Clause
                  then Tree (Visual_Node).Next_Sibling
                  else 0);
               Target_Node   : constant Node_Index := Node.Right_Child;
               Position_Node : constant Node_Index := (if Target_Node > 0 then Tree (Target_Node).Next_Sibling else 0);
               Clause_Node   : Node_Index := (if Position_Node > 0 then Tree (Position_Node).Next_Sibling else 0);
               View_Expr     : Unbounded_String := U ("0");
               Alpha_Mask    : Boolean := False;
            begin
               while Clause_Node > 0 loop
                  if Tree (Clause_Node).Kind = AST_Constrain_To_Clause then
                     View_Expr := U (Expr (Tree (Clause_Node).Left_Child));
                  elsif Tree (Clause_Node).Kind = AST_Mode_Clause then
                     Alpha_Mask := Upper_Text (Raw_Feature_Atom (Tree (Clause_Node).Left_Child)) = "ALPHAMASK";
                  end if;
                  Clause_Node := Tree (Clause_Node).Next_Sibling;
               end loop;

               Line ("ALB_STATIC_BLIT(" &
                     Expr (Visual_Node) & ", " &
                     (if Visual_With > 0 then Expr (Tree (Visual_With).Left_Child) else "0") & ", " &
                     (if Visual_With > 0 then "true" else "false") & ", " &
                     Expr (Target_Node) & ", " &
                     Expr (Tree (Position_Node).Left_Child) & ", " &
                     Expr (Tree (Position_Node).Right_Child) & ", " &
                     To_String (View_Expr) & ", " &
                     (if Alpha_Mask then "true" else "false") & ");");
            end;

         when AST_Set_Axis_Stmt | AST_Add_Axis_Stmt | AST_Get_Axis_Stmt |
              AST_Blend_Emotion_Stmt | AST_Decay_Emotion_Stmt |
              AST_Dominant_Emotion_Stmt =>
            declare
               Emo_Node  : constant Node_Index := Node.Left_Child;
               Arg1_Node : constant Node_Index := Node.Right_Child;
               Arg2_Node : constant Node_Index :=
                 (if Arg1_Node > 0 then Tree (Arg1_Node).Next_Sibling else 0);
               Arg3_Node : constant Node_Index :=
                 (if Arg2_Node > 0 then Tree (Arg2_Node).Next_Sibling else 0);
               --  Arg order per statement: SET/ADD e axis val;
               --  GET e axis INTO out (out is Arg3); BLEND e axis amt;
               --  DECAY e amt; DOMINANT e out.
               Arr : Unbounded_String;
               Off : Natural := 0;
            begin
               case Node.Kind is
                  when AST_Set_Axis_Stmt | AST_Add_Axis_Stmt =>
                     Resolve_Emotion_Axis (Emo_Node, Arg1_Node, Arr, Off,
                                           "SET_AXIS/ADD_AXIS");
                     Emit_Firewall_Touch (Arg2_Node, True, False);
                     if Node.Kind = AST_Set_Axis_Stmt then
                        Line (To_String (Arr) & "[" & Trim_Image (Off) &
                              "] = Math.max(0, Math.min(255, Math.trunc(Number(" &
                              Expr (Arg2_Node) & ") ?? 0)));");
                     else
                        --  ADD clamps the DELTA to 0..255 first, then
                        --  saturating-adds (FASM Clamp_Emotion_Delta).
                        Line (To_String (Arr) & "[" & Trim_Image (Off) &
                              "] = Math.min(255, (" & To_String (Arr) & "[" &
                              Trim_Image (Off) & "] | 0) + Math.max(0, " &
                              "Math.min(255, Math.trunc(Number(" &
                              Expr (Arg2_Node) & ") ?? 0))));");
                     end if;
                  when AST_Get_Axis_Stmt =>
                     Resolve_Emotion_Axis (Emo_Node, Arg1_Node, Arr, Off,
                                           "GET_AXIS");
                     Emit_Firewall_Touch (Arg2_Node, False, True);
                     Line (Statement_Target_Name (Arg2_Node) & " = " &
                           To_String (Arr) & "[" & Trim_Image (Off) & "];");
                  when AST_Blend_Emotion_Stmt =>
                     Resolve_Emotion_Axis (Emo_Node, Arg1_Node, Arr, Off,
                                           "BLEND_EMOTION");
                     Emit_Firewall_Touch (Arg2_Node, True, False);
                     Line ("ALB_EMO_BLEND(" & To_String (Arr) & ", " &
                           To_String (Arr) & "_COUNT, " & Trim_Image (Off) &
                           ", Math.trunc(Number(" & Expr (Arg2_Node) &
                           ") ?? 0));");
                  when AST_Decay_Emotion_Stmt =>
                     declare
                        E_Idx : constant Natural :=
                          Find_Emotion (Emotion_Name_Of (Emo_Node));
                     begin
                        if E_Idx = 0 then
                           raise Program_Error with
                             "EMOTION DECAY_EMOTION needs a declared " &
                             "EMOTION name (got '" &
                             Emotion_Name_Of (Emo_Node) & "')";
                        end if;
                        Arr := U ("ALB_EMOTION_" &
                                  Scoped_Name (Emotion_Name_Of (Emo_Node)));
                     end;
                     Emit_Firewall_Touch (Arg1_Node, True, False);
                     Line ("ALB_EMO_DECAY(" & To_String (Arr) & ", " &
                           To_String (Arr) & "_COUNT, Math.trunc(Number(" &
                           Expr (Arg1_Node) & ") ?? 0));");
                  when AST_Dominant_Emotion_Stmt =>
                     declare
                        E_Idx : constant Natural :=
                          Find_Emotion (Emotion_Name_Of (Emo_Node));
                     begin
                        if E_Idx = 0 then
                           raise Program_Error with
                             "EMOTION DOMINANT_EMOTION needs a declared " &
                             "EMOTION name (got '" &
                             Emotion_Name_Of (Emo_Node) & "')";
                        end if;
                        Arr := U ("ALB_EMOTION_" &
                                  Scoped_Name (Emotion_Name_Of (Emo_Node)));
                     end;
                     Emit_Firewall_Touch (Arg1_Node, False, True);
                     Line (Statement_Target_Name (Arg1_Node) &
                           " = ALB_EMO_DOMINANT(" & To_String (Arr) & ", " &
                           To_String (Arr) & "_COUNT);");
                  when others =>
                     null;
               end case;
            end;

         when AST_Predict_Markov_Stmt =>
            declare
               Emo_Node : constant Node_Index :=
                 (if Node.Right_Child > 0
                    and then Tree (Node.Right_Child).Next_Sibling > 0
                  then Tree (Tree (Node.Right_Child).Next_Sibling).Next_Sibling
                  else 0);
               --  WITH EMOTION: resolve to the declared flat U8 array.
               Emo_E : constant Natural :=
                 Find_Emotion (Emotion_Name_Of (Emo_Node));
            begin
               Emit_Firewall_Touch (Node.Left_Child, True, False);
               Emit_Firewall_Touch (Node.Right_Child, True, False);
               Emit_Firewall_Touch
                 (Tree (Node.Right_Child).Next_Sibling, False, True);
               if Emo_Node > 0 then
                  if Emo_E = 0 then
                     raise Program_Error with
                       "EMOTION WITH EMOTION needs a declared EMOTION " &
                       "name (got '" & Emotion_Name_Of (Emo_Node) & "')";
                  end if;
                  Line (Statement_Target_Name
                          (Tree (Node.Right_Child).Next_Sibling) &
                        " = ALB_MARKOV_PREDICT_E(" &
                        Expr (Node.Left_Child) & ", " &
                        Expr (Node.Right_Child) & ", ALB_EMOTION_" &
                        Scoped_Name (Emotion_Name_Of (Emo_Node)) & ");");
               else
                  Line (Statement_Target_Name
                          (Tree (Node.Right_Child).Next_Sibling) &
                        " = ALB_MARKOV_PREDICT(" &
                        Expr (Node.Left_Child) & ", " &
                        Expr (Node.Right_Child) & ");");
               end if;
            end;

         when AST_Infer_Network_Stmt =>
            declare
               Emo_Node : constant Node_Index :=
                 (if Node.Right_Child > 0
                    and then Tree (Node.Right_Child).Next_Sibling > 0
                  then Tree (Tree (Node.Right_Child).Next_Sibling).Next_Sibling
                  else 0);
               Emo_E : constant Natural :=
                 Find_Emotion (Emotion_Name_Of (Emo_Node));
            begin
               Emit_Firewall_Touch (Node.Left_Child, True, False);
               Emit_Firewall_Touch (Node.Right_Child, True, False);
               Emit_Firewall_Touch
                 (Tree (Node.Right_Child).Next_Sibling, False, True);
               if Emo_Node > 0 then
                  --  FASM: bias input elems by emotion axis values
                  --  (min(input len, axis count, 8)) before infer.
                  if Emo_E = 0 then
                     raise Program_Error with
                       "EMOTION WITH EMOTION needs a declared EMOTION " &
                       "name (got '" & Emotion_Name_Of (Emo_Node) & "')";
                  end if;
                  Line ("{ const __alb_nn_inp = " & Expr (Node.Right_Child) &
                        "; ALB_EMO_BIAS_INPUTS(__alb_nn_inp, ALB_EMOTION_" &
                        Scoped_Name (Emotion_Name_Of (Emo_Node)) & "_COUNT, " &
                        "ALB_EMOTION_" &
                        Scoped_Name (Emotion_Name_Of (Emo_Node)) & "); " &
                        "ALB_NN_INFER(" & Expr (Node.Left_Child) &
                        ", __alb_nn_inp, " &
                        Statement_Target_Name
                          (Tree (Node.Right_Child).Next_Sibling) & "); }");
               else
                  Line ("ALB_NN_INFER(" & Expr (Node.Left_Child) & ", " &
                        Expr (Node.Right_Child) & ", " &
                        Statement_Target_Name
                          (Tree (Node.Right_Child).Next_Sibling) & ");");
               end if;
            end;

         when AST_Train_Network_Stmt =>
            declare
               Train_Node  : constant Node_Index := Node.Right_Child;
               Expect_Node : constant Node_Index := (if Train_Node > 0 then Tree (Train_Node).Next_Sibling else 0);
               Epoch_Node  : constant Node_Index := (if Expect_Node > 0 then Tree (Expect_Node).Next_Sibling else 0);
            begin
               Emit_Firewall_Touch (Node.Left_Child, True, True);
               Emit_Firewall_Touch (Train_Node, True, False);
               Emit_Firewall_Touch (Expect_Node, True, False);
               Line ("ALB_NN_TRAIN(" & Expr (Node.Left_Child) & ", " &
                     Expr (Train_Node) & ", " & Expr (Expect_Node) & ", " &
                     (if Epoch_Node > 0 then Expr (Epoch_Node) else "1") & ");");
            end;

         when AST_Export_PPM_Block =>
            declare
               Path_Node     : constant Node_Index := Node.Right_Child;
               Format_Node   : constant Node_Index := (if Path_Node > 0 then Tree (Path_Node).Next_Sibling else 0);
               Body_Node     : constant Node_Index := (if Format_Node > 0 then Tree (Format_Node).Next_Sibling else 0);
               Fallback_Node : constant Node_Index := (if Body_Node > 0 then Tree (Body_Node).Next_Sibling else 0);
               Status_Name   : constant String := Next_Temp_Name ("export_ppm");
            begin
               Line ("{");
               Indent_Level := Indent_Level + 1;
               Line ("const " & Status_Name & " = ALB_EXPORT_PPM(" &
                     Expr (Node.Left_Child) & ", " &
                     As_Text_Expr (Path_Node) & ", " &
                     Feature_Text_Expr (Format_Node) & ");");
               Line ("if (" & Status_Name & " !== 0) {");
               Indent_Level := Indent_Level + 1;
               Emit_Block (Body_Node);
               Indent_Level := Indent_Level - 1;
               if Fallback_Node > 0 then
                  Line ("} else {");
                  Indent_Level := Indent_Level + 1;
                  Emit_Fallback_Body (Fallback_Node);
                  Indent_Level := Indent_Level - 1;
                  Line ("}");
               else
                  Line ("}");
               end if;
               Indent_Level := Indent_Level - 1;
               Line ("}");
            end;

         when AST_Fits_Cube_Block =>
            Emit_Warn_Once ("fits-cube-albw",
                            "FITS_CUBE is not implemented on ALBW yet; running FALLBACK when present");
            if Node.Right_Child > 0
              and then Tree (Node.Right_Child).Next_Sibling > 0
              and then Tree (Tree (Node.Right_Child).Next_Sibling).Next_Sibling > 0
            then
               Emit_Fallback_Body (Tree (Tree (Node.Right_Child).Next_Sibling).Next_Sibling);
            end if;

         when AST_Ini_Bind_Block =>
            declare
               Path_Node      : constant Node_Index := Node.Right_Child;
               Body_Node      : constant Node_Index := (if Path_Node > 0 then Tree (Path_Node).Next_Sibling else 0);
               Fallback_Node  : constant Node_Index := (if Body_Node > 0 then Tree (Body_Node).Next_Sibling else 0);
               Table_Name     : constant String := "__alb_ini_table_" & Next_Temp_Name ("bind");
               Embed_Name     : constant String := "__alb_ini_text_" & Next_Temp_Name ("bind");
               Static_Path    : Unbounded_String := U ("");
               Entry_Node     : Node_Index := 0;
            begin
               if Path_Node > 0 and then Tree (Path_Node).Kind = AST_String_Expr then
                  Static_Path := U (Resolve_Static_Asset_Path (Strip_String_Node (Path_Node)));
               end if;

               if Length (Static_Path) > 0 then
                  Emit_Embedded_Text_File (Embed_Name, To_String (Static_Path));
               else
                  Line ("const " & Embed_Name & ": string | null = null;");
               end if;

               Line ("{");
               Indent_Level := Indent_Level + 1;
               if Body_Node > 0 then
                  Emit_Block (Body_Node);
               end if;
               Line ("const " & Table_Name & ": Array<{ key: string; apply: (value: number) => void }> = [");
               Indent_Level := Indent_Level + 1;
               if Body_Node > 0 then
                  Entry_Node := Tree (Body_Node).Left_Child;
               end if;
               while Entry_Node > 0 loop
                  if Tree (Entry_Node).Kind = AST_Let_Stmt
                    and then Tree (Entry_Node).Left_Child > 0
                    and then Tree (Tree (Entry_Node).Left_Child).Kind = AST_Var_Expr
                  then
                     declare
                        Target_Var : constant Node_Index := Tree (Entry_Node).Left_Child;
                        Raw_Key    : constant String := Raw_Lexeme (Tree (Target_Var).Token_Index);
                        Lower_Key  : constant String := Ada.Characters.Handling.To_Lower (Raw_Key);
                     begin
                        Line ("{ key: " & Escape_TS_String (Lower_Key) &
                              ", apply: (value: number) => { " &
                              Statement_Target_Name (Target_Var) &
                              " = value; } },");
                     end;
                  end if;
                  Entry_Node := Tree (Entry_Node).Next_Sibling;
               end loop;
               Indent_Level := Indent_Level - 1;
               Line ("];");
               Line ("if (ALB_INI_BIND(" & As_Text_Expr (Path_Node) & ", " & Embed_Name & ", " & Table_Name & ") === 0) {");
               Indent_Level := Indent_Level + 1;
               if Body_Node > 0 then
                  Emit_Block (Body_Node);
               end if;
               Emit_Fallback_Body (Fallback_Node);
               Indent_Level := Indent_Level - 1;
               Line ("}");
               Indent_Level := Indent_Level - 1;
               Line ("}");
            end;

         when AST_Stream_Bypass_Block =>
            Emit_Warn_Once ("stream-bypass-albw",
                            "STREAM_BYPASS is ignored on ALBW; running FALLBACK when present");
            if Node.Right_Child > 0
              and then Tree (Node.Right_Child).Next_Sibling > 0
              and then Tree (Tree (Node.Right_Child).Next_Sibling).Next_Sibling > 0
              and then Tree (Tree (Tree (Node.Right_Child).Next_Sibling).Next_Sibling).Next_Sibling > 0
            then
               Emit_Fallback_Body
                 (Tree (Tree (Tree (Node.Right_Child).Next_Sibling).Next_Sibling).Next_Sibling);
            end if;

         when AST_Synth_Bake_Block =>
            Emit_Warn_Once ("synth-bake-albw",
                            "SYNTH_BAKE is not implemented on ALBW yet; running FALLBACK when present");
            if Node.Right_Child > 0
              and then Tree (Node.Right_Child).Next_Sibling > 0
              and then Tree (Tree (Node.Right_Child).Next_Sibling).Next_Sibling > 0
            then
               Emit_Fallback_Body (Tree (Tree (Node.Right_Child).Next_Sibling).Next_Sibling);
            end if;

         when AST_Mount_Archive_Block =>
            Emit_Warn_Once ("mount-archive-albw",
                            "MOUNT_ARCHIVE is not available on ALBW; running FALLBACK when present");
            if Node.Right_Child > 0
              and then Tree (Node.Right_Child).Next_Sibling > 0
              and then Tree (Tree (Node.Right_Child).Next_Sibling).Next_Sibling > 0
            then
               Emit_Fallback_Body (Tree (Tree (Node.Right_Child).Next_Sibling).Next_Sibling);
            end if;

         when AST_Network_Sniff_Stmt =>
            Emit_Firewall_Touch (Node.Left_Child, True, True);
            Emit_Firewall_Touch (Node.Right_Child, False, True);
            Line ("ALB_SNIFFER_CAPTURE(" & Expr (Node.Left_Child) & ", " &
                  Statement_Target_Name (Node.Right_Child) & ");");

         when AST_Parse_Ethernet_Stmt =>
            declare
               Src_Node : constant Node_Index := Node.Left_Child;
               D1       : constant Node_Index := Node.Right_Child;
               D2       : constant Node_Index := (if D1 > 0 then Tree (D1).Next_Sibling else 0);
               D3       : constant Node_Index := (if D2 > 0 then Tree (D2).Next_Sibling else 0);
            begin
               Emit_Firewall_Touch (Src_Node, True, False);
               if D1 > 0 then
                  Emit_Firewall_Touch (D1, False, True);
                  Line (Statement_Target_Name (D1) & " = ALB_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 0, 6);");
               end if;
               if D2 > 0 then
                  Emit_Firewall_Touch (D2, False, True);
                  Line (Statement_Target_Name (D2) & " = ALB_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 6, 6);");
               end if;
               if D3 > 0 then
                  Emit_Firewall_Touch (D3, False, True);
                  Line (Statement_Target_Name (D3) & " = ALB_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 12, 2);");
               end if;
            end;

         when AST_Parse_IP_Stmt =>
            declare
               Src_Node : constant Node_Index := Node.Left_Child;
               D1       : constant Node_Index := Node.Right_Child;
               D2       : constant Node_Index := (if D1 > 0 then Tree (D1).Next_Sibling else 0);
               D3       : constant Node_Index := (if D2 > 0 then Tree (D2).Next_Sibling else 0);
               D4       : constant Node_Index := (if D3 > 0 then Tree (D3).Next_Sibling else 0);
            begin
               Emit_Firewall_Touch (Src_Node, True, False);
               if D1 > 0 then
                  Emit_Firewall_Touch (D1, False, True);
                  Line (Statement_Target_Name (D1) & " = ALB_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 26, 4);");
               end if;
               if D2 > 0 then
                  Emit_Firewall_Touch (D2, False, True);
                  Line (Statement_Target_Name (D2) & " = ALB_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 30, 4);");
               end if;
               if D3 > 0 then
                  Emit_Firewall_Touch (D3, False, True);
                  Line (Statement_Target_Name (D3) & " = ALB_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 23, 1);");
               end if;
               if D4 > 0 then
                  Emit_Firewall_Touch (D4, False, True);
                  Line (Statement_Target_Name (D4) & " = ALB_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 16, 2);");
               end if;
            end;

         when AST_Parse_TCP_Stmt =>
            declare
               Src_Node : constant Node_Index := Node.Left_Child;
               D1       : constant Node_Index := Node.Right_Child;
               D2       : constant Node_Index := (if D1 > 0 then Tree (D1).Next_Sibling else 0);
               D3       : constant Node_Index := (if D2 > 0 then Tree (D2).Next_Sibling else 0);
               D4       : constant Node_Index := (if D3 > 0 then Tree (D3).Next_Sibling else 0);
            begin
               Emit_Firewall_Touch (Src_Node, True, False);
               if D1 > 0 then
                  Emit_Firewall_Touch (D1, False, True);
                  Line (Statement_Target_Name (D1) & " = ALB_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 34, 2);");
               end if;
               if D2 > 0 then
                  Emit_Firewall_Touch (D2, False, True);
                  Line (Statement_Target_Name (D2) & " = ALB_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 36, 2);");
               end if;
               if D3 > 0 then
                  Emit_Firewall_Touch (D3, False, True);
                  Line (Statement_Target_Name (D3) & " = ALB_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 38, 4);");
               end if;
               if D4 > 0 then
                  Emit_Firewall_Touch (D4, False, True);
                  Line (Statement_Target_Name (D4) & " = ALB_BUFFER_PACK_LE(" & Expr (Src_Node) & ", 42, 4);");
               end if;
            end;

         when AST_Network_Listen_Stmt =>
            Emit_Firewall_Touch (Node.Left_Child, True, True);
            Line ("ALB_NET_LISTEN(" & Expr (Node.Left_Child) & ");");

         when AST_Network_Accept_Stmt =>
            Emit_Firewall_Touch (Node.Left_Child, True, True);
            Emit_Firewall_Touch (Node.Right_Child, False, True);
            Line (Statement_Target_Name (Node.Right_Child) &
                  " = ALB_NET_ACCEPT(" & Expr (Node.Left_Child) & ");");

         when AST_Network_Receive_Stmt =>
            Emit_Firewall_Touch (Node.Left_Child, True, True);
            Emit_Firewall_Touch (Node.Right_Child, False, True);
            Line ("ALB_NET_RECEIVE(" & Expr (Node.Left_Child) & ", " &
                  Statement_Target_Name (Node.Right_Child) & ");");

         when AST_Network_Send_Stmt =>
            Emit_Firewall_Touch (Node.Left_Child, True, True);
            Emit_Firewall_Touch (Node.Right_Child, True, False);
            Line ("ALB_NET_SEND(" & Expr (Node.Left_Child) & ", " &
                  Expr (Node.Right_Child) & ");");

         when AST_Network_Close_Stmt =>
            Emit_Firewall_Touch (Node.Left_Child, True, True);
            Line ("ALB_NET_CLOSE(" & Expr (Node.Left_Child) & ");");

         when AST_Read_Process_Memory_Stmt =>
            declare
               Addr_Node   : constant Node_Index := Node.Right_Child;
               Target_Node : constant Node_Index := (if Addr_Node > 0 then Tree (Addr_Node).Next_Sibling else 0);
               Target_Raw  : constant String := Raw_Feature_Atom (Target_Node);
               Target_Sym  : constant Symbol_Record := Resolve_Symbol (Target_Raw);
            begin
               if Target_Sym.Active and then Target_Sym.Kind in Sym_Strict_Array | Sym_Slide_Array | Sym_Parallel_Field then
                  Line ("ALB_PROCESS_READ_BUFFER(" & Expr (Node.Left_Child) & ", " &
                        Expr (Addr_Node) & ", " & Statement_Target_Name (Target_Node) & ");");
               else
                  Line (Statement_Target_Name (Target_Node) & " = ALB_PROCESS_READ_SCALAR(" &
                        Expr (Node.Left_Child) & ", " & Expr (Addr_Node) & ");");
               end if;
            end;

         when AST_Write_Process_Memory_Stmt =>
            declare
               Addr_Node  : constant Node_Index := Node.Right_Child;
               Value_Node : constant Node_Index := (if Addr_Node > 0 then Tree (Addr_Node).Next_Sibling else 0);
            begin
               Line ("ALB_PROCESS_WRITE_SCALAR(" & Expr (Node.Left_Child) & ", " &
                     Expr (Addr_Node) & ", " & Expr (Value_Node) & ");");
            end;

         when AST_Monitor_Process_Memory_Stmt =>
            declare
               Addr_Node    : constant Node_Index := Node.Right_Child;
               Type_Node    : constant Node_Index := (if Addr_Node > 0 then Tree (Addr_Node).Next_Sibling else 0);
               Target_Node  : constant Node_Index := (if Type_Node > 0 then Tree (Type_Node).Next_Sibling else 0);
               Change_Node  : constant Node_Index := (if Target_Node > 0 then Tree (Target_Node).Next_Sibling else 0);
            begin
               Line ("{");
               Indent_Level := Indent_Level + 1;
               Line ("const __alb_monitor_value = { value: Number(" & Expr (Target_Node) & ") };");
               Line ("const __alb_monitor_change = { value: Number(" & Expr (Change_Node) & ") };");
               Line ("ALB_PROCESS_MONITOR(" & Expr (Node.Left_Child) & ", " &
                     Expr (Addr_Node) & ", __alb_monitor_value, __alb_monitor_change);");
               Line (Statement_Target_Name (Target_Node) & " = __alb_monitor_value.value;");
               Line (Statement_Target_Name (Change_Node) & " = __alb_monitor_change.value;");
               Indent_Level := Indent_Level - 1;
               Line ("}");
            end;

         when AST_Dump_Process_Memory_Stmt =>
            declare
               Addr_Node  : constant Node_Index := Node.Right_Child;
               Size_Node  : constant Node_Index := (if Addr_Node > 0 then Tree (Addr_Node).Next_Sibling else 0);
               Path_Node  : constant Node_Index := (if Size_Node > 0 then Tree (Size_Node).Next_Sibling else 0);
            begin
               Line ("ALB_PROCESS_DUMP(" & Expr (Node.Left_Child) & ", " &
                     Expr (Addr_Node) & ", " & Expr (Size_Node) & ", " &
                     Expr (Path_Node) & ");");
            end;

         when AST_Terminate_Process_Stmt =>
            Line ("if (albProcessTable[" & Expr (Node.Left_Child) &
                  " | 0]) albProcessTable[" & Expr (Node.Left_Child) & " | 0].alive = false;");

         when AST_Create_Process_Stmt =>
            declare
               Args_Node   : constant Node_Index := Node.Right_Child;
               Target_Node : constant Node_Index := (if Args_Node > 0 then Tree (Args_Node).Next_Sibling else 0);
            begin
               Line (Statement_Target_Name (Target_Node) &
                     " = ALB_PROCESS_CREATE(" & Expr (Node.Left_Child) & ", " &
                     (if Args_Node > 0 then Expr (Args_Node) else """""") & ");");
            end;

         when AST_Elevate_Privileges_Stmt =>
            Line ("ALB_PROCESS_ELEVATE(" & Expr (Node.Left_Child) & ");");

         when AST_Hack_Memory_Stmt =>
            declare
               Addr_Node  : constant Node_Index := Node.Right_Child;
               Value_Node : constant Node_Index := (if Addr_Node > 0 then Tree (Addr_Node).Next_Sibling else 0);
            begin
               Line ("ALB_PROCESS_WRITE_SCALAR(" & Expr (Node.Left_Child) & ", " &
                     Expr (Addr_Node) & ", " & Expr (Value_Node) & ");");
            end;

         when AST_Inject_Code_Memory_Stmt | AST_Inject_Code_Stmt =>
            declare
               Payload_Node : constant Node_Index := Node.Right_Child;
               Target_Node  : constant Node_Index := (if Payload_Node > 0 then Tree (Payload_Node).Next_Sibling else 0);
            begin
               if Target_Node > 0 then
                  Line (Statement_Target_Name (Target_Node) & " = 0;");
               end if;
            end;

         when AST_Hijack_Process_Memory_Stmt =>
            declare
               Addr_Node    : constant Node_Index := Node.Right_Child;
               Detour_Node  : constant Node_Index := (if Addr_Node > 0 then Tree (Addr_Node).Next_Sibling else 0);
               Target_Node  : constant Node_Index := (if Detour_Node > 0 then Tree (Detour_Node).Next_Sibling else 0);
            begin
               if Target_Node > 0 then
                  Line (Statement_Target_Name (Target_Node) & " = 0;");
               end if;
            end;

         when AST_Sniff_Network_Stmt =>
            Line ("ALB_PROCESS_SNIFF(" & Expr (Node.Left_Child) & ", " &
                  Statement_Target_Name (Node.Right_Child) & ");");

         when AST_Encrypt_File_Stmt | AST_Decrypt_File_Stmt =>
            declare
               Key_Node  : constant Node_Index := Node.Right_Child;
               Path_Node : constant Node_Index := (if Key_Node > 0 then Tree (Key_Node).Next_Sibling else 0);
            begin
               Line ("ALB_FILE_XOR(" & Expr (Node.Left_Child) & ", " &
                     Expr (Key_Node) & ", " & Expr (Path_Node) & ");");
            end;

         when AST_Print_Stmt =>
            if Node.Left_Child > 0 then
               Line ("ALB_PRINT(" & As_Text_Expr (Node.Left_Child) & ");");
            else
               Line ("ALB_PRINT("""");");
            end if;

         when AST_Locate_Stmt =>
            Line ("ALB_LOCATE(" & Expr (Node.Left_Child) & ", " &
                  Expr (Node.Right_Child) & ");");

         when AST_Print_Str_Stmt =>
            if Node.Left_Child > 0 then
               Line ("ALB_PRINT_RAW(" & As_Text_Expr (Node.Left_Child) & ");");
            else
               Line ("ALB_PRINT_RAW("""");");
            end if;

         when AST_Draw | AST_Fill | AST_Plot | AST_Text =>
            declare
               Args      : array (1 .. 8) of Unbounded_String := (others => U ("0"));
               Count     : Natural := 0;
               Curr      : Node_Index := 0;
               Call_Name : Unbounded_String := U ("");
            begin
               if Node.Left_Child > 0 and then Tree (Node.Left_Child).Kind = AST_Arg_List then
                  Curr := Tree (Node.Left_Child).Left_Child;
                  while Curr > 0 and then Count < 8 loop
                     Count := Count + 1;
                     if Node.Kind = AST_Text and then Count = 3 then
                        Args (Count) := U (As_Text_Expr (Curr));
                     else
                        Args (Count) := U (Expr (Curr));
                     end if;
                     Curr := Tree (Curr).Next_Sibling;
                  end loop;
               end if;

               if Node.Kind = AST_Text then
                  if Count >= 3 then
                     Line ("ALB_DRAW_TEXT(" & To_String (Args (1)) & ", " &
                           To_String (Args (2)) & ", " & To_String (Args (3)) & ");");
                  end if;
               elsif Node.Kind = AST_Plot then
                  if Count >= 2 then
                     Line ("ALB_PLOT(" & To_String (Args (1)) & ", " & To_String (Args (2)) & ");");
                  end if;
               else
                  case Tokens (Node.Token_Index).Kind is
                     when Tok_Rect =>
                        if Node.Kind = AST_Draw then
                           Call_Name := U ("ALB_DRAW_RECT");
                        else
                           Call_Name := U ("ALB_FILL_RECT");
                        end if;
                     when Tok_Line =>
                        Call_Name := U ("ALB_DRAW_LINE");
                     when Tok_Circle =>
                        if Node.Kind = AST_Draw then
                           Call_Name := U ("ALB_DRAW_CIRCLE");
                        else
                           Call_Name := U ("ALB_FILL_CIRCLE");
                        end if;
                     when Tok_Triangle =>
                        if Node.Kind = AST_Draw then
                           Call_Name := U ("ALB_DRAW_TRIANGLE");
                        else
                           Call_Name := U ("ALB_FILL_TRIANGLE");
                        end if;
                     when others =>
                        Call_Name := U ("/* unsupported draw primitive */");
                  end case;

                  if Length (Call_Name) > 0 and then To_String (Call_Name) (To_String (Call_Name)'First) /= '/' then
                     declare
                        Arg_Text : Unbounded_String := U ("");
                        Call_Text : constant String := To_String (Call_Name);
                     begin
                        for I in 1 .. Count loop
                           if I > 1 then
                              Append (Arg_Text, ", ");
                           end if;
                           Append (Arg_Text, To_String (Args (I)));
                        end loop;
                        Line (Call_Text & "(" & To_String (Arg_Text) & ");");
                     end;
                  else
                     Line (To_String (Call_Name));
                  end if;
               end if;
            end;

         when AST_Msg_Box =>
            Line ("ALB_MSG_BOX(" & Expr (Node.Left_Child) &
                  (if Node.Right_Child > 0 then ", " & Expr (Node.Right_Child) else "") &
                  ");");

         when AST_Listen =>
            Saw_Listen := True;

         when AST_Cease =>
            Line ("ALB_CEASE();");

         when AST_Play_Sound =>
            Line ("ALB_PLAY_SOUND(" & Expr (Node.Left_Child) & ");");

         when AST_Play_Music =>
            Line ("ALB_PLAY_MUSIC(" & Expr (Node.Left_Child) & ");");

         when AST_Play_Music_From =>
            Line ("void ALB_PLAY_MUSIC_FROM(" & Expr (Node.Left_Child) & ");");

         when AST_Input_Stmt =>
            --  Coerce the entered text to the target's declared kind —
            --  `INPUT >> s32` must store a number, not "2" (strict ===
            --  comparisons downstream would never match).
            Line (Statement_Target_Name (Node.Right_Child) & " = " &
                  Cast_Expr (Infer_Expr_Kind (Node.Right_Child),
                    "ALB_PROMPT_TEXT(" &
                    (if Node.Left_Child > 0 then Expr (Node.Left_Child) else """""") &
                    ")") & ";");

         when AST_Readline_Stmt =>
            if Node.Left_Child > 0 then
               Line (Statement_Target_Name (Node.Left_Child) & " = " &
                     Cast_Expr (Infer_Expr_Kind (Node.Left_Child),
                       "ALB_READLINE_TEXT()") & ";");
            else
               Line ("ALB_READLINE_TEXT();");
            end if;

         when AST_File_Open =>
            Line ("/* file open expression should be used in LET/assignment context */");

         when AST_File_Close =>
            Line ("ALB_Close(" & Expr (Node.Left_Child) & ");");

         when AST_File_Seek =>
            Line ("ALB_Seek(" & Expr (Node.Left_Child) & ", " &
                  Expr (Node.Right_Child) & ");");

         when AST_File_Read =>
            Line ("ALB_Read(" & Expr (Node.Left_Child) & ", " &
                  Expr (Node.Right_Child) & ");");

         when AST_File_Write =>
            Line ("ALB_Write(" & Expr (Node.Left_Child) & ", " & Expr (Node.Right_Child) & ");");

         when AST_Load_Stmt =>
            declare
               Target_Sym : constant Symbol_Record := Target_Symbol (Node.Right_Child);
            begin
               if Target_Sym.Active
                 and then Target_Sym.Kind in Sym_Strict_Array | Sym_Slide_Array
               then
                  Line ("ALB_LoadBuffer(" & Expr (Node.Left_Child) & ", " &
                        Statement_Target_Name (Node.Right_Child) & ");");
               else
                  Line (Statement_Target_Name (Node.Right_Child) & " = ALB_LoadTextBuffer(" &
                        Expr (Node.Left_Child) & ");");
               end if;
            end;

         when AST_Flush_Stmt =>
            if Tree (Node.Left_Child).Next_Sibling > 0 then
               Line ("ALB_FlushBuffer(" & Statement_Target_Name (Node.Left_Child) &
                     ", " & Expr (Node.Right_Child) & ", " &
                     Expr (Tree (Node.Left_Child).Next_Sibling) & ");");
            else
               Line ("ALB_FlushBuffer(" & Statement_Target_Name (Node.Left_Child) &
                     ", " & Expr (Node.Right_Child) & ");");
            end if;

         when AST_Poke_Stmt =>
            Line ("ALB_POKE(" & Expr (Node.Left_Child) & ", " & Expr (Node.Right_Child) & ");");

         when AST_Save_State =>
            Line ("ALB_SAVE_STATE();");

         when AST_Load_State =>
            Line ("ALB_LOAD_STATE();");

         when AST_Claim_Stmt =>
            declare
               Claim_Var : constant String :=
                 (if Node.Left_Child > 0
                    and then Tree (Node.Left_Child).Token_Index > 0
                  then Raw_Lexeme (Tree (Node.Left_Child).Token_Index)
                  else "");
            begin
               Raw_Name := U (Claim_Var);
               if Claim_Var'Length > 0
                 and then Find_Symbol_Shaped
                            (To_String (Current_Routine), To_String (Raw_Name),
                             Want_Array => False, Strict => True) = 0
                 and then Find_Symbol_Shaped
                            ("", Scoped_Name (To_String (Raw_Name)),
                             Want_Array => False, Strict => True) = 0
               then
                  if Length (Current_Routine) > 0 then
                     Register_Symbol (To_String (Current_Routine), To_String (Raw_Name), Safe_JS_Name (To_String (Raw_Name)), VK_Number, Sym_Scalar);
                     Line ("var " & Safe_JS_Name (To_String (Raw_Name)) & ": number = 0;");
                  else
                     Register_Symbol ("", Scoped_Name (To_String (Raw_Name)), Scoped_Name (To_String (Raw_Name)), VK_Number, Sym_Scalar);
                     Line ("var " & Scoped_Name (To_String (Raw_Name)) & ": number = 0;");
                  end if;
               end if;
               Line (Statement_Target_Name (Node.Left_Child) & " = ALB_CLAIM();");
            end;

         when AST_Bind_Stmt =>
            declare
               Args : Unbounded_String := U ("");
               Curr : Node_Index := 0;
               First : Boolean := True;
            begin
               Append (Args, Expr (Node.Left_Child));
               Curr := Node.Right_Child;
               if Curr > 0 and then Tree (Curr).Kind = AST_Arg_List then
                  Curr := Tree (Curr).Left_Child;
                  while Curr > 0 loop
                     if First then
                        Append (Args, ", ");
                        First := False;
                     else
                        Append (Args, ", ");
                     end if;
                     Append (Args, Expr (Curr));
                     Curr := Tree (Curr).Next_Sibling;
                  end loop;
               end if;
               Line ("ALB_BIND(" & To_String (Args) & ");");
            end;

         when AST_Drop_Stmt =>
            Line ("ALB_DROP(" & Expr (Node.Left_Child) & ");");

         when AST_Sweep_Stmt =>
            Line ("ALB_SWEEP(" & Expr (Node.Left_Child) & ");");

         when AST_Knows_Fact =>
            Line ("ALB_KNOWS_SET(" &
                  Escape_TS_String (Raw_Lexeme (Tree (Node.Left_Child).Token_Index)) &
                  ", " & Expr (Node.Right_Child) & ");");

         when AST_Assert_Stmt =>
            Line
              ("ALB_REL_SET(" &
               Predicate_Id_Expr (Index) & ", " &
               Predicate_Arity_Expr (Index) & ", " &
               Predicate_Arg1_Expr (Index) &
               ", 0, 0, 0, 1);");

         --  Bare fact `p(a).` — same lowering as ASSERT p(a).
         when AST_Fact =>
            Line
              ("ALB_REL_SET(" &
               Predicate_Id_Expr (Node.Left_Child) & ", " &
               Predicate_Arity_Expr (Node.Left_Child) & ", " &
               Predicate_Arg1_Expr (Node.Left_Child) &
               ", 0, 0, 0, 1);");

         when AST_Retract_Stmt =>
            Line
              ("ALB_REL_RETRACT(" &
               Predicate_Id_Expr (Index) & ", " &
               Predicate_Arity_Expr (Index) & ", " &
               Predicate_Arg1_Expr (Index) &
               ", 0, 0, 0);");

         when AST_Update_Stmt =>
            Line ("ALB_REL_SET(" &
                  Predicate_Id_Expr (Node.Left_Child) & ", " &
                  Predicate_Arity_Expr (Node.Left_Child) & ", " &
                  Predicate_Arg1_Expr (Node.Left_Child) &
                  ", 0, 0, 0, " & Expr (Node.Right_Child) & ");");

         when AST_Findall_Query =>
            Line ("ALB_REL_FINDALL1(" &
                  Predicate_Id_Expr (Node.Left_Child) & ", " &
                  Statement_Target_Name (Node.Right_Child) & ");");

         when AST_Knows_Change =>
            Remember_Watch_Node (Index);

         when AST_Rule_Decl | AST_Constraint_Decl =>
            Remember_Rule_Node (Index);

         when AST_Temporal_Block =>
            Emit_Block (Node.Left_Child);

         when AST_Advance_Stmt =>
            declare
               Count_Expr : constant String :=
                 (if Node.Left_Child > 0 then Expr (Node.Left_Child) else "1");
            begin
               for I in 1 .. Symbol_Count loop
                  if Symbols (I).Active and then Symbols (I).Kind = Sym_Temporal then
                     Line ("for (let __adv = 0; __adv < (" & Count_Expr & "); __adv += 1) {");
                     Indent_Level := Indent_Level + 1;
                     --  FASM order: record current at [head], THEN step.
                     Line (To_String (Symbols (I).JS_Name) & "_history[" &
                           To_String (Symbols (I).JS_Name) & "_head] = " &
                           To_String (Symbols (I).JS_Name) & " as never;");
                     Line (To_String (Symbols (I).JS_Name) & "_head = (" &
                           To_String (Symbols (I).JS_Name) & "_head + 1) % " &
                           Trim_Image (Symbols (I).History_Size) & ";");
                     Indent_Level := Indent_Level - 1;
                     Line ("}");
                  end if;
               end loop;
            end;

         when AST_Set_Alpha =>
            if Node.Left_Child > 0 and then Tree (Node.Left_Child).Kind = AST_Arg_List then
               declare
                  Curr : Node_Index := Tree (Node.Left_Child).Left_Child;
                  A1   : constant String := (if Curr > 0 then Expr (Curr) else "0");
                  A2   : Unbounded_String := U ("255");
               begin
                  if Curr > 0 then
                     Curr := Tree (Curr).Next_Sibling;
                  end if;
                  if Curr > 0 then
                     A2 := U (Expr (Curr));
                  end if;
                  Line ("ALB_SET_ALPHA(" & A1 & ", " & To_String (A2) & ");");
               end;
            end if;

         when AST_Set_Clip =>
            declare
               Curr : Node_Index := Tree (Node.Left_Child).Left_Child;
               A1, A2, A3, A4 : Unbounded_String := U ("0");
            begin
               if Curr > 0 then A1 := U (Expr (Curr)); Curr := Tree (Curr).Next_Sibling; end if;
               if Curr > 0 then A2 := U (Expr (Curr)); Curr := Tree (Curr).Next_Sibling; end if;
               if Curr > 0 then A3 := U (Expr (Curr)); Curr := Tree (Curr).Next_Sibling; end if;
               if Curr > 0 then A4 := U (Expr (Curr)); end if;
               Line ("ALB_SET_CLIP(" & To_String (A1) & ", " & To_String (A2) & ", " & To_String (A3) & ", " & To_String (A4) & ");");
            end;

         when AST_Set_Origin =>
            declare
               Curr : Node_Index := Tree (Node.Left_Child).Left_Child;
               A1, A2 : Unbounded_String := U ("0");
            begin
               if Curr > 0 then A1 := U (Expr (Curr)); Curr := Tree (Curr).Next_Sibling; end if;
               if Curr > 0 then A2 := U (Expr (Curr)); end if;
               Line ("ALB_SET_ORIGIN(" & To_String (A1) & ", " & To_String (A2) & ");");
            end;

         when AST_Delay_Stmt =>
            Line ("ALB_Delay(" & Expr (Node.Left_Child) & ");");

         when AST_Try_Stmt =>
            Line ("try {");
            Indent_Level := Indent_Level + 1;
            Emit_Block (Node.Left_Child);
            Indent_Level := Indent_Level - 1;
            if Node.Right_Child > 0 then
               Line ("} catch (__alb_err) {");
               Indent_Level := Indent_Level + 1;
               declare
                  Catch_Name : constant String :=
                    (if Node.Token_Index > 0 then Raw_Lexeme (Node.Token_Index) else "");
                  Catch_JS   : constant String := Safe_JS_Name (Catch_Name);
                  Catch_Id   : Natural := 0;
               begin
                  if Catch_Name'Length > 0 then
                     Line ("const " & Catch_JS &
                           ": string = String((__alb_err instanceof Error) ? __alb_err.message : __alb_err);");
                     Catch_Id :=
                       Push_Shadow_Symbol
                         (Scope   => To_String (Current_Routine),
                          Name    => Catch_Name,
                          JS_Name => Catch_JS,
                          Tag     => VK_String);
                  end if;
                  Emit_Block (Node.Right_Child);
                  Pop_Shadow_Symbol (Catch_Id);
               end;
               Indent_Level := Indent_Level - 1;
               Line ("}");
            else
               Line ("} catch (_e) {}");
            end if;

         when AST_Throw_Stmt =>
            Line ("throw new Error(" & Expr (Node.Left_Child) & ");");

         when AST_Runtime_Assert =>
            Line ("if (!Boolean(" & Expr (Node.Left_Child) &
                  ")) { ALB_FATAL('runtime assert failed'); }");

         when AST_Reversible_Block =>
            --  FASM parity: REVERSIBLE blocks may only contain
            --  reversible ops (or nested REVERSIBLE blocks).
            declare
               Stmt_Idx : Node_Index :=
                 (if Node.Left_Child > 0
                  then Tree (Node.Left_Child).Left_Child else 0);
            begin
               while Stmt_Idx > 0 loop
                  if Tree (Stmt_Idx).Kind not in
                    AST_Rev_Add_Stmt | AST_Rev_Sub_Stmt |
                    AST_Rev_Xor_Stmt | AST_Rev_Rol_Stmt |
                    AST_Rev_Ror_Stmt | AST_Rev_Swap_Stmt |
                    AST_Rev_Not_Stmt | AST_Rev_Neg_Stmt |
                    AST_Reversible_Block
                  then
                     raise Program_Error with
                       "REVERSIBLE block may only contain reversible " &
                       "ops (got " &
                       Node_Kind'Image (Tree (Stmt_Idx).Kind) & ")";
                  end if;
                  Stmt_Idx := Tree (Stmt_Idx).Next_Sibling;
               end loop;
               Reversible_Depth := Reversible_Depth + 1;
               Emit_Block (Node.Left_Child);
               Reversible_Depth := Reversible_Depth - 1;
            end;

         when AST_Atomic_Block =>
            Emit_Block (Node.Left_Child);

         when AST_Rev_Add_Stmt | AST_Rev_Sub_Stmt | AST_Rev_Xor_Stmt |
              AST_Rev_Rol_Stmt | AST_Rev_Ror_Stmt | AST_Rev_Swap_Stmt |
              AST_Rev_Not_Stmt | AST_Rev_Neg_Stmt =>
            --  FASM parity: reversible ops require REVERSIBLE context.
            if Reversible_Depth = 0 then
               raise Program_Error with
                 Node_Kind'Image (Node.Kind) &
                 " requires a REVERSIBLE block";
            end if;
            case Node.Kind is
               when AST_Rev_Add_Stmt =>
                  Line (Statement_Target_Name (Node.Left_Child) & " += " & Expr (Node.Right_Child) & ";");
               when AST_Rev_Sub_Stmt =>
                  Line (Statement_Target_Name (Node.Left_Child) & " -= " & Expr (Node.Right_Child) & ";");
               when AST_Rev_Xor_Stmt =>
                  Line (Statement_Target_Name (Node.Left_Child) & " ^= " & Expr (Node.Right_Child) & ";");
               when AST_Rev_Rol_Stmt =>
                  Line (Statement_Target_Name (Node.Left_Child) & " = (" & Statement_Target_Name (Node.Left_Child) &
                        " << " & Expr (Node.Right_Child) & ") | (" & Statement_Target_Name (Node.Left_Child) &
                        " >>> (32 - (" & Expr (Node.Right_Child) & ")));");
               when AST_Rev_Ror_Stmt =>
                  Line (Statement_Target_Name (Node.Left_Child) & " = (" & Statement_Target_Name (Node.Left_Child) &
                        " >>> " & Expr (Node.Right_Child) & ") | (" & Statement_Target_Name (Node.Left_Child) &
                        " << (32 - (" & Expr (Node.Right_Child) & ")));");
               when AST_Rev_Swap_Stmt =>
                  Line ("{ const __tmp = " & Statement_Target_Name (Node.Left_Child) & "; " &
                        Statement_Target_Name (Node.Left_Child) & " = " & Statement_Target_Name (Node.Right_Child) &
                        "; " & Statement_Target_Name (Node.Right_Child) & " = __tmp; }");
               when AST_Rev_Not_Stmt =>
                  Line (Statement_Target_Name (Node.Left_Child) & " = ~" & Statement_Target_Name (Node.Left_Child) & ";");
               when AST_Rev_Neg_Stmt =>
                  Line (Statement_Target_Name (Node.Left_Child) & " = -" & Statement_Target_Name (Node.Left_Child) & ";");
               when others =>
                  null;
            end case;

         when AST_Spawn_Stmt =>
            --  SPAWN is synchronous (same as the FASM backend): emit the
            --  routine call directly. Left = callee node, Right = args.
            if Node.Left_Child > 0 then
               declare
                  SN : constant AST_Node := Tree (Node.Left_Child);
               begin
                  if SN.Kind = AST_Member_Expr then
                     Line (Expr (Node.Left_Child) & "(" &
                       Join_Arg_List (Node.Right_Child) & ");");
                  elsif SN.Token_Index > 0 then
                     declare
                        Callee : constant String :=
                          Resolve_Routine_Name (Raw_Lexeme (SN.Token_Index));
                     begin
                        if Callee'Length > 0 then
                           Line (Callee & "(" &
                             Join_Arg_List (Node.Right_Child) & ");");
                        else
                           Line (Expr (Node.Left_Child) & "(" &
                             Join_Arg_List (Node.Right_Child) & ");");
                        end if;
                     end;
                  else
                     Line (Expr (Node.Left_Child) & "(" &
                       Join_Arg_List (Node.Right_Child) & ");");
                  end if;
               end;
            end if;
         when AST_Sync_Stmt =>
            null;

         when AST_BinOp =>
            Line (Expr (Index) & ";");

         when AST_Enable_Typescript_Block =>
            Line (Enable_Inner_Text (Node.Token_Index));

         --  BRAILLE / NEMETH raw blocks lower to a transcription call
         --  on a compile-time static string literal.  No assignment or
         --  implicit print — the engine state is read back through
         --  Ueb.ToUni/ToBrf/Cell (or Nemeth.*), which the driver
         --  auto-imports when it sees a block.  `BRAILLE G1` selects
         --  the uncontracted grade; `AS name` snapshots the transcript
         --  into name_* bindings.
         when AST_Braille_Block =>
            declare
               G1    : Boolean;
               Ver   : Boolean;
               Cap   : Unbounded_String;
               OPath : Unbounded_String;
            begin
               Block_Opener_Flags (Node.Token_Index, G1, Ver, Cap, OPath);
               if G1 then
                  Line ("Ueb_TranscribeG1(" &
                        Escape_TS_String
                          (Block_Inner_Text (Node.Token_Index)) & ");");
               else
                  Line ("Ueb_Transcribe(" &
                        Escape_TS_String
                          (Block_Inner_Text (Node.Token_Index)) & ");");
               end if;
               if Ver then
                  Line ("if (Ueb_ErrCount() > 0) ALB_FATAL(" &
                        "'BRAILLE VERIFY: ' + Ueb_ErrCount() + " &
                        "' transcription error(s); first: ' + " &
                        "Ueb_ErrText(0));");
               end if;
               Emit_Block_Capture
                 (To_String (Cap), "Ueb", "Ueb_ucell", "Ueb_ubrfa",
                  "braille", "");
               if Length (OPath) > 0 then
                  Line ("ALB_FlushBuffer(Ueb_ToBrf(), " &
                        Escape_TS_String (To_String (OPath)) & ");");
               end if;
            end;

         when AST_Nemeth_Block =>
            declare
               G1    : Boolean;   --  unused; kept for the shared parser
               Ver   : Boolean;
               Cap   : Unbounded_String;
               OPath : Unbounded_String;
            begin
               Block_Opener_Flags (Node.Token_Index, G1, Ver, Cap, OPath);
               Line ("Nemeth_Transcribe(" &
                     Escape_TS_String
                       (Block_Inner_Text (Node.Token_Index)) & ");");
               if Ver then
                  Line ("if (Nemeth_ErrCount() > 0) ALB_FATAL(" &
                        "'NEMETH VERIFY: ' + Nemeth_ErrCount() + " &
                        "' transcription error(s); first: ' + " &
                        "Nemeth_ErrText(0));");
               end if;
               Emit_Block_Capture
                 (To_String (Cap), "Nemeth", "Nemeth_ncell",
                  "Nemeth_brfa", "nemeth",
                  Escape_TS_String
                    (Block_Inner_Text (Node.Token_Index)));
               if Length (OPath) > 0 then
                  Line ("ALB_FlushBuffer(Nemeth_ToBrf(), " &
                        Escape_TS_String (To_String (OPath)) & ");");
               end if;
            end;

         --  `PREDICATE name(args)` — closed-world contract: registers
         --  the name + arg count; every later reference to this pred is
         --  compile-time checked at the Predicate_Id_Expr choke point.
         when AST_Predicate_Decl =>
            declare
               Pred_Name : constant String :=
                 Predicate_Name_From_Node (Node.Left_Child);
               Pred_Arty : constant Natural :=
                 Predicate_Arg_Count (Node.Left_Child);
            begin
               if Pred_Name'Length = 0 then
                  raise Program_Error with
                    "PREDICATE declaration needs a name";
               end if;
               if Find_Declared_Pred (Pred_Name) /= 0 then
                  raise Program_Error with
                    "PREDICATE '" & Pred_Name & "' declared twice";
               end if;
               if Declared_Pred_Count >= Max_Declared_Preds then
                  raise Program_Error with "too many PREDICATE declarations";
               end if;
               Declared_Pred_Count := Declared_Pred_Count + 1;
               Declared_Pred_Names (Declared_Pred_Count) := U (Pred_Name);
               Declared_Pred_Arity (Declared_Pred_Count) := Pred_Arty;
               declare
                  Dead_Id : constant Natural :=
                    Ensure_Predicate_Id (Pred_Name);
               begin
                  pragma Unreferenced (Dead_Id);
               end;
            end;

         --  Cut `!` outside a rule body has no meaning — the parser only
         --  produces it at statement level; Horn-clause nodes are never
         --  allocated. Fail loud rather than silently skip.
         when AST_Cut_Stmt | AST_Horn_Clause =>
            raise Program_Error with
              "DATALOG '" & Node_Kind'Image (Node.Kind) &
              "' is only meaningful inside a RULE/CONSTRAINT body";

         when AST_Enable_Ada_Block | AST_Enable_Java_Block | AST_Enable_Asm | AST_Disable_Asm | AST_Asm_Block | AST_Case_Stmt | AST_Predicate | AST_Logic_Var | AST_Inline_Asm_Expr | AST_Inline_Ada_Expr | AST_Inline_Java_Expr | AST_Read_Pixel | AST_Array_Assign | AST_Array_Access | AST_Simd_Intrinsic | AST_Str_Concat | AST_Param_Decl | AST_Require_Clause | AST_Ensure_Clause | AST_String_Decl | AST_Bitfield_Decl | AST_SYS_RENDERER | AST_Atom =>
            Line ("/* unsupported or backend-specific node: " & Node_Kind'Image (Node.Kind) & " */");

         when others =>
            Line ("/* TODO node: " & Node_Kind'Image (Node.Kind) & " */");
      end case;
   end Emit_Node;

   --  --rt-trim flush:  Emit_Runtime's line range ([Rt_Start, Rt_End))
   --  is split into declaration units; a unit is kept iff its name
   --  appears (identifier boundary) anywhere in the rest of the
   --  output or inside another kept unit.  Non-decl lines attach to
   --  the preceding unit (multi-line functions close correctly);
   --  lines before the first unit (header, 'use strict') always
   --  emit.  Failure mode is over-inclusion only — a helper whose
   --  name shows up inside a string literal is kept, never dropped.
   procedure Flush_Output is
      Max_Units : constant := 4096;
      Unit_First   : array (1 .. Max_Units) of Natural := (others => 0);
      Unit_Last    : array (1 .. Max_Units) of Natural := (others => 0);
      Unit_Used    : array (1 .. Max_Units) of Boolean := (others => False);
      Unit_Always  : array (1 .. Max_Units) of Boolean := (others => False);
      Unit_Scanned : array (1 .. Max_Units) of Boolean := (others => False);
      Unit_Name    : array (1 .. Max_Units) of Unbounded_String;
      Unit_N       : Natural := 0;
      First_Unit_Line : Natural := 0;
      Marked_New   : Boolean := False;
      Changed      : Boolean := True;
      Iter         : Natural := 0;

      function Is_Ident_Char (C : Character) return Boolean is
      begin
         return (C >= 'a' and then C <= 'z')
           or else (C >= 'A' and then C <= 'Z')
           or else (C >= '0' and then C <= '9')
           or else C = '_' or else C = '$';
      end Is_Ident_Char;

      function Match_Kw
        (S        : String;
         Kw       : String;
         Name_Out : out Unbounded_String) return Boolean
      is
         P  : Natural;
         St : Natural;
      begin
         Name_Out := To_Unbounded_String ("");
         if S'Length <= Kw'Length + 1 then
            return False;
         end if;
         if S (S'First .. S'First + Kw'Length - 1) /= Kw then
            return False;
         end if;
         P := S'First + Kw'Length;
         while P <= S'Last and then S (P) = ' ' loop
            P := P + 1;
         end loop;
         St := P;
         while P <= S'Last and then Is_Ident_Char (S (P)) loop
            P := P + 1;
         end loop;
         if P > St then
            Name_Out := To_Unbounded_String (S (St .. P - 1));
            return True;
         end if;
         return False;
      end Match_Kw;

      --  A unit starts at column 0 with a decl keyword.  type/
      --  interface/enum/class/export lines are kept unconditionally.
      procedure Unit_Start_Info
        (S        : in String;
         Is_Start : out Boolean;
         Is_Alw   : out Boolean;
         Name     : out Unbounded_String)
      is
      begin
         Is_Start := False;
         Is_Alw := False;
         Name := To_Unbounded_String ("");
         if S'Length = 0 or else S (S'First) = ' ' or else S (S'First) = ASCII.HT then
            return;
         end if;
         if S'Length > 6 and then S (S'First .. S'First + 5) = "async " then
            if Match_Kw (S (S'First + 6 .. S'Last), "function ", Name) then
               Is_Start := True;
            end if;
            return;
         end if;
         if Match_Kw (S, "function ", Name)
           or else Match_Kw (S, "const ", Name)
           or else Match_Kw (S, "let ", Name)
           or else Match_Kw (S, "var ", Name)
         then
            Is_Start := True;
            return;
         end if;
         if Match_Kw (S, "type ", Name)
           or else Match_Kw (S, "interface ", Name)
           or else Match_Kw (S, "enum ", Name)
           or else Match_Kw (S, "class ", Name)
         then
            Is_Start := True;
            Is_Alw := True;
            return;
         end if;
         if S'Length > 7 and then S (S'First .. S'First + 6) = "export " then
            Is_Start := True;
            Is_Alw := True;
         end if;
      end Unit_Start_Info;

      --  Mark every unit whose declared name appears as an
      --  identifier run in S.
      procedure Scan_For_Units (S : String) is
         P  : Natural := S'First;
         St : Natural;
         Found : Boolean;
      begin
         while P <= S'Last loop
            if Is_Ident_Char (S (P)) then
               St := P;
               while P <= S'Last and then Is_Ident_Char (S (P)) loop
                  P := P + 1;
               end loop;
               for U in 1 .. Unit_N loop
                  Found := False;
                  if not Unit_Always (U)
                    and then not Unit_Used (U)
                    and then Natural (Length (Unit_Name (U))) = P - St
                    and then To_String (Unit_Name (U)) = S (St .. P - 1)
                  then
                     Unit_Used (U) := True;
                     Marked_New := True;
                     Found := True;
                  end if;
                  exit when Found;
               end loop;
            else
               P := P + 1;
            end if;
         end loop;
      end Scan_For_Units;

      Is_Start : Boolean;
      Is_Alw   : Boolean;
      UName    : Unbounded_String;
      Prev_U   : Natural := 0;
   begin
      if not Rt_Trim_Enabled or else Rt_End <= Rt_Start + 1 then
         for L in 1 .. Out_Line_N loop
            Ada.Text_IO.Put_Line (Out_File, To_String (Out_Lines (L)));
         end loop;
         if Length (Out_Cur) > 0 then
            Ada.Text_IO.Put (Out_File, To_String (Out_Cur));
         end if;
         return;
      end if;

      --  split the runtime region into decl units
      for L in Rt_Start .. Rt_End - 1 loop
         Unit_Start_Info (To_String (Out_Lines (L)), Is_Start, Is_Alw, UName);
         if Is_Start then
            if Unit_N >= Max_Units then
               raise Program_Error with "runtime unit table full";
            end if;
            Unit_N := Unit_N + 1;
            Unit_First (Unit_N) := L;
            Unit_Last (Unit_N) := L;
            Unit_Name (Unit_N) := UName;
            Unit_Always (Unit_N) := Is_Alw;
            Prev_U := Unit_N;
         elsif Prev_U > 0 then
            Unit_Last (Prev_U) := L;
         end if;
      end loop;
      First_Unit_Line := (if Unit_N > 0 then Unit_First (1) else Rt_End);

      --  seed: program text + --rt-keep names
      for L in 1 .. Rt_Start - 1 loop
         Scan_For_Units (To_String (Out_Lines (L)));
      end loop;
      for L in Rt_End .. Out_Line_N loop
         Scan_For_Units (To_String (Out_Lines (L)));
      end loop;
      if Length (Out_Cur) > 0 then
         Scan_For_Units (To_String (Out_Cur));
      end if;
      for K in 1 .. Rt_Keep_N loop
         for U in 1 .. Unit_N loop
            if Unit_Name (U) = Rt_Keep (K) then
               Unit_Used (U) := True;
            end if;
         end loop;
      end loop;

      --  fixpoint: kept units pull in the helpers they reference
      while Changed and then Iter < 64 loop
         Changed := False;
         Iter := Iter + 1;
         for U in 1 .. Unit_N loop
            if (Unit_Used (U) or else Unit_Always (U))
              and then not Unit_Scanned (U)
            then
               Unit_Scanned (U) := True;
               Marked_New := False;
               for L in Unit_First (U) .. Unit_Last (U) loop
                  Scan_For_Units (To_String (Out_Lines (L)));
               end loop;
               if Marked_New then
                  Changed := True;
               end if;
            end if;
         end loop;
      end loop;

      --  emit: program head + always-lines + kept units + program tail
      for L in 1 .. Rt_Start - 1 loop
         Ada.Text_IO.Put_Line (Out_File, To_String (Out_Lines (L)));
      end loop;
      for L in Rt_Start .. First_Unit_Line - 1 loop
         Ada.Text_IO.Put_Line (Out_File, To_String (Out_Lines (L)));
      end loop;
      for U in 1 .. Unit_N loop
         if Unit_Used (U) or else Unit_Always (U) then
            for L in Unit_First (U) .. Unit_Last (U) loop
               Ada.Text_IO.Put_Line (Out_File, To_String (Out_Lines (L)));
            end loop;
         end if;
      end loop;
      for L in Rt_End .. Out_Line_N loop
         Ada.Text_IO.Put_Line (Out_File, To_String (Out_Lines (L)));
      end loop;
      if Length (Out_Cur) > 0 then
         Ada.Text_IO.Put (Out_File, To_String (Out_Cur));
      end if;
   end Flush_Output;

   procedure Compile_To_File
     (Root            : in AST_Node;
      Output_Filename : in String) is
      function Find_Node_Index (Wanted : AST_Node) return Node_Index is
      begin
         for I in Tree'Range loop
            if Tree (I).Kind = Wanted.Kind
              and then Tree (I).Token_Index = Wanted.Token_Index
              and then Tree (I).Left_Child = Wanted.Left_Child
              and then Tree (I).Right_Child = Wanted.Right_Child
              and then Tree (I).Next_Sibling = Wanted.Next_Sibling
            then
               return I;
            end if;
         end loop;
         return 0;
      end Find_Node_Index;

      procedure Emit_Top_Level (First : Node_Index) is
         Curr : Node_Index := First;
      begin
         while Curr > 0 loop
            Emit_Node (Curr);
            Curr := Tree (Curr).Next_Sibling;
         end loop;
      end Emit_Top_Level;

      procedure Emit_Top_Level_Range
        (First       : Node_Index;
         Stop_Before : Node_Index)
      is
         Curr : Node_Index := First;
      begin
         while Curr > 0 loop
            exit when Stop_Before /= 0 and then Curr = Stop_Before;
            Emit_Node (Curr);
            Curr := Tree (Curr).Next_Sibling;
         end loop;
      end Emit_Top_Level_Range;

      function Statement_List_First (Idx : Node_Index) return Node_Index is
      begin
         if Idx > 0
           and then (Tree (Idx).Kind = AST_Program
                     or else Tree (Idx).Kind = AST_Block_Stmt)
         then
            return Tree (Idx).Left_Child;
         end if;
         return Idx;
      end Statement_List_First;

      function Find_Listen_Stmt (First : Node_Index) return Node_Index is
         Curr : Node_Index := First;
      begin
         while Curr > 0 loop
            if Tree (Curr).Kind = AST_Listen then
               return Curr;
            end if;
            Curr := Tree (Curr).Next_Sibling;
         end loop;
         return 0;
      end Find_Listen_Stmt;

      Root_Index : constant Node_Index := Find_Node_Index (Root);
      Stmt_First : Node_Index := 0;
      Listen_Idx : Node_Index := 0;
   begin
      Reset_State;
      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Output_Filename);
      File_Open := True;

      if Root_Index > 0 then
         Current_Module := U ("");
         Scan_Features (Root_Index);
         Flush_Mcp_Registrations;
         Current_Module := U ("");
      end if;

      Emit_Module_Imports;
      Emit_Runtime;
      --  Rule tables and KNOWS_CHANGE watches must be live before
      --  top-level code executes; both functions emit post-traversal
      --  (JS hoists decls, so early wiring is safe).
      Line ("if (typeof ALB_INIT_LOGIC === 'function') ALB_INIT_LOGIC();");
      Line ("if (typeof ALB_WATCH_DISPATCH === 'function') ALB_NOTIFY_KNOWS_CHANGE = ALB_WATCH_DISPATCH;");
      if Root_Index > 0 then
         Stmt_First := Statement_List_First (Root_Index);
         Listen_Idx := Find_Listen_Stmt (Stmt_First);
         Emit_Top_Level_Range (Stmt_First, Listen_Idx);
      elsif Root.Kind /= AST_Null then
         Line ("/* ALBW warning: could not recover top-level root index for " &
               Node_Kind'Image (Root.Kind) & " */");
      end if;

      Emit_Address_Routines;
      Emit_State_Routines;
      Emit_Logic_Setup;
      Emit_Event_Handler ("ALB_ON_TICK", Tick_Blocks, Tick_Block_Count);
      Emit_Event_Handler ("ALB_ON_PAINT", Paint_Blocks, Paint_Block_Count);
      Emit_Event_Handler ("ALB_ON_KEY", Key_Blocks, Key_Block_Count);
      Emit_Module_Exports;
      Emit_Foreign_Loaders;

      New_Line_Emit;
      Line ("function ALB_ProgramShutdown(): void {");
      Indent_Level := Indent_Level + 1;
      Line ("if (albShutdownDone) return;");
      Line ("albShutdownDone = true;");
      if Listen_Idx > 0 then
         Emit_Top_Level_Range (Tree (Listen_Idx).Next_Sibling, 0);
      end if;
      Indent_Level := Indent_Level - 1;
      Line ("}");

      if Saw_Create or else Saw_Listen or else Tick_Block_Count > 0 or else Paint_Block_Count > 0 or else Key_Block_Count > 0 then
         New_Line_Emit;
         if Need_Wasm_Loaders then
            Line ("void Promise.all(albWasmLoaders).then(() => {");
            Indent_Level := Indent_Level + 1;
            Line ("ALB_PREPARE_FRAME();");
            Line ("requestAnimationFrame(ALB_RunFrame);");
            Indent_Level := Indent_Level - 1;
            Line ("}).catch((err) => ALB_FATAL(err));");
         else
            Line ("ALB_PREPARE_FRAME();");
            Line ("requestAnimationFrame(ALB_RunFrame);");
         end if;
      elsif Need_Wasm_Loaders then
         New_Line_Emit;
         Line ("void Promise.all(albWasmLoaders).catch((err) => ALB_FATAL(err));");
      end if;

      --  Hoisted LAMBDA bodies last — function decls hoist in JS, and
      --  top-level placement enforces the globals+params-only rule.
      Flush_Lambda_Decls;

      Flush_Output;
      Ada.Text_IO.Close (Out_File);
      File_Open := False;
   exception
      when others =>
         if File_Open then
            begin
               Ada.Text_IO.Close (Out_File);
            exception
               when others =>
                  null;
            end;
         end if;
         raise;
   end Compile_To_File;

   procedure Set_No_Console_Overlay (Enabled : in Boolean) is
   begin
      No_Console_Overlay := Enabled;
   end Set_No_Console_Overlay;

   procedure Set_Rt_Trim (Enabled : in Boolean) is
   begin
      Rt_Trim_Enabled := Enabled;
   end Set_Rt_Trim;

   procedure Add_Rt_Keep (Name : in String) is
   begin
      if Rt_Keep_N < Max_Rt_Keep then
         Rt_Keep_N := Rt_Keep_N + 1;
         Rt_Keep (Rt_Keep_N) := To_Unbounded_String (Name);
      end if;
   end Add_Rt_Keep;

   procedure Clear_Rt_Keep is
   begin
      Rt_Keep_N := 0;
   end Clear_Rt_Keep;

end Emit_Native_TypeScript;

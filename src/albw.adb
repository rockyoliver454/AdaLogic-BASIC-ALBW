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

with Ada.Command_Line;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Streams.Stream_IO;
with Ada.Text_IO; use Ada.Text_IO;
with Ada.Text_IO.Text_Streams;

with Alb_Platform;
with Compiler_State; use Compiler_State;
with ALB_Oracle;     use ALB_Oracle;
with ALB_JSON;
with Tokenizer;      use Tokenizer;
with Parser;         use Parser;
with AST;            use AST;
with Emit_Native_TypeScript;
with Code_Information;
with GNAT.OS_Lib;    use GNAT.OS_Lib;

procedure ALBW is

   Max_Path_Len   : constant := 512;
   Max_Includes   : constant := 2048;
   Max_Input_Size : constant := Input_Buffer'Length;
   Max_Stage_Assets : constant := 256;

   Input_Len     : Natural := 0;
   Token_Count   : Natural := 0;
   Root          : Node_Index := 0;
   Parse_Success : Boolean := False;

   Lex_Diag   : Lexer_Diagnostic;
   Parse_Diag : Parser_Diagnostic;

   Include_Vault : array (1 .. Max_Includes) of String (1 .. Max_Path_Len) :=
     (others => (others => ' '));
   Include_Lens  : array (1 .. Max_Includes) of Natural := (others => 0);
   Include_Count : Natural := 0;

   --  BRAILLE / NEMETH raw blocks: weave-time detection.  Flush_Line
   --  sets the *_Block_Seen flags on any lone keyword line so a block
   --  hiding inside an included file still fails loudly when the
   --  engine was never woven.  *_Engine_Woven tracks ueb.albi /
   --  nemeth.albi includes by resolved-path basename.
   Braille_Block_Seen  : Boolean := False;
   Nemeth_Block_Seen   : Boolean := False;
   Ueb_Engine_Woven    : Boolean := False;
   Nemeth_Engine_Woven : Boolean := False;
   Stage_Assets  : array (1 .. Max_Stage_Assets) of String (1 .. Max_Path_Len) :=
     (others => (others => ' '));
   Stage_Asset_Lens : array (1 .. Max_Stage_Assets) of Natural := (others => 0);
   Stage_Asset_Count : Natural := 0;
   Module_Aware_Output : Boolean := False;
   Exit_Failed         : Boolean := False;

   Quiet_Mode     : Boolean := False;
   Metrics_Mode   : Boolean := False;
   Walker_Mode    : Boolean := False;
   TSC_Mode       : Boolean := False;
   Build_Mode     : Boolean := False;
   Library_Mode   : Boolean := False;
   MCP_Mode       : Boolean := False;
   Rt_Trim_Mode   : Boolean := True;
   Max_Rt_Keep_Args : constant := 128;
   Rt_Keep_Args   : array (1 .. Max_Rt_Keep_Args) of
     Ada.Strings.Unbounded.Unbounded_String;
   Rt_Keep_Arg_N  : Natural := 0;
   TS_Target      : String (1 .. 16) := (others => ' ');
   TS_Target_Len  : Natural := 0;
   Out_Dir        : String (1 .. Max_Path_Len) := (others => ' ');
   Out_Dir_Len    : Natural := 0;

   Source_File    : String (1 .. Max_Path_Len) := (others => ' ');
   Source_Len     : Natural := 0;
   Output_File    : String (1 .. Max_Path_Len) := (others => ' ');
   Output_Len     : Natural := 0;

   type Arg_List is array (Positive range <>) of String_Access;

   procedure Free (Args : in out Arg_List) is
   begin
      for I in Args'Range loop
         Free (Args (I));
      end loop;
   end Free;

   function To_Upper (Ch : Character) return Character is
   begin
      if Ch in 'a' .. 'z' then
         return Character'Val (Character'Pos (Ch) - 32);
      end if;
      return Ch;
   end To_Upper;

   function Trim_Image (N : Integer) return String is
      S : constant String := Integer'Image (N);
      F : Positive := S'First;
   begin
      while F < S'Last and then S (F) = ' ' loop
         F := F + 1;
      end loop;
      return S (F .. S'Last);
   end Trim_Image;

   function Oracle_Text (Code : Oracle_Code) return String is
   begin
      case Code is
         when Err_None                       => return "no error";
         when Err_Lex_Unclosed_String        => return "unclosed string literal";
         when Err_Lex_Invalid_Hex            => return "invalid hex literal";
         when Err_Lex_Invalid_Bin            => return "invalid binary literal";
         when Err_Lex_Rogue_Symbol           => return "unrecognized symbol";
         when Err_Lex_Bad_Interp             => return "bad string interpolation";
         when Err_Parse_Missing_Then         => return "expected THEN";
         when Err_Parse_Missing_Until        => return "expected UNTIL";
         when Err_Parse_Missing_To           => return "expected TO";
         when Err_Parse_Missing_Assign       => return "expected '='";
         when Err_Parse_Missing_Type_Name    => return "expected type name";
         when Err_Parse_Missing_Bracket      => return "missing bracket/paren";
         when Err_Parse_Block_Overflow       => return "block too large";
         when Err_Parse_Expected_Value       => return "expected a value or statement";
         when Err_Parse_Reserved_Keyword     => return "reserved keyword used as an identifier or called without parens";
         when Err_Parse_Expected_Type        => return "expected a type";
         when Err_Parse_Expected_Var         => return "expected a variable name";
         when Err_Parse_Expected_Block_End   => return "expected block terminator";
         when Err_Parse_Rogue_Syntax         => return "unrecognized syntax";
         when Err_Parse_Misplaced_Decl       => return "misplaced declaration";
         when Err_Type_Conflict              => return "type conflict";
         when Err_Symbol_Redeclared          => return "symbol redeclared";
         when Err_Mem_Out_Of_Bounds          => return "memory out of bounds";
         when Err_Sandbox_Violation          => return "sandbox violation";
         when Err_Call_Stack_Overflow        => return "call stack overflow";
         when Err_Proc_Not_Found             => return "procedure not found";
         when Err_Runtime_IO_Failure         => return "runtime I/O failure";
         when Err_Runtime_Invalid_Handle     => return "invalid handle";
         when Err_Runtime_Unsupported        => return "unsupported at runtime";
         when Err_Emit_Symbol_Not_Found      => return "emit: symbol not found";
         when Err_Emit_Invalid_Type_Cast     => return "emit: invalid type cast";
         when Err_Emit_Struct_Field_Missing  => return "emit: struct field missing";
         when Err_Emit_Win32_ABI_Mismatch    => return "emit: Win32 ABI mismatch";
         when Err_Compiler_AST_Mismatch      => return "compiler: AST mismatch";
      end case;
   end Oracle_Text;

    function Safe_Identifier (Name : String) return String is
       Result : String (1 .. Name'Length) := Name;
    begin
       for I in Result'Range loop
          if Result (I) = '.' then
             Result (I) := '_';
          end if;
       end loop;
       return Result;
    end Safe_Identifier;

    function Parent_Directory (Path : String) return String is
    begin
       for I in reverse Path'Range loop
          if Path (I) = '\' or else Path (I) = '/' then
             return Path (Path'First .. I);
          end if;
       end loop;
       return "";
    end Parent_Directory;

    function Base_Name (Path : String) return String is
    begin
       if Path'Length = 0 then
          return "output";
       end if;
       declare
          Raw  : constant String := Ada.Directories.Base_Name (Path);
          Dot  : Natural := 0;
       begin
          for I in reverse Raw'Range loop
             exit when Raw (I) = '\' or else Raw (I) = '/';
             if Raw (I) = '.' then
                Dot := I;
                exit;
             end if;
          end loop;
          if Dot > Raw'First then
             return Raw (Raw'First .. Dot - 1);
          end if;
          return Raw;
       end;
    exception
       when others =>
          return "output";
    end Base_Name;

   function Default_Output_Name (Input : String) return String is
   begin
      return Base_Name (Input) & ".ts";
   end Default_Output_Name;

   function Default_Out_Dir (Input : String) return String is
   begin
      return "web_" & Base_Name (Input);
   end Default_Out_Dir;

   procedure Print_Help is
   begin
      Put_Line ("ALBW: AdaLogic BASIC for the Web");
      Put_Line ("Usage: albw [options] <input.alb> [output.ts]");
      New_Line;
      Put_Line ("Options:");
      Put_Line ("  -o <file>        Output .ts file (default: derived from input name)");
      Put_Line ("  --outdir <dir>   Output directory (default: current dir, or web_<name> with --build)");
      Put_Line ("  --metrics, -m    Show code metrics after compilation");
      Put_Line ("  --walker, -w     Show AST structure and token information");
      Put_Line ("  --quiet, -q      Suppress informational messages");
      Put_Line ("  --tsc            Compile .ts to .js via tsc after transpilation");
      Put_Line ("  --target <ver>   TypeScript target (es5, es2020, esnext)");
      Put_Line ("  --build, -b      Full build: transpile + tsc + package with index.html");
      Put_Line ("  --library, -l    Library build: transpile + tsc, no index.html shell");
      Put_Line ("                   (for EXPORT_ES / EXPORT_WASM shared modules)");
      Put_Line ("  --mcp            Run as an MCP server (JSON-RPC over stdio); agents");
      Put_Line ("                   get validate/tokenize/compile/fixture tools in-process");
      Put_Line ("  --rt-trim[=on|off]  Trim unused ALB_*/alb* runtime helpers from the");
      Put_Line ("                   emitted .ts (default: on; usage scan + closure)");
      Put_Line ("  --rt-keep=<name> Pin a runtime helper into the output (repeatable)");
      Put_Line ("  --help, -h       Show this help");
   end Print_Help;

   function Spawn_And_Check
     (Working_Dir : String;
      Program     : String;
      Args        : Arg_List) return Boolean
   is
      Original_Dir : constant String := Ada.Directories.Current_Directory;
      Exit_Code    : Integer := -1;
      Ada_Args     : GNAT.OS_Lib.Argument_List (1 .. Args'Length);
      Resolved     : GNAT.OS_Lib.String_Access;
   begin
      for I in Args'Range loop
         Ada_Args (I) := Args (I);
      end loop;
      Ada.Directories.Set_Directory (Working_Dir);
      -- POSIX GNAT.OS_Lib.Spawn does not search PATH for a bare program
      -- name (execvp fallback is not used), so resolve it explicitly.
      Resolved := GNAT.OS_Lib.Locate_Exec_On_Path (Program);
      if Resolved /= null then
         Exit_Code := GNAT.OS_Lib.Spawn (Resolved.all, Ada_Args);
         GNAT.OS_Lib.Free (Resolved);
      else
         Exit_Code := GNAT.OS_Lib.Spawn (Program, Ada_Args);
      end if;
      Ada.Directories.Set_Directory (Original_Dir);
      return Exit_Code = 0;
   exception
      when others =>
         begin
            Ada.Directories.Set_Directory (Original_Dir);
         exception
            when others => null;
         end;
         return False;
   end Spawn_And_Check;

    procedure Write_Index_HTML
      (Dir            : String;
       Title          : String;
       JS_Name        : String;
       Module_Aware   : Boolean;
       Document_Shell : Boolean)
    is
       HTML_Path : constant String := Ada.Directories.Compose (Dir, "index.html");
       File      : Ada.Text_IO.File_Type;
    begin
       Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, HTML_Path);
       Ada.Text_IO.Put_Line (File, "<!doctype html>");
       Ada.Text_IO.Put_Line (File, "<html lang=""en"">");
       Ada.Text_IO.Put_Line (File, "<head>");
       Ada.Text_IO.Put_Line (File, "  <meta charset=""utf-8"">");
       Ada.Text_IO.Put_Line (File, "  <meta name=""viewport"" content=""width=device-width, initial-scale=1"">");
       Ada.Text_IO.Put_Line (File, "  <title>" & Title & "</title>");
       Ada.Text_IO.Put_Line (File, "  <style>");
       if Document_Shell then
          -- Light document shell for MODE DOCUMENT pages (sites, docs).
          -- Game / canvas builds keep the dark console shell below.
          Ada.Text_IO.Put_Line (File, "    html, body { margin: 0; padding: 0; width: 100%; min-height: 100%; background: #ffffff; color: #0f172a; font-family: ""Segoe UI"", system-ui, sans-serif; }");
       else
          Ada.Text_IO.Put_Line (File, "    html, body { margin: 0; padding: 0; width: 100%; min-height: 100%; background: #050511; color: #fff; font-family: Consolas, monospace; }");
       end if;
       Ada.Text_IO.Put_Line (File, "    body { position: relative; }");
       Ada.Text_IO.Put_Line (File, "  </style>");
       Ada.Text_IO.Put_Line (File, "</head>");
       Ada.Text_IO.Put_Line (File, "<body>");
       Ada.Text_IO.Put_Line (File, "  <script>");
       Ada.Text_IO.Put_Line (File, "    (function () {");
       Ada.Text_IO.Put_Line (File, "      function launch() {");
       Ada.Text_IO.Put_Line (File, "        var script = document.createElement('script');");
       if Module_Aware then
          Ada.Text_IO.Put_Line (File, "        script.type = 'module';");
       end if;
       Ada.Text_IO.Put_Line (File, "        script.src = './" & JS_Name & "';");
       Ada.Text_IO.Put_Line (File, "        document.body.appendChild(script);");
       Ada.Text_IO.Put_Line (File, "      }");
       Ada.Text_IO.Put_Line (File, "      if (document.readyState === 'complete') {");
       Ada.Text_IO.Put_Line (File, "        setTimeout(launch, 0);");
       Ada.Text_IO.Put_Line (File, "      } else {");
       Ada.Text_IO.Put_Line (File, "        window.addEventListener('load', function () { setTimeout(launch, 0); }, { once: true });");
       Ada.Text_IO.Put_Line (File, "      }");
       Ada.Text_IO.Put_Line (File, "    }());");
       Ada.Text_IO.Put_Line (File, "  </script>");
       Ada.Text_IO.Put_Line (File, "</body>");
       Ada.Text_IO.Put_Line (File, "</html>");
       Ada.Text_IO.Close (File);
    end Write_Index_HTML;

    procedure Write_Tsconfig
      (Dir          : String;
       TS_Name      : String;
       JS_Name      : String;
       Target       : String;
       Module_Aware : Boolean)
    is
       Config_Path : constant String := Ada.Directories.Compose (Dir, "tsconfig.json");
       File        : Ada.Text_IO.File_Type;
       TS_Target   : String (1 .. 16) := (others => ' ');
       TS_TLen     : Natural := Target'Length;
    begin
       if TS_TLen = 0 then
          TS_TLen := 6;
          TS_Target (1 .. 6) := "es2020";
       else
          TS_Target (1 .. TS_TLen) := Target;
       end if;
       Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Config_Path);
       Ada.Text_IO.Put_Line (File, "{");
       Ada.Text_IO.Put_Line (File, "  ""compilerOptions"": {");
       Ada.Text_IO.Put_Line (File, "    ""target"": """ & TS_Target (1 .. TS_TLen) & """,");
       if Module_Aware then
          Ada.Text_IO.Put_Line (File, "    ""module"": ""es2020"",");
          Ada.Text_IO.Put_Line (File, "    ""moduleResolution"": ""node"",");
       else
          Ada.Text_IO.Put_Line (File, "    ""module"": ""none"",");
          Ada.Text_IO.Put_Line (File, "    ""outFile"": """ & JS_Name & """,");
       end if;
       Ada.Text_IO.Put_Line (File, "    ""strict"": false,");
       Ada.Text_IO.Put_Line (File, "    ""noImplicitAny"": false,");
       Ada.Text_IO.Put_Line (File, "    ""noCheck"": true,");
       Ada.Text_IO.Put_Line (File, "    ""ignoreDeprecations"": ""6.0"",");
       Ada.Text_IO.Put_Line (File, "    ""lib"": [""es2020"", ""dom""]");
       Ada.Text_IO.Put_Line (File, "  },");
       Ada.Text_IO.Put_Line (File, "  ""files"": [""" & TS_Name & """]");
       Ada.Text_IO.Put_Line (File, "}");
       Ada.Text_IO.Close (File);
    end Write_Tsconfig;

   procedure Print_Walker_Info is
   begin
      New_Line;
      Put_Line ("=== ALBW Walker ===");
      Put_Line ("Token count : " & Trim_Image (Token_Count));
      Put_Line ("Source size : " & Trim_Image (Input_Len) & " bytes");
      Put_Line ("Include count: " & Trim_Image (Include_Count));
      New_Line;
      for I in 1 .. Include_Count loop
         Put_Line ("  included: " & Include_Vault (I) (1 .. Include_Lens (I)));
      end loop;
      New_Line;
      Put_Line ("=== AST Root ===");
      if Root > 0 then
         Put_Line ("  Kind   : " & Node_Kind'Image (Tree (Root).Kind));
         Put_Line ("  Token  : " & Trim_Image (Tree (Root).Token_Index));
         Put_Line ("  Left   : " & Trim_Image (Tree (Root).Left_Child));
         Put_Line ("  Right  : " & Trim_Image (Tree (Root).Right_Child));
         Put_Line ("  Sibling: " & Trim_Image (Tree (Root).Next_Sibling));
      else
         Put_Line ("  (null)");
      end if;
      New_Line;
   end Print_Walker_Info;

   function Resolve_Local_Asset_Path
     (Raw_Path : String;
      Base_Dir   : String) return String;

   procedure Log (Msg : String) is
   begin
      if not Quiet_Mode then
         Put_Line (Msg);
      end if;
   end Log;

   function Is_Already_Included (File_Name : String) return Boolean is
   begin
      for I in 1 .. Include_Count loop
         if Include_Lens (I) = File_Name'Length
           and then Include_Vault (I) (1 .. File_Name'Length) = File_Name
         then
            return True;
         end if;
      end loop;
      return False;
   end Is_Already_Included;

   procedure Register_Include
     (File_Name : String;
      Success   : in out Boolean) is
   begin
      if Include_Count >= Max_Includes or else File_Name'Length > Max_Path_Len then
         Success := False;
         return;
      end if;

      Include_Count := Include_Count + 1;
      Include_Lens (Include_Count) := File_Name'Length;
      Include_Vault (Include_Count) := (others => ' ');
      Include_Vault (Include_Count) (1 .. File_Name'Length) := File_Name;
   end Register_Include;

   procedure Append_Source
     (Text    : String;
      Success : in out Boolean) is
   begin
      if not Success then
         return;
      end if;

      if Input_Len + Text'Length > Max_Input_Size then
         Success := False;
         return;
      end if;

      Input_Buffer (Input_Len + 1 .. Input_Len + Text'Length) := Text;
      Input_Len := Input_Len + Text'Length;
   end Append_Source;

   procedure Parse_Include_Line
     (Line_Text : String;
      Line_Len  : Natural;
      Match     : out Boolean;
      File_Name : out String;
      File_Len  : out Natural)
   is
      P       : Natural := 1;
      Start   : Natural := 0;
      Stop    : Natural := 0;
      Keyword : constant String := "INCLUDE";
   begin
      Match := False;
      File_Len := 0;
      File_Name := (others => ' ');

      while P <= Line_Len and then
        (Line_Text (P) = ' ' or else Line_Text (P) = ASCII.HT)
      loop
         P := P + 1;
      end loop;

      if P + Keyword'Length - 1 > Line_Len then
         return;
      end if;

      for I in Keyword'Range loop
         if To_Upper (Line_Text (P + (I - Keyword'First))) /= Keyword (I) then
            return;
         end if;
      end loop;

      P := P + Keyword'Length;
      while P <= Line_Len and then
        (Line_Text (P) = ' ' or else Line_Text (P) = ASCII.HT)
      loop
         P := P + 1;
      end loop;

      if P > Line_Len or else Line_Text (P) /= '"' then
         return;
      end if;

      Start := P + 1;
      Stop := Start;
      while Stop <= Line_Len and then Line_Text (Stop) /= '"' loop
         Stop := Stop + 1;
      end loop;

      if Stop <= Line_Len and then Stop > Start then
         File_Len := Stop - Start;
         if File_Len <= File_Name'Length then
            File_Name
              (File_Name'First .. File_Name'First + File_Len - 1) :=
                Line_Text (Start .. Stop - 1);
            Match := True;
         end if;
      end if;
   end Parse_Include_Line;

   function Is_Word_Char (Ch : Character) return Boolean is
   begin
      return Ch in 'A' .. 'Z' or else Ch in 'a' .. 'z'
        or else Ch in '0' .. '9' or else Ch = '_';
   end Is_Word_Char;

   --  Call-site scan: true when Up contains `Word(` where the char
   --  before the word is not an identifier char — used to detect the
   --  BRAILLE/NEMETH expression builtins (BRF/UNI/BRFG1/NBRF/NUNI).
   function Line_Has_Call (Up : String; Word : String) return Boolean is
      Idx : Natural := Up'First;
   begin
      while Idx + Word'Length <= Up'Last loop
         if Up (Idx .. Idx + Word'Length - 1) = Word
           and then Up (Idx + Word'Length) = '('
           and then (Idx = Up'First
                     or else not Is_Word_Char (Up (Idx - 1)))
         then
            return True;
         end if;
         Idx := Idx + 1;
      end loop;
      return False;
   end Line_Has_Call;

   --  BRAILLE / NEMETH raw blocks: line-shape predicate shared by the
   --  weave-time detector (Flush_Line) and the main-file prescan.
   --  True when the line's first word is the block keyword followed by
   --  a valid opener tail: optional `G1` (BRAILLE only), `VERIFY`,
   --  `OUT "<path>"`, `AS <ident>` — in any order, then nothing but
   --  blanks or a -- comment.  Mirrors the tokenizer's Block_Opener_Ok
   --  so `braille`/`nemeth` stay usable as ordinary identifiers
   --  elsewhere.
   function Line_Opens_Word_Block
     (Buf      : String;
      Len      : Natural;
      Word     : String;
      Allow_G1 : Boolean) return Boolean
   is
      P : Natural := Buf'First;

      procedure Skip_Blanks is
      begin
         while P <= Len and then
           (Buf (P) = ' ' or else Buf (P) = ASCII.HT)
         loop
            P := P + 1;
         end loop;
      end Skip_Blanks;

      function Ident_At (W : String) return Boolean is
      begin
         if P + W'Length - 1 > Len then
            return False;
         end if;
         for K in W'Range loop
            if To_Upper (Buf (P + (K - W'First))) /= W (K) then
               return False;
            end if;
         end loop;
         return P + W'Length > Len
           or else not Is_Word_Char (Buf (P + W'Length));
      end Ident_At;

      function Take_Ident return Boolean is
      begin
         if P > Len then
            return False;
         end if;
         if not ((Buf (P) in 'A' .. 'Z')
                 or else (Buf (P) in 'a' .. 'z')
                 or else Buf (P) = '_')
         then
            return False;
         end if;
         while P <= Len and then Is_Word_Char (Buf (P)) loop
            P := P + 1;
         end loop;
         Skip_Blanks;
         return True;
      end Take_Ident;
   begin
      Skip_Blanks;

      if not Ident_At (Word) then
         return False;
      end if;
      P := P + Word'Length;

      loop
         Skip_Blanks;
         exit when P > Len;
         exit when Buf (P) = '-' and then P < Len
           and then Buf (P + 1) = '-';

         if Allow_G1 and then Ident_At ("G1") then
            P := P + 2;
         elsif Ident_At ("VERIFY") then
            P := P + 6;
         elsif Ident_At ("OUT") then
            P := P + 3;
            Skip_Blanks;
            if P > Len or else Buf (P) /= '"' then
               return False;
            end if;
            P := P + 1;
            while P <= Len and then Buf (P) /= '"' loop
               P := P + 1;
            end loop;
            if P > Len then
               return False;
            end if;
            P := P + 1;
         elsif Ident_At ("AS") then
            P := P + 2;
            Skip_Blanks;
            if not Take_Ident then
               return False;
            end if;
         else
            return False;
         end if;
      end loop;
      return True;
   end Line_Opens_Word_Block;

   --  Resolved-path basename check for engine includes; requires a
   --  path separator (or the bare name) before the suffix so that
   --  e.g. "xueb.albi" cannot masquerade as the engine file.
   function Path_Ends_With (Path : String; Suffix : String) return Boolean is
   begin
      if Path'Length < Suffix'Length then
         return False;
      end if;
      declare
         Tail : constant String := Path (Path'Last - Suffix'Length + 1 .. Path'Last);
      begin
         for I in Suffix'Range loop
            if To_Upper (Tail (I - Suffix'First + Tail'First)) /=
               Suffix (I)
            then
               return False;
            end if;
         end loop;
      end;
      return Path'Length = Suffix'Length or else
        Path (Path'Last - Suffix'Length) = '/' or else
        Path (Path'Last - Suffix'Length) = '\';
   end Path_Ends_With;

    procedure Weave_File
      (File_Name : String;
       Success   : in out Boolean)
    is
       File        : Ada.Streams.Stream_IO.File_Type;
       Stream_Ptr  : Ada.Streams.Stream_IO.Stream_Access;
       Ch          : Character;
       Line_Buffer : String (1 .. 2048) := (others => ' ');
       Line_Len    : Natural := 0;
       File_Dir    : constant String := Parent_Directory (File_Name);

       procedure Flush_Line is
          Include_Match : Boolean := False;
          Include_Name  : String (1 .. Max_Path_Len) := (others => ' ');
          Include_Len   : Natural := 0;
          Resolved      : String (1 .. Max_Path_Len) := (others => ' ');
          Resolved_Len  : Natural := 0;
       begin
          Parse_Include_Line
            (Line_Buffer,
             Line_Len,
             Include_Match,
             Include_Name,
             Include_Len);

          if Include_Match then
             declare
                Raw_Include : constant String := Include_Name (1 .. Include_Len);
                Resolved_Path : constant String :=
                  Resolve_Local_Asset_Path (Raw_Include, File_Dir);
            begin
               if Resolved_Path'Length = 0 or else Resolved_Path'Length > Max_Path_Len then
                  Put_Line ("ALBW: include not found: " & Raw_Include & " (from " & File_Name & ")");
                  Success := False;
               else
                  Resolved_Len := Resolved_Path'Length;
                  Resolved (1 .. Resolved_Len) := Resolved_Path;
                  if Path_Ends_With
                    (Resolved (1 .. Resolved_Len), "UEB.ALBI")
                  then
                     Ueb_Engine_Woven := True;
                  elsif Path_Ends_With
                    (Resolved (1 .. Resolved_Len), "NEMETH.ALBI")
                  then
                     Nemeth_Engine_Woven := True;
                  end if;
                  Weave_File (Resolved (1 .. Resolved_Len), Success);
                end if;
             end;
          else
             if Line_Len > 0 then
                if Line_Opens_Word_Block
                  (Line_Buffer, Line_Len, "BRAILLE", True)
                then
                   Braille_Block_Seen := True;
                elsif Line_Opens_Word_Block
                  (Line_Buffer, Line_Len, "NEMETH", False)
                then
                   Nemeth_Block_Seen := True;
                end if;

                --  expression builtins need the engine woven too
                if not (Braille_Block_Seen and then Nemeth_Block_Seen) then
                   declare
                      Up : String (1 .. Line_Buffer'Last);
                   begin
                      for I in 1 .. Line_Len loop
                         Up (I) := To_Upper (Line_Buffer (I));
                      end loop;
                      if not Braille_Block_Seen and then
                        (Line_Has_Call (Up (1 .. Line_Len), "BRF")
                         or else Line_Has_Call (Up (1 .. Line_Len), "UNI")
                         or else Line_Has_Call (Up (1 .. Line_Len), "BRFG1"))
                      then
                         Braille_Block_Seen := True;
                      end if;
                      if not Nemeth_Block_Seen and then
                        (Line_Has_Call (Up (1 .. Line_Len), "NBRF")
                         or else Line_Has_Call (Up (1 .. Line_Len), "NUNI")
                         or else Line_Has_Call (Up (1 .. Line_Len), "UNBRF")
                         or else Line_Has_Call (Up (1 .. Line_Len), "UNUNI"))
                      then
                         Nemeth_Block_Seen := True;
                      end if;
                   end;
                end if;

                Append_Source (Line_Buffer (1 .. Line_Len), Success);
             end if;
             Append_Source (ASCII.LF & "", Success);
          end if;

          Line_Len := 0;
       end Flush_Line;
   begin
      if not Success or else Is_Already_Included (File_Name) then
         return;
      end if;

      Register_Include (File_Name, Success);
      if not Success then
         return;
      end if;

      Log ("  weaving: " & File_Name);

      begin
         Ada.Streams.Stream_IO.Open
           (File,
            Ada.Streams.Stream_IO.In_File,
            File_Name);
         Stream_Ptr := Ada.Streams.Stream_IO.Stream (File);
      exception
         when E : others =>
            Put_Line ("ALBW: could not open source file: " & File_Name & " - " &
              Ada.Exceptions.Exception_Message (E));
            Success := False;
            return;
      end;

      while not Ada.Streams.Stream_IO.End_Of_File (File) loop
         Character'Read (Stream_Ptr, Ch);

         if Ch = ASCII.CR then
            null;
         elsif Ch = ASCII.LF then
            Flush_Line;
            exit when not Success;
         else
            if Line_Len < Line_Buffer'Length then
               Line_Len := Line_Len + 1;
               Line_Buffer (Line_Len) := Ch;
            else
               Success := False;
               exit;
            end if;
         end if;
      end loop;

      if Success and then Line_Len > 0 then
         Flush_Line;
      end if;

      Ada.Streams.Stream_IO.Close (File);
   exception
      when E : others =>
         Put_Line ("ALBW: weave failure in " & File_Name & " - " &
           Ada.Exceptions.Exception_Message (E));
         Success := False;
         begin
            Ada.Streams.Stream_IO.Close (File);
         exception
            when others =>
               null;
         end;
   end Weave_File;

   --  Prescan the main source for standalone BRAILLE / NEMETH block
   --  openers so the matching transcription engine (ueb.albi /
   --  nemeth.albi) can be woven ahead of user code, and remember
   --  which IMPORT / engine-INCLUDE lines already exist so the
   --  driver never injects a duplicate.
   procedure Prescan_For_Raw_Blocks
     (File_Name   : String;
      Use_Braille : out Boolean;
      Use_Nemeth  : out Boolean;
      Has_Ueb_Inc : out Boolean;
      Has_Nem_Inc : out Boolean;
      Has_Imp_Ueb : out Boolean;
      Has_Imp_Nem : out Boolean)
   is
      File        : Ada.Streams.Stream_IO.File_Type;
      Stream_Ptr  : Ada.Streams.Stream_IO.Stream_Access;
      Ch          : Character;
      Line_Buffer : String (1 .. 2048) := (others => ' ');
      Line_Len    : Natural := 0;

      procedure Scan_Line is
         Up : String (1 .. Line_Buffer'Last);
         P  : Natural := 1;
      begin
         for I in 1 .. Line_Len loop
            Up (I) := To_Upper (Line_Buffer (I));
         end loop;

         while P <= Line_Len and then
           (Up (P) = ' ' or else Up (P) = ASCII.HT)
         loop
            P := P + 1;
         end loop;

         if P > Line_Len or else
           (Up (P) = '-' and then P < Line_Len
            and then Up (P + 1) = '-')
         then
            return;  --  blank or comment line
         end if;

         if Line_Opens_Word_Block
           (Line_Buffer, Line_Len, "BRAILLE", True)
         then
            Use_Braille := True;
         elsif Line_Opens_Word_Block
           (Line_Buffer, Line_Len, "NEMETH", False)
         then
            Use_Nemeth := True;
         end if;

         --  expression builtins need the engine woven too
         if Line_Has_Call (Up (1 .. Line_Len), "BRF")
           or else Line_Has_Call (Up (1 .. Line_Len), "UNI")
           or else Line_Has_Call (Up (1 .. Line_Len), "BRFG1")
         then
            Use_Braille := True;
         end if;
         if Line_Has_Call (Up (1 .. Line_Len), "NBRF")
           or else Line_Has_Call (Up (1 .. Line_Len), "NUNI")
           or else Line_Has_Call (Up (1 .. Line_Len), "UNBRF")
           or else Line_Has_Call (Up (1 .. Line_Len), "UNUNI")
         then
            Use_Nemeth := True;
         end if;

         if Ada.Strings.Fixed.Index
           (Up (1 .. Line_Len), "UEB.ALBI") > 0
         then
            Has_Ueb_Inc := True;
         end if;
         if Ada.Strings.Fixed.Index
           (Up (1 .. Line_Len), "NEMETH.ALBI") > 0
         then
            Has_Nem_Inc := True;
         end if;

         --  IMPORT UEB / IMPORT NEMETH: first word IMPORT, second the
         --  module name.
         if P + 5 <= Line_Len and then Up (P .. P + 5) = "IMPORT"
           and then (P + 6 > Line_Len
                     or else not Is_Word_Char (Up (P + 6)))
         then
            P := P + 6;
            while P <= Line_Len and then
              (Up (P) = ' ' or else Up (P) = ASCII.HT)
            loop
               P := P + 1;
            end loop;
            if P + 2 <= Line_Len and then Up (P .. P + 2) = "UEB"
              and then (P + 3 > Line_Len
                        or else not Is_Word_Char (Up (P + 3)))
            then
               Has_Imp_Ueb := True;
            elsif P + 5 <= Line_Len and then Up (P .. P + 5) = "NEMETH"
              and then (P + 6 > Line_Len
                        or else not Is_Word_Char (Up (P + 6)))
            then
               Has_Imp_Nem := True;
            end if;
         end if;
      end Scan_Line;
   begin
      Use_Braille := False;  Use_Nemeth := False;
      Has_Ueb_Inc := False;  Has_Nem_Inc := False;
      Has_Imp_Ueb := False;  Has_Imp_Nem := False;

      begin
         Ada.Streams.Stream_IO.Open
           (File, Ada.Streams.Stream_IO.In_File, File_Name);
         Stream_Ptr := Ada.Streams.Stream_IO.Stream (File);
      exception
         when others =>
            return;
      end;

      while not Ada.Streams.Stream_IO.End_Of_File (File) loop
         Character'Read (Stream_Ptr, Ch);

         if Ch = ASCII.CR then
            null;
         elsif Ch = ASCII.LF then
            Scan_Line;
            Line_Len := 0;
         elsif Line_Len < Line_Buffer'Length then
            Line_Len := Line_Len + 1;
            Line_Buffer (Line_Len) := Ch;
         end if;
      end loop;

      if Line_Len > 0 then
         Scan_Line;
      end if;

      Ada.Streams.Stream_IO.Close (File);
   exception
      when others =>
         begin
            Ada.Streams.Stream_IO.Close (File);
         exception
            when others =>
               null;
         end;
   end Prescan_For_Raw_Blocks;

   function Strip_String_Node (Idx : Node_Index) return String is
      Tok : Token := Tokens (Tree (Idx).Token_Index);
   begin
      if Tok.Length >= 2 then
         return Input_Buffer (Tok.Start + 1 .. Tok.Start + Tok.Length - 2);
      else
         return "";
      end if;
   end Strip_String_Node;

   function Path_Exists (Path : String) return Boolean is
   begin
      return Path'Length > 0 and then Ada.Directories.Exists (Path);
   exception
      when others =>
         return False;
   end Path_Exists;

   function Resolve_Local_Asset_Path
     (Raw_Path : String;
      Base_Dir : String) return String
   is
      Trimmed : constant String := Ada.Strings.Fixed.Trim (Raw_Path, Ada.Strings.Both);
      function Join_Base_Path (Dir : String; Leaf : String) return String is
      begin
         if Leaf'Length = 0 then
            return Dir;
         elsif Dir'Length = 0 then
            return Leaf;
         elsif Leaf (Leaf'First) = '\' or else Leaf (Leaf'First) = '/' then
            return Leaf;
         elsif Leaf'Length >= 2
           and then Leaf (Leaf'First) = '.'
           and then (Leaf (Leaf'First + 1) = '\' or else Leaf (Leaf'First + 1) = '/')
         then
            if Leaf'Length = 2 then
               return Dir;
            elsif Dir (Dir'Last) = '\' or else Dir (Dir'Last) = '/' then
               return Dir & Leaf (Leaf'First + 2 .. Leaf'Last);
            else
               return Dir & Directory_Separator
                 & Leaf (Leaf'First + 2 .. Leaf'Last);
            end if;
         else
            for I in Leaf'Range loop
               if Leaf (I) = '\' or else Leaf (I) = '/' then
                  if Dir (Dir'Last) = '\' or else Dir (Dir'Last) = '/' then
                     return Dir & Leaf;
                  else
                     return Dir & Directory_Separator & Leaf;
                  end if;
               end if;
            end loop;
            return Ada.Directories.Compose (Dir, Leaf);
         end if;
      end Join_Base_Path;

      function Try_Exists (Candidate : String) return Boolean is
      begin
         return Path_Exists (Candidate)
           or else Path_Exists (Candidate & ".albi")
           or else Path_Exists (Candidate & ".alb");
      end Try_Exists;

      function With_Extension (Candidate : String) return String is
      begin
         if Path_Exists (Candidate) then
            return Candidate;
         elsif Path_Exists (Candidate & ".albi") then
            return Candidate & ".albi";
         else
            return Candidate & ".alb";
         end if;
      end With_Extension;
   begin
      if Trimmed'Length = 0 then
         return "";
      elsif Path_Exists (Trimmed) then
         return Trimmed;
      elsif Base_Dir'Length > 0 then
         declare
            Candidate : constant String := Join_Base_Path (Base_Dir, Trimmed);
         begin
            if Try_Exists (Candidate) then
               return With_Extension (Candidate);
            end if;
         end;
      end if;

      declare
         Candidate : constant String := Join_Base_Path
           (Ada.Directories.Current_Directory, Trimmed);
      begin
         if Try_Exists (Candidate) then
            return With_Extension (Candidate);
         end if;
      end;

      --  ALB_LIB search path: `;`-separated directories searched after the
      --  source file's own dir and cwd — the stdlib delivery mechanism.
      --  `INCLUDE "alb_fmt"` resolves to `<ALB_LIB dir>/alb_fmt.albi`.
      if Ada.Environment_Variables.Exists ("ALB_LIB") then
         declare
            Libs  : constant String := Ada.Environment_Variables.Value ("ALB_LIB");
            Start : Natural := Libs'First;
         begin
            for I in Libs'Range loop
               if Alb_Platform.Is_List_Sep (Libs (I))
                 or else I = Libs'Last
               then
                  declare
                     Last : constant Natural :=
                       (if Alb_Platform.Is_List_Sep (Libs (I))
                        then I - 1 else I);
                     Dir  : constant String :=
                       (if Last >= Start
                        then Ada.Strings.Fixed.Trim
                          (Libs (Start .. Last), Ada.Strings.Both)
                        else "");
                  begin
                     if Dir'Length > 0 then
                        declare
                           Candidate : constant String :=
                             Join_Base_Path (Dir, Trimmed);
                        begin
                           if Try_Exists (Candidate) then
                              return With_Extension (Candidate);
                           end if;
                        end;
                     end if;
                  end;
                  Start := I + 1;
               end if;
            end loop;
         end;
      end if;

      return "";
   end Resolve_Local_Asset_Path;

   procedure Register_Stage_Asset (File_Name : String) is
   begin
      if File_Name'Length = 0 or else File_Name'Length > Max_Path_Len then
         return;
      end if;

      for I in 1 .. Stage_Asset_Count loop
         if Stage_Asset_Lens (I) = File_Name'Length
           and then Stage_Assets (I) (1 .. File_Name'Length) = File_Name
         then
            return;
         end if;
      end loop;

      if Stage_Asset_Count < Max_Stage_Assets then
         Stage_Asset_Count := Stage_Asset_Count + 1;
         Stage_Asset_Lens (Stage_Asset_Count) := File_Name'Length;
         Stage_Assets (Stage_Asset_Count) := (others => ' ');
         Stage_Assets (Stage_Asset_Count) (1 .. File_Name'Length) := File_Name;
      end if;
   end Register_Stage_Asset;

   procedure Scan_Web_Features (First : Node_Index) is
      Curr     : Node_Index := First;
      Source_Dir : constant String := Parent_Directory (Source_File (1 .. Source_Len));
   begin
      while Curr > 0 loop
         case Tree (Curr).Kind is
            when AST_Import_ES | AST_Import_WASM =>
               Module_Aware_Output := True;
               if Tree (Curr).Right_Child > 0 then
                  declare
                     Resolved : constant String :=
                       Resolve_Local_Asset_Path
                         (Strip_String_Node (Tree (Curr).Right_Child),
                          Source_Dir);
                  begin
                     if Resolved'Length > 0 then
                        Register_Stage_Asset (Resolved);
                     end if;
                  end;
               end if;

            when AST_Export_ES | AST_Export_WASM =>
               Module_Aware_Output := True;

            when others =>
               null;
         end case;

         if Tree (Curr).Left_Child > 0 then
            Scan_Web_Features (Tree (Curr).Left_Child);
         end if;
         if Tree (Curr).Right_Child > 0 then
            Scan_Web_Features (Tree (Curr).Right_Child);
         end if;
         Curr := Tree (Curr).Next_Sibling;
      end loop;
   end Scan_Web_Features;

   function Source_Wants_No_Console return Boolean is
      Sample : constant String := Input_Buffer (1 .. Input_Len);
   begin
      return Ada.Strings.Fixed.Index (Sample, "NO CONSOLE") > 0
        or else Ada.Strings.Fixed.Index (Sample, "MODE NO CONSOLE") > 0;
   end Source_Wants_No_Console;

   -- Document / marketing pages (no CREATE_WINDOW canvas). Agents previously
   -- hand-edited the generated index.html away from the game shell — that is
   -- wrong. Prefer an explicit MODE DOCUMENT marker in the .alb source.
   function Source_Wants_Document_Shell return Boolean is
      Sample : constant String := Input_Buffer (1 .. Input_Len);
   begin
      return Ada.Strings.Fixed.Index (Sample, "MODE DOCUMENT") > 0
        or else Ada.Strings.Fixed.Index (Sample, "DOCUMENT SHELL") > 0;
   end Source_Wants_Document_Shell;

   procedure Copy_Stage_Assets (Dest_Dir : String) is
   begin
      for I in 1 .. Stage_Asset_Count loop
         declare
            Source_Path : constant String := Stage_Assets (I) (1 .. Stage_Asset_Lens (I));
            Dest_Path   : constant String := Ada.Directories.Compose
              (Dest_Dir,
               Ada.Directories.Base_Name (Source_Path));
         begin
            if Source_Path /= Dest_Path then
               Ada.Directories.Copy_File (Source_Path, Dest_Path);
            end if;
         exception
            when others =>
               Put_Line ("ALBW: failed to stage asset " & Source_Path);
         end;
      end loop;
   end Copy_Stage_Assets;

   -- ================================================================
   --  MCP server mode (--mcp)
   --
   --  JSON-RPC 2.0 over newline-delimited JSON on stdin/stdout. All
   --  compiler chatter is redirected to stderr via Set_Output so the
   --  stdout channel stays pure protocol. Tools reach straight into
   --  the tokenize -> parse -> emit pipeline.
   -- ================================================================

   procedure Run_MCP is
      use ALB_JSON;
      use Ada.Strings.Unbounded;

      In_Stream : constant Ada.Text_IO.Text_Streams.Stream_Access :=
        Ada.Text_IO.Text_Streams.Stream (Ada.Text_IO.Standard_Input);

      MCP_Scratch : constant String :=
        Ada.Directories.Compose (Alb_Platform.Temp_Dir, "albw_mcp");

      MCP_Compile_Seq : Natural := 0;

      ------------------------------------------------------------

      function Read_Message (EOF : out Boolean) return Unbounded_String is
         Buf : Unbounded_String := Null_Unbounded_String;
         Ch  : Character;
      begin
         EOF := False;
         loop
            begin
               Character'Read (In_Stream, Ch);
            exception
               when Ada.IO_Exceptions.End_Error | Ada.IO_Exceptions.Mode_Error =>
                  EOF := True;
                  return Buf;
            end;
            exit when Ch = ASCII.LF;
            if Ch /= ASCII.CR then
               Append (Buf, String'(1 => Ch));
               if Length (Buf) > Max_JSON_Chars then
                  return Buf;  -- oversized message: let Parse fail it
               end if;
            end if;
         end loop;
         return Buf;
      end Read_Message;

      procedure Respond (Text : String) is
      begin
         Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Output, Text);
         Ada.Text_IO.Flush (Ada.Text_IO.Standard_Output);
      end Respond;

      ------------------------------------------------------------
      --  shared front-half of the compile pipeline

      procedure Reset_Pipeline is
      begin
         Input_Buffer := (others => ' ');
         Temp_Buffer := (others => ' ');
         Tokens := (others => (Kind => Tok_Error, Start => 1,
                               Length => 0, Line => 1, Column => 1));
         Tree := (others => (Kind => AST_Null, Token_Index => 0,
                             Left_Child => 0, Right_Child => 0,
                             Next_Sibling => 0));
         Input_Len := 0;
         Token_Count := 0;
         Root := 0;
         Parse_Success := False;
         Include_Count := 0;
         Stage_Asset_Count := 0;
         Module_Aware_Output := False;
      end Reset_Pipeline;

      function Load_Source (Args : J_Index) return Boolean is
         Src : J_Index;
      begin
         Reset_Pipeline;
         Src := Member (Args, "source");
         if Src /= 0 and then Kind (Src) = J_Str then
            declare
               S : constant String := As_String (Src);
            begin
               if S'Length > Max_Input_Size then
                  return False;
               end if;
               Input_Len := S'Length;
               Input_Buffer (1 .. Input_Len) := S;
               return True;
            end;
         end if;
         Src := Member (Args, "path");
         if Src /= 0 and then Kind (Src) = J_Str then
            declare
               Ok : Boolean := True;
            begin
               Weave_File (As_String (Src), Ok);
               return Ok and then Input_Len > 0;
            end;
         end if;
         return False;
      end Load_Source;

      function Diag_Array (D : Parser.Parser_Diagnostic) return J_Index is
         A : J_Index := New_Arr;
         E : J_Index;
      begin
         for I in 1 .. D.Error_Count loop
            E := New_Obj;
            Put_Member (E, "line",
                        New_Num (Long_Long_Integer (D.Errors (I).Line)));
            Put_Member (E, "col",
                        New_Num (Long_Long_Integer (D.Errors (I).Col)));
            Put_Member (E, "code",
                        New_Str (Oracle_Code'Image (D.Errors (I).Code)));
            Put_Member (E, "severity",
                        New_Str
                          ((if D.Errors (I).Severity = Fatal
                            then "fatal" else "warning")));
            Put_Member (E, "message",
                        New_Str (Oracle_Text (D.Errors (I).Code)));
            Append_Child (A, E);
         end loop;
         return A;
      end Diag_Array;

      ------------------------------------------------------------
      --  tools

      procedure Tool_Validate (Args : J_Index; Result : J_Index) is
         LD : Lexer_Diagnostic;
         PD : Parser_Diagnostic;
      begin
         if not Load_Source (Args) then
            Put_Member (Result, "success", New_Bool (False));
            Put_Member (Result, "stage", New_Str ("load"));
            Put_Member (Result, "error",
                        New_Str ("need 'source' or 'path', or unreadable file"));
            return;
         end if;
         Tokenize (Input_Buffer (1 .. Input_Len), Tokens, Token_Count, LD);
         if not LD.Success then
            Put_Member (Result, "success", New_Bool (False));
            Put_Member (Result, "stage", New_Str ("lexer"));
            declare
               A : J_Index := New_Arr;
               E : J_Index := New_Obj;
            begin
               Put_Member (E, "line", New_Num (Long_Long_Integer (LD.Error_Line)));
               Put_Member (E, "col", New_Num (Long_Long_Integer (LD.Error_Col)));
               Put_Member (E, "code", New_Str (Oracle_Code'Image (LD.Code)));
               Put_Member (E, "severity", New_Str ("fatal"));
               Put_Member (E, "message", New_Str (Oracle_Text (LD.Code)));
               Append_Child (A, E);
               Put_Member (Result, "diagnostics", A);
            end;
            return;
         end if;
         Parse (Tokens, Token_Count, Tree, Root, Parse_Success, PD);
         Put_Member (Result, "diagnostics", Diag_Array (PD));
         Put_Member (Result, "token_count",
                     New_Num (Long_Long_Integer (Token_Count)));
         Put_Member (Result, "root", New_Num (Long_Long_Integer (Root)));
         if not Parse_Success or else not PD.Success or else Root = 0 then
            Put_Member (Result, "success", New_Bool (False));
            Put_Member (Result, "stage", New_Str ("parser"));
            --  Append the primary diag unless the ledger already has it
            --  (the parser duplicates head-of-ledger into Error_Line/
            --  Error_Col/Code).
            if PD.Error_Count = 0
              or else PD.Errors (PD.Error_Count).Code /= PD.Code
            then
               declare
                  E : J_Index := New_Obj;
               begin
                  Put_Member (E, "line",
                              New_Num (Long_Long_Integer (PD.Error_Line)));
                  Put_Member (E, "col",
                              New_Num (Long_Long_Integer (PD.Error_Col)));
                  Put_Member (E, "code",
                              New_Str (Oracle_Code'Image (PD.Code)));
                  Put_Member (E, "severity", New_Str ("fatal"));
                  Put_Member (E, "message", New_Str (Oracle_Text (PD.Code)));
                  Append_Child (Member (Result, "diagnostics"), E);
               end;
            end if;
            return;
         end if;
         declare
            Fatal_Seen : Boolean := False;
         begin
            for I in 1 .. PD.Error_Count loop
               if PD.Errors (I).Severity = Fatal then
                  Fatal_Seen := True;
               end if;
            end loop;
            if Fatal_Seen then
               Put_Member (Result, "success", New_Bool (False));
               Put_Member (Result, "stage", New_Str ("parser"));
               return;
            end if;
         end;
         Put_Member (Result, "success", New_Bool (True));
         Put_Member (Result, "stage", New_Str ("ok"));
      end Tool_Validate;

      procedure Tool_Tokenize (Args : J_Index; Result : J_Index) is
         LD : Lexer_Diagnostic;
         A  : J_Index := New_Arr;
         T  : J_Index;
      begin
         if not Load_Source (Args) then
            Put_Member (Result, "success", New_Bool (False));
            Put_Member (Result, "error",
                        New_Str ("need 'source' or 'path'"));
            return;
         end if;
         Tokenize (Input_Buffer (1 .. Input_Len), Tokens, Token_Count, LD);
         Put_Member (Result, "success", New_Bool (LD.Success));
         Put_Member (Result, "token_count",
                     New_Num (Long_Long_Integer (Token_Count)));
         if not LD.Success then
            Put_Member (Result, "error",
                        New_Str
                          ("lexer error at " &
                           Trim_Image (Integer (LD.Error_Line)) & ":" &
                           Trim_Image (Integer (LD.Error_Col)) & " " &
                           Oracle_Text (LD.Code)));
         end if;
         for I in 1 .. Token_Count loop
            T := New_Obj;
            if T = 0 then
               Put_Member (Result, "tokens_truncated", New_Bool (True));
               exit;
            end if;
            Put_Member (T, "index", New_Num (Long_Long_Integer (I)));
            Put_Member (T, "kind",
                        New_Str (Token_Kind'Image (Tokens (I).Kind)));
            Put_Member (T, "start",
                        New_Num (Long_Long_Integer (Tokens (I).Start)));
            Put_Member (T, "length",
                        New_Num (Long_Long_Integer (Tokens (I).Length)));
            Put_Member (T, "line",
                        New_Num (Long_Long_Integer (Tokens (I).Line)));
            Put_Member (T, "col",
                        New_Num (Long_Long_Integer (Tokens (I).Column)));
            declare
               S : constant String :=
                 Input_Buffer (Tokens (I).Start ..
                               Tokens (I).Start + Tokens (I).Length - 1);
            begin
               Put_Member (T, "text", New_Str (S));
            exception
               when others =>
                  Put_Member (T, "text", New_Str (""));
            end;
            Append_Child (A, T);
         end loop;
         Put_Member (Result, "tokens", A);
      end Tool_Tokenize;

      function Read_File_Text (Path : String) return Unbounded_String is
         F    : Ada.Streams.Stream_IO.File_Type;
         S    : Ada.Streams.Stream_IO.Stream_Access;
         Ch   : Character;
         Buf  : Unbounded_String := Null_Unbounded_String;
      begin
         Ada.Streams.Stream_IO.Open (F, Ada.Streams.Stream_IO.In_File, Path);
         S := Ada.Streams.Stream_IO.Stream (F);
         while not Ada.Streams.Stream_IO.End_Of_File (F) loop
            Character'Read (S, Ch);
            Append (Buf, String'(1 => Ch));
         end loop;
         Ada.Streams.Stream_IO.Close (F);
         return Buf;
      exception
         when others =>
            begin
               Ada.Streams.Stream_IO.Close (F);
            exception
               when others => null;
            end;
            return Null_Unbounded_String;
      end Read_File_Text;

      procedure Tool_Compile (Args : J_Index; Result : J_Index) is
         LD : Lexer_Diagnostic;
         PD : Parser_Diagnostic;
      begin
         if not Load_Source (Args) then
            Put_Member (Result, "success", New_Bool (False));
            Put_Member (Result, "stage", New_Str ("load"));
            Put_Member (Result, "error",
                        New_Str ("need 'source' or 'path', or unreadable file"));
            return;
         end if;
         Tokenize (Input_Buffer (1 .. Input_Len), Tokens, Token_Count, LD);
         if not LD.Success then
            Put_Member (Result, "success", New_Bool (False));
            Put_Member (Result, "stage", New_Str ("lexer"));
            Put_Member (Result, "error",
                        New_Str
                          ("at " & Trim_Image (Integer (LD.Error_Line)) &
                           ":" & Trim_Image (Integer (LD.Error_Col)) &
                           " " & Oracle_Text (LD.Code)));
            return;
         end if;
         Parse (Tokens, Token_Count, Tree, Root, Parse_Success, PD);
         Put_Member (Result, "diagnostics", Diag_Array (PD));
         if not Parse_Success or else not PD.Success or else Root = 0 then
            Put_Member (Result, "success", New_Bool (False));
            Put_Member (Result, "stage", New_Str ("parser"));
            Put_Member (Result, "error",
                        New_Str
                          ("at " & Trim_Image (Integer (PD.Error_Line)) &
                           ":" & Trim_Image (Integer (PD.Error_Col)) &
                           " " & Oracle_Text (PD.Code)));
            return;
         end if;
         declare
            Fatal_Seen : Boolean := False;
         begin
            for I in 1 .. PD.Error_Count loop
               if PD.Errors (I).Severity = Fatal then
                  Fatal_Seen := True;
               end if;
            end loop;
            if Fatal_Seen then
               Put_Member (Result, "success", New_Bool (False));
               Put_Member (Result, "stage", New_Str ("parser"));
               Put_Member (Result, "error",
                           New_Str ("parse recovery dropped statements"));
               return;
            end if;
         end;
         if Root > 0 then
            Scan_Web_Features (Root);
         end if;
         Emit_Native_TypeScript.Set_No_Console_Overlay
           (Source_Wants_No_Console);
         Emit_Native_TypeScript.Set_Rt_Trim (Rt_Trim_Mode);
         Emit_Native_TypeScript.Clear_Rt_Keep;
         for K in 1 .. Rt_Keep_Arg_N loop
            Emit_Native_TypeScript.Add_Rt_Keep
              (Ada.Strings.Unbounded.To_String (Rt_Keep_Args (K)));
         end loop;
         MCP_Compile_Seq := MCP_Compile_Seq + 1;
         declare
            TS_Path : constant String :=
              Ada.Directories.Compose
                (MCP_Scratch,
                 "mcp_" & Trim_Image (Integer (MCP_Compile_Seq)) & ".ts");
         begin
            Ada.Directories.Create_Path (MCP_Scratch);
            Emit_Native_TypeScript.Compile_To_File (Tree (Root), TS_Path);
            Put_Member (Result, "success", New_Bool (True));
            Put_Member (Result, "stage", New_Str ("ok"));
            Put_Member (Result, "ts_path", New_Str (TS_Path));
            Put_Member (Result, "ts",
                        New_Str (To_String (Read_File_Text (TS_Path))));
         exception
            when E : others =>
               Put_Member (Result, "success", New_Bool (False));
               Put_Member (Result, "stage", New_Str ("emit"));
               Put_Member (Result, "error",
                           New_Str (Ada.Exceptions.Exception_Message (E)));
         end;
      end Tool_Compile;

      ------------------------------------------------------------
      --  fixture ledger + build lock (parallel-agent arbitration)

      function Default_Tests_Dir return String is
         C : constant String := Ada.Directories.Compose ("albw", "tests");
      begin
         if Ada.Directories.Exists (C) then
            return C;
         elsif Ada.Environment_Variables.Exists ("ALB_WORKSPACE") then
            declare
               P : constant String := Ada.Directories.Compose
                 (Ada.Directories.Compose
                    (Ada.Environment_Variables.Value ("ALB_WORKSPACE"),
                     "albw"),
                  "tests");
            begin
               if Ada.Directories.Exists (P) then
                  return P;
               end if;
            end;
         end if;
         return C;  -- let the caller see the failure
      end Default_Tests_Dir;

      function Acquire_Lock (Lock_Path : String;
                             Retries   : Natural := 100) return Boolean is
         FD : File_Descriptor;
      begin
         for I in 1 .. Retries loop
            FD := Create_New_File (Lock_Path, GNAT.OS_Lib.Binary);
            if FD /= Invalid_FD then
               Close (FD);
               return True;
            end if;
            delay 0.05;
         end loop;
         return False;
      end Acquire_Lock;

      procedure Release_Lock (Lock_Path : String) is
      begin
         begin
            Ada.Directories.Delete_File (Lock_Path);
         exception
            when others => null;
         end;
      end Release_Lock;

      function Highest_Fixture_Number (Dir : String) return Natural is
         Highest : Natural := 0;
         Search  : Ada.Directories.Search_Type;
         Ent     : Ada.Directories.Directory_Entry_Type;
      begin
         Ada.Directories.Start_Search
           (Search, Dir, "*.alb",
            (Ada.Directories.Ordinary_File => True, others => False));
         while Ada.Directories.More_Entries (Search) loop
            Ada.Directories.Get_Next_Entry (Search, Ent);
            declare
               N  : constant String :=
                 Ada.Directories.Simple_Name (Ent);
               V  : Natural := 0;
               OK : Boolean := False;
            begin
               for I in N'Range loop
                  exit when N (I) not in '0' .. '9';
                  V := V * 10 + Character'Pos (N (I)) - Character'Pos ('0');
                  OK := True;
               end loop;
               if OK and then V > Highest then
                  Highest := V;
               end if;
            end;
         end loop;
         Ada.Directories.End_Search (Search);
         return Highest;
      exception
         when others =>
            return 0;
      end Highest_Fixture_Number;

      procedure Tool_Fixture_Claim (Args : J_Index; Result : J_Index) is
         Dir     : constant String := Default_Tests_Dir;
         Cnt     : constant Long_Long_Integer :=
           As_Integer (Member (Args, "count"));
         Agent   : constant String :=
           As_String (Member (Args, "agent"));
         Ledger  : constant String :=
           Ada.Directories.Compose (Dir, ".fixture_ledger.json");
         Lock    : constant String := Ledger & ".lock";
         High    : Natural;
         First_N : Natural;
         Led_Ok  : Boolean := False;
      begin
         if Cnt <= 0 or else Cnt > 500 then
            Put_Member (Result, "success", New_Bool (False));
            Put_Member (Result, "error",
                        New_Str ("count must be 1..500"));
            return;
         end if;
         if not Ada.Directories.Exists (Dir) then
            Put_Member (Result, "success", New_Bool (False));
            Put_Member (Result, "error",
                        New_Str ("tests dir not found: " & Dir));
            return;
         end if;
         if not Acquire_Lock (Lock) then
            Put_Member (Result, "success", New_Bool (False));
            Put_Member (Result, "error",
                        New_Str ("fixture ledger busy (lock held)"));
            return;
         end if;
         begin
            High := Highest_Fixture_Number (Dir);
            --  Fold in the ledger's high-water mark. Hand-scanned —
            --  ALB_JSON.Parse would clobber the live request DOM.
            if Path_Exists (Ledger) then
               declare
                  LT : constant String :=
                    To_String (Read_File_Text (Ledger));
                  HW_Key : constant String := """high_water"":";
                  P      : Natural := 0;
                  V      : Natural := 0;
                  Digits_Seen : Boolean := False;
               begin
                  P := Ada.Strings.Fixed.Index (LT, HW_Key);
                  if P > 0 then
                     P := P + HW_Key'Length;
                     while P <= LT'Last and then LT (P) in '0' .. '9' loop
                        V := V * 10 + Character'Pos (LT (P)) -
                          Character'Pos ('0');
                        Digits_Seen := True;
                        P := P + 1;
                     end loop;
                     if Digits_Seen and then V > High then
                        High := V;
                     end if;
                  end if;
               end;
            end if;

            First_N := High + 1;
            declare
               A : J_Index := New_Arr;
               F : Ada.Text_IO.File_Type;
               New_Claim : Unbounded_String := Null_Unbounded_String;
            begin
               --  Append the claim to the ledger by text rewrite:
               --  insert before the closing ']' of "claims".
               Append (New_Claim, "{""agent"":""");
               Escape
                 ((if Agent'Length > 0 then Agent else "unknown"),
                  New_Claim);
               Append (New_Claim,
                       """,""first"":" & Trim_Image (Integer (First_N)) &
                       ",""last"":" &
                       Trim_Image (Integer (First_N + Natural (Cnt) - 1)) &
                       "}");
               declare
                  LT       : constant String :=
                    (if Path_Exists (Ledger)
                     then To_String (Read_File_Text (Ledger))
                     else "{""claims"":[],""high_water"":0}");
                  Claims_At : constant Natural :=
                    Ada.Strings.Fixed.Index (LT, """claims"":[");
                  New_HW   : constant String :=
                    """high_water"":" &
                    Trim_Image (Integer (First_N + Natural (Cnt) - 1));
                  Body_Txt : Unbounded_String := Null_Unbounded_String;
               begin
                  --  Rebuild ledger text: claims array + new claim,
                  --  then rewritten high_water.
                  if Claims_At > 0 then
                     declare
                        Bracket : Natural := Claims_At + 9;
                     begin
                        while Bracket <= LT'Last
                          and then LT (Bracket) /= ']' loop
                           Bracket := Bracket + 1;
                        end loop;
                        if Bracket <= LT'Last then
                           Append (Body_Txt, LT (LT'First .. Bracket - 1));
                           if Bracket - 1 > Claims_At + 9
                             and then LT (Bracket - 1) /= '['
                             and then LT (Bracket - 1) /= ' '
                           then
                              Append (Body_Txt, ",");
                           end if;
                           Append (Body_Txt, To_String (New_Claim));
                           Append (Body_Txt, LT (Bracket .. LT'Last));
                        else
                           Append (Body_Txt, LT);
                        end if;
                     end;
                  else
                     Append (Body_Txt, LT);
                  end if;
                  --  Rewrite high_water.
                  declare
                     S : constant String := To_String (Body_Txt);
                     H : constant Natural :=
                       Ada.Strings.Fixed.Index (S, """high_water"":");
                  begin
                     if H > 0 then
                        declare
                           Tail : Natural := H + 13;
                           Txt  : Unbounded_String :=
                             To_Unbounded_String (S (S'First .. H - 1));
                        begin
                           while Tail <= S'Last
                             and then S (Tail) in '0' .. '9' loop
                              Tail := Tail + 1;
                           end loop;
                           Append (Txt, New_HW);
                           Append (Txt, S (Tail .. S'Last));
                           Ada.Text_IO.Create (F, Ada.Text_IO.Out_File,
                                               Ledger & ".tmp");
                           Ada.Text_IO.Put (F, To_String (Txt));
                           Ada.Text_IO.Close (F);
                        end;
                     else
                        Ada.Text_IO.Create (F, Ada.Text_IO.Out_File,
                                            Ledger & ".tmp");
                        Ada.Text_IO.Put (F, S);
                        Ada.Text_IO.Close (F);
                     end if;
                  end;
               end;
               if Path_Exists (Ledger) then
                  Ada.Directories.Delete_File (Ledger);
               end if;
               Ada.Directories.Rename (Ledger & ".tmp", Ledger);
               Led_Ok := True;

               for I in 0 .. Natural (Cnt) - 1 loop
                  Append_Child (A, New_Num (Long_Long_Integer (First_N + I)));
               end loop;
               Put_Member (Result, "success", New_Bool (True));
               Put_Member (Result, "dir", New_Str (Dir));
               Put_Member (Result, "first",
                           New_Num (Long_Long_Integer (First_N)));
               Put_Member (Result, "last",
                           New_Num (Long_Long_Integer
                             (First_N + Natural (Cnt) - 1)));
               Put_Member (Result, "claimed", A);
            end;
         exception
            when E : others =>
               Put_Member (Result, "success", New_Bool (False));
               Put_Member (Result, "error",
                           New_Str (Ada.Exceptions.Exception_Message (E)));
               if not Led_Ok then
                  begin
                     if Path_Exists (Ledger & ".tmp") then
                        Ada.Directories.Delete_File (Ledger & ".tmp");
                     end if;
                  exception
                     when others => null;
                  end;
               end if;
         end;
         Release_Lock (Lock);
      end Tool_Fixture_Claim;

      procedure Tool_Build_Driver (Args : J_Index; Result : J_Index) is
         Drv : constant String := As_String (Member (Args, "driver"));
         Repo : constant String :=
           (if Ada.Environment_Variables.Exists ("ALB_REPO_ROOT")
            then Ada.Environment_Variables.Value ("ALB_REPO_ROOT")
            else Ada.Directories.Current_Directory);
         Lock : constant String :=
           Ada.Directories.Compose
             (Ada.Directories.Compose (Repo, "obj"), ".build.lock");
         Gpr  : constant String :=
           (if Ada.Environment_Variables.Exists ("ALB_GPRBUILD")
            then Ada.Environment_Variables.Value ("ALB_GPRBUILD")
            else (if Path_Exists
                    ("H:\GNATSTUDIO\bin\AdaLogic_BASIC\release\deps\gprbuild_25.0.1\bin\gprbuild.exe")
                  then "H:\GNATSTUDIO\bin\AdaLogic_BASIC\release\deps\gprbuild_25.0.1\bin\gprbuild.exe"
                  else "gprbuild"));
      begin
         if Drv'Length = 0 or else Drv'Length > 64 then
            Put_Member (Result, "success", New_Bool (False));
            Put_Member (Result, "error", New_Str ("need 'driver' name"));
            return;
         end if;
         for Ch of Drv loop
            if not (Ch in 'a' .. 'z' or else Ch in 'A' .. 'Z' or else
                    Ch in '0' .. '9' or else Ch = '_' or else Ch = '-')
            then
               Put_Member (Result, "success", New_Bool (False));
               Put_Member (Result, "error",
                           New_Str ("driver name has illegal chars"));
               return;
            end if;
         end loop;
         if Ada.Environment_Variables.Exists ("ALB_GNAT_BIN") then
            declare
               GB : constant String :=
                 Ada.Environment_Variables.Value ("ALB_GNAT_BIN");
               P  : constant String :=
                 (if Ada.Environment_Variables.Exists ("PATH")
                  then Ada.Environment_Variables.Value ("PATH") else "");
            begin
               Ada.Environment_Variables.Set
                 ("PATH", GB & Path_Separator & P);
            end;
         end if;
         begin
            Ada.Directories.Create_Path
              (Ada.Directories.Compose (Repo, "obj"));
         exception
            when others => null;
         end;
         if not Acquire_Lock (Lock, Retries => 600) then
            Put_Member (Result, "success", New_Bool (False));
            Put_Member (Result, "error",
                        New_Str ("build lock held >30s by another agent"));
            return;
         end if;
         begin
            declare
               Log_Path : constant String :=
                 Ada.Directories.Compose
                   (Ada.Directories.Compose (Repo, "obj"),
                    "build_" & Drv & ".log");
               Arg_List : GNAT.OS_Lib.Argument_List (1 .. 4);
               Succ     : Boolean := False;
               Code     : Integer := -1;
               Log_Text : Unbounded_String;
            begin
               Arg_List (1) := new String'("-P");
               Arg_List (2) := new String'("adalogic_basic_dist.gpr");
               Arg_List (3) := new String'(Drv);
               Arg_List (4) := new String'("-p");
               Spawn (Gpr, Arg_List, Log_Path, Succ, Code);
               for A of Arg_List loop
                  Free (A);
               end loop;
               Log_Text := Read_File_Text (Log_Path);
               Put_Member (Result, "success", New_Bool (Code = 0));
               Put_Member (Result, "exit_code",
                           New_Num (Long_Long_Integer (Code)));
               Put_Member (Result, "driver", New_Str (Drv));
               declare
                  S : constant String := To_String (Log_Text);
                  K : constant Natural := S'Length;
               begin
                  Put_Member (Result, "log_tail",
                              New_Str (S ((if K > 4000 then K - 3999
                                           else S'First) .. K)));
               end;
            end;
         exception
            when E : others =>
               Put_Member (Result, "success", New_Bool (False));
               Put_Member (Result, "error",
                           New_Str (Ada.Exceptions.Exception_Message (E)));
         end;
         Release_Lock (Lock);
      end Tool_Build_Driver;

      ------------------------------------------------------------
      --  tool table

      function Tool_Registry return J_Index is
         A : J_Index := New_Arr;

         procedure Add (Name, Desc, Schema : String) is
            T : J_Index := New_Obj;
         begin
            Put_Member (T, "name", New_Str (Name));
            Put_Member (T, "description", New_Str (Desc));
            --  J_Raw: schema text passes through untouched — Parse would
            --  clobber the live request DOM mid-call.
            Put_Member (T, "inputSchema", New_Raw (Schema));
            Append_Child (A, T);
         end Add;

      begin
         Add ("alb.validate",
              "Tokenize + parse ALB source ('source' string or 'path' " &
              "file). Returns structured diagnostics " &
              "(line/col/code/severity/message), token count, AST root.",
              "{""type"":""object"",""properties"":{" &
              """source"":{""type"":""string""},""path"":{""type"":""string""}}}");
         Add ("alb.tokenize",
              "Lex ALB source into the full token stream: kind, byte " &
              "start, length, line, column, and raw text per token.",
              "{""type"":""object"",""properties"":{" &
              """source"":{""type"":""string""},""path"":{""type"":""string""}}}");
         Add ("alb.compile",
              "Full pipeline: weave + tokenize + parse + emit " &
              "TypeScript. Returns diagnostics and the emitted TS text " &
              "plus its scratch path.",
              "{""type"":""object"",""properties"":{" &
              """source"":{""type"":""string""},""path"":{""type"":""string""}}}");
         Add ("alb.fixture_claim",
              "Reserve the next free NNN fixture numbers in " &
              "albw/tests (ledger-backed, lock-arbitrated). Args: " &
              "count (1..500), agent (optional name).",
              "{""type"":""object"",""properties"":{" &
              """count"":{""type"":""integer""},""agent"":{""type"":""string""}}," &
              """required"":[""count""]}");
         Add ("albw.build_driver",
              "Serialized gprbuild of one compiler driver (albw, albt, " &
              "malbr, ...). Lock-arbitrated so parallel agents never " &
              "share obj/. Env: ALB_GPRBUILD, ALB_GNAT_BIN, ALB_REPO_ROOT.",
              "{""type"":""object"",""properties"":{" &
              """driver"":{""type"":""string""}},""required"":[""driver""]}");
         return A;
      end Tool_Registry;

      procedure Dispatch_Call (Name : String;
                               Args : J_Index;
                               Result : J_Index;
                               Is_Err : out Boolean) is
      begin
         Is_Err := False;
         if Name = "alb.validate" then
            Tool_Validate (Args, Result);
         elsif Name = "alb.tokenize" then
            Tool_Tokenize (Args, Result);
         elsif Name = "alb.compile" then
            Tool_Compile (Args, Result);
         elsif Name = "alb.fixture_claim" then
            Tool_Fixture_Claim (Args, Result);
         elsif Name = "albw.build_driver" then
            Tool_Build_Driver (Args, Result);
         else
            Is_Err := True;
            Put_Member (Result, "error",
                        New_Str ("unknown tool: " & Name));
         end if;
      exception
         when E : others =>
            Is_Err := True;
            Put_Member (Result, "success", New_Bool (False));
            Put_Member (Result, "error",
                        New_Str (Ada.Exceptions.Exception_Message (E)));
      end Dispatch_Call;

      ------------------------------------------------------------

      procedure Handle (Root_Node : J_Index) is
         Method   : constant String := As_String (Member (Root_Node, "method"));
         Id_Node  : J_Index := Member (Root_Node, "id");
         Params   : J_Index := Member (Root_Node, "params");
         Resp     : J_Index := New_Obj;
         Result   : J_Index;
         Err      : Boolean := False;
      begin
         Put_Member (Resp, "jsonrpc", New_Str ("2.0"));
         Put_Member (Resp, "id", (if Id_Node /= 0 then Id_Node
                                  else New_Str ("")));

         if Method = "initialize" then
            Result := New_Obj;
            declare
               PV : constant String :=
                 As_String (Member (Params, "protocolVersion"));
            begin
               Put_Member (Result, "protocolVersion",
                           New_Str ((if PV'Length > 0 then PV
                                     else "2024-11-05")));
            end;
            declare
               Caps : J_Index := New_Obj;
               Srv  : J_Index := New_Obj;
            begin
               Put_Member (Caps, "tools", New_Obj);
               Put_Member (Result, "capabilities", Caps);
               Put_Member (Srv, "name", New_Str ("albw"));
               Put_Member (Srv, "title",
                           New_Str ("ALBW compiler toolchain"));
               Put_Member (Srv, "version", New_Str ("0.1.0"));
               Put_Member (Result, "serverInfo", Srv);
            end;
            Put_Member (Resp, "result", Result);

         elsif Method = "ping" then
            Put_Member (Resp, "result", New_Obj);

         elsif Method = "shutdown" then
            Put_Member (Resp, "result", New_Obj);

         elsif Method = "tools/list" then
            Result := New_Obj;
            Put_Member (Result, "tools", Tool_Registry);
            Put_Member (Resp, "result", Result);

         elsif Method = "tools/call" then
            declare
               TName : constant String :=
                 As_String (Member (Params, "name"));
               TArgs : J_Index := Member (Params, "arguments");
               Inner : J_Index := New_Obj;
               Cont  : J_Index := New_Arr;
               Item  : J_Index := New_Obj;
               ToolR : J_Index := New_Obj;
            begin
               if TArgs = 0 or else Kind (TArgs) /= J_Obj then
                  TArgs := New_Obj;
               end if;
               Dispatch_Call (TName, TArgs, ToolR, Err);
               Put_Member (Item, "type", New_Str ("text"));
               Put_Member (Item, "text", New_Str (Serialize (ToolR)));
               Append_Child (Cont, Item);
               Put_Member (Inner, "content", Cont);
               Put_Member (Inner, "structuredContent", ToolR);
               if Err then
                  Put_Member (Inner, "isError", New_Bool (True));
               end if;
               Put_Member (Resp, "result", Inner);
            end;

         elsif Id_Node /= 0 then
            declare
               EO : J_Index := New_Obj;
            begin
               Put_Member (EO, "code", New_Num (-32601));
               Put_Member (EO, "message",
                           New_Str ("method not found: " & Method));
               Put_Member (Resp, "error", EO);
            end;
         else
            null;  -- notification with no id: no response
         end if;

         if Id_Node /= 0 then
            Respond (Serialize (Resp));
         end if;
      end Handle;

      Msg   : Unbounded_String;
      EOF   : Boolean;
      JRoot : J_Index;

   begin
      --  Everything that isn't a protocol response goes to stderr.
      Ada.Text_IO.Set_Output (Ada.Text_IO.Standard_Error);
      loop
         Msg := Read_Message (EOF);
         if EOF then
            exit when Length (Msg) = 0;
         end if;
         if Length (Msg) > 0 then
            JRoot := ALB_JSON.Parse (To_String (Msg));
            if JRoot = 0 then
               declare
                  Resp : J_Index := New_Obj;
                  EO   : J_Index := New_Obj;
               begin
                  Put_Member (Resp, "jsonrpc", New_Str ("2.0"));
                  Put_Member (Resp, "id", New_Str (""));
                  Put_Member (EO, "code", New_Num (-32700));
                  Put_Member (EO, "message",
                              New_Str (To_String (Parse_Error)));
                  Put_Member (Resp, "error", EO);
                  Respond (Serialize (Resp));
               end;
            else
               declare
                  M : constant String :=
                    As_String (Member (JRoot, "method"));
               begin
                  if M = "exit" then
                     exit;
                  elsif M = "notifications/initialized"
                    or else M = "initialized"
                  then
                     null;
                  else
                     Handle (JRoot);
                  end if;
               end;
            end if;
         end if;
         exit when EOF;
      end loop;
   end Run_MCP;

   procedure Parse_Args is
      Skip_Next : Boolean := False;
   begin
      for I in 1 .. Ada.Command_Line.Argument_Count loop
         if Skip_Next then
            Skip_Next := False;
         else
            declare
               Arg : constant String := Ada.Command_Line.Argument (I);
            begin
               if Arg = "-o" then
                  if I < Ada.Command_Line.Argument_Count then
                     declare
                        N : constant String := Ada.Command_Line.Argument (I + 1);
                     begin
                        Output_Len := N'Length;
                        Output_File (1 .. Output_Len) := N;
                     end;
                     Skip_Next := True;
                  else
                     Put_Line ("ALBW: '-o' requires a filename.");
                     return;
                  end if;
               elsif Arg = "--outdir" then
                  if I < Ada.Command_Line.Argument_Count then
                     declare
                        N : constant String := Ada.Command_Line.Argument (I + 1);
                     begin
                        Out_Dir_Len := N'Length;
                        Out_Dir (1 .. Out_Dir_Len) := N;
                     end;
                     Skip_Next := True;
                  else
                     Put_Line ("ALBW: '--outdir' requires a directory.");
                     return;
                  end if;
               elsif Arg = "--metrics" or else Arg = "-m" then
                  Metrics_Mode := True;
               elsif Arg = "--walker" or else Arg = "-w" then
                  Walker_Mode := True;
               elsif Arg = "--quiet" or else Arg = "-q" then
                  Quiet_Mode := True;
               elsif Arg = "--tsc" then
                  TSC_Mode := True;
               elsif Arg = "--mcp" then
                  MCP_Mode := True;
               elsif Arg = "--rt-trim" or else Arg = "--rt-trim=on" then
                  Rt_Trim_Mode := True;
               elsif Arg = "--rt-trim=off" or else Arg = "--no-rt-trim" then
                  Rt_Trim_Mode := False;
               elsif Arg'Length > 10
                 and then Arg (Arg'First .. Arg'First + 9) = "--rt-keep="
               then
                  if Rt_Keep_Arg_N < Max_Rt_Keep_Args then
                     Rt_Keep_Arg_N := Rt_Keep_Arg_N + 1;
                     Rt_Keep_Args (Rt_Keep_Arg_N) :=
                       Ada.Strings.Unbounded.To_Unbounded_String
                         (Arg (Arg'First + 10 .. Arg'Last));
                  end if;
               elsif Arg = "--target" then
                  if I < Ada.Command_Line.Argument_Count then
                     declare
                        N : constant String := Ada.Command_Line.Argument (I + 1);
                     begin
                        TS_Target_Len := N'Length;
                        TS_Target (1 .. TS_Target_Len) := N;
                     end;
                     Skip_Next := True;
                  else
                     Put_Line ("ALBW: '--target' requires a version (es5, es2020, esnext).");
                     return;
                  end if;
               elsif Arg = "--build" or else Arg = "-b" then
                  Build_Mode := True;
                  TSC_Mode := True;
               elsif Arg = "--library" or else Arg = "-l" then
                  Library_Mode := True;
                  Build_Mode := True;
                  TSC_Mode := True;
               elsif Arg = "--help" or else Arg = "-h" then
                  Print_Help;
                  return;
               elsif Arg'Length > 0 and then Arg (Arg'First) = '-' then
                  Put_Line ("ALBW: unknown option " & Arg);
                  return;
               else
                  if Source_Len = 0 then
                     Source_Len := Arg'Length;
                     Source_File (1 .. Source_Len) := Arg;
                  elsif Output_Len = 0 then
                     Output_Len := Arg'Length;
                     Output_File (1 .. Output_Len) := Arg;
                  else
                     Put_Line ("ALBW: unexpected extra argument " & Arg);
                     return;
                  end if;
               end if;
            end;
         end if;
      end loop;
   end Parse_Args;

    TS_Path       : String (1 .. Max_Path_Len) := (others => ' ');
   TS_Len        : Natural := 0;
   JS_Path       : String (1 .. Max_Path_Len) := (others => ' ');
   JS_Len        : Natural := 0;
   Final_Dir     : String (1 .. Max_Path_Len) := (others => ' ');
   Final_Dir_Len : Natural := 0;
   Final_Title   : String (1 .. Max_Path_Len) := (others => ' ');
   Final_Title_Len : Natural := 0;
   Success       : Boolean := True;

   --  BRAILLE / NEMETH prescan results (see Prescan_For_Raw_Blocks).
   Want_Braille    : Boolean := False;
   Want_Nemeth     : Boolean := False;
   Src_Has_Ueb_Inc : Boolean := False;
   Src_Has_Nem_Inc : Boolean := False;
   Src_Has_Imp_Ueb : Boolean := False;
   Src_Has_Imp_Nem : Boolean := False;

begin
   Parse_Args;

   if MCP_Mode then
      Run_MCP;
      return;
   end if;

   if Source_Len = 0 then
      Put_Line ("ALBW: no input file specified.");
      Print_Help;
      return;
   end if;

   declare
      T : constant String := Base_Name (Source_File (1 .. Source_Len));
   begin
      Final_Title_Len := T'Length;
      Final_Title (1 .. Final_Title_Len) := T;
   end;

   -- Determine output .ts path
   if Output_Len = 0 then
      if Build_Mode then
         if Out_Dir_Len = 0 then
            Out_Dir_Len := Default_Out_Dir (Source_File (1 .. Source_Len))'Length;
            Out_Dir (1 .. Out_Dir_Len) := Default_Out_Dir (Source_File (1 .. Source_Len));
         end if;
         Final_Dir_Len := Out_Dir_Len;
         Final_Dir (1 .. Final_Dir_Len) := Out_Dir (1 .. Out_Dir_Len);
         declare
            N : constant String := Ada.Directories.Compose
              (Final_Dir (1 .. Final_Dir_Len), Default_Output_Name (Source_File (1 .. Source_Len)));
         begin
            TS_Len := N'Length;
            TS_Path (1 .. TS_Len) := N;
         end;
      else
         if Out_Dir_Len > 0 then
            declare
               N : constant String := Ada.Directories.Compose
                 (Out_Dir (1 .. Out_Dir_Len),
                  Default_Output_Name (Source_File (1 .. Source_Len)));
            begin
               TS_Len := N'Length;
               TS_Path (1 .. TS_Len) := N;
               Final_Dir_Len := Out_Dir_Len;
               Final_Dir (1 .. Final_Dir_Len) := Out_Dir (1 .. Out_Dir_Len);
            end;
         else
            declare
               N : constant String := Default_Output_Name (Source_File (1 .. Source_Len));
            begin
               TS_Len := N'Length;
               TS_Path (1 .. TS_Len) := N;
            end;
         end if;
      end if;
   else
      --  Relative -o names must always land under --outdir when set.
      --  Do not trust Containing_Directory("") / "." quirks for bare filenames.
      declare
         Has_Dir_Sep : Boolean := False;
      begin
         for I in 1 .. Output_Len loop
            if Output_File (I) = '\' or else Output_File (I) = '/' then
               Has_Dir_Sep := True;
               exit;
            end if;
         end loop;

         if Out_Dir_Len > 0 and then not Has_Dir_Sep then
            declare
               N : constant String := Ada.Directories.Compose
                 (Out_Dir (1 .. Out_Dir_Len),
                  Output_File (1 .. Output_Len));
            begin
               TS_Len := N'Length;
               TS_Path (1 .. TS_Len) := N;
               Final_Dir_Len := Out_Dir_Len;
               Final_Dir (1 .. Final_Dir_Len) := Out_Dir (1 .. Out_Dir_Len);
            end;
         elsif Out_Dir_Len > 0
           and then Ada.Directories.Containing_Directory (Output_File (1 .. Output_Len)) = ""
         then
            declare
               N : constant String := Ada.Directories.Compose
                 (Out_Dir (1 .. Out_Dir_Len),
                  Output_File (1 .. Output_Len));
            begin
               TS_Len := N'Length;
               TS_Path (1 .. TS_Len) := N;
               Final_Dir_Len := Out_Dir_Len;
               Final_Dir (1 .. Final_Dir_Len) := Out_Dir (1 .. Out_Dir_Len);
            end;
         else
            TS_Len := Output_Len;
            TS_Path (1 .. TS_Len) := Output_File (1 .. Output_Len);
            if Ada.Directories.Containing_Directory (TS_Path (1 .. TS_Len))'Length > 0 then
               Final_Dir_Len := Ada.Directories.Containing_Directory (TS_Path (1 .. TS_Len))'Length;
               Final_Dir (1 .. Final_Dir_Len) :=
                 Ada.Directories.Containing_Directory (TS_Path (1 .. TS_Len));
            elsif Build_Mode and Out_Dir_Len = 0 then
               Final_Dir_Len := Default_Out_Dir (Source_File (1 .. Source_Len))'Length;
               Final_Dir (1 .. Final_Dir_Len) := Default_Out_Dir (Source_File (1 .. Source_Len));
            elsif Out_Dir_Len > 0 then
               Final_Dir_Len := Out_Dir_Len;
               Final_Dir (1 .. Final_Dir_Len) := Out_Dir (1 .. Out_Dir_Len);
            end if;
         end if;
      end;
   end if;

   -- Determine the JS path (for tsc output)
   if Build_Mode or TSC_Mode then
      declare
         TS_Base : constant String := Base_Name (TS_Path (1 .. TS_Len));
         JS_Name : constant String := TS_Base & ".js";
      begin
         if Final_Dir_Len > 0 then
            declare
               N : constant String := Ada.Directories.Compose
                 (Final_Dir (1 .. Final_Dir_Len), JS_Name);
            begin
               JS_Len := N'Length;
               JS_Path (1 .. JS_Len) := N;
            end;
         else
            JS_Len := JS_Name'Length;
            JS_Path (1 .. JS_Len) := JS_Name;
         end if;
      end;
   end if;

   Log ("ALBW: transpiling " & Source_File (1 .. Source_Len));

   Input_Buffer := (others => ' ');
   Temp_Buffer := (others => ' ');
   Tokens := (others => (Kind => Tok_Error, Start => 1, Length => 0, Line => 1, Column => 1));
   Tree := (others => (Kind => AST_Null, Token_Index => 0, Left_Child => 0, Right_Child => 0, Next_Sibling => 0));

   --  BRAILLE / NEMETH raw blocks: when the source opens one, weave
   --  the matching transcription engine BEFORE the user file so its
   --  module decls precede user code, then inject the IMPORT line so
   --  Ueb.* / Nemeth.* accessors resolve.  An explicit user INCLUDE of
   --  the engine suppresses the auto-weave (the include vault would
   --  dedup a second weave to the same resolved path anyway).
   Prescan_For_Raw_Blocks
     (Source_File (1 .. Source_Len),
      Want_Braille, Want_Nemeth,
      Src_Has_Ueb_Inc, Src_Has_Nem_Inc,
      Src_Has_Imp_Ueb, Src_Has_Imp_Nem);

   if Success and then Want_Nemeth and then not Src_Has_Nem_Inc then
      declare
         Eng : constant String := Resolve_Local_Asset_Path
           ("nemeth.albi",
            Parent_Directory (Source_File (1 .. Source_Len)));
      begin
         if Eng'Length = 0 then
            Put_Line
              ("ALBW: NEMETH block requires nemeth.albi - " &
               "place it beside the source or on ALB_LIB");
            Success := False;
         else
            Nemeth_Engine_Woven := True;
            Weave_File (Eng, Success);
         end if;
      end;
   end if;

   if Success and then Want_Braille and then not Src_Has_Ueb_Inc then
      declare
         Eng : constant String := Resolve_Local_Asset_Path
           ("ueb.albi",
            Parent_Directory (Source_File (1 .. Source_Len)));
      begin
         if Eng'Length = 0 then
            Put_Line
              ("ALBW: BRAILLE block requires ueb.albi - " &
               "place it beside the source or on ALB_LIB");
            Success := False;
         else
            Ueb_Engine_Woven := True;
            Weave_File (Eng, Success);
         end if;
      end;
   end if;

   if Success and then Want_Nemeth and then not Src_Has_Imp_Nem then
      Append_Source ("IMPORT NEMETH" & ASCII.LF, Success);
   end if;
   if Success and then Want_Braille and then not Src_Has_Imp_Ueb then
      Append_Source ("IMPORT UEB" & ASCII.LF, Success);
   end if;

   Weave_File (Source_File (1 .. Source_Len), Success);

   --  A BRAILLE / NEMETH block seen only inside an included file
   --  escapes the prescan; fail loudly rather than emit a call to a
   --  transcription routine that does not exist in the output.
   if Success then
      if Braille_Block_Seen and then not Ueb_Engine_Woven then
         Put_Line
           ("ALBW: BRAILLE block used but the ueb engine was not " &
            "woven - add INCLUDE ""ueb.albi"" or set ALB_LIB");
         Success := False;
      elsif Nemeth_Block_Seen and then not Nemeth_Engine_Woven then
         Put_Line
           ("ALBW: NEMETH block used but the nemeth engine was not " &
            "woven - add INCLUDE ""nemeth.albi"" or set ALB_LIB");
         Success := False;
      end if;
   end if;
   if not Success or else Input_Len = 0 then
      Put_Line
        ("ALBW: failed to read or weave source file. success=" &
         Boolean'Image (Success) &
         " input_len=" &
         Trim_Image (Integer (Input_Len)) &
         " includes=" &
         Trim_Image (Integer (Include_Count)));
      return;
   end if;

   Tokenize
     (Input_Buffer (1 .. Input_Len),
      Tokens,
      Token_Count,
      Lex_Diag);

   if not Lex_Diag.Success then
      Put_Line
        ("ALBW lexer error at " &
         Trim_Image (Integer (Lex_Diag.Error_Line)) &
         ":" &
         Trim_Image (Integer (Lex_Diag.Error_Col)) &
         " " & Oracle_Text (Lex_Diag.Code));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   end if;

   Parse
     (Tokens,
      Token_Count,
      Tree,
      Root,
      Parse_Success,
      Parse_Diag);

   if not Parse_Success or else not Parse_Diag.Success or else Root = 0 then
      Put_Line
        ("ALBW parser error at " &
         Trim_Image (Integer (Parse_Diag.Error_Line)) &
         ":" &
         Trim_Image (Integer (Parse_Diag.Error_Col)) &
         ": " & Oracle_Text (Parse_Diag.Code));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   end if;

   --  Panic-mode statement recovery can mark the parse "successful" while
   --  still recording errors (dropped statements = wrong program = unsafe
   --  to emit).  Report them all and fail on any Fatal — same rule as MALBR.
   if Parse_Diag.Error_Count > 0 then
      declare
         Fatal_Seen : Boolean := False;
      begin
         for I in 1 .. Parse_Diag.Error_Count loop
            declare
               E : constant Error_Record := Parse_Diag.Errors (I);
            begin
               Put_Line
                 ("ALBW " &
                  (if E.Severity = Fatal then "error" else "warning") &
                  " at line " & Trim_Image (E.Line) &
                  ", col " & Trim_Image (E.Col) &
                  ": " & Oracle_Text (E.Code));
               if E.Severity = Fatal then
                  Fatal_Seen := True;
               end if;
            end;
         end loop;
         if Fatal_Seen then
            Put_Line ("ALBW: aborting — parse recovery dropped statements");
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
            return;
         end if;
      end;
   end if;

   Module_Aware_Output := False;
   Stage_Asset_Count := 0;
   if Root > 0 then
      Scan_Web_Features (Root);
   end if;
   if Library_Mode then
      --  Shared-library packages must compile as ES modules even if the
      --  feature scan somehow missed EXPORT_ES / EXPORT_WASM nodes.
      Module_Aware_Output := True;
   end if;

   if Walker_Mode then
      Print_Walker_Info;
   end if;

    if Final_Dir_Len > 0 then
       begin
          Ada.Directories.Create_Path (Final_Dir (1 .. Final_Dir_Len));
       exception
          when E : others =>
             Put_Line ("ALBW: could not create output directory: " &
               Ada.Exceptions.Exception_Message (E));
             return;
       end;
   end if;

    -- Build mode: generate tsconfig
    if Build_Mode then
       declare
          TS_Base : constant String := Base_Name (TS_Path (1 .. TS_Len));
          JS_Name : constant String := TS_Base & ".js";
          Targ    : String (1 .. TS_Target_Len) := TS_Target (1 .. TS_Target_Len);
       begin
          Write_Tsconfig
            (Final_Dir (1 .. Final_Dir_Len),
             TS_Base & ".ts",
             JS_Name,
             Targ (1 .. TS_Target_Len),
             Module_Aware_Output);
       end;
    end if;

    if Source_Wants_No_Console then
       Emit_Native_TypeScript.Set_No_Console_Overlay (True);
    end if;
    Emit_Native_TypeScript.Set_Rt_Trim (Rt_Trim_Mode);
    Emit_Native_TypeScript.Clear_Rt_Keep;
    for K in 1 .. Rt_Keep_Arg_N loop
       Emit_Native_TypeScript.Add_Rt_Keep (Ada.Strings.Unbounded.To_String (Rt_Keep_Args (K)));
    end loop;

    Emit_Native_TypeScript.Compile_To_File (Tree (Root), TS_Path (1 .. TS_Len));
   Log ("ALBW: emitted " & TS_Path (1 .. TS_Len));

   -- Metrics requested: scan all included files
   if Metrics_Mode then
      Code_Information.Reset_Metrics;
      for I in 1 .. Include_Count loop
         Code_Information.Scan_Target (Include_Vault (I) (1 .. Include_Lens (I)));
      end loop;
      Code_Information.Print_Metrics;
   end if;

   -- tsc mode: compile .ts to .js
   if TSC_Mode then
      declare
         TSC_Args : Arg_List (1 .. 5);
         Arg_Idx  : Positive := 1;
         TSC_OK   : Boolean;
      begin
         TSC_Args (Arg_Idx) := new String'("--project");
         Arg_Idx := Arg_Idx + 1;

         if Final_Dir_Len > 0 then
            declare
               Config_Path : constant String :=
                 Ada.Directories.Compose (Final_Dir (1 .. Final_Dir_Len), "tsconfig.json");
            begin
               TSC_Args (Arg_Idx) := new String'(Config_Path);
               Arg_Idx := Arg_Idx + 1;
            end;
         else
            TSC_Args (Arg_Idx) := new String'("tsconfig.json");
            Arg_Idx := Arg_Idx + 1;
         end if;

         Log ("ALBW: running tsc...");
         TSC_OK := Spawn_And_Check (Ada.Directories.Current_Directory, "tsc",
           TSC_Args (1 .. Arg_Idx - 1));
         Free (TSC_Args);

         if not TSC_OK then
            Put_Line ("ALBW: tsc compilation failed.");
            Exit_Failed := True;
            return;
         end if;
         Log ("ALBW: tsc ok");
      end;
   end if;

   if Build_Mode and then Final_Dir_Len > 0 and then Stage_Asset_Count > 0 then
      Copy_Stage_Assets (Final_Dir (1 .. Final_Dir_Len));
   end if;

   -- Build mode: generate index.html (skipped for --library shared modules)
   if Build_Mode and then not Library_Mode then
      declare
         JS_Name : constant String := Base_Name (TS_Path (1 .. TS_Len)) & ".js";
      begin
          Write_Index_HTML
            (Final_Dir (1 .. Final_Dir_Len),
             Final_Title (1 .. Final_Title_Len),
             JS_Name,
             Module_Aware_Output,
             Source_Wants_Document_Shell);
         Log ("ALBW: wrote " &
           Ada.Directories.Compose (Final_Dir (1 .. Final_Dir_Len), "index.html"));
      end;
   elsif Library_Mode then
      Log ("ALBW: library mode — skipped index.html");
   end if;

   Log ("ALBW: done.");

   if Exit_Failed then
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;

exception
   when E : others =>
      Put_Line ("ALBW fatal: " & Ada.Exceptions.Exception_Message (E));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
end ALBW;

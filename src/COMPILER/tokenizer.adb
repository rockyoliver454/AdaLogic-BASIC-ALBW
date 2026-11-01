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

with range_spec; use range_spec;

package body Tokenizer is

   --  Core scanner.  Callers may pass a slice of the real source so
   --  token Start/Length stay real coordinates; Seed_Line/Seed_Col
   --  anchor diagnostics; Measure counts tokens without writing them
   --  (used by the interpolation pass to size a splice before moving).
   procedure Scan (Input       : in String;
                   Tokens      : out Token_Array;
                   Token_Count : in out Natural;
                   Diagnostic  : in out Lexer_Diagnostic;
                   Seed_Line   : in Positive := 1;
                   Seed_Col    : in Positive := 1;
                   Measure     : in Boolean := False) is
      I          : Positive := Input'First;
      Curr_Line  : Positive := Seed_Line;
      Curr_Col   : Positive := Seed_Col;
      Token_Line : Positive := 1;
      Token_Col  : Positive := 1;
      C          : Character;
      Len        : Natural;
      Closed     : Boolean;

      -- Inject the precise Oracle Case Code
      procedure Set_Error (Code : Oracle_Code; Err_L, Err_C : Positive) is
      begin
         if not Diagnostic.Success then return; end if; 
         Diagnostic.Success := False;
         Diagnostic.Error_Line := Err_L;
         Diagnostic.Error_Col  := Err_C;
         Diagnostic.Code       := Code;
      end Set_Error;

      procedure Commit_Token (K : Token_Kind; L : Natural) is
      begin
         if Token_Count < Max_Tokens then
            Token_Count := Token_Count + 1;
            if not Measure then
               Tokens(Token_Count) := (Kind => K, Start => I, Length => L, Line => Token_Line, Column => Token_Col);
            end if;
         else
            Set_Error (Err_Mem_Out_Of_Bounds, Token_Line, Token_Col);
         end if;

         -- DA FIX 1: Dynamic bounds for infinite scaling! (No mair 4096 hard cap)
         if L > 0 then
            for Offset in 0 .. L - 1 loop
               if I + Offset <= Input'Last then
                  if Input(I + Offset) = ASCII.LF then
                     Curr_Line := Curr_Line + 1; Curr_Col  := 1;
                  else
                     Curr_Col := Curr_Col + 1;
                  end if;
               end if;
            end loop;
         end if;
         I := I + L;
      end Commit_Token;
      
      function Upper (Ch : Character) return Character is
      begin
         if Ch >= 'a' and Ch <= 'z' then
            return Character'Val (Character'Pos (Ch) - 32);
         else
            return Ch;
         end if;
      end Upper;

      function Is_Ident_Char (Ch : Character) return Boolean is
      begin
         return (Ch >= 'A' and Ch <= 'Z') or else
                (Ch >= 'a' and Ch <= 'z') or else
                (Ch >= '0' and Ch <= '9') or else
                Ch = '_' or else Ch = '$';
      end Is_Ident_Char;

      function Scan_Number_Length
        (Start_At : Positive) return Natural
      is
         J             : Natural := Start_At;
         Seen_Digit    : Boolean := False;
         Seen_Dot      : Boolean := False;
         Seen_Exponent : Boolean := False;
      begin
         while J <= Input'Last loop
            if Input (J) in '0' .. '9' then
               Seen_Digit := True;
               J := J + 1;
            elsif Input (J) = '_' then
               if J = Start_At
                 or else J = Input'Last
                 or else Input (J - 1) not in '0' .. '9'
                 or else Input (J + 1) not in '0' .. '9'
               then
                  exit;
               end if;
               J := J + 1;
            elsif Input (J) = '.'
              and then not Seen_Dot
              and then not Seen_Exponent
              and then J < Input'Last
              and then Input (J + 1) in '0' .. '9'
            then
               Seen_Dot := True;
               J := J + 1;
            elsif (Input (J) = 'e' or else Input (J) = 'E')
              and then not Seen_Exponent
              and then Seen_Digit
            then
               declare
                  Exp_Pos : Natural := J + 1;
               begin
                  if Exp_Pos <= Input'Last
                    and then Input (Exp_Pos) in '+' | '-'
                  then
                     Exp_Pos := Exp_Pos + 1;
                  end if;

                  if Exp_Pos > Input'Last
                    or else Input (Exp_Pos) not in '0' .. '9'
                  then
                     exit;
                  end if;
               end;

               Seen_Exponent := True;
               J := J + 1;
               if J <= Input'Last and then Input (J) in '+' | '-' then
                  J := J + 1;
               end if;
            else
               exit;
            end if;
         end loop;

         return J - Start_At;
      end Scan_Number_Length;

      function Follows_Power_Operator
        (After_Pos : Natural) return Boolean
      is
         J : Natural := After_Pos;
      begin
         while J <= Input'Last
           and then
             (Input (J) = ' '
              or else Input (J) = ASCII.HT
              or else Input (J) = ASCII.CR)
         loop
            J := J + 1;
         end loop;

         return J <= Input'Last
           and then
             (Input (J) = '^'
              or else
                (Input (J) = '*'
                 and then J < Input'Last
                 and then Input (J + 1) = '*'));
      end Follows_Power_Operator;

      function Is_End_ASM_Line
        (Line_Start : Positive;
         Line_End   : Natural) return Boolean
      is
         P : Natural := Line_Start;

         function Is_Blank (Ch : Character) return Boolean is
         begin
            return Ch = ' ' or else Ch = ASCII.HT or else Ch = ASCII.CR;
         end Is_Blank;
      begin
         while P <= Line_End and then Is_Blank (Input (P)) loop
            P := P + 1;
         end loop;

         if P + 2 > Line_End then
            return False;
         end if;

         if Upper (Input (P)) /= 'E' or else
            Upper (Input (P + 1)) /= 'N' or else
            Upper (Input (P + 2)) /= 'D'
         then
            return False;
         end if;

         P := P + 3;

         if P > Line_End or else
           not (Input (P) = ' ' or else Input (P) = ASCII.HT)
         then
            return False;
         end if;

         while P <= Line_End and then
           (Input (P) = ' ' or else Input (P) = ASCII.HT)
         loop
            P := P + 1;
         end loop;

         if P + 2 > Line_End then
            return False;
         end if;

         if Upper (Input (P)) /= 'A' or else
            Upper (Input (P + 1)) /= 'S' or else
            Upper (Input (P + 2)) /= 'M'
         then
            return False;
         end if;

         P := P + 3;

         while P <= Line_End and then Is_Blank (Input (P)) loop
            P := P + 1;
         end loop;

         return P > Line_End;
      end Is_End_ASM_Line;

      function Is_End_ENABLE_Line
        (Line_Start : Positive;
         Line_End   : Natural) return Boolean
      is
         P : Natural := Line_Start;

         function Is_Blank (Ch : Character) return Boolean is
         begin
            return Ch = ' ' or else Ch = ASCII.HT or else Ch = ASCII.CR;
         end Is_Blank;
      begin
         while P <= Line_End and then Is_Blank (Input (P)) loop
            P := P + 1;
         end loop;

         if P + 2 > Line_End then
            return False;
         end if;

         if Upper (Input (P)) /= 'E' or else
            Upper (Input (P + 1)) /= 'N' or else
            Upper (Input (P + 2)) /= 'D'
         then
            return False;
         end if;

         P := P + 3;

         if P > Line_End or else
           not (Input (P) = ' ' or else Input (P) = ASCII.HT)
         then
            return False;
         end if;

         while P <= Line_End and then
           (Input (P) = ' ' or else Input (P) = ASCII.HT)
         loop
            P := P + 1;
         end loop;

         if P + 5 > Line_End then
            return False;
         end if;

         if Upper (Input (P)) /= 'E' or else
            Upper (Input (P + 1)) /= 'N' or else
            Upper (Input (P + 2)) /= 'A' or else
            Upper (Input (P + 3)) /= 'B' or else
            Upper (Input (P + 4)) /= 'L' or else
            Upper (Input (P + 5)) /= 'E'
         then
            return False;
         end if;

         P := P + 6;

         while P <= Line_End and then Is_Blank (Input (P)) loop
            P := P + 1;
         end loop;

         return P > Line_End;
      end Is_End_ENABLE_Line;


      procedure Scan_ASM_Block
        (Start_Pos : Positive;
         Block_Len : out Natural;
         Found     : out Boolean)
      is
         P          : Natural := Start_Pos;
         Line_Start : Positive := Start_Pos;
         Line_End   : Natural := Start_Pos;
      begin
         Found := False;
         Block_Len := 0;

         while P <= Input'Last loop
            Line_Start := Positive (P);

            while P <= Input'Last and then Input (P) /= ASCII.LF loop
               P := P + 1;
            end loop;

            Line_End := P - 1;

            if Line_Start > Start_Pos and then
               Is_End_ASM_Line (Line_Start, Line_End)
            then
               if P <= Input'Last and then Input (P) = ASCII.LF then
                  Block_Len := P - Start_Pos + 1;
               else
                  Block_Len := P - Start_Pos;
               end if;

               Found := True;
               return;
            end if;

            if P <= Input'Last and then Input (P) = ASCII.LF then
               P := P + 1;
            end if;
         end loop;

         Block_Len := Input'Last - Start_Pos + 1;
      end Scan_ASM_Block;

      procedure Scan_Java_Block
        (Start_Pos : Positive;
         Block_Len : out Natural;
         Found     : out Boolean)
      is
         P          : Natural := Start_Pos;
         Line_Start : Positive := Start_Pos;
         Line_End   : Natural := Start_Pos;
      begin
         Found := False;
         Block_Len := 0;

         while P <= Input'Last loop
            Line_Start := Positive (P);

            while P <= Input'Last and then Input (P) /= ASCII.LF loop
               P := P + 1;
            end loop;

            Line_End := P - 1;

            if Line_Start > Start_Pos and then
               Is_End_ENABLE_Line (Line_Start, Line_End)
            then
               if P <= Input'Last and then Input (P) = ASCII.LF then
                  Block_Len := P - Start_Pos + 1;
               else
                  Block_Len := P - Start_Pos;
               end if;

               Found := True;
               return;
            end if;

            if P <= Input'Last and then Input (P) = ASCII.LF then
               P := P + 1;
            end if;
         end loop;

         Block_Len := Input'Last - Start_Pos + 1;
      end Scan_Java_Block;

      --  BRAILLE / NEMETH raw data blocks.  The opener keyword must be
      --  the only non-blank content on its line (a trailing -- comment
      --  is allowed) and must sit at the start of a line, so `braille`
      --  and `nemeth` remain legal identifiers everywhere else.  The
      --  terminator is a line holding only END <WORD> or the glued
      --  END<WORD> form, matched case-insensitively.  A bare END line
      --  does NOT close the block — it stays verbatim content and can
      --  never collide with an outer BEGIN .. END closer.

      function At_Line_Start (Pos : Natural) return Boolean is
         P : Natural := Pos;
      begin
         while P > Input'First loop
            exit when Input (P - 1) = ASCII.LF;
            if Input (P - 1) /= ' ' and then
               Input (P - 1) /= ASCII.HT and then
               Input (P - 1) /= ASCII.CR
            then
               return False;
            end if;
            P := P - 1;
         end loop;
         return True;
      end At_Line_Start;

      --  Opener tail for a BRAILLE / NEMETH block: after the keyword the
      --  line may carry optional tail words — `G1` (BRAILLE only),
      --  `VERIFY`, `OUT "<path>"`, `AS <ident>` — in any order, then
      --  nothing but blanks or a -- comment.  The whole opener line
      --  lives inside the token span so the emitter can read the
      --  flags/name back out — the lexer only needs to validate the
      --  shape.
      function Block_Opener_Ok
        (After_Pos : Natural;
         Allow_G1  : Boolean) return Boolean
      is
         P : Natural := After_Pos;

         procedure Skip_Blanks is
         begin
            while P <= Input'Last and then
              (Input (P) = ' ' or else Input (P) = ASCII.HT)
            loop
               P := P + 1;
            end loop;
         end Skip_Blanks;

         function Ident_At (Word : String) return Boolean is
         begin
            if P + Word'Length - 1 > Input'Last then
               return False;
            end if;
            for K in Word'Range loop
               if Upper (Input (P + (K - Word'First))) /= Word (K) then
                  return False;
               end if;
            end loop;
            return P + Word'Length > Input'Last
              or else not Is_Ident_Char (Input (P + Word'Length));
         end Ident_At;

         function Take_Ident return Boolean is
         begin
            if P > Input'Last then
               return False;
            end if;
            if not ((Input (P) in 'A' .. 'Z')
                    or else (Input (P) in 'a' .. 'z')
                    or else Input (P) = '_')
            then
               return False;
            end if;
            while P <= Input'Last and then Is_Ident_Char (Input (P)) loop
               P := P + 1;
            end loop;
            Skip_Blanks;
            return True;
         end Take_Ident;
      begin
         loop
            Skip_Blanks;
            exit when P > Input'Last;
            exit when Input (P) = ASCII.LF or else Input (P) = ASCII.CR;
            exit when Input (P) = '-' and then P < Input'Last
              and then Input (P + 1) = '-';

            if Allow_G1 and then Ident_At ("G1") then
               P := P + 2;
            elsif Ident_At ("VERIFY") then
               P := P + 6;
            elsif Ident_At ("OUT") then
               P := P + 3;
               Skip_Blanks;
               if P > Input'Last or else Input (P) /= '"' then
                  return False;
               end if;
               P := P + 1;
               while P <= Input'Last
                 and then Input (P) /= '"'
                 and then Input (P) /= ASCII.LF
                 and then Input (P) /= ASCII.CR
               loop
                  P := P + 1;
               end loop;
               if P > Input'Last or else Input (P) /= '"' then
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
      end Block_Opener_Ok;

      function Is_End_Word_Line
        (Line_Start : Positive;
         Line_End   : Natural;
         Word       : String) return Boolean
      is
         P : Natural := Line_Start;
      begin
         while P <= Line_End and then
           (Input (P) = ' ' or else Input (P) = ASCII.HT or else
            Input (P) = ASCII.CR)
         loop
            P := P + 1;
         end loop;

         if P + 2 > Line_End or else
            Upper (Input (P))     /= 'E' or else
            Upper (Input (P + 1)) /= 'N' or else
            Upper (Input (P + 2)) /= 'D'
         then
            return False;
         end if;
         P := P + 3;

         while P <= Line_End and then
           (Input (P) = ' ' or else Input (P) = ASCII.HT)
         loop
            P := P + 1;
         end loop;

         --  the matching word is required: a bare END line must not
         --  terminate the block (it stays verbatim content and cannot
         --  collide with an outer BEGIN .. END closer).
         if P + Word'Length - 1 > Line_End then
            return False;
         end if;

         for K in Word'Range loop
            if Upper (Input (P + (K - Word'First))) /= Word (K) then
               return False;
            end if;
         end loop;
         P := P + Word'Length;

         while P <= Line_End and then
           (Input (P) = ' ' or else Input (P) = ASCII.HT)
         loop
            P := P + 1;
         end loop;

         return P > Line_End;
      end Is_End_Word_Line;

      procedure Scan_Word_Block
        (Start_Pos : Positive;
         Word      : String;
         Block_Len : out Natural;
         Found     : out Boolean)
      is
         P          : Natural := Start_Pos;
         Line_Start : Positive := Start_Pos;
         Line_End   : Natural := Start_Pos;
      begin
         Found := False;
         Block_Len := 0;

         while P <= Input'Last loop
            Line_Start := Positive (P);

            while P <= Input'Last and then Input (P) /= ASCII.LF loop
               P := P + 1;
            end loop;

            Line_End := P - 1;

            if Line_Start > Start_Pos and then
               Is_End_Word_Line (Line_Start, Line_End, Word)
            then
               if P <= Input'Last and then Input (P) = ASCII.LF then
                  Block_Len := P - Start_Pos + 1;
               else
                  Block_Len := P - Start_Pos;
               end if;

               Found := True;
               return;
            end if;

            if P <= Input'Last and then Input (P) = ASCII.LF then
               P := P + 1;
            end if;
         end loop;

         Block_Len := Input'Last - Start_Pos + 1;
      end Scan_Word_Block;

      function Next_Word_Is
        (After_Pos : Natural;
         Word      : String) return Boolean
      is
         P : Natural := After_Pos;
      begin
         while P <= Input'Last and then
           (Input (P) = ' ' or else Input (P) = ASCII.HT)
         loop
            P := P + 1;
         end loop;

         if Word'Length = 0 or else P + Word'Length - 1 > Input'Last then
            return False;
         end if;

         for K in Word'Range loop
            if Upper (Input (P + (K - Word'First))) /= Upper (Word (K)) then
               return False;
            end if;
         end loop;

         return P + Word'Length > Input'Last
           or else not Is_Ident_Char (Input (P + Word'Length));
      end Next_Word_Is;

      function Next_Word_Is_ASM (After_Pos : Natural) return Boolean is
      begin
         return Next_Word_Is (After_Pos, "ASM");
      end Next_Word_Is_ASM;

      function Next_Word_Is_JAVA (After_Pos : Natural) return Boolean is
      begin
         return Next_Word_Is (After_Pos, "JAVA");
      end Next_Word_Is_JAVA;

      function Next_Word_Is_ADA (After_Pos : Natural) return Boolean is
      begin
         return Next_Word_Is (After_Pos, "ADA");
      end Next_Word_Is_ADA;

      function Next_Word_Is_TYPESCRIPT (After_Pos : Natural) return Boolean is
      begin
         return Next_Word_Is (After_Pos, "TYPESCRIPT");
      end Next_Word_Is_TYPESCRIPT;

      function Next_Word_Is_C (After_Pos : Natural) return Boolean is
      begin
         return Next_Word_Is (After_Pos, "C");
      end Next_Word_Is_C;

      function Next_Word_Is_CSHARP (After_Pos : Natural) return Boolean is
      begin
         return Next_Word_Is (After_Pos, "CSHARP");
      end Next_Word_Is_CSHARP;

      function Spaced_Keyword_Length
        (After_Pos : Natural;
         Word      : String) return Natural
      is
         P : Natural := After_Pos;
      begin
         while P <= Input'Last and then
           (Input (P) = ' ' or else Input (P) = ASCII.HT)
         loop
            P := P + 1;
         end loop;

         if P + Word'Length - 1 > Input'Last then
            return 0;
         end if;

         for K in Word'Range loop
            if Upper (Input (P + (K - Word'First))) /= Upper (Word (K)) then
               return 0;
            end if;
         end loop;

         if P + Word'Length <= Input'Last
           and then Is_Ident_Char (Input (P + Word'Length))
         then
            return 0;
         end if;

         return P + Word'Length - After_Pos;
      end Spaced_Keyword_Length;


   begin
      --  Token_Count is seeded by the caller (0 = fresh scan; >0 =
      --  append mode used by the interpolation splice); Diagnostic
      --  likewise arrives initialised so sub-scans can propagate.

      while I <= Input'Last loop
         Token_Line := Curr_Line; Token_Col  := Curr_Col; C := Input(I);

         if C = ' ' or C = ASCII.HT or C = ASCII.CR or C = ';' then
             Curr_Col := Curr_Col + 1; I := I + 1;
          elsif C = ASCII.LF then
             Curr_Line := Curr_Line + 1; Curr_Col := 1; I := I + 1;
             
          elsif C = '-' and then I < Input'Last and then Input(I + 1) = '-' then
             if Token_Count > 0
               and then I > Input'First
               and then Input(I - 1) not in ' ' | ASCII.HT | ASCII.CR | ASCII.LF
               and then Tokens(Token_Count).Line = Curr_Line
               and then Tokens(Token_Count).Kind in Tok_Atom | Tok_Logic_Var | Tok_R_Paren | Tok_R_Square | Tok_Number | Tok_String | Tok_Const_Id
             then
                Commit_Token(Tok_Minus, 1);
             else
                -- Skip everything until Newline or EOF
                while I <= Input'Last and then Input(I) /= ASCII.LF loop
                   I := I + 1;
                   Curr_Col := Curr_Col + 1;
                end loop;
             end if;

          elsif C = '/' and then I < Input'Last and then Input(I + 1) = '/' then
             -- C/C++ line comment
             while I <= Input'Last and then Input(I) /= ASCII.LF loop
                I := I + 1;
                Curr_Col := Curr_Col + 1;
             end loop;

          elsif C = '/' and then I < Input'Last and then Input(I + 1) = '*' then
             -- C/C++ block comment
             I := I + 2;
             Curr_Col := Curr_Col + 2;

             declare
                Closed : Boolean := False;
             begin
                while I <= Input'Last loop
                   if I < Input'Last and then Input(I) = '*' and then Input(I + 1) = '/' then
                      I := I + 2;
                      Curr_Col := Curr_Col + 2;
                      Closed := True;
                      exit;
                   elsif Input(I) = ASCII.LF then
                      Curr_Line := Curr_Line + 1;
                      Curr_Col := 1;
                      I := I + 1;
                   else
                      I := I + 1;
                      Curr_Col := Curr_Col + 1;
                   end if;
                end loop;

                if not Closed then
                   Set_Error(Err_Lex_Unclosed_String, Token_Line, Token_Col);
                end if;
             end;
             
          elsif C = '"' or C = '`' then
            if C = '"' then
               Len := 1; Closed := False;
               for J in I + 1 .. Input'Last loop
                  Len := Len + 1; if Input(J) = C then Closed := True; exit; end if;
               end loop;
            else
               --  backtick strings interpolate: the close only counts
               --  outside {..} regions, and quoted spans inside those
               --  regions (nested backticks, "..." args) hide braces
               Len := 1; Closed := False;
               declare
                  J     : Natural := I + 1;
                  Depth : Natural := 0;
               begin
                  while J <= Input'Last and then not Closed loop
                     if Depth = 0 then
                        if Input (J) = '`' then
                           Closed := True;
                        elsif Input (J) = '{' then
                           if J < Input'Last
                             and then Input (J + 1) = '{'
                           then
                              J := J + 1;   --  '{{' escape: not interp
                           else
                              Depth := 1;
                           end if;
                        end if;
                     else
                        if Input (J) = '"' or else Input (J) = '`' then
                           declare
                              Q : constant Character := Input (J);
                           begin
                              J := J + 1;
                              while J <= Input'Last
                                and then Input (J) /= Q loop
                                 J := J + 1;
                              end loop;
                           end;
                        elsif Input (J) = '{' then
                           Depth := Depth + 1;
                        elsif Input (J) = '}' then
                           Depth := Depth - 1;
                        end if;
                     end if;
                     if not Closed then
                        J := J + 1;
                     end if;
                  end loop;
                  --  Len is positional: the quote-skip above advances J
                  --  by whole quoted spans, so a per-char count is wrong
                  if Closed then Len := J - I + 1; else Len := J - I; end if;
               end;
            end if;
            if not Closed then
               Set_Error (Err_Lex_Unclosed_String, Token_Line, Token_Col);
               Commit_Token (Tok_Error, Len);
            else Commit_Token (Tok_String, Len); end if;

         -- 3. HEXADECIMAL LITERALS ($FF_FF) and tile literals ($8x8)
         elsif C = '$' then
            declare
               Tile_Len        : Natural := 1;
               J               : Natural := I + 1;
               Saw_Head_Digit  : Boolean := False;
               Saw_Tail_Digit  : Boolean := False;
               Saw_Tile_Marker : Boolean := False;
            begin
               while J <= Input'Last and then Input(J) in '0' .. '9' loop
                  Tile_Len := Tile_Len + 1;
                  Saw_Head_Digit := True;
                  J := J + 1;
               end loop;

               if Saw_Head_Digit
                 and then J <= Input'Last
                 and then (Input(J) = 'x' or else Input(J) = 'X')
               then
                  Saw_Tile_Marker := True;
                  Tile_Len := Tile_Len + 1;
                  J := J + 1;

                  while J <= Input'Last and then Input(J) in '0' .. '9' loop
                     Tile_Len := Tile_Len + 1;
                     Saw_Tail_Digit := True;
                     J := J + 1;
                  end loop;
               end if;

               if Saw_Tile_Marker and then Saw_Tail_Digit then
                  Commit_Token (Tok_Tile_Size, Tile_Len);
               else
                  Len := 1;
                  declare 
                     Found_Bad : Boolean := False; 
                  begin
                     for Scan in I + 1 .. Input'Last loop
                        declare C2 : Character := Input(Scan); begin
                           -- Is it a valid Hex digit?
                           if (C2 >= '0' and C2 <= '9') or else (C2 >= 'A' and C2 <= 'F') or else 
                              (C2 >= 'a' and C2 <= 'f') or else C2 = '_' then 
                              Len := Len + 1;
                           -- Is it an ILLEGAL letter? (G-Z)
                           elsif (C2 >= 'G' and C2 <= 'Z') or else (C2 >= 'g' and C2 <= 'z') then
                              Set_Error (Err_Lex_Invalid_Hex, Token_Line, Token_Col);
                              Len := Len + 1;
                              Found_Bad := True;
                           else 
                              exit; 
                           end if;
                        end;
                     end loop;
                     
                     if Len = 1 or Found_Bad then
                        if Len = 1 then Set_Error (Err_Lex_Invalid_Hex, Token_Line, Token_Col); end if;
                        Commit_Token (Tok_Error, Len); -- Mark the whole malformed word as an Error
                     else 
                        Commit_Token (Tok_Hex_Literal, Len); 
                     end if;
                  end;
               end if;
            end;

         -- 4. BINARY LITERALS (%1010_1010)
         elsif C = '%' then
            Len := 1;
            declare 
               Found_Bad : Boolean := False; 
            begin
               for J in I + 1 .. Input'Last loop
                  declare C2 : Character := Input(J); begin
                     if C2 = '0' or C2 = '1' or C2 = '_' then 
                        Len := Len + 1;
                     elsif (C2 >= '2' and C2 <= '9') or else 
                           (C2 >= 'A' and C2 <= 'Z') or else (C2 >= 'a' and C2 <= 'z') then
                        Set_Error (Err_Lex_Invalid_Bin, Token_Line, Token_Col);
                        Len := Len + 1;
                        Found_Bad := True;
                     else 
                        exit; 
                     end if;
                  end;
               end loop;
               
               if Len = 1 or Found_Bad then
                  if Len = 1 then Set_Error (Err_Lex_Invalid_Bin, Token_Line, Token_Col); end if;
                  Commit_Token (Tok_Error, Len);
               else 
                  Commit_Token (Tok_Bin_Literal, Len); 
               end if;
            end;
            
         -- 5. OCTAL LITERALS (&O755)  /  Task B2: bare '&' as pipe alias
         elsif C = '&' then
            Len := 1;
            if I < Input'Last and then (Input(I + 1) = 'O' or Input(I + 1) = 'o') then
               -- Classic BASIC octal literal:  &O755
               declare
                  Found_Bad : Boolean := False;
               begin
                  Len := Len + 1;
                  for J in I + 2 .. Input'Last loop
                     declare C2 : Character := Input(J); begin
                        if (C2 >= '0' and C2 <= '7') or C2 = '_' then
                           Len := Len + 1;
                        elsif (C2 >= '8' and C2 <= '9') or else
                              (C2 >= 'A' and C2 <= 'Z') or else (C2 >= 'a' and C2 <= 'z') then
                           Set_Error (Err_Parse_Expected_Value, Token_Line, Token_Col);
                           Len := Len + 1;
                           Found_Bad := True;
                        else
                           exit;
                        end if;
                     end;
                  end loop;

                  if Len <= 2 or Found_Bad then
                     Commit_Token (Tok_Error, Len);
                  else
                     Commit_Token (Tok_Octal_Literal, Len);
                  end if;
               end;
            elsif I < Input'Last and then Input (I + 1) = '&' then
               -- '&&' is reserved (future logical AND).  Be loud about it.
               Set_Error (Err_Lex_Rogue_Symbol, Token_Line, Token_Col);
               Commit_Token (Tok_Error, 2);
            else
               -- Bare '&':  QBASIC / VB-style alias for '|' (Tok_Pipe).
               Commit_Token (Tok_Ampersand, 1);
            end if;
            
         -- DA FIX: CONSTANTS (#MAX_ENTITIES)
         elsif C = '#' then
            Len := 1;
            for J in I + 1 .. Input'Last loop
               declare C2 : Character := Input(J); begin
                  if (C2 >= 'A' and C2 <= 'Z') or else (C2 >= 'a' and C2 <= 'z') or else 
                     (C2 >= '0' and C2 <= '9') or else C2 = '_' then
                     Len := Len + 1;
                  else exit; end if;
               end;
            end loop;
            if Len = 1 then
               Set_Error (Err_Lex_Rogue_Symbol, Token_Line, Token_Col);
               Commit_Token (Tok_Error, Len);
            else
               Commit_Token (Tok_Const_Id, Len);
            end if;

         -- DA FIX 2: Restored Context-Aware Negative Numbers (The Elegant Way!)
         elsif C in '0' .. '9' or else
               (C = '-'
                and then I < Input'Last
                and then Input (I + 1) in '0' .. '9'
                and then
                  (Token_Count = 0
                   or else
                     Tokens (Token_Count).Kind not in
                       Tok_Logic_Var | Tok_Atom | Tok_Number |
                       Tok_String | Tok_Hex_Literal | Tok_Bin_Literal |
                       Tok_R_Paren | Tok_R_Square)
                and then
                  not Follows_Power_Operator
                    (I + 1 + Scan_Number_Length (I + 1)))
         then
            Len := 0;
            if C = '-' then
               Len := 1; -- Ensnare the minus sign as part o' the literal!
            end if;

            Len := Len + Scan_Number_Length (I + Len);
            
            declare
               RS_Stat : Boolean;
               Ival    : RS_Interval;
            begin
               Create(0.0, Long_Float(Input'Length), Ival, RS_Stat);
               pragma Assert (RS_Stat and then Contains(Ival, Long_Float(Len)));
            end;
            
            Commit_Token (Tok_Number, Len);

         elsif (C >= 'A' and C <= 'Z') or (C >= 'a' and C <= 'z') then
            Len := 0;
            for J in I .. Input'Last loop
               declare C2 : Character := Input(J); begin
                  if (C2 >= 'A' and C2 <= 'Z') or (C2 >= 'a' and C2 <= 'z') or 
                     (C2 >= '0' and C2 <= '9') or C2 = '_' or C2 = '$' then Len := Len + 1;
                  else exit; end if;
               end;
            end loop;

            declare 
               Raw_Sub : String := Input(I .. I + Len - 1);
               Sub     : String (1 .. Len);
            begin
               -- DA ARMOR PLATING: Force everything to UPPERCASE
               for K in 1 .. Len loop
                  if Raw_Sub(Raw_Sub'First + K - 1) >= 'a' and Raw_Sub(Raw_Sub'First + K - 1) <= 'z' then
                     Sub(K) := Character'Val(Character'Pos(Raw_Sub(Raw_Sub'First + K - 1)) - 32);
                  else
                     Sub(K) := Raw_Sub(Raw_Sub'First + K - 1);
                  end if;
               end loop;
               
               if Sub = "ASM" then
                  declare
                     Block_Len : Natural := 0;
                     Found     : Boolean := False;
                  begin
                     Scan_ASM_Block (I, Block_Len, Found);

                     if Found then
                        Commit_Token (Tok_Asm_Block, Block_Len);
                     else
                        Set_Error (Err_Lex_Unclosed_String, Token_Line, Token_Col);
                        Commit_Token (Tok_Error, Block_Len);
                     end if;
                  end;

               elsif Sub = "INLINE" and then Next_Word_Is_ASM (I + Len) then
                  declare
                     Block_Len : Natural := 0;
                     Found     : Boolean := False;
                  begin
                     Scan_ASM_Block (I, Block_Len, Found);

                     if Found then
                        Commit_Token (Tok_Inline_Asm_Block, Block_Len);
                     else
                        Set_Error (Err_Lex_Unclosed_String, Token_Line, Token_Col);
                        Commit_Token (Tok_Error, Block_Len);
                     end if;
                  end;

               elsif Sub = "ENABLE" and then Next_Word_Is_ADA (I + Len) then
                  declare
                     Block_Len : Natural := 0;
                     Found     : Boolean := False;
                  begin
                     Scan_Java_Block (I, Block_Len, Found);

                     if Found then
                        Commit_Token (Tok_Enable_Ada_Block, Block_Len);
                     else
                        Set_Error (Err_Lex_Unclosed_String, Token_Line, Token_Col);
                        Commit_Token (Tok_Error, Block_Len);
                     end if;
                  end;

               elsif Sub = "INLINE" and then Next_Word_Is_ADA (I + Len) then
                  declare
                     Block_Len : Natural := 0;
                     Found     : Boolean := False;
                  begin
                     Scan_Java_Block (I, Block_Len, Found);

                     if Found then
                        Commit_Token (Tok_Inline_Ada_Block, Block_Len);
                     else
                        Set_Error (Err_Lex_Unclosed_String, Token_Line, Token_Col);
                        Commit_Token (Tok_Error, Block_Len);
                     end if;
                  end;

               elsif Sub = "ENABLE" and then Next_Word_Is_JAVA (I + Len) then
                  declare
                     Block_Len : Natural := 0;
                     Found     : Boolean := False;
                  begin
                     Scan_Java_Block (I, Block_Len, Found);

                     if Found then
                        Commit_Token (Tok_Enable_Java_Block, Block_Len);
                     else
                        Set_Error (Err_Lex_Unclosed_String, Token_Line, Token_Col);
                        Commit_Token (Tok_Error, Block_Len);
                     end if;
                  end;

               elsif Sub = "INLINE" and then Next_Word_Is_JAVA (I + Len) then
                  declare
                     Block_Len : Natural := 0;
                     Found     : Boolean := False;
                  begin
                     Scan_Java_Block (I, Block_Len, Found);

                     if Found then
                        Commit_Token (Tok_Inline_Java_Block, Block_Len);
                     else
                        Set_Error (Err_Lex_Unclosed_String, Token_Line, Token_Col);
                        Commit_Token (Tok_Error, Block_Len);
                     end if;
                  end;

               elsif Sub = "ENABLE" and then Next_Word_Is_TYPESCRIPT (I + Len) then
                  declare
                     Block_Len : Natural := 0;
                     Found     : Boolean := False;
                  begin
                     Scan_Java_Block (I, Block_Len, Found);

                     if Found then
                        Commit_Token (Tok_Enable_Typescript_Block, Block_Len);
                     else
                        Set_Error (Err_Lex_Unclosed_String, Token_Line, Token_Col);
                        Commit_Token (Tok_Error, Block_Len);
                     end if;
                  end;

               elsif Sub = "INLINE" and then Next_Word_Is_TYPESCRIPT (I + Len) then
                  declare
                     Block_Len : Natural := 0;
                     Found     : Boolean := False;
                  begin
                     Scan_Java_Block (I, Block_Len, Found);

                     if Found then
                        Commit_Token (Tok_Inline_Typescript_Block, Block_Len);
                     else
                        Set_Error (Err_Lex_Unclosed_String, Token_Line, Token_Col);
                        Commit_Token (Tok_Error, Block_Len);
                     end if;
                  end;

               elsif (Sub = "ENABLE" and then Next_Word_Is_C (I + Len))
                 or else Sub = "ENABLEC"
               then
                  declare
                     Block_Len : Natural := 0;
                     Found     : Boolean := False;
                  begin
                     Scan_Java_Block (I, Block_Len, Found);

                     if Found then
                        Commit_Token (Tok_Enable_C_Block, Block_Len);
                     else
                        Set_Error (Err_Lex_Unclosed_String, Token_Line, Token_Col);
                        Commit_Token (Tok_Error, Block_Len);
                     end if;
                  end;

               elsif (Sub = "INLINE" and then Next_Word_Is_C (I + Len))
                 or else Sub = "INLINEC"
               then
                  declare
                     Block_Len : Natural := 0;
                     Found     : Boolean := False;
                  begin
                     Scan_Java_Block (I, Block_Len, Found);

                     if Found then
                        Commit_Token (Tok_Inline_C_Block, Block_Len);
                     else
                        Set_Error (Err_Lex_Unclosed_String, Token_Line, Token_Col);
                        Commit_Token (Tok_Error, Block_Len);
                     end if;
                  end;

               elsif Sub = "ENABLE" and then Next_Word_Is_CSHARP (I + Len) then
                  declare
                     Block_Len : Natural := 0;
                     Found     : Boolean := False;
                  begin
                     Scan_Java_Block (I, Block_Len, Found);

                     if Found then
                        Commit_Token (Tok_Enable_CSharp_Block, Block_Len);
                     else
                        Set_Error (Err_Lex_Unclosed_String, Token_Line, Token_Col);
                        Commit_Token (Tok_Error, Block_Len);
                     end if;
                  end;

               elsif Sub = "INLINE" and then Next_Word_Is_CSHARP (I + Len) then
                  declare
                     Block_Len : Natural := 0;
                     Found     : Boolean := False;
                  begin
                     Scan_Java_Block (I, Block_Len, Found);

                     if Found then
                        Commit_Token (Tok_Inline_CSharp_Block, Block_Len);
                     else
                        Set_Error (Err_Lex_Unclosed_String, Token_Line, Token_Col);
                        Commit_Token (Tok_Error, Block_Len);
                     end if;
                  end;

               elsif (Sub = "ENABLE" and then Next_Word_Is (I + Len, "PYTHON"))
                 or else Sub = "ENABLEPYTHON"
               then
                  declare
                     Block_Len : Natural := 0;
                     Found     : Boolean := False;
                  begin
                     Scan_Java_Block (I, Block_Len, Found);

                     if Found then
                        Commit_Token (Tok_Enable_Python_Block, Block_Len);
                     else
                        Set_Error (Err_Lex_Unclosed_String, Token_Line, Token_Col);
                        Commit_Token (Tok_Error, Block_Len);
                     end if;
                  end;

               elsif (Sub = "INLINE" and then Next_Word_Is (I + Len, "PYTHON"))
                 or else Sub = "INLINEPYTHON"
               then
                  declare
                     Block_Len : Natural := 0;
                     Found     : Boolean := False;
                  begin
                     Scan_Java_Block (I, Block_Len, Found);

                     if Found then
                        Commit_Token (Tok_Inline_Python_Block, Block_Len);
                     else
                        Set_Error (Err_Lex_Unclosed_String, Token_Line, Token_Col);
                        Commit_Token (Tok_Error, Block_Len);
                     end if;
                  end;

               elsif (Sub = "ENABLE" and then Next_Word_Is (I + Len, "LUA54"))
                 or else Sub = "ENABLELUA54"
               then
                  declare
                     Block_Len : Natural := 0;
                     Found     : Boolean := False;
                  begin
                     Scan_Java_Block (I, Block_Len, Found);

                     if Found then
                        Commit_Token (Tok_Enable_Lua54_Block, Block_Len);
                     else
                        Set_Error (Err_Lex_Unclosed_String, Token_Line, Token_Col);
                        Commit_Token (Tok_Error, Block_Len);
                     end if;
                  end;

               elsif (Sub = "INLINE" and then (Next_Word_Is (I + Len, "LUA") or else Next_Word_Is (I + Len, "LUA54")))
                 or else Sub = "INLINELUA"
                 or else Sub = "INLINELUA54"
               then
                  declare
                     Block_Len : Natural := 0;
                     Found     : Boolean := False;
                  begin
                     Scan_Java_Block (I, Block_Len, Found);

                     if Found then
                        Commit_Token (Tok_Inline_Lua_Block, Block_Len);
                     else
                        Set_Error (Err_Lex_Unclosed_String, Token_Line, Token_Col);
                        Commit_Token (Tok_Error, Block_Len);
                     end if;
                  end;

               elsif (Sub = "ENABLE" and then Next_Word_Is (I + Len, "RUBY"))
                 or else Sub = "ENABLERUBY"
               then
                  declare
                     Block_Len : Natural := 0;
                     Found     : Boolean := False;
                  begin
                     Scan_Java_Block (I, Block_Len, Found);

                     if Found then
                        Commit_Token (Tok_Enable_Ruby_Block, Block_Len);
                     else
                        Set_Error (Err_Lex_Unclosed_String, Token_Line, Token_Col);
                        Commit_Token (Tok_Error, Block_Len);
                     end if;
                  end;

               elsif (Sub = "INLINE" and then Next_Word_Is (I + Len, "RUBY"))
                 or else Sub = "INLINERUBY"
               then
                  declare
                     Block_Len : Natural := 0;
                     Found     : Boolean := False;
                  begin
                     Scan_Java_Block (I, Block_Len, Found);

                     if Found then
                        Commit_Token (Tok_Inline_Ruby_Block, Block_Len);
                     else
                        Set_Error (Err_Lex_Unclosed_String, Token_Line, Token_Col);
                        Commit_Token (Tok_Error, Block_Len);
                     end if;
                  end;

               elsif (Sub = "ENABLE" and then Next_Word_Is (I + Len, "JAVASCRIPT"))
                 or else Sub = "ENABLEJAVASCRIPT"
               then
                  declare
                     Block_Len : Natural := 0;
                     Found     : Boolean := False;
                  begin
                     Scan_Java_Block (I, Block_Len, Found);

                     if Found then
                        Commit_Token (Tok_Enable_Javascript_Block, Block_Len);
                     else
                        Set_Error (Err_Lex_Unclosed_String, Token_Line, Token_Col);
                        Commit_Token (Tok_Error, Block_Len);
                     end if;
                  end;

               elsif (Sub = "INLINE" and then Next_Word_Is (I + Len, "JAVASCRIPT"))
                 or else Sub = "INLINEJAVASCRIPT"
               then
                  declare
                     Block_Len : Natural := 0;
                     Found     : Boolean := False;
                  begin
                     Scan_Java_Block (I, Block_Len, Found);

                     if Found then
                        Commit_Token (Tok_Inline_Javascript_Block, Block_Len);
                     else
                        Set_Error (Err_Lex_Unclosed_String, Token_Line, Token_Col);
                        Commit_Token (Tok_Error, Block_Len);
                     end if;
                  end;

               elsif (Sub = "ENABLE" and then Next_Word_Is (I + Len, "RUST"))
                 or else Sub = "ENABLERUST" or else Sub = "ENABLE_RUST"
               then
                  declare
                     Block_Len : Natural := 0;
                     Found     : Boolean := False;
                  begin
                     Scan_Java_Block (I, Block_Len, Found);

                     if Found then
                        Commit_Token (Tok_Enable_Rust_Block, Block_Len);
                     else
                        Set_Error (Err_Lex_Unclosed_String, Token_Line, Token_Col);
                        Commit_Token (Tok_Error, Block_Len);
                     end if;
                  end;

               elsif (Sub = "INLINE" and then Next_Word_Is (I + Len, "RUST"))
                 or else Sub = "INLINERUST" or else Sub = "INLINE_RUST"
               then
                  declare
                     Block_Len : Natural := 0;
                     Found     : Boolean := False;
                  begin
                     Scan_Java_Block (I, Block_Len, Found);

                     if Found then
                        Commit_Token (Tok_Inline_Rust_Block, Block_Len);
                     else
                        Set_Error (Err_Lex_Unclosed_String, Token_Line, Token_Col);
                        Commit_Token (Tok_Error, Block_Len);
                     end if;
                  end;

               elsif (Sub = "ENABLE" and then Next_Word_Is (I + Len, "WASM"))
                 or else Sub = "ENABLEWASM" or else Sub = "ENABLE_WASM"
               then
                  declare
                     Block_Len : Natural := 0;
                     Found     : Boolean := False;
                  begin
                     Scan_Java_Block (I, Block_Len, Found);

                     if Found then
                        Commit_Token (Tok_Enable_Wasm_Block, Block_Len);
                     else
                        Set_Error (Err_Lex_Unclosed_String, Token_Line, Token_Col);
                        Commit_Token (Tok_Error, Block_Len);
                     end if;
                  end;

               elsif (Sub = "INLINE" and then Next_Word_Is (I + Len, "WASM"))
                 or else Sub = "INLINEWASM" or else Sub = "INLINE_WASM"
               then
                  declare
                     Block_Len : Natural := 0;
                     Found     : Boolean := False;
                  begin
                     Scan_Java_Block (I, Block_Len, Found);

                     if Found then
                        Commit_Token (Tok_Inline_Wasm_Block, Block_Len);
                     else
                        Set_Error (Err_Lex_Unclosed_String, Token_Line, Token_Col);
                        Commit_Token (Tok_Error, Block_Len);
                     end if;
                  end;

               --  BRAILLE / NEMETH raw data blocks: contextual openers.
               --  A lone keyword at line start opens a verbatim block
               --  terminated by a line holding only END / END <WORD>.
               --  The line-start + end-of-line guards keep `braille`
               --  and `nemeth` usable as ordinary identifiers anywhere
               --  else in the grammar.
               elsif Sub = "BRAILLE" and then At_Line_Start (I)
                 and then Block_Opener_Ok (I + Len, True)
               then
                  declare
                     Block_Len : Natural := 0;
                     Found     : Boolean := False;
                  begin
                     Scan_Word_Block (I, "BRAILLE", Block_Len, Found);

                     if Found then
                        Commit_Token (Tok_Braille_Block, Block_Len);
                     else
                        Set_Error (Err_Lex_Unclosed_String, Token_Line, Token_Col);
                        Commit_Token (Tok_Error, Block_Len);
                     end if;
                  end;

               elsif Sub = "NEMETH" and then At_Line_Start (I)
                 and then Block_Opener_Ok (I + Len, False)
               then
                  declare
                     Block_Len : Natural := 0;
                     Found     : Boolean := False;
                  begin
                     Scan_Word_Block (I, "NEMETH", Block_Len, Found);

                     if Found then
                        Commit_Token (Tok_Nemeth_Block, Block_Len);
                     else
                        Set_Error (Err_Lex_Unclosed_String, Token_Line, Token_Col);
                        Commit_Token (Tok_Error, Block_Len);
                     end if;
                  end;

               else
                  if Len > 10
                    and then Sub (Sub'First .. Sub'First + 9) = "ENABLEASM_"
                  then
                     Commit_Token (Tok_EnableASM, Len);

                  else


               -- DA FIX 4: MACH-SPEED JUMP TABLE! O(1) String Bypassing!
               case Len is
                  when 2 =>
                     if Sub = "AS" then Commit_Token(Tok_As, 2);
                     elsif Sub = "AT" then Commit_Token(Tok_At, 2);
                     elsif Sub = "IF" then Commit_Token(Tok_If, 2);
                     elsif Sub = "TO" then Commit_Token(Tok_To, 2);
                     elsif Sub = "BY" then Commit_Token(Tok_By, 2);
                     elsif Sub = "ON" then Commit_Token(Tok_On, 2);
                     elsif Sub = "IN" then Commit_Token(Tok_In, 2);
                     elsif Sub = "IS" then Commit_Token(Tok_Is, 2);
                     elsif Sub = "OR" then Commit_Token(Tok_Or, 2);
                     elsif Sub = "I8" then Commit_Token(Tok_I8, 2);
                     elsif Sub = "U0" then Commit_Token(Tok_U0, 2);
                     elsif C >= 'A' and C <= 'Z' then Commit_Token(Tok_Logic_Var, Len); else Commit_Token(Tok_Atom, Len); end if;
                  when 3 =>
                     if Sub = "LET" then Commit_Token(Tok_Let, 3);
                     elsif Sub = "USE" then Commit_Token(Tok_Use, 3);
                     elsif Sub = "RND" then Commit_Token(Tok_Rnd, 3);
                     elsif Sub = "TCP" then Commit_Token(Tok_TCP, 3);
                     elsif Sub = "UDP" then Commit_Token(Tok_UDP, 3);
                     elsif Sub = "TRY" then Commit_Token(Tok_Try, 3);
                     elsif Sub = "FOR" then Commit_Token(Tok_For, 3);
                     elsif Sub = "OUT" then Commit_Token(Tok_Out, 3);
                     elsif Sub = "REF" then Commit_Token(TOK_REF, 3);
                     elsif Sub = "END" then Commit_Token(Tok_End, 3);
                     elsif Sub = "AND" then Commit_Token(Tok_And, 3);
                     elsif Sub = "XOR" then Commit_Token(Tok_Xor, 3);
                     elsif Sub = "DOT" then Commit_Token(Tok_Dot_Prod, 3); -- Use da fixed token!
                     elsif Sub = "FMA" then Commit_Token(TOK_FMA, 3);
                     elsif Sub = "SHL" then Commit_Token(Tok_Shl, 3);
                     elsif Sub = "NOW" then Commit_Token(Tok_Now, 3);
                     elsif Sub = "SHR" then Commit_Token(Tok_Shr, 3);
                     elsif Sub = "MOD" then Commit_Token(Tok_Mod, 3);
                     elsif Sub = "NOT" then Commit_Token(Tok_Not, 3);
                      elsif Sub = "KEY" then Commit_Token(Tok_Key, 3);
                      elsif Sub = "LEN" then Commit_Token(Tok_Len, 3); -- DA NEW LEN
                     elsif Sub = "CLS" then Commit_Token(Tok_Cls, 3);
                      elsif Sub = "CIN" then Commit_Token(Tok_Input, 3);
                      elsif Sub = "I16" then Commit_Token(Tok_I16, 3);
                      elsif Sub = "I32" then Commit_Token(Tok_I32, 3);
                      elsif Sub = "I64" then Commit_Token(Tok_I64, 3);
                     elsif Sub = "MCP" then Commit_Token(Tok_Mcp, 3);
                     elsif C >= 'A' and C <= 'Z' then Commit_Token(Tok_Logic_Var, Len); else Commit_Token(Tok_Atom, Len); end if;
                  when 4 =>
                     if Sub = "THEN" then Commit_Token(Tok_Then, 4);
                     elsif Sub = "WHEN" then Commit_Token(Tok_When, 4);
                     elsif Sub = "MODE" then Commit_Token(Tok_Mode, 4);
                     elsif Sub = "PORT" then Commit_Token(Tok_Port, 4);
                     elsif Sub = "SIZE" then Commit_Token(Tok_Size, 4);
                     elsif Sub = "FILE" then Commit_Token(Tok_File, 4);
                     elsif Sub = "PINS" then Commit_Token(Tok_Pins, 4);
                     elsif Sub = "WITH" then Commit_Token(Tok_With, 4);
                     elsif Sub = "AXES" then Commit_Token(Tok_Axes, 4);
                     --elsif Sub = "GOTO" then Commit_Token(Tok_Goto, 4);
                     elsif Sub = "PLAY" then Commit_Token(Tok_Play, 4); -- DA NEW AUDIO FORGE
                     elsif Sub = "ENUM" then Commit_Token(Tok_Enum, 4); -- DA NEW ENUM
                     elsif Sub = "CAST" then Commit_Token(Tok_Cast, 4); -- DA NEW CAST
                     elsif Sub = "TYPE" then Commit_Token(Tok_TYPE, 4);
                     elsif Sub = "CASE" then Commit_Token(Tok_Case, 4);
                     elsif Sub = "PAST" then Commit_Token(Tok_Past, 4);
                     elsif Sub = "TRUE" then Commit_Token(Tok_TRUE, 4);
                     elsif Sub = "LERP" then Commit_Token(Tok_Lerp, 4);
                     elsif Sub = "FROM" then Commit_Token(TOK_FROM, 4);
                     elsif Sub = "MAT2" then Commit_Token(Tok_Mat2, 4);
                     elsif Sub = "MAT3" then Commit_Token(Tok_Mat3, 4);
                     elsif Sub = "MAT4" then Commit_Token(Tok_Mat4, 4);
                      elsif Sub = "STEP" then Commit_Token(Tok_Step, 4); -- DA NEW STEP
                      elsif Sub = "CALL" then Commit_Token(Tok_Call, 4);
                      elsif Sub = "COUT" then Commit_Token(Tok_Print_Str, 4);
                      elsif Sub = "ENDL" then Commit_Token(Tok_Endl, 4);
                      elsif Sub = "LOAD" then Commit_Token(Tok_Load, 4);
                      elsif Sub = "OPEN" then Commit_Token(Tok_Open, 4);
                     elsif Sub = "READ" then Commit_Token(Tok_Read, 4);
                     elsif Sub = "PEEK" then Commit_Token(Tok_Peek, 4); 
                     elsif Sub = "FILL" then Commit_Token(TOK_FILL, 4);
                     elsif Sub = "SYNC" then Commit_Token(Tok_Sync, 4);
                     elsif Sub = "POKE" then Commit_Token(Tok_Poke, 4); 
                     elsif Sub = "FIND" then Commit_Token(Tok_Find, 4);
                     elsif Sub = "INTO" then Commit_Token(Tok_Into, 4);
                     elsif Sub = "RULE" then Commit_Token(Tok_Rule, 4);
                     elsif Sub = "DRAW" then Commit_Token(Tok_Draw, 4);
                     elsif Sub = "RECT" then Commit_Token(Tok_Rect, 4);
                     elsif Sub = "LINE" then Commit_Token(Tok_LINE, 4);
                     -- DA DUMPTRUCK KEYWORDS (4 Letters)
                     elsif Sub = "BIND" then Commit_Token(Tok_Bind, 4);
                     elsif Sub = "DROP" then Commit_Token(Tok_Drop, 4);
                        
                     elsif Sub = "POLY" then Commit_Token(Tok_Poly, 4);
                     elsif Sub = "PLOT" then Commit_Token(Tok_Plot, 4);
                     elsif Sub = "TEXT" then Commit_Token(Tok_Text, 4);
                     elsif Sub = "ELSE" then Commit_Token(Tok_Else, 4);
                     --  ELSIF handled in when 5 / ELSEIF in when 6 below.
                     elsif Sub = "TICK" then Commit_Token(Tok_Tick, 4);
                     elsif Sub = "MID$" then Commit_Token(Tok_Mid, 4); -- DA NEW MID$
                     elsif C >= 'A' and C <= 'Z' then Commit_Token(Tok_Logic_Var, Len); else Commit_Token(Tok_Atom, Len); end if;
                  when 5 =>
                     if Sub = "PRINT" then Commit_Token(Tok_Print, 5);
                     elsif Sub = "ELSIF" then Commit_Token(Tok_Elseif, 5);
                     elsif Sub = "EXACT" then Commit_Token(Tok_Exact, 5);
                     elsif Sub = "BLOCK" then Commit_Token(Tok_Block, 5);
                     elsif Sub = "WIDTH" then Commit_Token(Tok_Width, 5);
                     elsif Sub = "ENTRY" then Commit_Token(Tok_Entry, 5);
                     elsif Sub = "FRAME" then Commit_Token(Tok_Frame, 5);
                     elsif Sub = "LAYER" then Commit_Token(Tok_Layer, 5);
                     elsif Sub = "ENDIF" then Commit_Token(Tok_End, 5);
                     elsif Sub = "DELAY" then Commit_Token(Tok_Delay, 5);
                     elsif Sub = "BREAK" then Commit_Token(Tok_Break, 5); -- DA NEW BREAK
                     elsif Sub = "DEREF" then Commit_Token(Tok_Deref, 5); 
                     elsif Sub = "BEGIN" then Commit_Token(Tok_Begin, 5);
                     elsif Sub = "UNTIL" then Commit_Token(Tok_Until, 5);
                     elsif Sub = "PROVE" then Commit_Token(Tok_PROVE, 5);
                     elsif Sub = "CLEAR" then Commit_Token(Tok_CLEAR, 5);
                     elsif Sub = "SPLAT" then Commit_Token(Tok_Splat, 5);
                     elsif Sub = "CLAMP" then Commit_Token(Tok_Clamp, 5);
                     elsif Sub = "CROSS" then Commit_Token(Tok_Cross, 5);
                     elsif Sub = "BLEND" then Commit_Token(Tok_Blend, 5);
                     elsif Sub = "SLIDE" then Commit_Token(Tok_Slide, 5);
                     elsif Sub = "SPAWN" then Commit_Token(Tok_Spawn, 5);
                     elsif Sub = "CATCH" then Commit_Token(Tok_Catch, 5);
                     elsif Sub = "THROW" then Commit_Token(Tok_Throw, 5);
                     elsif Sub = "WHILE" then Commit_Token(Tok_While, 5);
                     elsif Sub = "RANGE" then Commit_Token(Tok_Range, 5);
                     elsif Sub = "FALSE" then Commit_Token(Tok_FALSE, 5);
                     elsif Sub = "MUSIC" then Commit_Token(Tok_Music, 5);
                     elsif Sub = "SOUND" then Commit_Token(Tok_Sound, 5);
                     elsif Sub = "FLUSH" then Commit_Token(Tok_Flush, 5);
                     elsif Sub = "WRITE" then Commit_Token(Tok_Write, 5);
                     elsif Sub = "INPUT" then Commit_Token(Tok_Input, 5);
                     -- DA DUMPTRUCK KEYWORDS (5 Letters)
                     elsif Sub = "CLAIM" then Commit_Token(Tok_Claim, 5);
                     elsif Sub = "SWEEP" then Commit_Token(Tok_Sweep, 5);
                        
                     elsif Sub = "CLOSE" then Commit_Token(Tok_Close, 5);
                     elsif Sub = "KNOWS" then Commit_Token(Tok_Knows, 5);
                     elsif Sub = "MATCH" then Commit_Token(Tok_Match, 5);
                     elsif Sub = "PAINT" then Commit_Token(Tok_Paint, 5);
                     elsif Sub = "COLOR" then Commit_Token(Tok_Color, 5);
                     elsif Sub = "PIXEL" then Commit_Token(Tok_Pixel, 5);
                     elsif Sub = "CEASE" then Commit_Token(Tok_Cease, 5);
                     elsif Sub = "LEFT$" then Commit_Token(Tok_Left, 5); -- DA NEW LEFT$
                     elsif C >= 'A' and C <= 'Z' then Commit_Token(Tok_Logic_Var, Len); else Commit_Token(Tok_Atom, Len); end if;
                  when 6 =>
                     if Sub = "ELSEIF" then Commit_Token(Tok_Elseif, 6);
                     elsif Sub = "ORELSE" then Commit_Token(Tok_Orelse, 6);
                     elsif Sub = "REPEAT" then Commit_Token(Tok_Repeat, 6);
                     elsif Sub = "SECURE" then Commit_Token(Tok_Secure, 6);
                     elsif Sub = "STRIDE" then Commit_Token(Tok_Stride, 6);
                     elsif Sub = "SOURCE" then Commit_Token(Tok_Source, 6);
                     elsif Sub = "FORMAT" then Commit_Token(Tok_Format, 6);
                     elsif Sub = "HEIGHT" then Commit_Token(Tok_Height, 6);
                     elsif Sub = "FRAMES" then Commit_Token(Tok_Frames, 6);
                     elsif Sub = "BOUNDS" then Commit_Token(Tok_Bounds, 6);
                     elsif Sub = "STATES" then Commit_Token(Tok_States, 6);
                     elsif Sub = "EPOCHS" then Commit_Token(Tok_Epochs, 6);
                     elsif Sub = "LOCATE" then Commit_Token(Tok_Locate, 6);
                     elsif Sub = "MODULE" then Commit_Token(Tok_Module, 6); -- DA NEW MODULE
                     elsif Sub = "IMPORT" then Commit_Token(Tok_Import, 6); -- DA NEW IMPORT
                     elsif Sub = "LAMBDA" then Commit_Token(Tok_Lambda, 6);
                     elsif Sub = "STRING" then Commit_Token(Tok_String_Type, 6);
                     elsif Sub = "STRICT" then Commit_Token(Tok_Strict, 6);
                     elsif Sub = "SELECT" then Commit_Token(Tok_Select, 6);
                     elsif Sub = "FUTURE" then Commit_Token(Tok_Future, 6);
                     elsif Sub = "SIZEOF" then Commit_Token(Tok_SizeOf, 6); -- DA NEW SIZEOF
                     elsif Sub = "TYPEOF" then Commit_Token(Tok_TypeOf, 6); -- DA NEW TYPEOF
                     elsif Sub = "CHOOSE" then Commit_Token(Tok_Choose, 6);
                     elsif Sub = "CIRCLE" then Commit_Token(TOK_CIRCLE, 6);
                     elsif Sub = "ENSURE" then Commit_Token(Tok_ENSURE, 6);
                     elsif Sub = "ATOMIC" then Commit_Token(Tok_Atomic, 6);
                     elsif Sub = "FLOAT2" then Commit_Token(Tok_Float2, 6);
                     -- ADVANCED REVERSE EXECUTION    
                     elsif Sub = "REVADD" then Commit_Token(Tok_RevAdd, 6);
                     elsif Sub = "REVSUB" then Commit_Token(Tok_RevSub, 6);
                     elsif Sub = "REVXOR" then Commit_Token(Tok_RevXor, 6);
                     elsif Sub = "REVROL" then Commit_Token(Tok_RevRol, 6);
                     elsif Sub = "REVROR" then Commit_Token(Tok_RevRor, 6);
                     elsif Sub = "REVNOT" then Commit_Token(Tok_RevNot, 6);
                     elsif Sub = "REVNEG" then Commit_Token(Tok_RevNeg, 6);

                     elsif Sub = "FLOAT4" then Commit_Token(Tok_Float4, 6);
                     elsif Sub = "DEFINE" then Commit_Token(TOK_DEFINE, 6);
                     elsif Sub = "STRUCT" then Commit_Token(Tok_Struct, 6);
                     elsif Sub = "RETURN" then Commit_Token(Tok_Return, 6);
                     elsif Sub = "ASSERT" then Commit_Token(Tok_Assert, 6);
                     elsif Sub = "UPDATE" then Commit_Token(Tok_Update, 6);
                     elsif Sub = "LISTEN" then Commit_Token(Tok_Listen, 6);
                     elsif Sub = "WEIGHT" then Commit_Token(Tok_Weight, 6);
                     elsif Sub = "RIGHT$" then Commit_Token(Tok_Right, 6); -- DA NEW RIGHT$
                     elsif Sub = "PRINT$" then Commit_Token(Tok_Print_Str, 6);
                     elsif C >= 'A' and C <= 'Z' then Commit_Token(Tok_Logic_Var, Len); else Commit_Token(Tok_Atom, Len); end if;
                   when 7 =>
                      if Sub = "PARSEIP" then Commit_Token(Tok_Parse_IP, 7);
                      elsif Sub = "ANDALSO" then Commit_Token(Tok_Andalso, 7);
                      elsif Sub = "INIBIND" then Commit_Token(Tok_Ini_Bind, 7);
                      elsif Sub = "VERSION" then Commit_Token(Tok_Version, 7); -- DA NEW VERSION
                     elsif Sub = "DEFAULT" then Commit_Token(Tok_Default, 7);
                     elsif Sub = "DESCRIP" then
                        declare
                           Extra_Len : constant Natural := Spaced_Keyword_Length (I + Len, "TOR");
                        begin
                           if Extra_Len > 0 then
                              Commit_Token (Tok_Descriptor, Len + Extra_Len);
                           elsif C >= 'A' and C <= 'Z' then
                              Commit_Token (Tok_Logic_Var, Len);
                           else
                              Commit_Token (Tok_Atom, Len);
                           end if;
                        end;
                     elsif Sub = "CHANGED" then Commit_Token(Tok_Changed, 7);
                     elsif Sub = "FINDALL" then Commit_Token(Tok_Findall, 7);
                     elsif Sub = "SWAPPOP" then Commit_Token(Tok_SwapPop, 7);
                     elsif Sub = "ADVANCE" then Commit_Token(Tok_Advance, 7);
                     elsif Sub = "HISTORY" then Commit_Token(Tok_History, 7);
                     elsif Sub = "RETRACT" then Commit_Token(Tok_Retract, 7);
                     elsif Sub = "MOUSE_X" then Commit_Token(Tok_Mouse_X, 7);
                     elsif Sub = "ROUTINE" then Commit_Token(Tok_Routine, 7);
                     elsif Sub = "PRIVATE" then Commit_Token(Tok_Private, 7);
                     elsif Sub = "REQUIRE" then Commit_Token(Tok_Require, 7);
                     elsif Sub = "REVSWAP" then Commit_Token(Tok_RevSwap, 7);
                     elsif Sub = "FOREACH" then Commit_Token(TOK_FOREACH, 7);
                     elsif Sub = "MOUSE_Y" then Commit_Token(Tok_Mouse_Y, 7);
                     elsif Sub = "MSG_BOX" then Commit_Token(Tok_Msg_Box, 7);
                     elsif Sub = "EMOTION" then Commit_Token(Tok_Emotion, 7);
                     elsif Sub = "INCLUDE" then Commit_Token(Tok_Include, 7);
                     elsif Sub = "FILELEN" then Commit_Token(Tok_Filelen, 7);
                     elsif Sub = "SPACING" then Commit_Token(Tok_Spacing, 7);
                     elsif Sub = "USEFONT" then Commit_Token(Tok_Use_Font, 7);
                     elsif Sub = "DECLARE" then
                        declare
                           Extra_Len : constant Natural := Spaced_Keyword_Length (I + Len, "MODULE");
                        begin
                           if Extra_Len > 0 then
                              Commit_Token (Tok_DeclareModule, Len + Extra_Len);
                           elsif C >= 'A' and C <= 'Z' then
                              Commit_Token (Tok_Logic_Var, Len);
                           else
                              Commit_Token (Tok_Atom, Len);
                           end if;
                        end;
                     elsif C >= 'A' and C <= 'Z' then Commit_Token(Tok_Logic_Var, Len); else Commit_Token(Tok_Atom, Len); end if;
                   when 9 =>
                      if Sub = "INTERFACE" then Commit_Token(Tok_Interface, 9);
                      elsif Sub = "INVARIANT" then Commit_Token(Tok_Invariant, 9);
                      elsif Sub = "FITS_CUBE" then Commit_Token(Tok_Fits_Cube, 9);
                      elsif Sub = "EXPORTPPM" then Commit_Token(Tok_Export_PPM, 9);
                      elsif Sub = "PARSE_TCP" then Commit_Token(Tok_Parse_TCP, 9);
                      elsif Sub = "ENDMODULE" then Commit_Token(Tok_EndModule, 9); -- DA NEW ENDMODULE
                     elsif Sub = "COLOR_LUT" then Commit_Token(Tok_Color_Lut, 9);
                     elsif Sub = "APPLY_LUT" then Commit_Token(Tok_Apply_Lut, 9);
                     elsif Sub = "BLIT_SAFE" then Commit_Token(Tok_Blit_Safe, 9);
                     elsif Sub = "FIRSTCHAR" then Commit_Token(Tok_First_Char, 9);
                     elsif Sub = "ANTIALIAS" then Commit_Token(Tok_Anti_Alias, 9);
                     elsif Sub = "END_MODEL" then Commit_Token(Tok_End_Model, 9);
                     elsif Sub = "IMPORTDLL" then Commit_Token(Tok_Import_DLL, 9);
                     elsif Sub = "EXPORTDLL" then Commit_Token(Tok_Export_DLL, 9);
                     elsif Sub = "IMPORTJAR" then Commit_Token(Tok_Import_JAR, 9);
                     elsif Sub = "EXPORTJAR" then Commit_Token(Tok_Export_JAR, 9);
                     elsif Sub = "IMPORT_SO" then Commit_Token(Tok_Import_SO, 9);
                     elsif Sub = "EXPORT_SO" then Commit_Token(Tok_Export_SO, 9);
                     elsif Sub = "IMPORT_ES" then Commit_Token(Tok_Import_ES, 9);
                     elsif Sub = "EXPORT_ES" then Commit_Token(Tok_Export_ES, 9);
                     elsif Sub = "PROCEDURE" then Commit_Token(Tok_Procedure, 9);
                     elsif Sub = "NORMALIZE" then Commit_Token(Tok_Normalize, 9); -- DA NEW MATH!
                     elsif Sub = "PREDICATE" then Commit_Token(Tok_Predicate, 9);
                     elsif Sub = "ENABLEASM" then Commit_Token(Tok_EnableASM, 9);
                     elsif Sub = "SET_ALPHA" then Commit_Token(TOK_SET_ALPHA, 9);
                     elsif C >= 'A' and C <= 'Z' then Commit_Token(Tok_Logic_Var, Len); else Commit_Token(Tok_Atom, Len); end if;
                   when 8 =>
                      if Sub = "PARSETCP" then Commit_Token(Tok_Parse_TCP, 8);
                      elsif Sub = "SET_AXIS" then Commit_Token(Tok_Set_Axis, 8);
                      elsif Sub = "ADD_AXIS" then Commit_Token(Tok_Add_Axis, 8);
                      elsif Sub = "GET_AXIS" then Commit_Token(Tok_Get_Axis, 8);
                      elsif Sub = "FALLBACK" then Commit_Token(Tok_Fallback, 8);
                      elsif Sub = "SYMBOLIC" then Commit_Token(Tok_Symbolic, 8);
                      elsif Sub = "FITSCUBE" then Commit_Token(Tok_Fits_Cube, 8);
                      elsif Sub = "INI_BIND" then Commit_Token(Tok_Ini_Bind, 8);
                      elsif Sub = "PARSE_IP" then Commit_Token(Tok_Parse_IP, 8);
                      elsif Sub = "MCP_PUMP" then Commit_Token(Tok_Mcp_Pump, 8);
                      elsif Sub = "FUNCTION" then Commit_Token(Tok_Function, 8);
                     elsif Sub = "COLORLUT" then Commit_Token(Tok_Color_Lut, 8);
                     elsif Sub = "APPLYLUT" then Commit_Token(Tok_Apply_Lut, 8);
                     elsif Sub = "BLITSAFE" then Commit_Token(Tok_Blit_Safe, 8);
                     elsif Sub = "USE_FONT" then Commit_Token(Tok_Use_Font, 8);
                     elsif Sub = "DENY_ALL" then Commit_Token(Tok_Deny_All, 8);
                     elsif Sub = "BOUND_TO" then Commit_Token(Tok_Bound_To, 8);
                     elsif Sub = "PROTOCOL" then Commit_Token(Tok_Protocol, 8);
                     elsif Sub = "EXPECTED" then Commit_Token(Tok_Expected, 8);
                     elsif Sub = "CONTINUE" then Commit_Token(Tok_Continue, 8); -- DA NEW CONTINUE
                     elsif Sub = "IMPORTSO" then Commit_Token(Tok_Import_SO, 8);
                     elsif Sub = "EXPORTSO" then Commit_Token(Tok_Export_SO, 8);
                     elsif Sub = "IMPORTES" then Commit_Token(Tok_Import_ES, 8);
                     elsif Sub = "EXPORTES" then Commit_Token(Tok_Export_ES, 8);
                     elsif Sub = "OFFSETOF" then Commit_Token(Tok_OffsetOf, 8); -- DA NEW OFFSETOF
                     elsif Sub = "PARALLEL" then Commit_Token(Tok_Parallel, 8);
                     elsif Sub = "READLINE" then Commit_Token(Tok_ReadLine, 8);
                     elsif Sub = "FILESEEK" then Commit_Token(Tok_Fileseek, 8);
                     elsif Sub = "TRIANGLE" then Commit_Token(TOK_TRIANGLE, 8);
                     elsif Sub = "TEMPORAL" then Commit_Token(Tok_Temporal, 8);
                     elsif Sub = "TIMELINE" then Commit_Token(Tok_Timeline, 8);
                     elsif Sub = "VMOUSE_X" then Commit_Token(TOK_VMOUSE_X, 8);
                     elsif Sub = "VMOUSE_Y" then Commit_Token(TOK_VMOUSE_Y, 8);
                     elsif Sub = "SET_CLIP" then Commit_Token(TOK_SET_CLIP, 8);
                     elsif Sub = "BITFIELD" then Commit_Token(Tok_Bitfield, 8);
                     elsif Sub = "IMPORT_C" then Commit_Token(Tok_IMPORT_C, 8);
                     elsif Sub = "COMPTIME" then Commit_Token(TOK_COMPTIME, 8);
                     elsif C >= 'A' and C <= 'Z' then Commit_Token(Tok_Logic_Var, Len);
                     else Commit_Token(Tok_Atom, Len); end if;
                    when 10 =>
                       if Sub = "CONSTRAINT" then Commit_Token(Tok_Constraint, 10);
                     elsif Sub = "EXPORT_PPM" then Commit_Token(Tok_Export_PPM, 10);
                      elsif Sub = "SYNTHBAKE" then Commit_Token(Tok_Synth_Bake, 10);
                      elsif Sub = "SYNTH_BAKE" then Commit_Token(Tok_Synth_Bake, 10);
                     elsif Sub = "MORTONTILE" then Commit_Token(Tok_Morton_Tile, 10);
                     elsif Sub = "MCP_LISTEN" then Commit_Token(Tok_Mcp_Listen, 10);
                     elsif Sub = "RATIOSPACE" then Commit_Token(Tok_Ratio_Space, 10);
                     elsif Sub = "BITMAPFONT" then Commit_Token(Tok_Bitmap_Font, 10);
                     elsif Sub = "DESCRIPTOR" then Commit_Token(Tok_Descriptor, 10);
                     elsif Sub = "SYSTEMFONT" then Commit_Token(Tok_System_Font, 10);
                     elsif Sub = "VISUALRULE" then Commit_Token(Tok_Visual_Rule, 10);
                     elsif Sub = "SETSHOEBOX" then Commit_Token(Tok_Set_Shoebox, 10);
                     elsif Sub = "GLYPHWIDTH" then Commit_Token(Tok_Glyph_Width, 10);
                     elsif Sub = "FIRST_CHAR" then Commit_Token(Tok_First_Char, 10);
                     elsif Sub = "ANTI_ALIAS" then Commit_Token(Tok_Anti_Alias, 10);
                     elsif Sub = "ENDPROCESS" then Commit_Token(Tok_End_Process, 10);
                     elsif Sub = "HACKMEMORY" then Commit_Token(Tok_Hack_Memory, 10);
                      elsif Sub = "INJECTCODE" then Commit_Token(Tok_Inject_Code, 10);
                      elsif Sub = "INJECTPAGE" then Commit_Token(Tok_Inject_Page, 10);
                     elsif Sub = "END_SOCKET" then Commit_Token(Tok_End_Socket, 10);
                     elsif Sub = "END_MATRIX" then Commit_Token(Tok_End_Matrix, 10);
                     elsif Sub = "ACTIVATION" then Commit_Token(Tok_Activation, 10);
                     elsif Sub = "PROCESSPID" then Commit_Token(Tok_Process_Pid, 10);
                     elsif Sub = "IMPORT_DLL" then Commit_Token(Tok_Import_DLL, Len);
                     elsif Sub = "EXPORT_DLL" then Commit_Token(Tok_Export_DLL, Len);
                     elsif Sub = "IMPORT_JAR" then Commit_Token(Tok_Import_JAR, Len);
                     elsif Sub = "EXPORT_JAR" then Commit_Token(Tok_Export_JAR, Len);
                     elsif Sub = "IMPORTWASM" then Commit_Token(Tok_Import_WASM, 10);
                     elsif Sub = "EXPORTWASM" then Commit_Token(Tok_Export_WASM, 10);
                     elsif Sub = "SET_ORIGIN" then Commit_Token(TOK_SET_ORIGIN, 10);
                     elsif Sub = "READ_PIXEL" then Commit_Token(TOK_READ_PIXEL, 10);
                     elsif Sub = "DISABLEASM" then Commit_Token(TOK_DISABLEASM, 10);
                     elsif Sub = "REVERSIBLE" then Commit_Token(Tok_Reversible, 10);
                     elsif Sub = "SAVE_STATE" then Commit_Token(TOK_SAVE_STATE, 10);
                     elsif Sub = "LOAD_STATE" then Commit_Token(TOK_LOAD_STATE, 10);
                     elsif C >= 'A' and C <= 'Z' then Commit_Token(Tok_Logic_Var, Len); else Commit_Token(Tok_Atom, Len); end if;
                  when 11 =>
                     if Sub = "MOUSE_CLICK" then Commit_Token(Tok_Mouse_Click, 11);
                     elsif Sub = "MOUSE_WHEEL" then Commit_Token(Tok_Mouse_Wheel, 11);
                      -- SYNTH_BAKE moved to Len=10
                     elsif Sub = "MORTON_TILE" then Commit_Token(Tok_Morton_Tile, 11);
                     elsif Sub = "RATIO_SPACE" then Commit_Token(Tok_Ratio_Space, 11);
                     elsif Sub = "BITMAP_FONT" then Commit_Token(Tok_Bitmap_Font, 11);
                     elsif Sub = "SYSTEM_FONT" then Commit_Token(Tok_System_Font, 11);
                     elsif Sub = "VISUAL_RULE" then Commit_Token(Tok_Visual_Rule, 11);
                     elsif Sub = "SET_SHOEBOX" then Commit_Token(Tok_Set_Shoebox, 11);
                     elsif Sub = "GLYPH_WIDTH" then Commit_Token(Tok_Glyph_Width, 11);
                     elsif Sub = "GLYPHHEIGHT" then Commit_Token(Tok_Glyph_Height, 11);
                     elsif Sub = "CONSTRAINTO" then Commit_Token(Tok_Constrain_To, 11);
                      elsif Sub = "END_PROCESS" then Commit_Token(Tok_End_Process, 11);
                      elsif Sub = "END_SNIFFER" then Commit_Token(Tok_End_Sniffer, 11);
                      elsif Sub = "HACK_MEMORY" then Commit_Token(Tok_Hack_Memory, 11);
                      elsif Sub = "INJECT_CODE" then Commit_Token(Tok_Inject_Code, 11);
                      elsif Sub = "INJECTFLAGS" then Commit_Token(Tok_Inject_Flags, 11);
                      elsif Sub = "INJECT_PAGE" then Commit_Token(Tok_Inject_Page, 11);
                     elsif Sub = "ENCRYPTFILE" then Commit_Token(Tok_Encrypt_File, 11);
                     elsif Sub = "DECRYPTFILE" then Commit_Token(Tok_Decrypt_File, 11);
                     elsif Sub = "PERMIT_READ" then Commit_Token(Tok_Permit_Read, 11);
                     elsif Sub = "BUFFER_SIZE" then Commit_Token(Tok_Buffer_Size, 11);
                     elsif Sub = "PROCESS_PID" then Commit_Token(Tok_Process_Pid, 11);
                     elsif Sub = "IMPORT_WASM" then Commit_Token(Tok_Import_WASM, 11);
                     elsif Sub = "EXPORT_WASM" then Commit_Token(Tok_Export_WASM, 11);
                     elsif Sub = "IMPORTDYLIB" then Commit_Token(Tok_Import_DYLIB, 11);
                     elsif Sub = "EXPORTDYLIB" then Commit_Token(Tok_Export_DYLIB, 11);
                     elsif Sub = "SETSTRETCHY" then Commit_Token(TOK_SET_STRETCHY, 11);
                     elsif Sub = "END_EMOTION" then Commit_Token(Tok_End_Emotion, 11);
                     elsif C >= 'A' and C <= 'Z' then Commit_Token(Tok_Logic_Var, Len); else Commit_Token(Tok_Atom, Len); end if;
                  when 12 =>
                     if Sub = "NETWORKSNIFF" then Commit_Token(Tok_Network_Sniff, 12);
                      elsif Sub = "STREAMBYPASS" then Commit_Token(Tok_Stream_Bypass, 12);
                      elsif Sub = "MOUNTARCHIVE" then Commit_Token(Tok_Mount_Archive, 12);
                      elsif Sub = "KNOWS_CHANGE" then Commit_Token(Tok_Change, 12);
                     elsif Sub = "CONSTRAIN_TO" then Commit_Token(Tok_Constrain_To, 12);
                     elsif Sub = "GLYPH_HEIGHT" then Commit_Token(Tok_Glyph_Height, 12);
                     elsif Sub = "CHARACTERSET" then Commit_Token(Tok_Character_Set, 12);
                      elsif Sub = "STATICSPRITE" then Commit_Token(Tok_Static_Sprite, 12);
                      elsif Sub = "PROCESSIMAGE" then Commit_Token(Tok_Process_Image, 12);
                      elsif Sub = "SNIFFNETWORK" then Commit_Token(Tok_Sniff_Network, 12);
                      elsif Sub = "INJECT_FLAGS" then Commit_Token(Tok_Inject_Flags, 12);
                     elsif Sub = "ELEVATEPRIVS" then Commit_Token(Tok_Elevate_Privileges, 12);
                     elsif Sub = "ENCRYPT_FILE" then Commit_Token(Tok_Encrypt_File, 12);
                     elsif Sub = "DECRYPT_FILE" then Commit_Token(Tok_Decrypt_File, 12);
                     elsif Sub = "END_FIREWALL" then Commit_Token(Tok_End_Firewall, 12);
                     elsif Sub = "PERMIT_WRITE" then Commit_Token(Tok_Permit_Write, 12);
                     elsif Sub = "IMPORT_DYLIB" then Commit_Token(Tok_Import_DYLIB, 12);
                     elsif Sub = "EXPORT_DYLIB" then Commit_Token(Tok_Export_DYLIB, 12);
                     elsif Sub = "MARKOV_MODEL" then Commit_Token(Tok_Markov_Model, 12);
                     elsif Sub = "NETWORK_SEND" then Commit_Token(Tok_Network_Send, 12);
                     elsif Sub = "END_TOPOLOGY" then Commit_Token(Tok_End_Topology, 12);
                     elsif Sub = "SETRESIZABLE" then Commit_Token(TOK_SET_RESIZABLE, 12);
                     elsif Sub = "SET_STRETCHY" then Commit_Token(TOK_SET_STRETCHY, 12);
                     elsif Sub = "SCREEN_WIDTH" then Commit_Token(TOK_SCREEN_WIDTH, 12);
                     elsif Sub = "SYS_RENDERER" then Commit_Token(TOK_SYS_RENDERER, 12);
                     elsif C >= 'A' and C <= 'Z' then Commit_Token(Tok_Logic_Var, Len); else Commit_Token(Tok_Atom, Len); end if;
                   when 13 =>
                      if Sub = "PARSEETHERNET" then Commit_Token(Tok_Parse_Ethernet, 13);
                      elsif Sub = "MOUNT_ARCHIVE" then Commit_Token(Tok_Mount_Archive, 13);
                      elsif Sub = "NETWORK_SNIFF" then Commit_Token(Tok_Network_Sniff, 13);
                      elsif Sub = "DECLAREMODULE" then Commit_Token(Tok_DeclareModule, 13); -- DA NEW DECLAREMODULE
                     elsif Sub = "CHARACTER_SET" then Commit_Token(Tok_Character_Set, 13);
                     elsif Sub = "STATICSURFACE" then Commit_Token(Tok_Static_Surface, 13);
                     elsif Sub = "STATIC_SPRITE" then Commit_Token(Tok_Static_Sprite, 13);
                     elsif Sub = "NETWORKSOCKET" then Commit_Token(Tok_Network_Socket, 13);
                     elsif Sub = "NETWORKLISTEN" then Commit_Token(Tok_Network_Listen, 13);
                     elsif Sub = "NETWORKACCEPT" then Commit_Token(Tok_Network_Accept, 13);
                     elsif Sub = "PREDICTMARKOV" then Commit_Token(Tok_Predict_Markov, 13);
                     elsif Sub = "PROCESSHANDLE" then Commit_Token(Tok_Process_Handle, 13);
                     elsif Sub = "PROCESS_IMAGE" then Commit_Token(Tok_Process_Image, 13);
                      elsif Sub = "PROCESSRIGHTS" then Commit_Token(Tok_Process_Rights, 13);
                      elsif Sub = "INJECTSYSCALL" then Commit_Token(Tok_Inject_Syscall, 13);
                      elsif Sub = "CREATEPROCESS" then Commit_Token(Tok_Create_Process, 13);
                     elsif Sub = "SNIFF_NETWORK" then Commit_Token(Tok_Sniff_Network, 13);
                     elsif Sub = "TERMINATEPROC" then Commit_Token(Tok_Terminate_Process, 13);
                     elsif Sub = "NETWORK_CLOSE" then Commit_Token(Tok_Network_Close, 13);
                     elsif Sub = "INFER_NETWORK" then Commit_Token(Tok_Infer_Network, 13);
                     elsif Sub = "TRAIN_NETWORK" then Commit_Token(Tok_Train_Network, 13);
                     elsif Sub = "CREATE_WINDOW" then Commit_Token(Tok_Create_Window, 13);
                     elsif Sub = "BLEND_EMOTION" then Commit_Token(Tok_Blend_Emotion, 13);
                     elsif Sub = "DECAY_EMOTION" then Commit_Token(Tok_Decay_Emotion, 13);
                     elsif Sub = "SETFULLSCREEN" then Commit_Token(TOK_SET_FULLSCREEN, 13);
                     elsif Sub = "SET_RESIZABLE" then Commit_Token(TOK_SET_RESIZABLE, 13);
                     elsif Sub = "SCREEN_HEIGHT" then Commit_Token(TOK_SCREEN_HEIGHT, 13);
                      elsif Sub = "VIRTUAL_WIDTH" then Commit_Token(TOK_VIRTUAL_WIDTH, 13);
                      elsif Sub = "STREAM_BYPASS" then Commit_Token(Tok_Stream_Bypass, 13);
                      elsif C >= 'A' and C <= 'Z' then Commit_Token(Tok_Logic_Var, Len); else Commit_Token(Tok_Atom, Len); end if;
                    when 14 =>
                       if Sub = "PARSE_ETHERNET" then Commit_Token(Tok_Parse_Ethernet, 14);
                       elsif Sub = "NETWORKSNIFFER" then Commit_Token(Tok_Network_Sniffer, 14);
                       elsif Sub = "VIRTUAL_HEIGHT" then Commit_Token(TOK_VIRTUAL_HEIGHT, 14);
                     elsif Sub = "STATIC_SURFACE" then Commit_Token(Tok_Static_Surface, 14);
                     elsif Sub = "RENDERVIEWPORT" then Commit_Token(Tok_Render_Viewport, 14);
                     elsif Sub = "NETWORK_SOCKET" then Commit_Token(Tok_Network_Socket, 14);
                     elsif Sub = "NETWORK_LISTEN" then Commit_Token(Tok_Network_Listen, 14);
                     elsif Sub = "NETWORK_ACCEPT" then Commit_Token(Tok_Network_Accept, 14);
                     elsif Sub = "PREDICT_MARKOV" then Commit_Token(Tok_Predict_Markov, 14);
                     elsif Sub = "CREATE_PROCESS" then Commit_Token(Tok_Create_Process, 14);
                      elsif Sub = "PROCESS_HANDLE" then Commit_Token(Tok_Process_Handle, 14);
                      elsif Sub = "INJECT_SYSCALL" then Commit_Token(Tok_Inject_Syscall, 14);
                      elsif Sub = "PROCESS_RIGHTS" then Commit_Token(Tok_Process_Rights, 14);
                     elsif C >= 'A' and C <= 'Z' then Commit_Token(Tok_Logic_Var, Len); else Commit_Token(Tok_Atom, Len); end if;
                   when 15 =>
                      if Sub = "NETWORK_SNIFFER" then Commit_Token(Tok_Network_Sniffer, 15);
                      elsif Sub = "NETWORK_RECEIVE" then Commit_Token(Tok_Network_Receive, 15);
                     elsif Sub = "RENDER_VIEWPORT" then Commit_Token(Tok_Render_Viewport, 15);
                     elsif Sub = "MEMORY_FIREWALL" then Commit_Token(Tok_Memory_Firewall, 15);
                     elsif Sub = "NEURAL_TOPOLOGY" then Commit_Token(Tok_Neural_Topology, 15);
                     elsif C >= 'A' and C <= 'Z' then Commit_Token(Tok_Logic_Var, Len); else Commit_Token(Tok_Atom, Len); end if;
                   when 16 =>
                      if Sub = "INJECTCODEMEMORY" then Commit_Token(Tok_Inject_Code_Memory, 16);
                      elsif Sub = "INJECTPAYLOADTYPE" then Commit_Token(Tok_Inject_Payload_Type, 16);
                      elsif Sub = "TERMINATEPROCESS" then Commit_Token(Tok_Terminate_Process, 16);
                      elsif Sub = "DOMINANT_EMOTION" then Commit_Token(Tok_Dominant_Emotion, 16);
                      elsif C >= 'A' and C <= 'Z' then Commit_Token(Tok_Logic_Var, Len); else Commit_Token(Tok_Atom, Len); end if;
                  when 17 =>
                     if Sub = "TRANSITION_MATRIX" then Commit_Token(Tok_Transition_Matrix, 17);
                     elsif Sub = "READPROCESSMEMORY" then Commit_Token(Tok_Read_Process_Memory, 17);
                     elsif Sub = "DUMPPROCESSMEMORY" then Commit_Token(Tok_Dump_Process_Memory, 17);
                     elsif Sub = "ELEVATEPRIVILEGES" then Commit_Token(Tok_Elevate_Privileges, 17);
                     elsif Sub = "TERMINATE_PROCESS" then Commit_Token(Tok_Terminate_Process, 17);
                     elsif C >= 'A' and C <= 'Z' then Commit_Token(Tok_Logic_Var, Len); else Commit_Token(Tok_Atom, Len); end if;
                  when 18 =>
                     if Sub = "INJECT_CODE_MEMORY" then Commit_Token(Tok_Inject_Code_Memory, 18);
                     elsif Sub = "WRITEPROCESSMEMORY" then Commit_Token(Tok_Write_Process_Memory, 18);
                     elsif Sub = "ELEVATE_PRIVILEGES" then Commit_Token(Tok_Elevate_Privileges, 18);
                     elsif C >= 'A' and C <= 'Z' then Commit_Token(Tok_Logic_Var, Len); else Commit_Token(Tok_Atom, Len); end if;
                   when 19 =>
                      if Sub = "HIJACKPROCESSMEMORY" then Commit_Token(Tok_Hijack_Process_Memory, 19);
                      elsif Sub = "INJECT_PAYLOAD_TYPE" then Commit_Token(Tok_Inject_Payload_Type, 19);
                      elsif Sub = "READ_PROCESS_MEMORY" then Commit_Token(Tok_Read_Process_Memory, 19);
                      elsif Sub = "DUMP_PROCESS_MEMORY" then Commit_Token(Tok_Dump_Process_Memory, 19);
                      elsif C >= 'A' and C <= 'Z' then Commit_Token(Tok_Logic_Var, Len); else Commit_Token(Tok_Atom, Len); end if;
                  when 20 =>
                     if Sub = "MONITORPROCESSMEMORY" then Commit_Token(Tok_Monitor_Process_Memory, 20);
                     elsif Sub = "WRITE_PROCESS_MEMORY" then Commit_Token(Tok_Write_Process_Memory, 20);
                     elsif C >= 'A' and C <= 'Z' then Commit_Token(Tok_Logic_Var, Len); else Commit_Token(Tok_Atom, Len); end if;
                  when 21 =>
                     if Sub = "HIJACK_PROCESS_MEMORY" then Commit_Token(Tok_Hijack_Process_Memory, 21);
                     elsif C >= 'A' and C <= 'Z' then Commit_Token(Tok_Logic_Var, Len); else Commit_Token(Tok_Atom, Len); end if;
                  when 22 =>
                     if Sub = "MONITOR_PROCESS_MEMORY" then Commit_Token(Tok_Monitor_Process_Memory, 22);
                     elsif C >= 'A' and C <= 'Z' then Commit_Token(Tok_Logic_Var, Len); else Commit_Token(Tok_Atom, Len); end if;
                       
                  when others =>
                     if C >= 'A' and C <= 'Z' then Commit_Token(Tok_Logic_Var, Len); else Commit_Token(Tok_Atom, Len); end if;
                  end case;
                  end if;
                  
               end if;
            end;

         else
            case C is
               when '(' => Commit_Token(Tok_L_Paren, 1);
               when ')' => Commit_Token(Tok_R_Paren, 1);
               when '[' => Commit_Token(Tok_L_Square, 1);
               when ']' => Commit_Token(Tok_R_Square, 1);
               when '{' => Commit_Token(Tok_Begin, 1);
               when '}' => Commit_Token(Tok_End, 1);
               when ',' => Commit_Token(Tok_Comma, 1);
               when '.' =>
                  if I < Input'Last and then Input(I + 1) = '.' then
                     Commit_Token(Tok_Dot_Dot, 2);
                  else
                     Commit_Token(Tok_Dot, 1);
                  end if;

               when ':' => 
                  if I < Input'Last and then Input(I+1) = '-' then Commit_Token(Tok_Horn_Clause, 2);
                  else 
                     --Set_Error(Err_Lex_Rogue_Symbol, Token_Line, Token_Col); Commit_Token(Tok_Error, 1); 
                     Commit_Token(Tok_Colon, 1);
                  end if;
               when '?' => 
                  if I < Input'Last and then Input(I+1) = '-' then Commit_Token(Tok_Query, 2);
                  else 
                     Commit_Token(Tok_Question, 1);
                  end if;
               when '=' => 
                  if I < Input'Last and then Input(I+1) = '>' then 
                     Commit_Token(Tok_Arrow, 2); 
                  elsif I < Input'Last and then Input(I+1) = '=' then
                     Commit_Token(Tok_Equal, 2); -- DA FIX 3: Equivalency Gate (==)
                  else
                     Commit_Token(Tok_Assign, 1);
                  end if;
               when '!' => -- DA FIX 3: Not Equal Gate (!=)
                  if I < Input'Last and then Input(I+1) = '=' then
                     Commit_Token(Tok_Not_Equal, 2);
                  else
                     Commit_Token(Tok_Cut, 1); -- DA NEW PROLOG CUT OPERATOR
                  end if;
               when '+' => Commit_Token(Tok_Plus, 1);
               when '-' => 
                  if I < Input'Last and then Input(I+1) = '>' then 
                     Commit_Token(Tok_Arrow, 2);
                  else 
                     Commit_Token(Tok_Minus, 1); -- Context-free minus!
                  end if;
               when '*' =>
                  if I < Input'Last and then Input(I + 1) = '*' then
                     Commit_Token(Tok_Pow, 2);
                  else
                     Commit_Token(Tok_Mul, 1);
                  end if;
               when '/' => Commit_Token(Tok_Div, 1);
               when '^' => Commit_Token(Tok_Pow, 1);
               when '<' => 
                  if I < Input'Last and then Input(I+1) = '<' then Commit_Token(Tok_Shl, 2);
                  elsif I < Input'Last and then Input(I+1) = '=' then Commit_Token(Tok_Less_Equal, 2);
                  elsif I < Input'Last and then Input(I+1) = '>' then Commit_Token(Tok_Not_Equal, 2); -- Supports Pascal/SQL style (<>)
                  else Commit_Token(Tok_Less, 1); end if;
               when '>' => 
                  if I < Input'Last and then Input(I+1) = '>' then Commit_Token(Tok_Shr, 2);
                  elsif I < Input'Last and then Input(I+1) = '=' then Commit_Token(Tok_Greater_Equal, 2);
                  else Commit_Token(Tok_Greater, 1); end if;
               when '@' => Commit_Token(Tok_AddressOf, 1);
               when '|' => Commit_Token(Tok_PIPE, 1);
               -- Note: '&' is handled earlier in the elsif chain (octal
               -- literal &Onnn / Tok_Ampersand pipe alias), it never
               -- reaches this case.
               when others =>
                  Set_Error(Err_Lex_Rogue_Symbol, Token_Line, Token_Col); Commit_Token(Tok_Error, 1);
            end case;
         end if;
      end loop;
   end Scan;

   -- ============================================================================
   --  BACKTICK STRING INTERPOLATION
   --  `pre{expr}post`  ->  "pre" | expr | "post"
   --
   --  Spliced at the token level so every backend sees a plain concat
   --  chain: fragment tokens are raw source spans whose first/last
   --  chars are the existing delimiters — '{', '}' and '`' all sit
   --  exactly where the emitter strips one char each side.
   --  '{{' emits a literal '{' via a 3-char span; '}' is free text in
   --  fragments (only closes an open interpolation).  Double-quoted
   --  strings are never touched — braces stay literal there.
   -- ============================================================================
   --  One pass per interpolated string (nesting adds a bounded few
   --  more); the cap only guards against non-convergence.
   Max_Interp_Passes : constant := 4096;

   function Is_Interp_String (Input : String; T : Token) return Boolean is
   begin
      if T.Kind /= Tok_String or else T.Length < 2 then return False; end if;
      if Input (T.Start) /= '`' then return False; end if;
      for P in T.Start + 1 .. T.Start + T.Length - 2 loop
         if Input (P) = '{' then return True; end if;
      end loop;
      return False;
   end Is_Interp_String;

   --  Find the first '}' at or after From, skipping "..." and `...`
   --  quoted spans (their braces are text, not structure).  0 = none.
   function Interp_Close (Input : String; From, Last : Positive) return Natural is
      P : Natural := From;
   begin
      while P <= Last loop
         if Input (P) = '"' or else Input (P) = '`' then
            declare
               Q : constant Character := Input (P);
            begin
               P := P + 1;
               while P <= Last and then Input (P) /= Q loop
                  P := P + 1;
               end loop;
            end;
         elsif Input (P) = '}' then
            return P;
         end if;
         P := P + 1;
      end loop;
      return 0;
   end Interp_Close;

   --  Expand the first interpolated string in the token stream.
   --  Returns False when none exist (the while-loop in Tokenize ends).
   procedure Expand_One_Interp (Input       : in String;
                                Tokens      : in out Token_Array;
                                Token_Count : in out Natural;
                                Diagnostic  : in out Lexer_Diagnostic;
                                Found       : out Boolean) is
      T        : Natural := 0;
      T_Start  : Positive := 1;
      T_End    : Positive := 1;
      Endm1    : Positive := 1;
      T_Line   : Positive := 1;
      T_Col    : Positive := 1;
      Pieces   : Natural := 0;       --  piece count (frags + exprs + lits)
      RC       : Natural := 0;       --  replacement token count
      Sub      : Lexer_Diagnostic;
      Fail     : Boolean := False;
      F, P, Q  : Natural;
      Expr_Lo, Expr_Hi : Natural;

      --  One piece-walk shared by the measure and emit passes.
      procedure Walk (Emit : in Boolean; W : in out Natural;
                      Count_Only : out Natural) is
         Frag_Len : Natural;
         SubN     : Natural;
         Seed     : Natural;
      begin
         Count_Only := 0;
         Pieces := 0;
         F := T_Start;
         P := F + 1;
         while P <= Endm1 and then not Fail loop
            if Input (P) = '{' then
               --  fragment [F..P]: '{' is the strip char
               Frag_Len := P - F + 1;
               if Frag_Len >= 2 then          --  strips to >= 0 chars
                  if Emit and then Pieces > 0 then
                     Tokens (W) := (Kind => Tok_PIPE, Start => P,
                                    Length => 1,
                                    Line => T_Line,
                                    Column => T_Col);
                     W := W + 1;
                  end if;
                  if Emit then
                     Tokens (W) := (Kind => Tok_String, Start => F,
                                    Length => Frag_Len,
                                    Line => T_Line,
                                    Column => T_Col);
                     W := W + 1;
                  else
                     Count_Only := Count_Only + 1;
                  end if;
                  Pieces := Pieces + 1;
                  if Pieces > 1 then Count_Only := Count_Only + 1; end if;
               end if;
               if P + 1 <= Endm1 and then Input (P + 1) = '{' then
                  --  '{{' escape: 3-char span '{{X' strips to '{'
                  if Emit and then Pieces > 0 then
                     Tokens (W) := (Kind => Tok_PIPE, Start => P,
                                    Length => 1,
                                    Line => T_Line,
                                    Column => T_Col);
                     W := W + 1;
                  end if;
                  if Emit then
                     Tokens (W) := (Kind => Tok_String, Start => P,
                                    Length => 3,
                                    Line => T_Line,
                                    Column => T_Col);
                     W := W + 1;
                  else
                     Count_Only := Count_Only + 1;
                  end if;
                  Pieces := Pieces + 1;
                  if Pieces > 1 then Count_Only := Count_Only + 1; end if;
                  F := P + 1;   --  second '{' is the frag's strip char
                  P := P + 2;
               else
                  --  interpolation: find matching '}'
                  if Emit and then Pieces > 0 then
                     Tokens (W) := (Kind => Tok_PIPE, Start => P,
                                    Length => 1,
                                    Line => T_Line,
                                    Column => T_Col);
                     W := W + 1;
                  end if;
                  if Pieces > 0 then Count_Only := Count_Only + 1; end if;
                  Q := Interp_Close (Input, P + 1, Endm1);
                  if Q = 0 or else Q = P + 1 then
                     Diagnostic := (Success    => False,
                                    Error_Line => T_Line,
                                    Error_Col  => T_Col,
                                    Code       => Err_Lex_Bad_Interp);
                     Fail := True;
                  else
                     Expr_Lo := P + 1;
                     Expr_Hi := Q - 1;
                     if Emit then
                        Seed := W - 1;   --  prev token = the pipe just written
                        Scan (Input (Expr_Lo .. Expr_Hi), Tokens, Seed,
                              Sub, T_Line,
                              T_Col + P - T_Start, False);
                        if not Sub.Success then
                           Diagnostic := Sub;
                           Fail := True;
                        else
                           W := Seed + 1;
                        end if;
                     else
                        --  measure into scratch: dummy pipe at Count+1
                        --  so prev-token context matches the emit pass
                        Tokens (Token_Count + 1) :=
                          (Kind => Tok_PIPE, Start => P, Length => 1,
                           Line => T_Line,
                           Column => T_Col);
                        Seed := Token_Count + 1;
                        Scan (Input (Expr_Lo .. Expr_Hi), Tokens, Seed,
                              Sub, T_Line,
                              T_Col + P - T_Start, True);
                        if not Sub.Success then
                           Diagnostic := Sub;
                           Fail := True;
                        else
                           SubN := Seed - (Token_Count + 1);
                           Count_Only := Count_Only + SubN;
                        end if;
                     end if;
                     Pieces := Pieces + 1;
                     F := Q;
                     P := Q + 1;
                  end if;
               end if;
            else
               P := P + 1;
            end if;
         end loop;
         if not Fail then
            --  closing fragment [F..T_End]: '`' is the strip char
            Frag_Len := T_End - F + 1;
            if Frag_Len >= 2 then
               if Emit and then Pieces > 0 then
                  Tokens (W) := (Kind => Tok_PIPE, Start => T_End,
                                 Length => 1,
                                 Line => T_Line,
                                 Column => T_Col);
                  W := W + 1;
               end if;
               if Emit then
                  Tokens (W) := (Kind => Tok_String, Start => F,
                                 Length => Frag_Len,
                                 Line => T_Line,
                                 Column => T_Col);
                  W := W + 1;
               else
                  Count_Only := Count_Only + 1;
               end if;
               Pieces := Pieces + 1;
               if Pieces > 1 then Count_Only := Count_Only + 1; end if;
            end if;
         end if;
      end Walk;

      W_Dummy : Natural := 0;
      Shift_N   : Integer := 0;
   begin
      --  locate the first backtick string containing '{'
      for I in 1 .. Token_Count loop
         if Is_Interp_String (Input, Tokens (I)) then
            T := I;
            exit;
         end if;
      end loop;
      if T = 0 then Found := False; return; end if;

      T_Start := Tokens (T).Start;
      T_End   := T_Start + Tokens (T).Length - 1;
      Endm1   := T_End - 1;
      T_Line  := Tokens (T).Line;
      T_Col   := Tokens (T).Column;

      --  measure pass: how many replacement tokens
      Walk (Emit => False, W => W_Dummy, Count_Only => RC);
      if Fail then Found := True; return; end if;

      Shift_N := Integer (RC) - 1;
      if Token_Count + Natural (Shift_N) > Max_Tokens then
         Diagnostic := (Success    => False,
                        Error_Line => T_Line,
                        Error_Col  => T_Col,
                        Code       => Err_Mem_Out_Of_Bounds);
         Found := True;
         return;
      end if;

      --  open the hole: shift the tail right, copying backwards
      if Shift_N > 0 then
         for K in reverse T + 1 .. Token_Count loop
            Tokens (K + Natural (Shift_N)) := Tokens (K);
         end loop;
         Token_Count := Token_Count + Natural (Shift_N);
      end if;

      --  emit pass: write pieces into the hole
      W_Dummy := T;
      declare
         Written : Natural := 0;
      begin
         Walk (Emit => True, W => W_Dummy, Count_Only => Written);
      end;
      Found := True;
   end Expand_One_Interp;

   procedure Tokenize (Input       : in String;
                       Tokens      : out Token_Array;
                       Token_Count : out Natural;
                       Diagnostic  : out Lexer_Diagnostic) is
      Passes : Natural := 0;
      Found  : Boolean;
   begin
      Token_Count := 0;
      Diagnostic := (Success => True, Error_Line => 1, Error_Col => 1,
                     Code => Err_None);
      Scan (Input, Tokens, Token_Count, Diagnostic);
      while Diagnostic.Success loop
         Expand_One_Interp (Input, Tokens, Token_Count,
                            Diagnostic, Found);
         exit when not Found;
         Passes := Passes + 1;
         if Passes > Max_Interp_Passes then
            Diagnostic := (Success => False, Error_Line => 1,
                           Error_Col => 1, Code => Err_Lex_Bad_Interp);
            exit;
         end if;
      end loop;
   end Tokenize;

end Tokenizer;

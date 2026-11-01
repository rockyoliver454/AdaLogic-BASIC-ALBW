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

with Ada.Unchecked_Conversion;

package body Wat_Assembler is

   --  ===================== bounded limits =====================
   Max_Wat_Tokens  : constant := 131072;
   Max_Funcs       : constant := 1024;
   Max_Types       : constant := 512;
   Max_Globals     : constant := 256;
   Max_Imports     : constant := 512;
   Max_Data_Segs   : constant := 256;
   Max_Local_Slots : constant := 32768;  -- params+locals, all funcs
   Max_Label_Depth : constant := 256;
   Max_Instr_Depth : constant := 512;

   --  ===================== token stream =====================
   type TK is (TK_LPar, TK_RPar, TK_Atom, TK_Str, TK_EOF);
   type Wat_Tok is record
      Kind : TK := TK_EOF;
      Pos  : Positive := 1;
      Len  : Natural := 0;
      Line : Positive := 1;
   end record;

   Toks   : array (1 .. Max_Wat_Tokens) of Wat_Tok;
   N_Toks : Natural := 0;
   Cur    : Natural := 0;
   Src    : Unbounded_String := To_Unbounded_String ("");
   Err    : Unbounded_String := To_Unbounded_String ("");

   --  ===================== module model =====================
   type Func_Type is record
      NP : Natural := 0;
      NR : Natural := 0;
      P  : Param_Vec := (others => VT_I32);
      R  : Result_Vec := (others => VT_I32);
   end record;
   Types      : array (1 .. Max_Types) of Func_Type;
   Type_Names : array (1 .. Max_Types) of Unbounded_String :=
     (others => To_Unbounded_String (""));
   N_Types : Natural := 0;

   type Func_Rec is record
      Active     : Boolean := False;
      Imported   : Boolean := False;
      Wasm_Idx   : Natural := 0;
      Type_Idx   : Natural := 0;
      Name       : Unbounded_String := To_Unbounded_String ("");
      Imp_Mod    : Unbounded_String := To_Unbounded_String ("");
      Imp_Field  : Unbounded_String := To_Unbounded_String ("");
      Body_First : Natural := 0;
      Body_Last  : Natural := 0;
      Loc_Off    : Natural := 0;   -- first slot in Local_* arena
      Loc_Cnt    : Natural := 0;   -- params + locals (wasm local space)
      Par_Cnt    : Natural := 0;
      --  params implied by a bare (type $t) ref occupy wasm local
      --  indices but have NO arena slots:  arena slot for index I is
      --  Loc_Off + I - Implicit_Pars.  Stays 0 when (param) children
      --  are explicit (they ARE arena slots).
      Implicit_Pars : Natural := 0;
      --  (type idx) ref inside the func: resolved post-parse against
      --  the declared type table; Sig_* keeps the explicit sig for
      --  the required match check.
      Decl_Type_Tok : Natural := 0;
      Sig_Explicit  : Boolean := False;
      Sig_FT_NP     : Natural := 0;
      Sig_FT_NR     : Natural := 0;
      Sig_P : Param_Vec := (others => VT_I32);
      Sig_R : Result_Vec := (others => VT_I32);
   end record;
   Funcs   : array (1 .. Max_Funcs) of Func_Rec;
   N_Funcs : Natural := 0;

   type Glob_Rec is record
      Active     : Boolean := False;
      Imported   : Boolean := False;
      Mutable    : Boolean := False;
      Wasm_Idx   : Natural := 0;
      VT         : Value_Type := VT_I32;
      Name       : Unbounded_String := To_Unbounded_String ("");
      Imp_Mod    : Unbounded_String := To_Unbounded_String ("");
      Imp_Field  : Unbounded_String := To_Unbounded_String ("");
      Init_First : Natural := 0;
      Init_Last  : Natural := 0;
   end record;
   Globals   : array (1 .. Max_Globals) of Glob_Rec;
   N_Globals : Natural := 0;

   type Mem_Rec is record
      Active    : Boolean := False;
      Imported  : Boolean := False;
      Wasm_Idx  : Natural := 0;
      Min_Pages : Unsigned_64 := 0;
      Has_Max   : Boolean := False;
      Max_Pages : Unsigned_64 := 0;
      Name      : Unbounded_String := To_Unbounded_String ("");
      Imp_Mod   : Unbounded_String := To_Unbounded_String ("");
      Imp_Field : Unbounded_String := To_Unbounded_String ("");
   end record;
   Mems   : array (1 .. 4) of Mem_Rec;
   N_Mems : Natural := 0;

   --  import descriptors in declaration order (section 2)
   type Imp_Kind is (IK_Func, IK_Mem, IK_Glob);
   type Imp_Rec is record
      Kind     : Imp_Kind := IK_Func;
      Mod_Name : Unbounded_String := To_Unbounded_String ("");
      Field    : Unbounded_String := To_Unbounded_String ("");
      Ent_Idx  : Natural := 0;   -- index into Funcs / Mems / Globals
   end record;
   Imports   : array (1 .. Max_Imports) of Imp_Rec;
   N_Imports : Natural := 0;

   type Exp_Kind is (EK_Func, EK_Mem, EK_Glob);
   type Exp_Rec is record
      Active : Boolean := False;
      Kind   : Exp_Kind := EK_Func;
      Name   : Unbounded_String := To_Unbounded_String ("");
      Idx    : Natural := 0;      -- wasm index in the kind's space
      Pend   : Boolean := False;  -- unresolved ref (standalone export)
      P_Pos  : Natural := 0;
      P_Len  : Natural := 0;
   end record;
   Exps   : array (1 .. Max_Exports) of Exp_Rec;
   N_Exps : Natural := 0;

   type Data_Rec is record
      Active    : Boolean := False;
      Mem_Idx   : Natural := 0;
      Off_First : Natural := 0;   -- token span of offset const expr
      Off_Last  : Natural := 0;
      Byte_Off  : Natural := 0;   -- into Data_Arena
      Byte_Len  : Natural := 0;
   end record;
   Datas        : array (1 .. Max_Data_Segs) of Data_Rec;
   N_Datas      : Natural := 0;
   --  data bytes land in the big scratch type so Decode_String can
   --  write the arena directly (no 256KB stack copies)
   Data_Arena   : Byte_Vec (1 .. Max_Output_Bytes);
   Data_Arena_N : Natural := 0;

   Start_Pos : Natural := 0;  -- token of start func ref, 0 = none
   Start_Len : Natural := 0;
   Start_Line : Natural := 0;

   --  locals arena: params+locals; name refs point into Src (Pos=0: anon)
   Local_Types : array (1 .. Max_Local_Slots) of Value_Type;
   Local_NPos  : array (1 .. Max_Local_Slots) of Natural;
   Local_NLen  : array (1 .. Max_Local_Slots) of Natural;
   Local_N     : Natural := 0;

   --  scratch encode buffers (sections + per-func bodies + locals vec)
   subtype Big_Bytes is Byte_Vec (1 .. Max_Output_Bytes);
   Sec_Buf  : Big_Bytes;
   Sec_N    : Natural := 0;
   Body_Buf : Big_Bytes;
   Body_N   : Natural := 0;
   Loc_Buf  : Big_Bytes;
   Loc_N    : Natural := 0;   -- set by Encode_Func_Body (locals vec)
   Out_Buf  : Big_Bytes;      -- final module image; copied to Bytes
   Out_N    : Natural := 0;

   --  ===================== error ledger =====================
   procedure Fail (Line : Natural; Msg : String) is
   begin
      if Length (Err) = 0 then
         if Line = 0 then
            Err := To_Unbounded_String (Msg);
         else
            Err := To_Unbounded_String
              ("line" & Natural'Image (Line) & ": " & Msg);
         end if;
      end if;
   end Fail;

   --  ===================== lexer =====================
   function Is_WS (C : Character) return Boolean is
   begin
      return C = ' ' or else C = ASCII.HT or else C = ASCII.CR
        or else C = ASCII.LF;
   end Is_WS;

   function Atom_End (S : String; I : Natural) return Natural is
      J : Natural := I;
   begin
      while J <= S'Last loop
         exit when Is_WS (S (J)) or else S (J) = '(' or else S (J) = ')'
           or else S (J) = '"' or else S (J) = ';';
         J := J + 1;
      end loop;
      return J;
   end Atom_End;

   procedure Lex (S : String) is
      I  : Natural := S'First;
      Ln : Positive := 1;
      D  : Natural := 0;
      --  token positions are stored 1-based (Src-relative): callers can
      --  hand in buffer slices whose 'First is mid-source
      B0 : constant Natural := S'First - 1;
   begin
      N_Toks := 0;
      while I <= S'Last loop
         if S (I) = ASCII.LF then
            Ln := Ln + 1;
            I := I + 1;
         elsif Is_WS (S (I)) then
            I := I + 1;
         elsif S (I) = ';' and then I + 1 <= S'Last
           and then S (I + 1) = ';'
         then
            while I <= S'Last and then S (I) /= ASCII.LF loop
               I := I + 1;
            end loop;
         elsif S (I) = '(' and then I + 1 <= S'Last
           and then S (I + 1) = ';'
         then
            D := 1;
            I := I + 2;
            while I <= S'Last and then D > 0 loop
               if S (I) = ASCII.LF then
                  Ln := Ln + 1;
                  I := I + 1;
               elsif S (I) = '(' and then I + 1 <= S'Last
                 and then S (I + 1) = ';'
               then
                  D := D + 1;
                  I := I + 2;
               elsif S (I) = ';' and then I + 1 <= S'Last
                 and then S (I + 1) = ')'
               then
                  D := D - 1;
                  I := I + 2;
               else
                  I := I + 1;
               end if;
            end loop;
            if D > 0 then
               Fail (Ln, "unterminated (; ;) block comment");
               return;
            end if;
         elsif S (I) = '(' then
            N_Toks := N_Toks + 1;
            Toks (N_Toks) := (TK_LPar, I - B0, 1, Ln);
            I := I + 1;
         elsif S (I) = ')' then
            N_Toks := N_Toks + 1;
            Toks (N_Toks) := (TK_RPar, I - B0, 1, Ln);
            I := I + 1;
         elsif S (I) = '"' then
            declare
               Start : constant Natural := I;
            begin
               I := I + 1;
               while I <= S'Last and then S (I) /= '"' loop
                  if S (I) = ASCII.LF then
                     Ln := Ln + 1;
                  end if;
                  if S (I) = '\' then
                     I := I + 2;
                     if I - 1 <= S'Last and then I <= S'Last
                       and then S (I - 1) = 'u'
                     then
                        while I <= S'Last and then S (I) /= '}' loop
                           I := I + 1;
                        end loop;
                        if I <= S'Last then
                           I := I + 1;
                        end if;
                     end if;
                  else
                     I := I + 1;
                  end if;
               end loop;
               if I > S'Last then
                  Fail (Ln, "unterminated string literal");
                  return;
               end if;
               I := I + 1;
               N_Toks := N_Toks + 1;
               Toks (N_Toks) := (TK_Str, Start - B0, I - Start, Ln);
            end;
         elsif S (I) = ';' then
            Fail (Ln, "stray ';' outside comment");
            return;
         else
            declare
               Start : constant Natural := I;
            begin
               I := Atom_End (S, I);
               N_Toks := N_Toks + 1;
               Toks (N_Toks) := (TK_Atom, Start - B0, I - Start, Ln);
            end;
         end if;
         if N_Toks >= Max_Wat_Tokens then
            Fail (Ln, "wat token overflow");
            return;
         end if;
      end loop;
   end Lex;

   --  ===================== token helpers =====================
   function Tok_Text (T : Natural) return String is
   begin
      return Slice (Src, Toks (T).Pos, Toks (T).Pos + Toks (T).Len - 1);
   end Tok_Text;

   function Peek_Kind return TK is
   begin
      if Cur < 1 or else Cur > N_Toks then
         return TK_EOF;
      end if;
      return Toks (Cur).Kind;
   end Peek_Kind;

   function Peek_Line return Natural is
   begin
      if Cur >= 1 and then Cur <= N_Toks then
         return Toks (Cur).Line;
      end if;
      return 0;
   end Peek_Line;

   function Peek_List_Head (S : String) return Boolean is
   begin
      return Cur >= 1 and then Cur + 1 <= N_Toks
        and then Toks (Cur).Kind = TK_LPar
        and then Toks (Cur + 1).Kind = TK_Atom
        and then Tok_Text (Cur + 1) = S;
   end Peek_List_Head;

   procedure Expect_RPar (What : String) is
   begin
      if Peek_Kind /= TK_RPar then
         Fail (Peek_Line, "expected ')' closing " & What);
      else
         Cur := Cur + 1;
      end if;
   end Expect_RPar;

   procedure Maybe_Id (Name : out Unbounded_String) is
   begin
      Name := To_Unbounded_String ("");
      if Peek_Kind = TK_Atom then
         declare
            S : constant String := Tok_Text (Cur);
         begin
            if S'Length >= 2 and then S (S'First) = '$' then
               Name := To_Unbounded_String (S);
               Cur := Cur + 1;
            end if;
         end;
      end if;
   end Maybe_Id;

   --  decode a TK_Str token's contents into bytes (escapes resolved).
   --  Into must be a Big-compatible arena; N counts bytes already used.
   procedure Decode_String
     (T : Natural;
      Into : in out Byte_Vec;
      N : in out Natural) is
      S    : constant String :=
        Slice (Src, Toks (T).Pos, Toks (T).Pos + Toks (T).Len - 1);
      I    : Natural := S'First + 1;
      Last : constant Natural := S'Last - 1;
      Hexv : Integer;
      Cp   : Unsigned_64;
      OK   : Boolean;

      function Hex_Digit (C : Character) return Integer is
      begin
         if C >= '0' and then C <= '9' then
            return Character'Pos (C) - Character'Pos ('0');
         elsif C >= 'a' and then C <= 'f' then
            return Character'Pos (C) - Character'Pos ('a') + 10;
         elsif C >= 'A' and then C <= 'F' then
            return Character'Pos (C) - Character'Pos ('A') + 10;
         end if;
         return -1;
      end Hex_Digit;

      procedure Put_B (B : Unsigned_8) is
      begin
         if N < Into'Last then
            N := N + 1;
            Into (N) := B;
         else
            Fail (Toks (T).Line, "string/data too large");
         end if;
      end Put_B;
   begin
      while I <= Last loop
         if S (I) = '\' and then I + 1 <= Last then
            if S (I + 1) = 't' then
               Put_B (9);  I := I + 2;
            elsif S (I + 1) = 'n' then
               Put_B (10); I := I + 2;
            elsif S (I + 1) = 'r' then
               Put_B (13); I := I + 2;
            elsif S (I + 1) = '"' then
               Put_B (34); I := I + 2;
            elsif S (I + 1) = ''' then
               Put_B (39); I := I + 2;
            elsif S (I + 1) = '\' then
               Put_B (92); I := I + 2;
            elsif S (I + 1) = 'u' and then I + 2 <= Last
              and then S (I + 2) = '{'
            then
               Cp := 0;
               OK := True;
               I := I + 3;
               while I <= Last and then S (I) /= '}' loop
                  Hexv := Hex_Digit (S (I));
                  if Hexv < 0 then
                     OK := False;
                     exit;
                  end if;
                  Cp := Cp * 16 + Unsigned_64 (Hexv);
                  I := I + 1;
               end loop;
               if I <= Last and then S (I) = '}' then
                  I := I + 1;
               else
                  OK := False;
               end if;
               if not OK or else Cp > 16#10FFFF# then
                  Fail (Toks (T).Line, "bad \u{..} escape");
               elsif Cp < 16#80# then
                  Put_B (Unsigned_8 (Cp));
               elsif Cp < 16#800# then
                  Put_B (16#C0# or Unsigned_8 (Shift_Right (Cp, 6)));
                  Put_B (16#80# or Unsigned_8 (Cp and 16#3F#));
               elsif Cp < 16#10000# then
                  Put_B (16#E0# or Unsigned_8 (Shift_Right (Cp, 12)));
                  Put_B (16#80# or Unsigned_8 (Shift_Right (Cp, 6) and 16#3F#));
                  Put_B (16#80# or Unsigned_8 (Cp and 16#3F#));
               else
                  Put_B (16#F0# or Unsigned_8 (Shift_Right (Cp, 18)));
                  Put_B (16#80# or Unsigned_8 (Shift_Right (Cp, 12) and 16#3F#));
                  Put_B (16#80# or Unsigned_8 (Shift_Right (Cp, 6) and 16#3F#));
                  Put_B (16#80# or Unsigned_8 (Cp and 16#3F#));
               end if;
            elsif I + 2 <= Last
              and then Hex_Digit (S (I + 1)) >= 0
              and then Hex_Digit (S (I + 2)) >= 0
            then
               --  \HH two hex digits (WAT byte escape)
               Put_B (Unsigned_8
                      (Hex_Digit (S (I + 1)) * 16 +
                       Hex_Digit (S (I + 2))));
               I := I + 3;
            else
               Fail (Toks (T).Line, "unsupported escape in string");
               I := I + 2;
            end if;
         else
            Put_B (Unsigned_8 (Character'Pos (S (I))));
            I := I + 1;
         end if;
      end loop;
   end Decode_String;

   --  names decode into the shared scratch buffer (parse phase and
   --  encode phase are disjoint — Sec_Buf is free during parse)
   function Str_Text (T : Natural) return Unbounded_String is
      N : Natural := 0;
      R : Unbounded_String := To_Unbounded_String ("");
   begin
      Decode_String (T, Sec_Buf, N);
      for I in 1 .. N loop
         Append (R, Character'Val (Natural (Sec_Buf (I))));
      end loop;
      return R;
   end Str_Text;

   --  ===================== numeric literal parsing =====================
   procedure Parse_Int_Bits (T    : Natural;
                             Bits : Natural;
                             Val  : out Unsigned_64;
                             OK   : out Boolean) is
      S   : constant String := Tok_Text (T);
      Buf : String (1 .. 80);
      RN  : Natural := 0;
      Neg : Boolean := False;
      I   : Natural;
      V   : Unsigned_64 := 0;
      D   : Natural;
      Max : Unsigned_64;
   begin
      OK := False;
      Val := 0;
      if S'Length > Buf'Length then
         Fail (Toks (T).Line, "integer literal too long");
         return;
      end if;
      for K in S'Range loop
         if S (K) /= '_' then
            RN := RN + 1;
            Buf (RN) := S (K);
         end if;
      end loop;
      I := 1;
      if RN >= 1 and then Buf (I) = '-' then
         Neg := True;
         I := I + 1;
      elsif RN >= 1 and then Buf (I) = '+' then
         I := I + 1;
      end if;
      if I > RN then
         Fail (Toks (T).Line, "empty integer literal");
         return;
      end if;

      if RN - I + 1 >= 2 and then Buf (I) = '0'
        and then (Buf (I + 1) = 'x' or else Buf (I + 1) = 'X')
      then
         I := I + 2;
         if I > RN then
            Fail (Toks (T).Line, "empty hex literal");
            return;
         end if;
         while I <= RN loop
            if Buf (I) >= '0' and then Buf (I) <= '9' then
               D := Character'Pos (Buf (I)) - Character'Pos ('0');
            elsif Buf (I) >= 'a' and then Buf (I) <= 'f' then
               D := Character'Pos (Buf (I)) - Character'Pos ('a') + 10;
            elsif Buf (I) >= 'A' and then Buf (I) <= 'F' then
               D := Character'Pos (Buf (I)) - Character'Pos ('A') + 10;
            else
               Fail (Toks (T).Line, "bad hex digit in literal");
               return;
            end if;
            if V > (Unsigned_64'Last - Unsigned_64 (D)) / 16 then
               Fail (Toks (T).Line, "integer literal overflow");
               return;
            end if;
            V := V * 16 + Unsigned_64 (D);
            I := I + 1;
         end loop;
      else
         while I <= RN loop
            if Buf (I) < '0' or else Buf (I) > '9' then
               Fail (Toks (T).Line, "bad digit in literal");
               return;
            end if;
            D := Character'Pos (Buf (I)) - Character'Pos ('0');
            if V > (Unsigned_64'Last - Unsigned_64 (D)) / 10 then
               Fail (Toks (T).Line, "integer literal overflow");
               return;
            end if;
            V := V * 10 + Unsigned_64 (D);
            I := I + 1;
         end loop;
      end if;

      if Bits < 64 then
         Max := Shift_Left (Unsigned_64'(1), Bits) - 1;
      else
         Max := Unsigned_64'Last;
      end if;
      if not Neg and then V > Max then
         Fail (Toks (T).Line, "integer literal out of range");
         return;
      end if;
      if Neg then
         declare
            Min_Mag : constant Unsigned_64 :=
              (if Bits < 64 then Shift_Left (Unsigned_64'(1), Bits - 1)
               else Shift_Left (Unsigned_64'(1), 63));
         begin
            if V > Min_Mag then
               Fail (Toks (T).Line, "negative literal out of range");
               return;
            end if;
            if Bits < 64 then
               Val := (not V + 1) and Max;
            else
               Val := (not V) + 1;
            end if;
         end;
      else
         Val := V;
      end if;
      OK := True;
   end Parse_Int_Bits;

   procedure Parse_Nat (T : Natural; V : out Natural; OK : out Boolean) is
      U64 : Unsigned_64;
   begin
      OK := False;
      V := 0;
      Parse_Int_Bits (T, 64, U64, OK);
      if not OK then
         return;
      end if;
      if U64 > Unsigned_64 (Natural'Last) then
         Fail (Toks (T).Line, "index literal too large");
         OK := False;
         return;
      end if;
      V := Natural (U64);
      OK := True;
   end Parse_Nat;

   --  float literal -> value or raw bits (inf/nan/nan:0xPAYLOAD)
   procedure Parse_Float (T        : Natural;
                          F        : out Long_Float;
                          Has_Raw  : out Boolean;
                          Raw_Bits : out Unsigned_64;
                          OK       : out Boolean) is
      S   : constant String := Tok_Text (T);
      Buf : String (1 .. 128);
      RN  : Natural := 0;
      I   : Natural := 1;
      Neg : Boolean := False;
   begin
      OK := False;
      F := 0.0;
      Has_Raw := False;
      Raw_Bits := 0;
      if S'Length > Buf'Length then
         Fail (Toks (T).Line, "float literal too long");
         return;
      end if;
      for K in S'Range loop
         if S (K) /= '_' then
            RN := RN + 1;
            Buf (RN) := S (K);
         end if;
      end loop;
      if RN = 0 then
         Fail (Toks (T).Line, "empty float literal");
         return;
      end if;
      if Buf (I) = '-' then
         Neg := True;
         I := I + 1;
      elsif Buf (I) = '+' then
         I := I + 1;
      end if;

      declare
         Rest : constant String := Buf (I .. RN);
         Up   : String (Rest'Range);
      begin
         for K in Rest'Range loop
            Up (K) := (if Rest (K) in 'a' .. 'z'
                       then Character'Val (Character'Pos (Rest (K)) - 32)
                       else Rest (K));
         end loop;

         if Up = "INF" then
            Has_Raw := True;
            Raw_Bits := 16#7FF0000000000000#
              or (if Neg then Shift_Left (Unsigned_64'(1), 63) else 0);
            OK := True;
            return;
         elsif Up = "NAN" then
            Has_Raw := True;
            Raw_Bits := 16#7FF8000000000000#
              or (if Neg then Shift_Left (Unsigned_64'(1), 63) else 0);
            OK := True;
            return;
         elsif Rest'Length > 4
           and then Up'Length >= 5
           and then Up (Up'First .. Up'First + 4) = "NAN:0"
           and then Up'Length >= 6
           and then Up (Up'First + 5) = 'X'
         then
            declare
               P   : Unsigned_64 := 0;
               D   : Natural;
               Bad : Boolean := False;
            begin
               if Up'Length < 7 then
                  Fail (Toks (T).Line, "bad nan:0x payload");
                  return;
               end if;
               for K in Up'First + 6 .. Up'Last loop
                  if Up (K) >= '0' and then Up (K) <= '9' then
                     D := Character'Pos (Up (K)) - Character'Pos ('0');
                  elsif Up (K) >= 'A' and then Up (K) <= 'F' then
                     D := Character'Pos (Up (K)) - Character'Pos ('A') + 10;
                  else
                     Bad := True;
                     exit;
                  end if;
                  P := P * 16 + Unsigned_64 (D);
               end loop;
               if Bad or else P = 0 or else P >= 16#10000000000000# then
                  Fail (Toks (T).Line, "bad nan:0x payload");
                  return;
               end if;
               Has_Raw := True;
               Raw_Bits := 16#7FF8000000000000# or P
                 or (if Neg then Shift_Left (Unsigned_64'(1), 63) else 0);
               OK := True;
               return;
            end;
         end if;

         --  hex float 0xM[.M][p±E]
         if Rest'Length >= 2 and then Rest (Rest'First) = '0'
           and then (Rest (Rest'First + 1) = 'x'
                     or else Rest (Rest'First + 1) = 'X')
         then
            declare
               Mant : Long_Float := 0.0;
               Frac : Long_Float := 1.0 / 16.0;
               Exp  : Long_Float := 0.0;
               K    : Natural := Rest'First + 2;
               Seen : Boolean := False;
               D    : Integer;
               Bad  : Boolean := False;

               function HexD (C : Character) return Integer is
               begin
                  if C >= '0' and then C <= '9' then
                     return Character'Pos (C) - Character'Pos ('0');
                  elsif C >= 'a' and then C <= 'f' then
                     return Character'Pos (C) - Character'Pos ('a') + 10;
                  elsif C >= 'A' and then C <= 'F' then
                     return Character'Pos (C) - Character'Pos ('A') + 10;
                  end if;
                  return -1;
               end HexD;
            begin
               while K <= Rest'Last and then Rest (K) /= '.'
                 and then Rest (K) /= 'p' and then Rest (K) /= 'P'
               loop
                  D := HexD (Rest (K));
                  if D < 0 then
                     Bad := True;
                     exit;
                  end if;
                  Mant := Mant * 16.0 + Long_Float (D);
                  Seen := True;
                  K := K + 1;
               end loop;
               if not Bad and then K <= Rest'Last and then Rest (K) = '.' then
                  K := K + 1;
                  while K <= Rest'Last
                    and then Rest (K) /= 'p' and then Rest (K) /= 'P'
                  loop
                     D := HexD (Rest (K));
                     if D < 0 then
                        Bad := True;
                        exit;
                     end if;
                     Mant := Mant + Long_Float (D) * Frac;
                     Frac := Frac / 16.0;
                     Seen := True;
                     K := K + 1;
                  end loop;
               end if;
               if not Bad and then K <= Rest'Last
                 and then (Rest (K) = 'p' or else Rest (K) = 'P')
               then
                  K := K + 1;
                  declare
                     Eneg : Boolean := False;
                     Eval : Natural := 0;
                  begin
                     if K <= Rest'Last
                       and then (Rest (K) = '-' or else Rest (K) = '+')
                     then
                        Eneg := Rest (K) = '-';
                        K := K + 1;
                     end if;
                     while K <= Rest'Last loop
                        if Rest (K) < '0' or else Rest (K) > '9' then
                           Bad := True;
                           exit;
                        end if;
                        Eval := Eval * 10 +
                          (Character'Pos (Rest (K)) - Character'Pos ('0'));
                        K := K + 1;
                     end loop;
                     if Eneg then
                        Exp := -Long_Float (Eval);
                     else
                        Exp := Long_Float (Eval);
                     end if;
                  end;
               end if;
               if Bad or else not Seen or else K <= Rest'Last then
                  Fail (Toks (T).Line, "bad hex float literal");
                  return;
               end if;
               --  clamp the binary exponent before Integer conversion
               if Exp > 1100.0 then
                  Exp := 1100.0;
               elsif Exp < -1100.0 then
                  Exp := -1100.0;
               end if;
               F := Mant * (2.0 ** Integer (Exp));
               if Neg then
                  F := -F;
               end if;
               OK := True;
               return;
            end;
         end if;

         --  decimal float/int via 'Value (normalize "1." / ".5")
         declare
            Num : String (1 .. RN - I + 2);
            NN  : Natural := 0;
            J   : Natural := I;
         begin
            if J <= RN and then Buf (J) = '.' then
               NN := NN + 1;
               Num (NN) := '0';
            end if;
            while J <= RN loop
               NN := NN + 1;
               Num (NN) := Buf (J);
               J := J + 1;
            end loop;
            if NN >= 1 and then Num (NN) = '.' then
               NN := NN + 1;
               Num (NN) := '0';
            end if;
            begin
               F := Long_Float'Value (Num (1 .. NN));
               if Neg then
                  F := -F;
               end if;
               OK := True;
            exception
               when others =>
                  Fail (Toks (T).Line, "bad float literal");
            end;
         end;
      end;
   end Parse_Float;

   --  ===================== valtype / type interning =====================
   function VT_Of (S : String; VT : out Value_Type) return Boolean is
   begin
      if S = "i32" then
         VT := VT_I32;
      elsif S = "i64" then
         VT := VT_I64;
      elsif S = "f32" then
         VT := VT_F32;
      elsif S = "f64" then
         VT := VT_F64;
      else
         return False;
      end if;
      return True;
   end VT_Of;

   function VT_Code (VT : Value_Type) return Unsigned_8 is
   begin
      case VT is
         when VT_I32 => return 16#7F#;
         when VT_I64 => return 16#7E#;
         when VT_F32 => return 16#7D#;
         when VT_F64 => return 16#7C#;
      end case;
   end VT_Code;

   function Same_Type (A, B : Func_Type) return Boolean is
   begin
      if A.NP /= B.NP or else A.NR /= B.NR then
         return False;
      end if;
      for K in 1 .. A.NP loop
         if A.P (K) /= B.P (K) then
            return False;
         end if;
      end loop;
      for K in 1 .. A.NR loop
         if A.R (K) /= B.R (K) then
            return False;
         end if;
      end loop;
      return True;
   end Same_Type;

   function Intern_Type (FT : Func_Type) return Natural is
   begin
      for I in 1 .. N_Types loop
         if Same_Type (Types (I), FT) then
            return I;
         end if;
      end loop;
      if N_Types >= Max_Types then
         Fail (0, "type table overflow");
         return 0;
      end if;
      N_Types := N_Types + 1;
      Types (N_Types) := FT;
      return N_Types;
   end Intern_Type;

   --  ===================== name resolution =====================
   function Find_Func_By_Name (Name : String) return Natural is
   begin
      for I in 1 .. N_Funcs loop
         if Funcs (I).Active
           and then To_String (Funcs (I).Name) = Name
         then
            return Funcs (I).Wasm_Idx + 1;   -- 1-based return, wasm idx
         end if;
      end loop;
      return 0;
   end Find_Func_By_Name;

   function Find_Glob_By_Name (Name : String) return Natural is
   begin
      for I in 1 .. N_Globals loop
         if Globals (I).Active
           and then To_String (Globals (I).Name) = Name
         then
            return Globals (I).Wasm_Idx + 1;
         end if;
      end loop;
      return 0;
   end Find_Glob_By_Name;

   function Find_Type_By_Name (Name : String) return Natural is
   begin
      for I in 1 .. N_Types loop
         if Length (Type_Names (I)) > 0
           and then To_String (Type_Names (I)) = Name
         then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Type_By_Name;

   function Find_Mem_By_Name (Name : String) return Natural is
   begin
      for I in 1 .. N_Mems loop
         if Mems (I).Active
           and then To_String (Mems (I).Name) = Name
         then
            return Mems (I).Wasm_Idx + 1;
         end if;
      end loop;
      return 0;
   end Find_Mem_By_Name;

   --  resolve $name-or-index ref to wasm index
   procedure Resolve_Ref (T    : Natural;
                          Kind : String;   -- "func"/"global"/"type"/"memory"
                          V    : out Natural;
                          OK   : out Boolean) is
      S : constant String := Tok_Text (T);
   begin
      OK := False;
      V := 0;
      if S'Length >= 2 and then S (S'First) = '$' then
         if Kind = "func" then
            V := Find_Func_By_Name (S);
         elsif Kind = "global" then
            V := Find_Glob_By_Name (S);
         elsif Kind = "memory" then
            V := Find_Mem_By_Name (S);
         else
            V := Find_Type_By_Name (S);
            if V > 0 then
               V := V - 1;   -- type names are 1-based table entries
               OK := True;
               return;
            end if;
         end if;
         if V = 0 then
            Fail (Toks (T).Line, "unknown " & Kind & " " & S);
            return;
         end if;
         V := V - 1;
         OK := True;
      else
         Parse_Nat (T, V, OK);
         if OK then
            if Kind = "func" and then V >= N_Funcs then
               Fail (Toks (T).Line, "func index out of range");
               OK := False;
            elsif Kind = "global" and then V >= N_Globals then
               Fail (Toks (T).Line, "global index out of range");
               OK := False;
            elsif Kind = "type" and then V >= N_Types then
               Fail (Toks (T).Line, "type index out of range");
               OK := False;
            elsif Kind = "memory" and then V >= N_Mems then
               Fail (Toks (T).Line, "memory index out of range");
               OK := False;
            end if;
         end if;
      end if;
   end Resolve_Ref;

   --  func record index from wasm index (for code emit ordering)
   function Func_Rec_Of_Wasm (W : Natural) return Natural is
   begin
      for I in 1 .. N_Funcs loop
         if Funcs (I).Active and then Funcs (I).Wasm_Idx = W then
            return I;
         end if;
      end loop;
      return 0;
   end Func_Rec_Of_Wasm;

   --  ===================== byte emitters =====================
   --  three output targets: final Bytes (via closure below), Sec_Buf,
   --  Body_Buf.  Simplest: generic put procedures on an explicit buffer.
   procedure Put_B (Buf : in out Big_Bytes; N : in out Natural;
                    B : Unsigned_8) is
   begin
      if N >= Buf'Last then
         Fail (0, "wasm output overflow");
         return;
      end if;
      N := N + 1;
      Buf (N) := B;
   end Put_B;

   procedure Put_ULEB (Buf : in out Big_Bytes; N : in out Natural;
                       V : Unsigned_64) is
      X : Unsigned_64 := V;
   begin
      loop
         declare
            B : Unsigned_8 := Unsigned_8 (X and 16#7F#);
         begin
            X := Shift_Right (X, 7);
            if X /= 0 then
               B := B or 16#80#;
            end if;
            Put_B (Buf, N, B);
            exit when X = 0;
         end;
      end loop;
   end Put_ULEB;

   procedure Put_SLEB (Buf : in out Big_Bytes; N : in out Natural;
                       V : Unsigned_64) is
      --  V holds the raw two's-complement bits at the operand width;
      --  sign-extend via shift on the 64-bit value.
      X : Unsigned_64 := V;
      More : Boolean := True;
      B    : Unsigned_8;
      Sign : Unsigned_8;
   begin
      while More loop
         B := Unsigned_8 (X and 16#7F#);
         X := Shift_Right_Arithmetic (X, 7);
         Sign := B and 16#40#;
         if (X = 0 and then Sign = 0)
           or else (X = Unsigned_64'Last and then Sign /= 0)
         then
            More := False;
         else
            B := B or 16#80#;
         end if;
         Put_B (Buf, N, B);
      end loop;
   end Put_SLEB;

   procedure Put_U32_LE (Buf : in out Big_Bytes; N : in out Natural;
                         V : Unsigned_32) is
   begin
      Put_B (Buf, N, Unsigned_8 (V and 16#FF#));
      Put_B (Buf, N, Unsigned_8 (Shift_Right (V, 8) and 16#FF#));
      Put_B (Buf, N, Unsigned_8 (Shift_Right (V, 16) and 16#FF#));
      Put_B (Buf, N, Unsigned_8 (Shift_Right (V, 24)));
   end Put_U32_LE;

   procedure Put_U64_LE (Buf : in out Big_Bytes; N : in out Natural;
                         V : Unsigned_64) is
   begin
      for K in 0 .. 7 loop
         Put_B (Buf, N, Unsigned_8 (Shift_Right (V, K * 8) and 16#FF#));
      end loop;
   end Put_U64_LE;

   procedure Put_Name (Buf : in out Big_Bytes; N : in out Natural;
                       S : String) is
   begin
      Put_ULEB (Buf, N, Unsigned_64 (S'Length));
      for K in S'Range loop
         Put_B (Buf, N, Unsigned_8 (Character'Pos (S (K))));
      end loop;
   end Put_Name;

   --  IEEE conversions
   function F32_Bits is new Ada.Unchecked_Conversion
     (IEEE_Float_32, Unsigned_32);
   function F64_Bits is new Ada.Unchecked_Conversion
     (IEEE_Float_64, Unsigned_64);

   --  f32 raw bits from an f64-style raw (inf / nan / nan:0xP):
   --  sign carries across; inf -> 0x7F800000; nan -> quiet payload
   --  truncated to the f32 mantissa field.
   function F32_Raw_Bits (RB : Unsigned_64) return Unsigned_32 is
      Sign : constant Unsigned_32 :=
        Unsigned_32 (Shift_Right (RB, 32)) and 16#80000000#;
   begin
      if (RB and 16#000FFFFFFFFFFFFF#) /= 0 then
         --  nan: 0x7F800000 | payload-low-23 | force quiet bit
         return Sign or 16#7F800000#
           or (Unsigned_32 (RB and 16#3FFFFF#) or 16#400000#);
      else
         return Sign or 16#7F800000#;  -- inf
      end if;
   end F32_Raw_Bits;

   --  ===================== forward decls =====================
   procedure Parse_Field;
   procedure Parse_Func;
   procedure Parse_Memory;
   procedure Parse_Global;
   procedure Parse_Import;
   procedure Parse_Export;
   procedure Parse_Type_Field;
   procedure Parse_Data;
   procedure Parse_Start;
   procedure Encode_Module (Bytes : out Byte_Vec; Byte_Count : out Natural);
   procedure Encode_Func_Body (Func_Idx : Natural);

   --  ===================== group parsers =====================
   --  (param ...): bare types OR ($name t) singles; appends to FT.P and,
   --  when Record_Locals, to the local arena (params are locals 0..).
   --  (local ...): same shape but only fills the arena.
   procedure Parse_Param_Group (FT            : in out Func_Type;
                                F             : in out Func_Rec;
                                Record_Locals : Boolean;
                                Is_Param      : Boolean) is
      VT : Value_Type;
   begin
      Cur := Cur + 2;  -- consume '(' 'param'/'local'
      loop
         exit when Length (Err) > 0;
         if Peek_Kind = TK_RPar then
            Cur := Cur + 1;
            exit;
         end if;
         if Peek_Kind /= TK_Atom then
            Fail (Peek_Line, "expected value type or ')' in param group");
            exit;
         end if;
         declare
            S      : constant String := Tok_Text (Cur);
            Has_N  : constant Boolean :=
              S'Length >= 2 and then S (S'First) = '$';
            N_Pos  : Natural := 0;
            N_Len  : Natural := 0;
         begin
            if Has_N then
               N_Pos := Toks (Cur).Pos;
               N_Len := Toks (Cur).Len;
               Cur := Cur + 1;
               if Peek_Kind /= TK_Atom
                 or else not VT_Of (Tok_Text (Cur), VT)
               then
                  Fail (Peek_Line, "expected value type after " & S);
                  exit;
               end if;
            else
               if not VT_Of (S, VT) then
                  Fail (Peek_Line, "expected value type, got '" & S & "'");
                  exit;
               end if;
            end if;

            if Is_Param then
               if FT.NP >= Max_Params then
                  Fail (Peek_Line, "param count overflow");
                  exit;
               end if;
               FT.NP := FT.NP + 1;
               FT.P (FT.NP) := VT;
            end if;
            if Record_Locals then
               if Local_N >= Max_Local_Slots then
                  Fail (Peek_Line, "local slot overflow");
                  exit;
               end if;
               Local_N := Local_N + 1;
               Local_Types (Local_N) := VT;
               Local_NPos (Local_N) := N_Pos;
               Local_NLen (Local_N) := N_Len;
               F.Loc_Cnt := F.Loc_Cnt + 1;
            end if;
            Cur := Cur + 1;
         end;
      end loop;
   end Parse_Param_Group;

   procedure Parse_Result_Group (FT : in out Func_Type) is
      VT : Value_Type;
   begin
      Cur := Cur + 2;  -- consume '(' 'result'
      loop
         exit when Length (Err) > 0;
         if Peek_Kind = TK_RPar then
            Cur := Cur + 1;
            exit;
         end if;
         if Peek_Kind /= TK_Atom
           or else not VT_Of (Tok_Text (Cur), VT)
         then
            Fail (Peek_Line, "expected value type in result group");
            exit;
         end if;
         if FT.NR >= 1 then
            Fail (Peek_Line,
                  "multi-result functions unsupported (MVP scope)");
            exit;
         end if;
         FT.NR := 1;
         FT.R (1) := VT;
         Cur := Cur + 1;
      end loop;
   end Parse_Result_Group;

   --  queue an export for an entity known only by record index
   --  (inline (export "n") inside a func/mem/global being parsed)
   procedure Add_Export (Kind : Exp_Kind; Name : Unbounded_String;
                        Ent_Idx : Natural) is
   begin
      if N_Exps >= Max_Exports then
         Fail (Peek_Line, "export table overflow");
         return;
      end if;
      N_Exps := N_Exps + 1;
      Exps (N_Exps).Active := True;
      Exps (N_Exps).Kind := Kind;
      Exps (N_Exps).Name := Name;
      Exps (N_Exps).Pend := True;
      Exps (N_Exps).Idx := Ent_Idx + 1;   -- entity record idx (PK_Ent)
   end Add_Export;

   --  queue an export by textual ref (standalone (export "n" (kind r)))
   procedure Add_Export_Ref (Kind : Exp_Kind; Name : Unbounded_String;
                           T : Natural) is
   begin
      if N_Exps >= Max_Exports then
         Fail (Peek_Line, "export table overflow");
         return;
      end if;
      N_Exps := N_Exps + 1;
      Exps (N_Exps).Active := True;
      Exps (N_Exps).Kind := Kind;
      Exps (N_Exps).Name := Name;
      Exps (N_Exps).Pend := True;
      Exps (N_Exps).Idx := 0;             -- PK_Ref: resolve from P_Pos
      Exps (N_Exps).P_Pos := Toks (T).Pos;
      Exps (N_Exps).P_Len := Toks (T).Len;
   end Add_Export_Ref;

   procedure Add_Import (Kind : Imp_Kind; Mod_Name, Field : Unbounded_String;
                        Ent_Idx : Natural) is
   begin
      if N_Imports >= Max_Imports then
         Fail (Peek_Line, "import table overflow");
         return;
      end if;
      N_Imports := N_Imports + 1;
      Imports (N_Imports).Kind := Kind;
      Imports (N_Imports).Mod_Name := Mod_Name;
      Imports (N_Imports).Field := Field;
      Imports (N_Imports).Ent_Idx := Ent_Idx;
   end Add_Import;

   --  (import "m" "n") as an inline child of func/memory/global
   procedure Parse_Inline_Import (Mod_Name, Field : out Unbounded_String) is
   begin
      Cur := Cur + 2;  -- consume '(' 'import'
      Mod_Name := To_Unbounded_String ("");
      Field := To_Unbounded_String ("");
      if Peek_Kind /= TK_Str then
         Fail (Peek_Line, "expected module name string in import");
         return;
      end if;
      Mod_Name := Str_Text (Cur);
      Cur := Cur + 1;
      if Peek_Kind /= TK_Str then
         Fail (Peek_Line, "expected field name string in import");
         return;
      end if;
      Field := Str_Text (Cur);
      Cur := Cur + 1;
      Expect_RPar ("import");
   end Parse_Inline_Import;

   --  (export "n") inline child — returns name
   function Parse_Inline_Export return Unbounded_String is
      N : Unbounded_String := To_Unbounded_String ("");
   begin
      Cur := Cur + 2;  -- consume '(' 'export'
      if Peek_Kind /= TK_Str then
         Fail (Peek_Line, "expected name string in export");
         return N;
      end if;
      N := Str_Text (Cur);
      Cur := Cur + 1;
      Expect_RPar ("export");
      return N;
   end Parse_Inline_Export;

   --  signature children shared by (func ...) and import func descs:
   --  (param) (result) (type) groups in any order.
   procedure Parse_Sig_Children (FT : in out Func_Type;
                                 F  : in out Func_Rec;
                                 Record_Locals : Boolean;
                                 Type_Ref_Tok   : out Natural;
                                 Sig_Explicit   : out Boolean) is
   begin
      Type_Ref_Tok := 0;
      Sig_Explicit := False;
      loop
         exit when Length (Err) > 0;
         if Peek_List_Head ("param") then
            Sig_Explicit := True;
            Parse_Param_Group (FT, F, Record_Locals, True);
         elsif Peek_List_Head ("result") then
            Sig_Explicit := True;
            Parse_Result_Group (FT);
         elsif Peek_List_Head ("type") then
            Cur := Cur + 2;
            if Peek_Kind = TK_Atom then
               Type_Ref_Tok := Cur;
               Cur := Cur + 1;
            else
               Fail (Peek_Line, "expected type index in (type ..)");
            end if;
            Expect_RPar ("type");
         else
            exit;
         end if;
      end loop;
   end Parse_Sig_Children;

   --  Cur sits on '('; Close_Tok returns that list's matching ')'
   --  (unlike Span_To_Close, which scans to the PARENT entity's close).
   procedure Scan_List (Close_Tok : out Natural) is
      D : Natural := 0;
      T : Natural := Cur;
   begin
      Close_Tok := 0;
      while T <= N_Toks loop
         if Toks (T).Kind = TK_LPar then
            D := D + 1;
         elsif Toks (T).Kind = TK_RPar then
            D := D - 1;
            if D = 0 then
               Close_Tok := T;
               return;
            end if;
         end if;
         T := T + 1;
      end loop;
      Fail (Peek_Line, "unbalanced list");
   end Scan_List;

   --  scan ahead from Cur to the ')' that closes the current entity
   --  (depth-aware); returns Last = token before that ')'.
   procedure Span_To_Close (Last : out Natural) is
      D : Natural := 0;
      T : Natural := Cur;
   begin
      Last := 0;
      while T <= N_Toks loop
         if Toks (T).Kind = TK_LPar then
            D := D + 1;
         elsif Toks (T).Kind = TK_RPar then
            if D = 0 then
               Last := T - 1;
               return;
            end if;
            D := D - 1;
         end if;
         T := T + 1;
      end loop;
      Fail (Peek_Line, "unbalanced parens in entity");
   end Span_To_Close;

   --  ===================== field parsers =====================
   procedure Parse_Func is
      F          : Func_Rec;
      FT         : Func_Type;
      Type_Tok   : Natural;
      Sig_Exp    : Boolean;
      First_Instr : Natural := 0;
   begin
      Cur := Cur + 2;  -- consume '(' 'func'
      F.Active := True;
      F.Loc_Off := Local_N + 1;
      Maybe_Id (F.Name);
      loop
         exit when Length (Err) > 0;
         if Peek_Kind = TK_RPar then
            Cur := Cur + 1;
            exit;
         elsif Peek_List_Head ("import") then
            Parse_Inline_Import (F.Imp_Mod, F.Imp_Field);
            F.Imported := True;
         elsif Peek_List_Head ("export") then
            Add_Export (EK_Func, Parse_Inline_Export, N_Funcs);
         elsif Peek_List_Head ("param")
           or else Peek_List_Head ("result")
           or else Peek_List_Head ("type")
         then
            Parse_Sig_Children (FT, F, True, Type_Tok, Sig_Exp);
            F.Decl_Type_Tok := Type_Tok;
            if Sig_Exp then
               F.Sig_Explicit := True;
            end if;
         elsif Peek_List_Head ("local") then
            Parse_Param_Group (FT, F, True, False);
         else
            --  instruction stream: span to this func's ')'
            First_Instr := Cur;
            Span_To_Close (F.Body_Last);
            F.Body_First := First_Instr;
            Cur := F.Body_Last + 2;  -- consume the ')'
            exit;
         end if;
      end loop;
      if F.Imported and then F.Body_First /= 0 then
         Fail (0, "imported func has a body");
         return;
      end if;
      if F.Decl_Type_Tok = 0 then
         --  Intern_Type is 1-based; Type_Idx carries the 0-based wasm idx
         F.Type_Idx := Intern_Type (FT) - 1;
      end if;
      F.Par_Cnt := FT.NP;
      F.Sig_FT_NP := FT.NP;  -- kept for (type) verification
      F.Sig_FT_NR := FT.NR;
      if N_Funcs >= Max_Funcs then
         Fail (0, "func table overflow");
         return;
      end if;
      N_Funcs := N_Funcs + 1;
      Funcs (N_Funcs) := F;
      --  remember declared sig for (type) cross-check
      Funcs (N_Funcs).Sig_P := FT.P;
      Funcs (N_Funcs).Sig_R := FT.R;
      if F.Imported then
         Add_Import (IK_Func, F.Imp_Mod, F.Imp_Field, N_Funcs);
      end if;
   end Parse_Func;

   procedure Parse_Memory is
      M   : Mem_Rec;
      V   : Natural;
      OK  : Boolean;
      Sub : Natural;
   begin
      Cur := Cur + 2;  -- consume '(' 'memory'
      M.Active := True;
      Maybe_Id (M.Name);
      loop
         exit when Length (Err) > 0;
         if Peek_Kind = TK_RPar then
            Cur := Cur + 1;
            exit;
         elsif Peek_List_Head ("import") then
            Parse_Inline_Import (M.Imp_Mod, M.Imp_Field);
            M.Imported := True;
         elsif Peek_List_Head ("export") then
            Add_Export (EK_Mem, Parse_Inline_Export, N_Mems);
         elsif Peek_List_Head ("data") then
            --  (data "s"...) inline: active segment at offset 0
            Cur := Cur + 2;
            if N_Datas >= Max_Data_Segs then
               Fail (Peek_Line, "data segment overflow");
               exit;
            end if;
            N_Datas := N_Datas + 1;
            Datas (N_Datas).Active := True;
            Datas (N_Datas).Mem_Idx := N_Mems;
            Datas (N_Datas).Off_First := 0;  -- const 0
            Datas (N_Datas).Byte_Off := Data_Arena_N + 1;
            Sub := Data_Arena_N;
            while Peek_Kind = TK_Str loop
               Decode_String (Cur, Data_Arena, Data_Arena_N);
               Cur := Cur + 1;
            end loop;
            Datas (N_Datas).Byte_Len := Data_Arena_N - Sub;
            Expect_RPar ("data");
         elsif Peek_Kind = TK_Atom then
            Parse_Nat (Cur, V, OK);
            if not OK then
               return;
            end if;
            M.Min_Pages := Unsigned_64 (V);
            Cur := Cur + 1;
            if Peek_Kind = TK_Atom then
               Parse_Nat (Cur, V, OK);
               if not OK then
                  return;
               end if;
               M.Has_Max := True;
               M.Max_Pages := Unsigned_64 (V);
               Cur := Cur + 1;
            end if;
         else
            Fail (Peek_Line, "unexpected token in memory");
            return;
         end if;
      end loop;
      if N_Mems >= Mems'Last then
         Fail (0, "memory table overflow (max 1 memory in MVP)");
         return;
      end if;
      N_Mems := N_Mems + 1;
      Mems (N_Mems) := M;
      if M.Imported then
         Add_Import (IK_Mem, M.Imp_Mod, M.Imp_Field, N_Mems);
      end if;
   end Parse_Memory;

   procedure Parse_Global is
      G          : Glob_Rec;
      VT         : Value_Type;
      First_Init : Natural := 0;
      Type_Seen  : Boolean := False;
   begin
      Cur := Cur + 2;  -- consume '(' 'global'
      G.Active := True;
      Maybe_Id (G.Name);
      loop
         exit when Length (Err) > 0;
         if Peek_Kind = TK_RPar then
            Cur := Cur + 1;
            exit;
         elsif Peek_List_Head ("import") then
            Parse_Inline_Import (G.Imp_Mod, G.Imp_Field);
            G.Imported := True;
         elsif Peek_List_Head ("export") then
            Add_Export (EK_Glob, Parse_Inline_Export, N_Globals);
         elsif Peek_List_Head ("mut") and then not Type_Seen then
            Cur := Cur + 2;
            G.Mutable := True;
            Type_Seen := True;
            if Peek_Kind /= TK_Atom
              or else not VT_Of (Tok_Text (Cur), VT)
            then
               Fail (Peek_Line, "expected value type in (mut ..)");
               return;
            end if;
            G.VT := VT;
            Cur := Cur + 1;
            Expect_RPar ("mut");
         elsif Peek_Kind = TK_Atom and then not Type_Seen then
            if not VT_Of (Tok_Text (Cur), VT) then
               Fail (Peek_Line,
                     "expected value type, got '" & Tok_Text (Cur) & "'");
               return;
            end if;
            G.VT := VT;
            Type_Seen := True;
            Cur := Cur + 1;
         else
            --  init expr span to ')'
            First_Init := Cur;
            Span_To_Close (G.Init_Last);
            G.Init_First := First_Init;
            Cur := G.Init_Last + 2;
            exit;
         end if;
      end loop;
      if G.Imported and then G.Init_First /= 0 then
         Fail (0, "imported global has an init expr");
         return;
      end if;
      if not G.Imported and then G.Init_First = 0 then
         Fail (0, "global missing init expr");
         return;
      end if;
      if N_Globals >= Max_Globals then
         Fail (0, "global table overflow");
         return;
      end if;
      N_Globals := N_Globals + 1;
      Globals (N_Globals) := G;
      if G.Imported then
         Add_Import (IK_Glob, G.Imp_Mod, G.Imp_Field, N_Globals);
      end if;
   end Parse_Global;

   procedure Parse_Import is
      Mod_Name : Unbounded_String := To_Unbounded_String ("");
      Field    : Unbounded_String := To_Unbounded_String ("");
   begin
      Cur := Cur + 2;  -- consume '(' 'import'
      if Peek_Kind /= TK_Str then
         Fail (Peek_Line, "expected module name string in import");
         return;
      end if;
      Mod_Name := Str_Text (Cur);
      Cur := Cur + 1;
      if Peek_Kind /= TK_Str then
         Fail (Peek_Line, "expected field name string in import");
         return;
      end if;
      Field := Str_Text (Cur);
      Cur := Cur + 1;
      if Peek_Kind /= TK_LPar or else Cur + 1 > N_Toks
        or else Toks (Cur + 1).Kind /= TK_Atom
      then
         Fail (Peek_Line, "expected (kind desc) in import");
         return;
      end if;
      declare
         Kind : constant String := Tok_Text (Cur + 1);
      begin
         if Kind = "func" then
            declare
               F        : Func_Rec;
               FT       : Func_Type;
               TT       : Natural;
               SE       : Boolean;
            begin
               Cur := Cur + 2;  -- consume '(' 'func'
               F.Active := True;
               F.Imported := True;
               F.Imp_Mod := Mod_Name;
               F.Imp_Field := Field;
               Maybe_Id (F.Name);
               Parse_Sig_Children (FT, F, False, TT, SE);
               F.Decl_Type_Tok := TT;
               F.Sig_Explicit := SE;
               Expect_RPar ("func");
               if F.Decl_Type_Tok = 0 then
                  F.Type_Idx := Intern_Type (FT) - 1;
               end if;
               F.Par_Cnt := FT.NP;
               F.Sig_FT_NP := FT.NP;
               F.Sig_FT_NR := FT.NR;
               if N_Funcs >= Max_Funcs then
                  Fail (0, "func table overflow");
                  return;
               end if;
               N_Funcs := N_Funcs + 1;
               Funcs (N_Funcs) := F;
               Funcs (N_Funcs).Sig_P := FT.P;
               Funcs (N_Funcs).Sig_R := FT.R;
               Add_Import (IK_Func, Mod_Name, Field, N_Funcs);
            end;
            Expect_RPar ("import");
         elsif Kind = "memory" then
            declare
               M  : Mem_Rec;
               V  : Natural;
               OK : Boolean;
            begin
               Cur := Cur + 2;  -- consume '(' 'memory'
               M.Active := True;
               M.Imported := True;
               M.Imp_Mod := Mod_Name;
               M.Imp_Field := Field;
               Maybe_Id (M.Name);
               if Peek_Kind = TK_Atom then
                  Parse_Nat (Cur, V, OK);
                  if not OK then
                     return;
                  end if;
                  M.Min_Pages := Unsigned_64 (V);
                  Cur := Cur + 1;
                  if Peek_Kind = TK_Atom then
                     Parse_Nat (Cur, V, OK);
                     if not OK then
                        return;
                     end if;
                     M.Has_Max := True;
                     M.Max_Pages := Unsigned_64 (V);
                     Cur := Cur + 1;
                  end if;
               end if;
               Expect_RPar ("memory");
               if N_Mems >= Mems'Last then
                  Fail (0, "memory table overflow");
                  return;
               end if;
               N_Mems := N_Mems + 1;
               Mems (N_Mems) := M;
               Add_Import (IK_Mem, Mod_Name, Field, N_Mems);
            end;
            Expect_RPar ("import");
         elsif Kind = "global" then
            declare
               G  : Glob_Rec;
               VT : Value_Type;
            begin
               Cur := Cur + 2;  -- consume '(' 'global'
               G.Active := True;
               G.Imported := True;
               G.Imp_Mod := Mod_Name;
               G.Imp_Field := Field;
               Maybe_Id (G.Name);
               if Peek_List_Head ("mut") then
                  Cur := Cur + 2;
                  G.Mutable := True;
                  if Peek_Kind /= TK_Atom
                    or else not VT_Of (Tok_Text (Cur), VT)
                  then
                     Fail (Peek_Line, "expected value type in (mut ..)");
                     return;
                  end if;
                  G.VT := VT;
                  Cur := Cur + 1;
                  Expect_RPar ("mut");
               elsif Peek_Kind = TK_Atom
                 and then VT_Of (Tok_Text (Cur), VT)
               then
                  G.VT := VT;
                  Cur := Cur + 1;
               else
                  Fail (Peek_Line, "expected global type");
                  return;
               end if;
               Expect_RPar ("global");
               if N_Globals >= Max_Globals then
                  Fail (0, "global table overflow");
                  return;
               end if;
               N_Globals := N_Globals + 1;
               Globals (N_Globals) := G;
               Add_Import (IK_Glob, Mod_Name, Field, N_Globals);
            end;
            Expect_RPar ("import");
         elsif Kind = "table" then
            Fail (Peek_Line,
                  "(import .. (table ..)) unsupported: no tables in MVP scope");
            return;
         else
            Fail (Peek_Line, "unsupported import kind '" & Kind & "'");
            return;
         end if;
      end;
   end Parse_Import;

   procedure Parse_Export is
      N : Unbounded_String := To_Unbounded_String ("");
   begin
      Cur := Cur + 2;  -- consume '(' 'export'
      if Peek_Kind /= TK_Str then
         Fail (Peek_Line, "expected name string in export");
         return;
      end if;
      N := Str_Text (Cur);
      Cur := Cur + 1;
      if Peek_Kind /= TK_LPar or else Cur + 1 > N_Toks
        or else Toks (Cur + 1).Kind /= TK_Atom
      then
         Fail (Peek_Line, "expected (kind ref) in export");
         return;
      end if;
      declare
         Kind : constant String := Tok_Text (Cur + 1);
      begin
         Cur := Cur + 2;  -- consume '(' 'kind'
         if Kind = "func" then
            if Peek_Kind /= TK_Atom then
               Fail (Peek_Line, "expected func ref in export");
               return;
            end if;
            Add_Export_Ref (EK_Func, N, Cur);
         elsif Kind = "memory" then
            if Peek_Kind /= TK_Atom then
               Fail (Peek_Line, "expected memory ref in export");
               return;
            end if;
            Add_Export_Ref (EK_Mem, N, Cur);
         elsif Kind = "global" then
            if Peek_Kind /= TK_Atom then
               Fail (Peek_Line, "expected global ref in export");
               return;
            end if;
            Add_Export_Ref (EK_Glob, N, Cur);
         elsif Kind = "table" then
            Fail (Peek_Line, "table exports unsupported (MVP scope)");
            return;
         else
            Fail (Peek_Line, "unsupported export kind '" & Kind & "'");
            return;
         end if;
         Cur := Cur + 1;  -- consume ref atom
         Expect_RPar ("kind");
      end;
      Expect_RPar ("export");
   end Parse_Export;

   procedure Parse_Type_Field is
      FT : Func_Type;
      F  : Func_Rec;   -- unused sink for Parse_Param_Group
      Id : Unbounded_String;
      Idx : Natural;
   begin
      Cur := Cur + 2;  -- consume '(' 'type'
      Maybe_Id (Id);
      if not Peek_List_Head ("func") then
         Fail (Peek_Line, "expected (func ..) in type decl");
         return;
      end if;
      Cur := Cur + 2;  -- consume '(' 'func'
      --  param/result groups inline (no locals recorded)
      loop
         exit when Length (Err) > 0;
         if Peek_List_Head ("param") then
            Parse_Param_Group (FT, F, False, True);
         elsif Peek_List_Head ("result") then
            Parse_Result_Group (FT);
         elsif Peek_Kind = TK_RPar then
            Cur := Cur + 1;
            exit;
         else
            Fail (Peek_Line, "unexpected token in type decl");
            return;
         end if;
      end loop;
      Expect_RPar ("type");
      --  bare param types inside (func i32 i32) shorthand also legal:
      --  handled above only via groups; bare atoms would error — spec
      --  requires groups anyway.
      Idx := Intern_Type (FT);
      if Idx > 0 and then Length (Id) > 0 then
         Type_Names (Idx) := Id;
      end if;
   end Parse_Type_Field;

   procedure Parse_Data is
      D   : Data_Rec;
      V   : Natural;
      OK  : Boolean;
      Sub : Natural;
   begin
      Cur := Cur + 2;  -- consume '(' 'data'
      D.Active := True;
      --  optional memidx
      if Peek_Kind = TK_Atom then
         declare
            S : constant String := Tok_Text (Cur);
         begin
            if S'Length >= 2 and then S (S'First) = '$' then
               Resolve_Ref (Cur, "memory", V, OK);
               if not OK then
                  return;
               end if;
               D.Mem_Idx := V;
               Cur := Cur + 1;
            elsif S'Length > 0 and then S (S'First) >= '0'
              and then S (S'First) <= '9'
            then
               Parse_Nat (Cur, V, OK);
               if not OK then
                  return;
               end if;
               D.Mem_Idx := V;
               Cur := Cur + 1;
            end if;
         end;
      end if;
      --  offset expr: (offset e) | (e) | bare "s" => 0
      if Peek_List_Head ("offset") then
         Cur := Cur + 2;
         D.Off_First := Cur;
         Span_To_Close (D.Off_Last);
         Cur := D.Off_Last + 2;  -- consume ')' of offset
      elsif Peek_Kind = TK_LPar then
         declare
            Close_T : Natural;
         begin
            D.Off_First := Cur;
            Scan_List (Close_T);
            if Close_T = 0 then
               return;
            end if;
            D.Off_Last := Close_T - 1;   -- instrs inside the list
            Cur := Close_T + 1;
         end;
      end if;
      D.Byte_Off := Data_Arena_N + 1;
      Sub := Data_Arena_N;
      while Peek_Kind = TK_Str loop
         Decode_String (Cur, Data_Arena, Data_Arena_N);
         Cur := Cur + 1;
      end loop;
      D.Byte_Len := Data_Arena_N - Sub;
      Expect_RPar ("data");
      if D.Off_First = 0 then
         --  (data "s") bare form: offset 0
         null;
      end if;
      if N_Datas >= Max_Data_Segs then
         Fail (0, "data segment overflow");
         return;
      end if;
      N_Datas := N_Datas + 1;
      Datas (N_Datas) := D;
   end Parse_Data;

   procedure Parse_Start is
   begin
      Cur := Cur + 2;  -- consume '(' 'start'
      if Peek_Kind /= TK_Atom then
         Fail (Peek_Line, "expected func ref in start");
         return;
      end if;
      Start_Pos := Toks (Cur).Pos;
      Start_Len := Toks (Cur).Len;
      Start_Line := Toks (Cur).Line;
      Cur := Cur + 1;
      Expect_RPar ("start");
   end Parse_Start;

   procedure Parse_Field is
   begin
      if Peek_Kind /= TK_LPar or else Cur + 1 > N_Toks
        or else Toks (Cur + 1).Kind /= TK_Atom
      then
         Fail (Peek_Line, "expected (field ..)");
         return;
      end if;
      declare
         Head : constant String := Tok_Text (Cur + 1);
      begin
         if Head = "func" then
            Parse_Func;
         elsif Head = "import" then
            Parse_Import;
         elsif Head = "export" then
            Parse_Export;
         elsif Head = "memory" then
            Parse_Memory;
         elsif Head = "global" then
            Parse_Global;
         elsif Head = "type" then
            Parse_Type_Field;
         elsif Head = "data" then
            Parse_Data;
         elsif Head = "start" then
            Parse_Start;
         elsif Head = "table" or else Head = "elem" then
            Fail (Toks (Cur + 1).Line,
                  "'" & Head & "' unsupported: no tables/elem in MVP scope");
         else
            Fail (Toks (Cur + 1).Line, "unknown module field '" & Head & "'");
         end if;
      end;
   end Parse_Field;

   --  ===================== instruction encoding =====================
   --  label stack for br/br_if/br_table resolution
   type Label_Kind is (LK_Block, LK_Loop, LK_If);
   type Label_Rec is record
      Name      : Unbounded_String := To_Unbounded_String ("");
      Kind      : Label_Kind := LK_Block;
      Else_Seen : Boolean := False;
   end record;
   Label_Stack : array (1 .. Max_Label_Depth) of Label_Rec;
   Label_N     : Natural := 0;

   --  current func context for local resolution (0 = const-expr mode)
   Cur_Func : Natural := 0;
   --  a stray 'end' at label depth 0 closes the implicit func block;
   --  after it, no more instructions may follow.
   Func_Ended : Boolean := False;

   --  named-local lookup: returns local index + 1, 0 = not found
   --  (a plain 0 result would collide with legitimate local index 0)
   function Find_Local (Name : String) return Natural is
      F    : Func_Rec;
      Slot : Natural;
   begin
      if Cur_Func = 0 then
         return 0;
      end if;
      F := Funcs (Cur_Func);
      for I in F.Implicit_Pars .. F.Loc_Cnt - 1 loop
         Slot := F.Loc_Off + I - F.Implicit_Pars;
         if Local_NLen (Slot) > 0 then
            declare
               N : constant String :=
                 Slice (Src, Local_NPos (Slot),
                        Local_NPos (Slot) + Local_NLen (Slot) - 1);
            begin
               if N = Name then
                  return I + 1;
               end if;
            end;
         end if;
      end loop;
      return 0;
   end Find_Local;

   --  forward
   procedure Instr_Stream (From_Tok, To_Tok : Natural);
   procedure Folded_Instr (Depth : Natural);

   procedure Push_Label (Name : Unbounded_String; K : Label_Kind) is
   begin
      if Label_N >= Max_Label_Depth then
         Fail (Peek_Line, "label depth overflow");
         return;
      end if;
      Label_N := Label_N + 1;
      Label_Stack (Label_N).Name := Name;
      Label_Stack (Label_N).Kind := K;
      Label_Stack (Label_N).Else_Seen := False;
   end Push_Label;

   procedure Resolve_Label (T : Natural; V : out Natural; OK : out Boolean) is
      S : constant String := Tok_Text (T);
   begin
      OK := False;
      V := 0;
      if S'Length >= 2 and then S (S'First) = '$' then
         for I in reverse 1 .. Label_N loop
            if To_String (Label_Stack (I).Name) = S then
               V := Label_N - I;
               OK := True;
               return;
            end if;
         end loop;
         Fail (Toks (T).Line, "unknown label " & S);
      else
         Parse_Nat (T, V, OK);
      end if;
   end Resolve_Label;

   --  optional (result t) blocktype — emits 0x40 or valtype code
   procedure Emit_Block_Type is
      VT : Value_Type;
   begin
      if Peek_List_Head ("result") then
         Cur := Cur + 2;
         if Peek_Kind /= TK_Atom or else not VT_Of (Tok_Text (Cur), VT) then
            Fail (Peek_Line, "expected value type in block result");
            return;
         end if;
         Put_B (Body_Buf, Body_N, VT_Code (VT));
         Cur := Cur + 1;
         Expect_RPar ("result");
      else
         Put_B (Body_Buf, Body_N, 16#40#);
      end if;
   end Emit_Block_Type;

   --  optional $label after block/loop/if
   function Maybe_Label return Unbounded_String is
      N : Unbounded_String := To_Unbounded_String ("");
   begin
      if Peek_Kind = TK_Atom then
         declare
            S : constant String := Tok_Text (Cur);
         begin
            if S'Length >= 2 and then S (S'First) = '$' then
               N := To_Unbounded_String (S);
               Cur := Cur + 1;
            end if;
         end;
      end if;
      return N;
   end Maybe_Label;

   --  memarg: consume offset=N / align=N atoms; returns (align_exp, off)
   procedure Parse_Memarg (Natural_Align : Unsigned_64;
                           A, O : out Unsigned_64) is
      S  : Unbounded_String;
      V  : Unsigned_64;
      OK : Boolean;
   begin
      A := Natural_Align;
      O := 0;
      loop
         exit when Peek_Kind /= TK_Atom;
         S := To_Unbounded_String (Tok_Text (Cur));
         if Length (S) > 7
           and then Slice (S, 1, 7) = "offset="
         then
            declare
               Num_Str : constant String := Slice (S, 8, Length (S));
            begin
               --  parse via a temp token shim: reuse Parse_Int_Bits on a
               --  synthetic — simplest is a small local parse.
               V := 0;
               OK := True;
               for K in Num_Str'Range loop
                  if Num_Str (K) < '0' or else Num_Str (K) > '9' then
                     OK := False;
                     exit;
                  end if;
                  V := V * 10 + Unsigned_64
                    (Character'Pos (Num_Str (K)) - Character'Pos ('0'));
               end loop;
               if not OK then
                  Fail (Peek_Line, "bad offset= value");
                  return;
               end if;
               O := V;
            end;
            Cur := Cur + 1;
         elsif Length (S) > 6
           and then Slice (S, 1, 6) = "align="
         then
            declare
               Num_Str : constant String := Slice (S, 7, Length (S));
            begin
               V := 0;
               OK := True;
               for K in Num_Str'Range loop
                  if Num_Str (K) < '0' or else Num_Str (K) > '9' then
                     OK := False;
                     exit;
                  end if;
                  V := V * 10 + Unsigned_64
                    (Character'Pos (Num_Str (K)) - Character'Pos ('0'));
               end loop;
               if not OK then
                  Fail (Peek_Line, "bad align= value");
                  return;
               end if;
               --  wasm encodes the exponent: align=N means 2^log2(N)
               if V = 0 or else (V and (V - 1)) /= 0 then
                  Fail (Peek_Line, "align= must be a power of two");
                  return;
               end if;
               declare
                  E : Unsigned_64 := 0;
                  X : Unsigned_64 := V;
               begin
                  while X > 1 loop
                     X := Shift_Right (X, 1);
                     E := E + 1;
                  end loop;
                  A := E;
               end;
            end;
            Cur := Cur + 1;
         else
            exit;
         end if;
      end loop;
   end Parse_Memarg;

   --  natural alignment exponent per memory op
   function Natural_Align_Of (Op : Unsigned_8) return Unsigned_64 is
   begin
      case Op is
         when 16#2C# | 16#2D# | 16#30# | 16#31# | 16#3A# | 16#3C# =>
            return 0;   -- 8-bit
         when 16#2E# | 16#2F# | 16#32# | 16#33# | 16#3B# | 16#3D# =>
            return 1;   -- 16-bit
         when 16#28# | 16#2A# | 16#34# | 16#35# | 16#36# | 16#38# | 16#3E# =>
            return 2;   -- 32-bit
         when others =>
            return 3;   -- 64-bit
      end case;
   end Natural_Align_Of;

   --  opcode lookup: returns opcode or 16#FF# for "not a numeric op"
   function Numeric_Op (S : String) return Unsigned_8 is
   begin
      --  comparisons
      if S = "i32.eqz" then return 16#45#;
      elsif S = "i32.eq" then return 16#46#;
      elsif S = "i32.ne" then return 16#47#;
      elsif S = "i32.lt_s" then return 16#48#;
      elsif S = "i32.lt_u" then return 16#49#;
      elsif S = "i32.gt_s" then return 16#4A#;
      elsif S = "i32.gt_u" then return 16#4B#;
      elsif S = "i32.le_s" then return 16#4C#;
      elsif S = "i32.le_u" then return 16#4D#;
      elsif S = "i32.ge_s" then return 16#4E#;
      elsif S = "i32.ge_u" then return 16#4F#;
      elsif S = "i64.eqz" then return 16#50#;
      elsif S = "i64.eq" then return 16#51#;
      elsif S = "i64.ne" then return 16#52#;
      elsif S = "i64.lt_s" then return 16#53#;
      elsif S = "i64.lt_u" then return 16#54#;
      elsif S = "i64.gt_s" then return 16#55#;
      elsif S = "i64.gt_u" then return 16#56#;
      elsif S = "i64.le_s" then return 16#57#;
      elsif S = "i64.le_u" then return 16#58#;
      elsif S = "i64.ge_s" then return 16#59#;
      elsif S = "i64.ge_u" then return 16#5A#;
      elsif S = "f32.eq" then return 16#5B#;
      elsif S = "f32.ne" then return 16#5C#;
      elsif S = "f32.lt" then return 16#5D#;
      elsif S = "f32.gt" then return 16#5E#;
      elsif S = "f32.le" then return 16#5F#;
      elsif S = "f32.ge" then return 16#60#;
      elsif S = "f64.eq" then return 16#61#;
      elsif S = "f64.ne" then return 16#62#;
      elsif S = "f64.lt" then return 16#63#;
      elsif S = "f64.gt" then return 16#64#;
      elsif S = "f64.le" then return 16#65#;
      elsif S = "f64.ge" then return 16#66#;
      --  i32 arithmetic
      elsif S = "i32.clz" then return 16#67#;
      elsif S = "i32.ctz" then return 16#68#;
      elsif S = "i32.popcnt" then return 16#69#;
      elsif S = "i32.add" then return 16#6A#;
      elsif S = "i32.sub" then return 16#6B#;
      elsif S = "i32.mul" then return 16#6C#;
      elsif S = "i32.div_s" then return 16#6D#;
      elsif S = "i32.div_u" then return 16#6E#;
      elsif S = "i32.rem_s" then return 16#6F#;
      elsif S = "i32.rem_u" then return 16#70#;
      elsif S = "i32.and" then return 16#71#;
      elsif S = "i32.or" then return 16#72#;
      elsif S = "i32.xor" then return 16#73#;
      elsif S = "i32.shl" then return 16#74#;
      elsif S = "i32.shr_s" then return 16#75#;
      elsif S = "i32.shr_u" then return 16#76#;
      elsif S = "i32.rotl" then return 16#77#;
      elsif S = "i32.rotr" then return 16#78#;
      --  i64 arithmetic
      elsif S = "i64.clz" then return 16#79#;
      elsif S = "i64.ctz" then return 16#7A#;
      elsif S = "i64.popcnt" then return 16#7B#;
      elsif S = "i64.add" then return 16#7C#;
      elsif S = "i64.sub" then return 16#7D#;
      elsif S = "i64.mul" then return 16#7E#;
      elsif S = "i64.div_s" then return 16#7F#;
      elsif S = "i64.div_u" then return 16#80#;
      elsif S = "i64.rem_s" then return 16#81#;
      elsif S = "i64.rem_u" then return 16#82#;
      elsif S = "i64.and" then return 16#83#;
      elsif S = "i64.or" then return 16#84#;
      elsif S = "i64.xor" then return 16#85#;
      elsif S = "i64.shl" then return 16#86#;
      elsif S = "i64.shr_s" then return 16#87#;
      elsif S = "i64.shr_u" then return 16#88#;
      elsif S = "i64.rotl" then return 16#89#;
      elsif S = "i64.rotr" then return 16#8A#;
      --  f32 arithmetic
      elsif S = "f32.abs" then return 16#8B#;
      elsif S = "f32.neg" then return 16#8C#;
      elsif S = "f32.ceil" then return 16#8D#;
      elsif S = "f32.floor" then return 16#8E#;
      elsif S = "f32.trunc" then return 16#8F#;
      elsif S = "f32.nearest" then return 16#90#;
      elsif S = "f32.sqrt" then return 16#91#;
      elsif S = "f32.add" then return 16#92#;
      elsif S = "f32.sub" then return 16#93#;
      elsif S = "f32.mul" then return 16#94#;
      elsif S = "f32.div" then return 16#95#;
      elsif S = "f32.min" then return 16#96#;
      elsif S = "f32.max" then return 16#97#;
      elsif S = "f32.copysign" then return 16#98#;
      --  f64 arithmetic
      elsif S = "f64.abs" then return 16#99#;
      elsif S = "f64.neg" then return 16#9A#;
      elsif S = "f64.ceil" then return 16#9B#;
      elsif S = "f64.floor" then return 16#9C#;
      elsif S = "f64.trunc" then return 16#9D#;
      elsif S = "f64.nearest" then return 16#9E#;
      elsif S = "f64.sqrt" then return 16#9F#;
      elsif S = "f64.add" then return 16#A0#;
      elsif S = "f64.sub" then return 16#A1#;
      elsif S = "f64.mul" then return 16#A2#;
      elsif S = "f64.div" then return 16#A3#;
      elsif S = "f64.min" then return 16#A4#;
      elsif S = "f64.max" then return 16#A5#;
      elsif S = "f64.copysign" then return 16#A6#;
      --  conversions
      elsif S = "i32.wrap_i64" then return 16#A7#;
      elsif S = "i32.trunc_f32_s" then return 16#A8#;
      elsif S = "i32.trunc_f32_u" then return 16#A9#;
      elsif S = "i32.trunc_f64_s" then return 16#AA#;
      elsif S = "i32.trunc_f64_u" then return 16#AB#;
      elsif S = "i64.extend_i32_s" then return 16#AC#;
      elsif S = "i64.extend_i32_u" then return 16#AD#;
      elsif S = "i64.trunc_f32_s" then return 16#AE#;
      elsif S = "i64.trunc_f32_u" then return 16#AF#;
      elsif S = "i64.trunc_f64_s" then return 16#B0#;
      elsif S = "i64.trunc_f64_u" then return 16#B1#;
      elsif S = "f32.convert_i32_s" then return 16#B2#;
      elsif S = "f32.convert_i32_u" then return 16#B3#;
      elsif S = "f32.convert_i64_s" then return 16#B4#;
      elsif S = "f32.convert_i64_u" then return 16#B5#;
      elsif S = "f32.demote_f64" then return 16#B6#;
      elsif S = "f64.convert_i32_s" then return 16#B7#;
      elsif S = "f64.convert_i32_u" then return 16#B8#;
      elsif S = "f64.convert_i64_s" then return 16#B9#;
      elsif S = "f64.convert_i64_u" then return 16#BA#;
      elsif S = "f64.promote_f32" then return 16#BB#;
      elsif S = "i32.reinterpret_f32" then return 16#BC#;
      elsif S = "i64.reinterpret_f64" then return 16#BD#;
      elsif S = "f32.reinterpret_i32" then return 16#BE#;
      elsif S = "f64.reinterpret_i64" then return 16#BF#;
      --  loads/stores
      elsif S = "i32.load" then return 16#28#;
      elsif S = "i64.load" then return 16#29#;
      elsif S = "f32.load" then return 16#2A#;
      elsif S = "f64.load" then return 16#2B#;
      elsif S = "i32.load8_s" then return 16#2C#;
      elsif S = "i32.load8_u" then return 16#2D#;
      elsif S = "i32.load16_s" then return 16#2E#;
      elsif S = "i32.load16_u" then return 16#2F#;
      elsif S = "i64.load8_s" then return 16#30#;
      elsif S = "i64.load8_u" then return 16#31#;
      elsif S = "i64.load16_s" then return 16#32#;
      elsif S = "i64.load16_u" then return 16#33#;
      elsif S = "i64.load32_s" then return 16#34#;
      elsif S = "i64.load32_u" then return 16#35#;
      elsif S = "i32.store" then return 16#36#;
      elsif S = "i64.store" then return 16#37#;
      elsif S = "f32.store" then return 16#38#;
      elsif S = "f64.store" then return 16#39#;
      elsif S = "i32.store8" then return 16#3A#;
      elsif S = "i32.store16" then return 16#3B#;
      elsif S = "i64.store8" then return 16#3C#;
      elsif S = "i64.store16" then return 16#3D#;
      elsif S = "i64.store32" then return 16#3E#;
      else
         return 16#FF#;
      end if;
   end Numeric_Op;

   function Is_Mem_Op (Op : Unsigned_8) return Boolean is
   begin
      return Op >= 16#28# and then Op <= 16#3E#;
   end Is_Mem_Op;

   --  consume a labelidx atom (numeric depth or $name)
   procedure Consume_Label_Imm is
      V  : Natural;
      OK : Boolean;
   begin
      if Peek_Kind /= TK_Atom then
         Fail (Peek_Line, "expected label index");
         return;
      end if;
      Resolve_Label (Cur, V, OK);
      if OK then
         Put_ULEB (Body_Buf, Body_N, Unsigned_64 (V));
      end if;
      Cur := Cur + 1;
   end Consume_Label_Imm;

   --  is the atom at Cur usable as a labelidx? (for br_table greed)
   function Is_Label_Atom return Boolean is
   begin
      if Peek_Kind /= TK_Atom then
         return False;
      end if;
      declare
         S : constant String := Tok_Text (Cur);
      begin
         if S'Length = 0 then
            return False;
         end if;
         if S (S'First) = '$' then
            return True;
         end if;
         for K in S'Range loop
            if S (K) < '0' or else S (K) > '9' then
               return False;
            end if;
         end loop;
         return True;
      end;
   end Is_Label_Atom;

   --  is the atom at Cur a bare index literal? (memidx operand)
   function Is_Nat_Atom return Boolean is
   begin
      if Peek_Kind /= TK_Atom then
         return False;
      end if;
      declare
         S : constant String := Tok_Text (Cur);
      begin
         if S'Length = 0 then
            return False;
         end if;
         for K in S'Range loop
            if S (K) < '0' or else S (K) > '9' then
               return False;
            end if;
         end loop;
         return True;
      end;
   end Is_Nat_Atom;

   --  flat instruction dispatch: Cur sits on the mnemonic atom.
   --  Shared by top-level streams and inside folded (block/loop/if).
   procedure Flat_Instr is
      A      : constant String := Tok_Text (Cur);
      Op     : Unsigned_8;
      V      : Natural;
      U      : Unsigned_64;
      OK     : Boolean;
      F      : Long_Float;
      HR     : Boolean;
      RB     : Unsigned_64;
      MA     : Unsigned_64;
      MO     : Unsigned_64;
      Lab_V  : array (1 .. 256) of Natural;
      N_LabN : Natural := 0;
   begin
      Cur := Cur + 1;  -- consume mnemonic
      if A = "block" or else A = "loop" or else A = "if" then
         declare
            Lbl : Unbounded_String;
         begin
            Lbl := Maybe_Label;
            if A = "block" then
               Put_B (Body_Buf, Body_N, 16#02#);
               Push_Label (Lbl, LK_Block);
            elsif A = "loop" then
               Put_B (Body_Buf, Body_N, 16#03#);
               Push_Label (Lbl, LK_Loop);
            else
               Put_B (Body_Buf, Body_N, 16#04#);
               Push_Label (Lbl, LK_If);
            end if;
            Emit_Block_Type;
         end;
      elsif A = "else" then
         if Label_N = 0
           or else Label_Stack (Label_N).Kind /= LK_If
           or else Label_Stack (Label_N).Else_Seen
         then
            Fail (Toks (Cur - 1).Line, "'else' outside if-block");
            return;
         end if;
         Label_Stack (Label_N).Else_Seen := True;
         Put_B (Body_Buf, Body_N, 16#05#);
      elsif A = "end" then
         if Label_N = 0 then
            if Cur_Func = 0 then
               Fail (Toks (Cur - 1).Line, "'end' outside a func body");
               return;
            end if;
            if Func_Ended then
               Fail (Toks (Cur - 1).Line, "duplicate func 'end'");
               return;
            end if;
            Func_Ended := True;
            Put_B (Body_Buf, Body_N, 16#0B#);
            return;
         end if;
         Label_N := Label_N - 1;
         Put_B (Body_Buf, Body_N, 16#0B#);
      elsif A = "br" then
         Put_B (Body_Buf, Body_N, 16#0C#);
         Consume_Label_Imm;
      elsif A = "br_if" then
         Put_B (Body_Buf, Body_N, 16#0D#);
         Consume_Label_Imm;
      elsif A = "br_table" then
         N_LabN := 0;
         while Is_Label_Atom loop
            Resolve_Label (Cur, V, OK);
            if not OK then
               return;
            end if;
            if N_LabN < Lab_V'Last then
               N_LabN := N_LabN + 1;
               Lab_V (N_LabN) := V;
            else
               Fail (Toks (Cur).Line, "br_table label overflow");
               return;
            end if;
            Cur := Cur + 1;
         end loop;
         if N_LabN = 0 then
            Fail (Toks (Cur).Line, "br_table needs at least one label");
            return;
         end if;
         Put_B (Body_Buf, Body_N, 16#0E#);
         Put_ULEB (Body_Buf, Body_N, Unsigned_64 (N_LabN - 1));
         for I in 1 .. N_LabN loop
            Put_ULEB (Body_Buf, Body_N, Unsigned_64 (Lab_V (I)));
         end loop;
      elsif A = "return" then
         Put_B (Body_Buf, Body_N, 16#0F#);
      elsif A = "call" then
         if Peek_Kind /= TK_Atom then
            Fail (Peek_Line, "expected func ref after call");
            return;
         end if;
         Resolve_Ref (Cur, "func", V, OK);
         if not OK then
            return;
         end if;
         Put_B (Body_Buf, Body_N, 16#10#);
         Put_ULEB (Body_Buf, Body_N, Unsigned_64 (V));
         Cur := Cur + 1;
      elsif A = "call_indirect" then
         Fail (Toks (Cur - 1).Line,
               "call_indirect unsupported: no tables in MVP scope");
         return;
      elsif A = "unreachable" then
         Put_B (Body_Buf, Body_N, 16#00#);
      elsif A = "nop" then
         Put_B (Body_Buf, Body_N, 16#01#);
      elsif A = "drop" then
         Put_B (Body_Buf, Body_N, 16#1A#);
      elsif A = "select" then
         Put_B (Body_Buf, Body_N, 16#1B#);
      elsif A = "local.get" or else A = "get_local" then
         if Peek_Kind /= TK_Atom then
            Fail (Peek_Line, "expected local index");
            return;
         end if;
         declare
            S : constant String := Tok_Text (Cur);
         begin
            if S'Length >= 2 and then S (S'First) = '$' then
               V := Find_Local (S);
               if V = 0 then
                  Fail (Toks (Cur).Line, "unknown local " & S);
                  return;
               end if;
               V := V - 1;
            else
               Parse_Nat (Cur, V, OK);
               if not OK then
                  return;
               end if;
               if Cur_Func /= 0
                 and then V >= Funcs (Cur_Func).Loc_Cnt
               then
                  Fail (Toks (Cur).Line, "local index out of range");
                  return;
               end if;
            end if;
         end;
         Put_B (Body_Buf, Body_N, 16#20#);
         Put_ULEB (Body_Buf, Body_N, Unsigned_64 (V));
         Cur := Cur + 1;
      elsif A = "local.set" or else A = "set_local" then
         if Peek_Kind /= TK_Atom then
            Fail (Peek_Line, "expected local index");
            return;
         end if;
         declare
            S : constant String := Tok_Text (Cur);
         begin
            if S'Length >= 2 and then S (S'First) = '$' then
               V := Find_Local (S);
               if V = 0 then
                  Fail (Toks (Cur).Line, "unknown local " & S);
                  return;
               end if;
               V := V - 1;
            else
               Parse_Nat (Cur, V, OK);
               if not OK then
                  return;
               end if;
               if Cur_Func /= 0
                 and then V >= Funcs (Cur_Func).Loc_Cnt
               then
                  Fail (Toks (Cur).Line, "local index out of range");
                  return;
               end if;
            end if;
         end;
         Put_B (Body_Buf, Body_N, 16#21#);
         Put_ULEB (Body_Buf, Body_N, Unsigned_64 (V));
         Cur := Cur + 1;
      elsif A = "local.tee" or else A = "tee_local" then
         if Peek_Kind /= TK_Atom then
            Fail (Peek_Line, "expected local index");
            return;
         end if;
         declare
            S : constant String := Tok_Text (Cur);
         begin
            if S'Length >= 2 and then S (S'First) = '$' then
               V := Find_Local (S);
               if V = 0 then
                  Fail (Toks (Cur).Line, "unknown local " & S);
                  return;
               end if;
               V := V - 1;
            else
               Parse_Nat (Cur, V, OK);
               if not OK then
                  return;
               end if;
               if Cur_Func /= 0
                 and then V >= Funcs (Cur_Func).Loc_Cnt
               then
                  Fail (Toks (Cur).Line, "local index out of range");
                  return;
               end if;
            end if;
         end;
         Put_B (Body_Buf, Body_N, 16#22#);
         Put_ULEB (Body_Buf, Body_N, Unsigned_64 (V));
         Cur := Cur + 1;
      elsif A = "global.get" or else A = "get_global" then
         if Peek_Kind /= TK_Atom then
            Fail (Peek_Line, "expected global index");
            return;
         end if;
         Resolve_Ref (Cur, "global", V, OK);
         if not OK then
            return;
         end if;
         Put_B (Body_Buf, Body_N, 16#23#);
         Put_ULEB (Body_Buf, Body_N, Unsigned_64 (V));
         Cur := Cur + 1;
      elsif A = "global.set" or else A = "set_global" then
         if Peek_Kind /= TK_Atom then
            Fail (Peek_Line, "expected global index");
            return;
         end if;
         Resolve_Ref (Cur, "global", V, OK);
         if not OK then
            return;
         end if;
         Put_B (Body_Buf, Body_N, 16#24#);
         Put_ULEB (Body_Buf, Body_N, Unsigned_64 (V));
         Cur := Cur + 1;
      elsif A = "i32.const" then
         if Peek_Kind /= TK_Atom then
            Fail (Peek_Line, "expected i32 literal");
            return;
         end if;
         Parse_Int_Bits (Cur, 32, U, OK);
         if not OK then
            return;
         end if;
         --  sign-extend the 32-bit operand for correct SLEB (-1 must
         --  encode as a 1-byte sleb, not as the u64 4294967295)
         if (U and 16#80000000#) /= 0 then
            U := U or 16#FFFFFFFF00000000#;
         end if;
         Put_B (Body_Buf, Body_N, 16#41#);
         Put_SLEB (Body_Buf, Body_N, U);
         Cur := Cur + 1;
      elsif A = "i64.const" then
         if Peek_Kind /= TK_Atom then
            Fail (Peek_Line, "expected i64 literal");
            return;
         end if;
         Parse_Int_Bits (Cur, 64, U, OK);
         if not OK then
            return;
         end if;
         Put_B (Body_Buf, Body_N, 16#42#);
         Put_SLEB (Body_Buf, Body_N, U);
         Cur := Cur + 1;
      elsif A = "f32.const" then
         if Peek_Kind /= TK_Atom then
            Fail (Peek_Line, "expected f32 literal");
            return;
         end if;
         Parse_Float (Cur, F, HR, RB, OK);
         if not OK then
            return;
         end if;
         Put_B (Body_Buf, Body_N, 16#43#);
         if HR then
            Put_U32_LE (Body_Buf, Body_N, F32_Raw_Bits (RB));
         else
            Put_U32_LE (Body_Buf, Body_N,
                        F32_Bits (IEEE_Float_32 (F)));
         end if;
         Cur := Cur + 1;
      elsif A = "f64.const" then
         if Peek_Kind /= TK_Atom then
            Fail (Peek_Line, "expected f64 literal");
            return;
         end if;
         Parse_Float (Cur, F, HR, RB, OK);
         if not OK then
            return;
         end if;
         Put_B (Body_Buf, Body_N, 16#44#);
         if HR then
            Put_U64_LE (Body_Buf, Body_N, RB);
         else
            Put_U64_LE (Body_Buf, Body_N,
                        F64_Bits (IEEE_Float_64 (F)));
         end if;
         Cur := Cur + 1;
      elsif A = "memory.size" then
         Put_B (Body_Buf, Body_N, 16#3F#);
         if Is_Nat_Atom then
            Cur := Cur + 1;
         end if;
         Put_ULEB (Body_Buf, Body_N, 0);
      elsif A = "memory.grow" then
         Put_B (Body_Buf, Body_N, 16#40#);
         if Is_Nat_Atom then
            Cur := Cur + 1;
         end if;
         Put_ULEB (Body_Buf, Body_N, 0);
      else
         Op := Numeric_Op (A);
         if Op = 16#FF# then
            Fail (Toks (Cur - 1).Line, "unknown instruction '" & A & "'");
            return;
         end if;
         Put_B (Body_Buf, Body_N, Op);
         if Is_Mem_Op (Op) then
            Parse_Memarg (Natural_Align_Of (Op), MA, MO);
            Put_ULEB (Body_Buf, Body_N, MA);
            Put_ULEB (Body_Buf, Body_N, MO);
         end if;
      end if;
   end Flat_Instr;

   --  flat instruction stream over a token span (func bodies, blocks)
   procedure Instr_Stream (From_Tok, To_Tok : Natural) is
   begin
      Cur := From_Tok;
      while Cur <= To_Tok loop
         exit when Length (Err) > 0;
         if Func_Ended then
            Fail (Toks (Cur).Line, "instructions after func 'end'");
            return;
         end if;
         if Toks (Cur).Kind = TK_Atom then
            Flat_Instr;
         elsif Toks (Cur).Kind = TK_LPar then
            Folded_Instr (0);
         else
            Fail (Toks (Cur).Line, "unexpected token in instruction stream");
            return;
         end if;
      end loop;
   end Instr_Stream;

   --  folded '(...)' instruction: Cur at '('
   procedure Folded_Instr (Depth : Natural) is
      Head_Line : Natural;
   begin
      if Depth >= Max_Instr_Depth then
         Fail (Peek_Line, "folded instruction depth overflow");
         return;
      end if;
      Head_Line := Peek_Line;
      Cur := Cur + 1;  -- consume '('
      if Peek_Kind /= TK_Atom then
         Fail (Peek_Line, "expected instruction after '('");
         return;
      end if;
      declare
         A : constant String := Tok_Text (Cur);
         V : Natural;
         U : Unsigned_64;
         OK : Boolean;
         F  : Long_Float;
         HR : Boolean;
         RB : Unsigned_64;
         Op : Unsigned_8;
         MA : Unsigned_64;
         MO : Unsigned_64;
         Lbl : Unbounded_String;
      begin
         Cur := Cur + 1;  -- consume mnemonic
         if A = "block" or else A = "loop" then
            Lbl := Maybe_Label;
            if A = "block" then
               Put_B (Body_Buf, Body_N, 16#02#);
               Push_Label (Lbl, LK_Block);
            else
               Put_B (Body_Buf, Body_N, 16#03#);
               Push_Label (Lbl, LK_Loop);
            end if;
            Emit_Block_Type;
            loop
               exit when Length (Err) > 0;
               if Peek_Kind = TK_RPar then
                  Cur := Cur + 1;
                  exit;
               elsif Peek_Kind = TK_LPar then
                  Folded_Instr (Depth + 1);
               elsif Peek_Kind = TK_Atom then
                  Flat_Instr;
               else
                  Fail (Peek_Line, "unexpected token in " & A);
                  exit;
               end if;
            end loop;
            if Label_N = 0 then
               Fail (Head_Line, "label stack underflow in " & A);
               return;
            end if;
            Label_N := Label_N - 1;
            Put_B (Body_Buf, Body_N, 16#0B#);
         elsif A = "if" then
            --  folded if:  (if $l? (result t)? cond* (then i*) (else i*)?)
            --  Emission order is fixed: cond operands -> 0x04 + bt ->
            --  then instrs -> 0x05 -> else instrs -> 0x0B.  The blocktype
            --  is consumed eagerly but emitted with the opcode; the
            --  0x05 goes out when the (else) list is sighted, BEFORE
            --  its children are encoded.
            declare
               BT         : Unsigned_8 := 16#40#;
               VT         : Value_Type;
               Saw_Then   : Boolean := False;
               Saw_Else   : Boolean := False;
               If_Opened  : Boolean := False;
            begin
               Lbl := Maybe_Label;
               if Peek_List_Head ("result") then
                  Cur := Cur + 2;
                  if Peek_Kind /= TK_Atom
                    or else not VT_Of (Tok_Text (Cur), VT)
                  then
                     Fail (Peek_Line, "expected value type in if result");
                     return;
                  end if;
                  BT := VT_Code (VT);
                  Cur := Cur + 1;
                  Expect_RPar ("result");
               end if;
               loop
                  exit when Length (Err) > 0;
                  if Peek_Kind = TK_RPar then
                     Cur := Cur + 1;
                     exit;
                  elsif Peek_List_Head ("then") then
                     if Saw_Then then
                        Fail (Peek_Line, "duplicate (then ..)");
                        exit;
                     end if;
                     Saw_Then := True;
                     if not If_Opened then
                        If_Opened := True;
                        Put_B (Body_Buf, Body_N, 16#04#);
                        Put_B (Body_Buf, Body_N, BT);
                        Push_Label (Lbl, LK_If);
                     end if;
                     Cur := Cur + 2;  -- consume '(' 'then'
                     loop
                        exit when Length (Err) > 0;
                        if Peek_Kind = TK_RPar then
                           Cur := Cur + 1;
                           exit;
                        elsif Peek_Kind = TK_LPar then
                           Folded_Instr (Depth + 1);
                        elsif Peek_Kind = TK_Atom then
                           Flat_Instr;
                        else
                           Fail (Peek_Line, "bad token in then");
                           exit;
                        end if;
                     end loop;
                  elsif Peek_List_Head ("else") then
                     if not Saw_Then then
                        Fail (Peek_Line, "(else ..) before (then ..)");
                        exit;
                     end if;
                     if Saw_Else then
                        Fail (Peek_Line, "duplicate (else ..)");
                        exit;
                     end if;
                     Saw_Else := True;
                     Put_B (Body_Buf, Body_N, 16#05#);
                     Cur := Cur + 2;  -- consume '(' 'else'
                     loop
                        exit when Length (Err) > 0;
                        if Peek_Kind = TK_RPar then
                           Cur := Cur + 1;
                           exit;
                        elsif Peek_Kind = TK_LPar then
                           Folded_Instr (Depth + 1);
                        elsif Peek_Kind = TK_Atom then
                           Flat_Instr;
                        else
                           Fail (Peek_Line, "bad token in else");
                           exit;
                        end if;
                     end loop;
                  elsif Peek_Kind = TK_LPar then
                     if If_Opened then
                        Fail (Peek_Line,
                              "folded operand after (then ..) in if");
                        exit;
                     end if;
                     --  condition operand(s): emitted before 0x04
                     Folded_Instr (Depth + 1);
                  else
                     Fail (Peek_Line,
                           "unexpected token in folded if");
                     exit;
                  end if;
               end loop;
               if not Saw_Then then
                  Fail (Head_Line, "folded if missing (then ..)");
                  return;
               end if;
               if Label_N = 0 then
                  Fail (Head_Line, "label stack underflow in if");
                  return;
               end if;
               Label_N := Label_N - 1;
               Put_B (Body_Buf, Body_N, 16#0B#);
            end;
         elsif A = "then" or else A = "else" then
            Fail (Head_Line, "'" & A & "' outside folded if");
            return;
         --  ----- plain ops with optional immediates + folded operands
         elsif A = "call" then
            if Peek_Kind /= TK_Atom then
               Fail (Peek_Line, "expected func ref after call");
               return;
            end if;
            Resolve_Ref (Cur, "func", V, OK);
            if not OK then
               return;
            end if;
            Cur := Cur + 1;
            while Peek_Kind = TK_LPar loop
               Folded_Instr (Depth + 1);
            end loop;
            if Peek_Kind = TK_Atom then
               Fail (Peek_Line, "bare operand in folded call");
               return;
            end if;
            Put_B (Body_Buf, Body_N, 16#10#);
            Put_ULEB (Body_Buf, Body_N, Unsigned_64 (V));
            Expect_RPar ("call");
         elsif A = "br" or else A = "br_if" then
            declare
               Op_C : constant Unsigned_8 :=
                 (if A = "br" then 16#0C# else 16#0D#);
            begin
               if Peek_Kind /= TK_Atom then
                  Fail (Peek_Line, "expected label in " & A);
                  return;
               end if;
               Resolve_Label (Cur, V, OK);
               if not OK then
                  return;
               end if;
               Cur := Cur + 1;
               while Peek_Kind = TK_LPar loop
                  Folded_Instr (Depth + 1);
               end loop;
               if Peek_Kind = TK_Atom then
                  Fail (Peek_Line, "bare operand in folded " & A);
                  return;
               end if;
               Put_B (Body_Buf, Body_N, Op_C);
               Put_ULEB (Body_Buf, Body_N, Unsigned_64 (V));
               Expect_RPar (A);
            end;
         elsif A = "br_table" then
            declare
               Lab_V  : array (1 .. 256) of Natural;
               N_LabN : Natural := 0;
            begin
               while Peek_Kind = TK_Atom and then Is_Label_Atom loop
                  Resolve_Label (Cur, V, OK);
                  if not OK then
                     return;
                  end if;
                  if N_LabN < Lab_V'Last then
                     N_LabN := N_LabN + 1;
                     Lab_V (N_LabN) := V;
                  else
                     Fail (Peek_Line, "br_table label overflow");
                     return;
                  end if;
                  Cur := Cur + 1;
               end loop;
               if N_LabN = 0 then
                  Fail (Peek_Line, "br_table needs at least one label");
                  return;
               end if;
               while Peek_Kind = TK_LPar loop
                  Folded_Instr (Depth + 1);
               end loop;
               Put_B (Body_Buf, Body_N, 16#0E#);
               Put_ULEB (Body_Buf, Body_N, Unsigned_64 (N_LabN - 1));
               for I in 1 .. N_LabN loop
                  Put_ULEB (Body_Buf, Body_N, Unsigned_64 (Lab_V (I)));
               end loop;
               Expect_RPar ("br_table");
            end;
         elsif A = "local.get" or else A = "get_local"
           or else A = "local.set" or else A = "set_local"
           or else A = "local.tee" or else A = "tee_local"
         then
            if Peek_Kind /= TK_Atom then
               Fail (Peek_Line, "expected local index");
               return;
            end if;
            declare
               S : constant String := Tok_Text (Cur);
            begin
               if S'Length >= 2 and then S (S'First) = '$' then
                  V := Find_Local (S);
                  if V = 0 then
                     Fail (Toks (Cur).Line, "unknown local " & S);
                     return;
                  end if;
                  V := V - 1;
               else
                  Parse_Nat (Cur, V, OK);
                  if not OK then
                     return;
                  end if;
                  if Cur_Func /= 0
                    and then V >= Funcs (Cur_Func).Loc_Cnt
                  then
                     Fail (Toks (Cur).Line, "local index out of range");
                     return;
                  end if;
               end if;
            end;
            Cur := Cur + 1;
            while Peek_Kind = TK_LPar loop
               Folded_Instr (Depth + 1);
            end loop;
            if Peek_Kind = TK_Atom then
               Fail (Peek_Line, "bare operand in folded " & A);
               return;
            end if;
            if A = "local.get" or else A = "get_local" then
               Put_B (Body_Buf, Body_N, 16#20#);
            elsif A = "local.set" or else A = "set_local" then
               Put_B (Body_Buf, Body_N, 16#21#);
            else
               Put_B (Body_Buf, Body_N, 16#22#);
            end if;
            Put_ULEB (Body_Buf, Body_N, Unsigned_64 (V));
            Expect_RPar (A);
         elsif A = "global.get" or else A = "get_global"
           or else A = "global.set" or else A = "set_global"
         then
            if Peek_Kind /= TK_Atom then
               Fail (Peek_Line, "expected global index");
               return;
            end if;
            Resolve_Ref (Cur, "global", V, OK);
            if not OK then
               return;
            end if;
            Cur := Cur + 1;
            while Peek_Kind = TK_LPar loop
               Folded_Instr (Depth + 1);
            end loop;
            if Peek_Kind = TK_Atom then
               Fail (Peek_Line, "bare operand in folded " & A);
               return;
            end if;
            if A = "global.get" or else A = "get_global" then
               Put_B (Body_Buf, Body_N, 16#23#);
            else
               Put_B (Body_Buf, Body_N, 16#24#);
            end if;
            Put_ULEB (Body_Buf, Body_N, Unsigned_64 (V));
            Expect_RPar (A);
         elsif A = "i32.const" or else A = "i64.const" then
            if Peek_Kind /= TK_Atom then
               Fail (Peek_Line, "expected literal in " & A);
               return;
            end if;
            Parse_Int_Bits (Cur, (if A = "i32.const" then 32 else 64),
                            U, OK);
            if not OK then
               return;
            end if;
            Cur := Cur + 1;
            if A = "i32.const" then
               if (U and 16#80000000#) /= 0 then
                  U := U or 16#FFFFFFFF00000000#;
               end if;
               Put_B (Body_Buf, Body_N, 16#41#);
               Put_SLEB (Body_Buf, Body_N, U);
            else
               Put_B (Body_Buf, Body_N, 16#42#);
               Put_SLEB (Body_Buf, Body_N, U);
            end if;
            Expect_RPar (A);
         elsif A = "f32.const" or else A = "f64.const" then
            if Peek_Kind /= TK_Atom then
               Fail (Peek_Line, "expected literal in " & A);
               return;
            end if;
            Parse_Float (Cur, F, HR, RB, OK);
            if not OK then
               return;
            end if;
            Cur := Cur + 1;
            if A = "f32.const" then
               Put_B (Body_Buf, Body_N, 16#43#);
               if HR then
                  Put_U32_LE (Body_Buf, Body_N, F32_Raw_Bits (RB));
               else
                  Put_U32_LE (Body_Buf, Body_N,
                              F32_Bits (IEEE_Float_32 (F)));
               end if;
            else
               Put_B (Body_Buf, Body_N, 16#44#);
               if HR then
                  Put_U64_LE (Body_Buf, Body_N, RB);
               else
                  Put_U64_LE (Body_Buf, Body_N,
                              F64_Bits (IEEE_Float_64 (F)));
               end if;
            end if;
            Expect_RPar (A);
         elsif A = "memory.size" or else A = "memory.grow" then
            if Is_Nat_Atom then
               Cur := Cur + 1;
            end if;
            if A = "memory.size" then
               Put_B (Body_Buf, Body_N, 16#3F#);
            else
               Put_B (Body_Buf, Body_N, 16#40#);
            end if;
            Put_ULEB (Body_Buf, Body_N, 0);
            Expect_RPar (A);
         elsif A = "unreachable" or else A = "nop" or else A = "drop"
           or else A = "select" or else A = "return"
         then
            while Peek_Kind = TK_LPar loop
               Folded_Instr (Depth + 1);
            end loop;
            if Peek_Kind = TK_Atom then
               Fail (Peek_Line, "unexpected operand in " & A);
               return;
            end if;
            if A = "unreachable" then
               Put_B (Body_Buf, Body_N, 16#00#);
            elsif A = "nop" then
               Put_B (Body_Buf, Body_N, 16#01#);
            elsif A = "drop" then
               Put_B (Body_Buf, Body_N, 16#1A#);
            elsif A = "select" then
               Put_B (Body_Buf, Body_N, 16#1B#);
            else
               Put_B (Body_Buf, Body_N, 16#0F#);
            end if;
            Expect_RPar (A);
         else
            Op := Numeric_Op (A);
            if Op = 16#FF# then
               Fail (Toks (Cur - 1).Line,
                     "unknown instruction '" & A & "'");
               return;
            end if;
            if Is_Mem_Op (Op) then
               Parse_Memarg (Natural_Align_Of (Op), MA, MO);
            end if;
            while Peek_Kind = TK_LPar loop
               Folded_Instr (Depth + 1);
            end loop;
            if Peek_Kind = TK_Atom then
               Fail (Peek_Line, "bare operand in folded " & A);
               return;
            end if;
            Put_B (Body_Buf, Body_N, Op);
            if Is_Mem_Op (Op) then
               Put_ULEB (Body_Buf, Body_N, MA);
               Put_ULEB (Body_Buf, Body_N, MO);
            end if;
            Expect_RPar (A);
         end if;
      end;
   end Folded_Instr;

   --  ===================== func body encode =====================
   --  emits into Loc_Buf (locals vec) + Body_Buf (instrs + end);
   --  callers emit uleb(Loc_N + Body_N) then both buffers.
   procedure Encode_Func_Body (Func_Idx : Natural) is
      F         : constant Func_Rec := Funcs (Func_Idx);
      Run_VT    : Value_Type;
      Run_Cnt   : Unsigned_64;
      Slot      : Natural;
      Run_Start : Natural;
      N_Locals  : Natural;
      Runs_Cnt  : Unsigned_64 := 0;
   begin
      Body_N := 0;
      Loc_N := 0;
      Label_N := 0;
      Func_Ended := False;

      --  locals decl: RLE over the func's non-param slots.
      --  pass 1 counts runs (the vec header); pass 2 writes them.
      N_Locals := F.Loc_Cnt - F.Par_Cnt;
      Run_Start := F.Loc_Off + F.Par_Cnt - F.Implicit_Pars;
      Run_Cnt := 0;
      Run_VT := VT_I32;
      for I in 0 .. N_Locals - 1 loop
         Slot := Run_Start + I;
         if Run_Cnt = 0 then
            Run_VT := Local_Types (Slot);
            Run_Cnt := 1;
         elsif Local_Types (Slot) = Run_VT then
            Run_Cnt := Run_Cnt + 1;
         else
            Runs_Cnt := Runs_Cnt + 1;
            Run_VT := Local_Types (Slot);
            Run_Cnt := 1;
         end if;
      end loop;
      if Run_Cnt > 0 then
         Runs_Cnt := Runs_Cnt + 1;
      end if;
      Put_ULEB (Loc_Buf, Loc_N, Runs_Cnt);
      Run_Cnt := 0;
      Run_VT := VT_I32;
      for I in 0 .. N_Locals - 1 loop
         Slot := Run_Start + I;
         if Run_Cnt = 0 then
            Run_VT := Local_Types (Slot);
            Run_Cnt := 1;
         elsif Local_Types (Slot) = Run_VT then
            Run_Cnt := Run_Cnt + 1;
         else
            Put_ULEB (Loc_Buf, Loc_N, Run_Cnt);
            Put_B (Loc_Buf, Loc_N, VT_Code (Run_VT));
            Run_VT := Local_Types (Slot);
            Run_Cnt := 1;
         end if;
      end loop;
      if Run_Cnt > 0 then
         Put_ULEB (Loc_Buf, Loc_N, Run_Cnt);
         Put_B (Loc_Buf, Loc_N, VT_Code (Run_VT));
      end if;

      --  instructions
      Cur_Func := Func_Idx;
      if F.Body_First > 0 then
         Instr_Stream (F.Body_First, F.Body_Last);
      end if;
      if Label_N /= 0 then
         Fail (0, "unbalanced block/loop/if in func body");
         return;
      end if;
      if not Func_Ended then
         Put_B (Body_Buf, Body_N, 16#0B#);  -- implicit func end
      end if;
      Func_Ended := False;
      Cur_Func := 0;
   end Encode_Func_Body;

   --  ===================== module encoder =====================
   --  section emit: body in Sec_Buf(1..Sec_N) prefixed with id+len;
   --  the module image lands in Out_Buf then copies to the caller.
   procedure Out_B (B : Unsigned_8) is
   begin
      if Out_N >= Out_Buf'Last then
         Fail (0, "wasm output overflow");
         return;
      end if;
      Out_N := Out_N + 1;
      Out_Buf (Out_N) := B;
   end Out_B;

   procedure Out_ULEB (V : Unsigned_64) is
      X : Unsigned_64 := V;
   begin
      loop
         declare
            B : Unsigned_8 := Unsigned_8 (X and 16#7F#);
         begin
            X := Shift_Right (X, 7);
            if X /= 0 then
               B := B or 16#80#;
            end if;
            Out_B (B);
            exit when X = 0;
         end;
      end loop;
   end Out_ULEB;

   procedure Emit_Sec (Id : Unsigned_8) is
   begin
      if Sec_N = 0 then
         return;
      end if;
      Out_B (Id);
      Out_ULEB (Unsigned_64 (Sec_N));
      for I in 1 .. Sec_N loop
         Out_B (Sec_Buf (I));
      end loop;
   end Emit_Sec;

   procedure Encode_Module (Bytes : out Byte_Vec; Byte_Count : out Natural) is
      V   : Natural;
      OK  : Boolean;
   begin
      Byte_Count := 0;
      Out_N := 0;
      --  header
      Out_B (0);  Out_B (16#61#);  Out_B (16#73#);  Out_B (16#6D#);
      Out_B (1);  Out_B (0);       Out_B (0);       Out_B (0);

      --  type section
      Sec_N := 0;
      if N_Types > 0 then
         Put_ULEB (Sec_Buf, Sec_N, Unsigned_64 (N_Types));
         for I in 1 .. N_Types loop
            Put_B (Sec_Buf, Sec_N, 16#60#);
            Put_ULEB (Sec_Buf, Sec_N, Unsigned_64 (Types (I).NP));
            for K in 1 .. Types (I).NP loop
               Put_B (Sec_Buf, Sec_N, VT_Code (Types (I).P (K)));
            end loop;
            Put_ULEB (Sec_Buf, Sec_N, Unsigned_64 (Types (I).NR));
            for K in 1 .. Types (I).NR loop
               Put_B (Sec_Buf, Sec_N, VT_Code (Types (I).R (K)));
            end loop;
         end loop;
      end if;
      Emit_Sec (1);

      --  import section
      Sec_N := 0;
      if N_Imports > 0 then
         Put_ULEB (Sec_Buf, Sec_N, Unsigned_64 (N_Imports));
         for I in 1 .. N_Imports loop
            Put_Name (Sec_Buf, Sec_N, To_String (Imports (I).Mod_Name));
            Put_Name (Sec_Buf, Sec_N, To_String (Imports (I).Field));
            case Imports (I).Kind is
               when IK_Func =>
                  Put_B (Sec_Buf, Sec_N, 0);
                  Put_ULEB (Sec_Buf, Sec_N,
                            Unsigned_64 (Funcs (Imports (I).Ent_Idx).Type_Idx));
               when IK_Mem =>
                  Put_B (Sec_Buf, Sec_N, 2);
                  declare
                     M : constant Mem_Rec := Mems (Imports (I).Ent_Idx);
                  begin
                     if M.Has_Max then
                        Put_B (Sec_Buf, Sec_N, 1);
                        Put_ULEB (Sec_Buf, Sec_N, M.Min_Pages);
                        Put_ULEB (Sec_Buf, Sec_N, M.Max_Pages);
                     else
                        Put_B (Sec_Buf, Sec_N, 0);
                        Put_ULEB (Sec_Buf, Sec_N, M.Min_Pages);
                     end if;
                  end;
               when IK_Glob =>
                  Put_B (Sec_Buf, Sec_N, 3);
                  declare
                     G : constant Glob_Rec := Globals (Imports (I).Ent_Idx);
                  begin
                     Put_B (Sec_Buf, Sec_N, VT_Code (G.VT));
                     Put_B (Sec_Buf, Sec_N,
                            (if G.Mutable then 1 else 0));
                  end;
            end case;
         end loop;
      end if;
      Emit_Sec (2);

      --  func section: defined funcs in wasm-index order
      Sec_N := 0;
      declare
         N_Def : Natural := 0;
      begin
         for I in 1 .. N_Funcs loop
            if not Funcs (I).Imported then
               N_Def := N_Def + 1;
            end if;
         end loop;
         if N_Def > 0 then
            Put_ULEB (Sec_Buf, Sec_N, Unsigned_64 (N_Def));
            for W in 0 .. N_Funcs - 1 loop
               declare
                  R : constant Natural := Func_Rec_Of_Wasm (W);
               begin
                  if R /= 0 and then not Funcs (R).Imported then
                     Put_ULEB (Sec_Buf, Sec_N,
                               Unsigned_64 (Funcs (R).Type_Idx));
                  end if;
               end;
            end loop;
         end if;
      end;
      Emit_Sec (3);

      --  memory section: defined memories only
      Sec_N := 0;
      declare
         N_Def : Natural := 0;
      begin
         for I in 1 .. N_Mems loop
            if not Mems (I).Imported then
               N_Def := N_Def + 1;
            end if;
         end loop;
         if N_Def > 0 then
            Put_ULEB (Sec_Buf, Sec_N, Unsigned_64 (N_Def));
            for I in 1 .. N_Mems loop
               if not Mems (I).Imported then
                  if Mems (I).Has_Max then
                     Put_B (Sec_Buf, Sec_N, 1);
                     Put_ULEB (Sec_Buf, Sec_N, Mems (I).Min_Pages);
                     Put_ULEB (Sec_Buf, Sec_N, Mems (I).Max_Pages);
                  else
                     Put_B (Sec_Buf, Sec_N, 0);
                     Put_ULEB (Sec_Buf, Sec_N, Mems (I).Min_Pages);
                  end if;
               end if;
            end loop;
         end if;
      end;
      Emit_Sec (5);

      --  global section: defined globals only
      Sec_N := 0;
      declare
         N_Def : Natural := 0;
      begin
         for I in 1 .. N_Globals loop
            if not Globals (I).Imported then
               N_Def := N_Def + 1;
            end if;
         end loop;
         if N_Def > 0 then
            Put_ULEB (Sec_Buf, Sec_N, Unsigned_64 (N_Def));
            for I in 1 .. N_Globals loop
               if not Globals (I).Imported then
                  Put_B (Sec_Buf, Sec_N, VT_Code (Globals (I).VT));
                  Put_B (Sec_Buf, Sec_N,
                         (if Globals (I).Mutable then 1 else 0));
                  --  init expr via the instruction stream walker
                  Body_N := 0;
                  Label_N := 0;
                  Cur_Func := 0;
                  Instr_Stream (Globals (I).Init_First,
                                Globals (I).Init_Last);
                  Put_B (Body_Buf, Body_N, 16#0B#);
                  for K in 1 .. Body_N loop
                     Put_B (Sec_Buf, Sec_N, Body_Buf (K));
                  end loop;
               end if;
            end loop;
         end if;
      end;
      Emit_Sec (6);

      --  export section
      Sec_N := 0;
      if N_Exps > 0 then
         Put_ULEB (Sec_Buf, Sec_N, Unsigned_64 (N_Exps));
         for I in 1 .. N_Exps loop
            Put_Name (Sec_Buf, Sec_N, To_String (Exps (I).Name));
            case Exps (I).Kind is
               when EK_Func => Put_B (Sec_Buf, Sec_N, 0);
               when EK_Mem  => Put_B (Sec_Buf, Sec_N, 2);
               when EK_Glob => Put_B (Sec_Buf, Sec_N, 3);
            end case;
            Put_ULEB (Sec_Buf, Sec_N, Unsigned_64 (Exps (I).Idx));
         end loop;
      end if;
      Emit_Sec (7);

      --  start section
      if Start_Pos > 0 then
         Sec_N := 0;
         declare
            S : constant String :=
              Slice (Src, Start_Pos, Start_Pos + Start_Len - 1);
         begin
            if S'Length >= 2 and then S (S'First) = '$' then
               V := Find_Func_By_Name (S);
               if V = 0 then
                  Fail (Start_Line, "unknown start func " & S);
                  return;
               end if;
               V := V - 1;
            else
               --  numeric ref — parse from the stored text directly
               V := 0;
               OK := True;
               for K in S'Range loop
                  if S (K) < '0' or else S (K) > '9' then
                     OK := False;
                     exit;
                  end if;
                  V := V * 10 + (Character'Pos (S (K)) -
                                 Character'Pos ('0'));
               end loop;
               if not OK or else V >= N_Funcs then
                  Fail (Start_Line, "bad start func ref");
                  return;
               end if;
            end if;
         end;
         Put_ULEB (Sec_Buf, Sec_N, Unsigned_64 (V));
         Emit_Sec (8);
      end if;

      --  code section
      Sec_N := 0;
      declare
         N_Def : Natural := 0;
      begin
         for I in 1 .. N_Funcs loop
            if not Funcs (I).Imported then
               N_Def := N_Def + 1;
            end if;
         end loop;
         if N_Def > 0 then
            Put_ULEB (Sec_Buf, Sec_N, Unsigned_64 (N_Def));
            for W in 0 .. N_Funcs - 1 loop
               declare
                  R : constant Natural := Func_Rec_Of_Wasm (W);
               begin
                  if R /= 0 and then not Funcs (R).Imported then
                     Encode_Func_Body (R);
                     if Length (Err) > 0 then
                        return;
                     end if;
                     Put_ULEB (Sec_Buf, Sec_N,
                               Unsigned_64 (Loc_N + Body_N));
                     for K in 1 .. Loc_N loop
                        Put_B (Sec_Buf, Sec_N, Loc_Buf (K));
                     end loop;
                     for K in 1 .. Body_N loop
                        Put_B (Sec_Buf, Sec_N, Body_Buf (K));
                     end loop;
                  end if;
               end;
            end loop;
         end if;
      end;
      Emit_Sec (10);

      --  data section
      Sec_N := 0;
      if N_Datas > 0 then
         Put_ULEB (Sec_Buf, Sec_N, Unsigned_64 (N_Datas));
         for I in 1 .. N_Datas loop
            Put_ULEB (Sec_Buf, Sec_N, Unsigned_64 (Datas (I).Mem_Idx));
            if Datas (I).Off_First = 0 then
               Put_B (Sec_Buf, Sec_N, 16#41#);  -- i32.const 0
               Put_B (Sec_Buf, Sec_N, 0);
            else
               Body_N := 0;
               Label_N := 0;
               Cur_Func := 0;
               Instr_Stream (Datas (I).Off_First, Datas (I).Off_Last);
               for K in 1 .. Body_N loop
                  Put_B (Sec_Buf, Sec_N, Body_Buf (K));
               end loop;
            end if;
            Put_B (Sec_Buf, Sec_N, 16#0B#);
            Put_ULEB (Sec_Buf, Sec_N,
                      Unsigned_64 (Datas (I).Byte_Len));
            for K in 0 .. Datas (I).Byte_Len - 1 loop
               Put_B (Sec_Buf, Sec_N,
                      Data_Arena (Datas (I).Byte_Off + K));
            end loop;
         end loop;
      end if;
      Emit_Sec (11);

      --  copy the image to the caller's bounded buffer
      Byte_Count := Out_N;
      for I in 1 .. Out_N loop
         Bytes (I) := Out_Buf (I);
      end loop;
   end Encode_Module;

   --  ===================== module parse driver =====================
   procedure Parse_Module is
      Id : Unbounded_String;
   begin
      if Peek_List_Head ("module") then
         Cur := Cur + 2;
         Maybe_Id (Id);
         while Peek_Kind /= TK_RPar and then Peek_Kind /= TK_EOF loop
            exit when Length (Err) > 0;
            Parse_Field;
         end loop;
         Expect_RPar ("module");
      else
         while Peek_Kind /= TK_EOF loop
            exit when Length (Err) > 0;
            Parse_Field;
         end loop;
      end if;
      if Peek_Kind /= TK_EOF and then Length (Err) = 0 then
         Fail (Peek_Line, "trailing content after module");
      end if;
   end Parse_Module;

   --  wasm index assignment + type-ref resolution
   procedure Resolve_Indices is
      W  : Natural;
      OK : Boolean;
      TI : Natural;
   begin
      W := 0;
      for I in 1 .. N_Funcs loop
         if Funcs (I).Imported then
            Funcs (I).Wasm_Idx := W;
            W := W + 1;
         end if;
      end loop;
      for I in 1 .. N_Funcs loop
         if not Funcs (I).Imported then
            Funcs (I).Wasm_Idx := W;
            W := W + 1;
         end if;
      end loop;
      W := 0;
      for I in 1 .. N_Mems loop
         if Mems (I).Imported then
            Mems (I).Wasm_Idx := W;
            W := W + 1;
         end if;
      end loop;
      for I in 1 .. N_Mems loop
         if not Mems (I).Imported then
            Mems (I).Wasm_Idx := W;
            W := W + 1;
         end if;
      end loop;
      W := 0;
      for I in 1 .. N_Globals loop
         if Globals (I).Imported then
            Globals (I).Wasm_Idx := W;
            W := W + 1;
         end if;
      end loop;
      for I in 1 .. N_Globals loop
         if not Globals (I).Imported then
            Globals (I).Wasm_Idx := W;
            W := W + 1;
         end if;
      end loop;

      --  (type) refs declared inside funcs
      for I in 1 .. N_Funcs loop
         if Funcs (I).Decl_Type_Tok > 0 then
            Cur := Funcs (I).Decl_Type_Tok;
            Resolve_Ref (Cur, "type", TI, OK);
            if not OK then
               return;
            end if;
            if Funcs (I).Sig_Explicit then
               declare
                  FT : Func_Type;
               begin
                  FT.NP := Funcs (I).Sig_FT_NP;
                  FT.NR := Funcs (I).Sig_FT_NR;
                  FT.P := Funcs (I).Sig_P;
                  FT.R := Funcs (I).Sig_R;
                  if not Same_Type (Types (TI + 1), FT) then
                     Fail (Toks (Cur).Line,
                           "(type) index signature mismatch");
                     return;
                  end if;
               end;
            end if;
            Funcs (I).Type_Idx := TI;
            --  bare (type) ref with no (param) children: the type's
            --  params occupy wasm local indices without arena slots
            if Funcs (I).Par_Cnt = 0 and then Types (TI + 1).NP > 0 then
               Funcs (I).Implicit_Pars := Types (TI + 1).NP;
               Funcs (I).Par_Cnt := Types (TI + 1).NP;
               Funcs (I).Loc_Cnt := Funcs (I).Loc_Cnt + Types (TI + 1).NP;
            end if;
         end if;
      end loop;

      --  pending exports
      for I in 1 .. N_Exps loop
         if Exps (I).Pend then
            if Exps (I).Idx > 0 then
               --  PK_Ent: entity record idx stored in Idx
               declare
                  Ent : constant Natural := Exps (I).Idx;
               begin
                  case Exps (I).Kind is
                     when EK_Func =>
                        Exps (I).Idx := Funcs (Ent).Wasm_Idx;
                     when EK_Mem =>
                        Exps (I).Idx := Mems (Ent).Wasm_Idx;
                     when EK_Glob =>
                        Exps (I).Idx := Globals (Ent).Wasm_Idx;
                  end case;
               end;
            else
               --  PK_Ref: textual ref — resolve via a temp token search
               declare
                  S   : constant String :=
                    Slice (Src, Exps (I).P_Pos,
                           Exps (I).P_Pos + Exps (I).P_Len - 1);
                  V_D : Natural := 0;
               begin
                  if S'Length >= 2 and then S (S'First) = '$' then
                     case Exps (I).Kind is
                        when EK_Func =>
                           V_D := Find_Func_By_Name (S);
                        when EK_Mem =>
                           V_D := Find_Mem_By_Name (S);
                        when EK_Glob =>
                           V_D := Find_Glob_By_Name (S);
                     end case;
                     if V_D = 0 then
                        Fail (0, "unknown export ref " & S);
                        return;
                     end if;
                     Exps (I).Idx := V_D - 1;
                  else
                     --  numeric ref
                     declare
                        N2 : Natural := 0;
                        Bad : Boolean := False;
                     begin
                        for K in S'Range loop
                           if S (K) < '0' or else S (K) > '9' then
                              Bad := True;
                              exit;
                           end if;
                           N2 := N2 * 10 + (Character'Pos (S (K)) -
                                            Character'Pos ('0'));
                        end loop;
                        if Bad then
                           Fail (0, "bad export ref " & S);
                           return;
                        end if;
                        case Exps (I).Kind is
                           when EK_Func =>
                              if N2 >= N_Funcs then
                                 Fail (0, "export func idx out of range");
                                 return;
                              end if;
                           when EK_Mem =>
                              if N2 >= N_Mems then
                                 Fail (0, "export mem idx out of range");
                                 return;
                              end if;
                           when EK_Glob =>
                              if N2 >= N_Globals then
                                 Fail (0, "export global idx out of range");
                                 return;
                              end if;
                        end case;
                        Exps (I).Idx := N2;
                     end;
                  end if;
               end;
            end if;
            Exps (I).Pend := False;
         end if;
      end loop;
   end Resolve_Indices;

   --  ===================== public driver =====================
   procedure Assemble
     (Source       : String;
      Bytes        : out Byte_Vec;
      Byte_Count   : out Natural;
      Exports      : out Export_Array;
      Export_Count : out Natural;
      Error        : out Unbounded_String) is
   begin
      Byte_Count := 0;
      Export_Count := 0;
      Error := To_Unbounded_String ("");
      Err := To_Unbounded_String ("");
      Src := To_Unbounded_String (Source);
      N_Funcs := 0;
      N_Types := 0;
      N_Globals := 0;
      N_Mems := 0;
      N_Imports := 0;
      N_Exps := 0;
      N_Datas := 0;
      Data_Arena_N := 0;
      Local_N := 0;
      Start_Pos := 0;
      Label_N := 0;
      Cur_Func := 0;
      Cur := 1;
      for I in 1 .. Max_Types loop
         Type_Names (I) := To_Unbounded_String ("");
      end loop;

      Lex (Source);
      if Length (Err) = 0 then
         Cur := 1;
         Parse_Module;
      end if;
      if Length (Err) = 0 then
         Resolve_Indices;
      end if;
      if Length (Err) = 0 and then N_Datas > 0 and then N_Mems = 0 then
         Fail (0, "data segment with no memory declared");
      end if;
      if Length (Err) = 0 then
         Encode_Module (Bytes, Byte_Count);
      end if;

      if Length (Err) > 0 then
         Error := Err;
         return;
      end if;

      --  export surface for the caller (func sigs included)
      for I in 1 .. N_Exps loop
         if Export_Count >= Max_Exports then
            exit;
         end if;
         Export_Count := Export_Count + 1;
         Exports (Export_Count).Name := Exps (I).Name;
         case Exps (I).Kind is
            when EK_Func =>
               declare
                  R : constant Natural := Func_Rec_Of_Wasm (Exps (I).Idx);
               begin
                  if R /= 0 then
                     declare
                        FT : constant Func_Type :=
                          Types (Funcs (R).Type_Idx + 1);
                     begin
                        Exports (Export_Count).Is_Function := True;
                        Exports (Export_Count).Param_Count := FT.NP;
                        for K in 1 .. FT.NP loop
                           Exports (Export_Count).Params (K) := FT.P (K);
                        end loop;
                        Exports (Export_Count).Result_Count := FT.NR;
                        for K in 1 .. FT.NR loop
                           Exports (Export_Count).Results (K) := FT.R (K);
                        end loop;
                     end;
                  end if;
               end;
            when others =>
               null;
         end case;
      end loop;
   end Assemble;

end Wat_Assembler;

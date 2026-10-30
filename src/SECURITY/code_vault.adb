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
with Ada.Strings.Fixed;
with ALB_Types;     use ALB_Types;
with Roman_Spec;    use Roman_Spec;
with Roman_Math;    use Roman_Math;
with Numerus_Verus; use Numerus_Verus;
with Float_Expr;    use Float_Expr;

package body Code_Vault is

   -- Virtual Machine OpCodes for da Literal Forge
   OP_ADD : constant U64 := 16#A100_0000_0000_0000#;
   OP_XOR : constant U64 := 16#B200_0000_0000_0000#;
   OP_LSL : constant U64 := 16#C300_0000_0000_0000#;
   OP_LUT : constant U64 := 16#D400_0000_0000_0000#; -- Lookup Table
   OP_NON : constant U64 := 16#E500_0000_0000_0000#; -- Non-Linear Transform

   --------------------
   -- Iteration_Salt --
   --------------------
   -- Hoisted tae da tap so To_Roman_Literal kens it!
   function Iteration_Salt (I : Integer) return Integer is
   begin
      return (I * 16#31337#) mod 16#FFFF#;
   end Iteration_Salt;

   -- Lookup Table for OP_LUT synchronization
   ALB_SBOX : constant array (0 .. 255) of U8 :=
     (16#63#,
      16#7C#,
      16#77#,
      16#7B#,
      16#F2#,
      16#6B#,
      16#6F#,
      16#C5#,
      16#30#,
      16#01#,
      16#67#,
      16#2B#,
      16#FE#,
      16#D7#,
      16#AB#,
      16#76#,
      16#CA#,
      16#82#,
      16#C9#,
      16#7D#,
      16#FA#,
      16#59#,
      16#47#,
      16#F0#,
      16#AD#,
      16#D4#,
      16#A2#,
      16#AF#,
      16#9C#,
      16#A4#,
      16#72#,
      16#C0#,
      16#B7#,
      16#FD#,
      16#93#,
      16#26#,
      16#36#,
      16#3F#,
      16#F7#,
      16#CC#,
      16#34#,
      16#A5#,
      16#E5#,
      16#F1#,
      16#71#,
      16#D8#,
      16#31#,
      16#15#,
      16#04#,
      16#C7#,
      16#23#,
      16#C3#,
      16#18#,
      16#96#,
      16#05#,
      16#9A#,
      16#07#,
      16#12#,
      16#80#,
      16#E2#,
      16#EB#,
      16#27#,
      16#B2#,
      16#75#,
      16#09#,
      16#83#,
      16#2C#,
      16#1A#,
      16#1B#,
      16#6E#,
      16#5A#,
      16#A0#,
      16#52#,
      16#3B#,
      16#D6#,
      16#B3#,
      16#29#,
      16#E3#,
      16#2F#,
      16#84#,
      16#53#,
      16#D1#,
      16#00#,
      16#ED#,
      16#20#,
      16#FC#,
      16#B1#,
      16#5B#,
      16#6A#,
      16#CB#,
      16#BE#,
      16#39#,
      16#4A#,
      16#4C#,
      16#58#,
      16#CF#,
      16#D0#,
      16#EF#,
      16#AA#,
      16#FB#,
      16#43#,
      16#4D#,
      16#33#,
      16#85#,
      16#45#,
      16#F9#,
      16#02#,
      16#7F#,
      16#50#,
      16#3C#,
      16#9F#,
      16#A8#,
      16#51#,
      16#A3#,
      16#40#,
      16#8F#,
      16#92#,
      16#9D#,
      16#38#,
      16#F5#,
      16#BC#,
      16#B6#,
      16#DA#,
      16#21#,
      16#10#,
      16#FF#,
      16#F3#,
      16#D2#,
      16#CD#,
      16#0C#,
      16#13#,
      16#EC#,
      16#5F#,
      16#97#,
      16#44#,
      16#17#,
      16#C4#,
      16#A7#,
      16#7E#,
      16#3D#,
      16#64#,
      16#5D#,
      16#19#,
      16#73#,
      16#60#,
      16#81#,
      16#4F#,
      16#DC#,
      16#22#,
      16#2A#,
      16#90#,
      16#88#,
      16#46#,
      16#EE#,
      16#B8#,
      16#14#,
      16#DE#,
      16#5E#,
      16#0B#,
      16#DB#,
      16#E0#,
      16#32#,
      16#3A#,
      16#0A#,
      16#49#,
      16#06#,
      16#24#,
      16#5C#,
      16#C2#,
      16#D3#,
      16#AC#,
      16#62#,
      16#91#,
      16#95#,
      16#E4#,
      16#79#,
      16#E7#,
      16#C8#,
      16#37#,
      16#6D#,
      16#8D#,
      16#D5#,
      16#4E#,
      16#A9#,
      16#6C#,
      16#56#,
      16#F4#,
      16#EA#,
      16#65#,
      16#7A#,
      16#AE#,
      16#08#,
      16#BA#,
      16#78#,
      16#25#,
      16#2E#,
      16#1C#,
      16#A6#,
      16#B4#,
      16#C6#,
      16#E8#,
      16#DD#,
      16#74#,
      16#1F#,
      16#4B#,
      16#BD#,
      16#8B#,
      16#8A#,
      16#70#,
      16#3E#,
      16#B5#,
      16#66#,
      16#48#,
      16#03#,
      16#F6#,
      16#0E#,
      16#61#,
      16#35#,
      16#57#,
      16#B9#,
      16#86#,
      16#C1#,
      16#1D#,
      16#9E#,
      16#E1#,
      16#F8#,
      16#98#,
      16#11#,
      16#69#,
      16#D9#,
      16#8E#,
      16#94#,
      16#9B#,
      16#1E#,
      16#87#,
      16#E9#,
      16#CE#,
      16#55#,
      16#28#,
      16#DF#,
      16#8C#,
      16#A1#,
      16#89#,
      16#0D#,
      16#BF#,
      16#E6#,
      16#42#,
      16#68#,
      16#41#,
      16#99#,
      16#2D#,
      16#0F#,
      16#B0#,
      16#54#,
      16#BB#,
      16#16#);

   ----------------------
   -- To_Roman_Literal --
   ----------------------
   function To_Roman_Literal (Val : U64) return String is
      Result : String (1 .. 8192) :=
        (others => ' '); -- Massive buffer for "pain"
      Pos    : Natural := 0;

      -- State for da Instruction Forge
      Acc    : U64 := 0;
      Iter   : Integer := 0;
      Monads : Integer;

      -- Float_Expr State
      F_Builder : Builder;
      F_Exp     : Expr;
      F_Status  : Status_Code;

      procedure Append_To_Res (S : String) is
      begin
         if Pos + S'Length <= Result'Last then
            Result (Pos + 1 .. Pos + S'Length) := S;
            Pos := Pos + S'Length;
         end if;
      end Append_To_Res;

      function To_Hex (N : U64) return String is
         Hex_Chars : constant String := "0123456789ABCDEF";
         Buf       : String (1 .. 18) := (others => ' ');
         V         : U64 := N;
      begin
         for J in reverse 3 .. 18 loop
            Buf (J) := Hex_Chars (Natural (V mod 16) + 1);
            V := V / 16;
         end loop;
         Buf (1 .. 2) := "0x";
         return Buf;
      end To_Hex;

   begin
      if not Secure_Mode then
         return U64'Image (Val) & "ULL";
      end if;

      -- Celestial Gating: Combo guard for decad harmony
      if not NV_Decad_System_Check
        or else not NV_Astronomy_System_Alignment_Check (10)
      then
         return To_Hex (Val) & "ULL";
      end if;

      -- 1. Vary da Monads: Randomize da number o' instructions based on resonance
      Monads :=
        8
        + Integer
            (NV_Astronomy_Get_Resonance (Long_Float (Val mod 100), 100.0)
             * 8.0);

      Append_To_Res ("ALB_V(");

      for I in 1 .. Monads loop
         Iter := I;
         declare
            Op_Type : constant Integer := I mod 5;
            Weight  : U64;
            Salt    : constant U64 := U64 (Iteration_Salt (I));
         begin
            case Op_Type is
               when 1 =>
                  -- OP_LUT
                  Weight := (Val / U64 (Monads)) and 16#FF#;
                  Append_To_Res
                    (To_Hex (OP_LUT or (Weight and 16#00FF_FFFF_FFFF_FFFF#)));
                  -- Correctly update Acc using the SBOX to match the C VM res += ALB_SBOX[val]
                  Acc := Acc + U64 (ALB_SBOX (Natural (Weight)));

               when 2 =>
                  -- OP_NON
                  Reset (F_Builder);
                  Make_Const
                    (F_Builder, Real (Val / U64 (Monads)), F_Exp, F_Status);
                  Append_To_Res
                    (To_Hex
                       (OP_NON
                        or (U64 (Val / U64 (Monads))
                            and 16#00FF_FFFF_FFFF_FFFF#)));
                  Acc := Acc + (Val / U64 (Monads));

               when 3 =>
                  -- OP_XOR
                  Weight := (Val / U64 (Monads)) xor 16#55AA_55AA_55AA_55AA#;
                  -- Mask Weight to 56 bits to preserve the 0xB2 opcode
                  Append_To_Res
                    (To_Hex (OP_XOR or (Weight and 16#00FF_FFFF_FFFF_FFFF#)));
                  -- Update accumulator using the masked recovery value
                  Acc :=
                    Acc
                    + ((Weight and 16#00FF_FFFF_FFFF_FFFF#)
                       xor 16#55AA_55AA_55AA_55AA#);

               when others =>
                  -- OP_LSL
                  Append_To_Res (To_Hex (OP_LSL or 0));
                  -- DA FIX: Ensure Acc bides in sync even for identity ops
                  -- (Since val is 0, res ^= 0 in C, so Acc stays same)
                  null;
            end case;

            if I < Monads then
               Append_To_Res (", ");
            end if;
         end;
      end loop;

      -- 3. Final Correction Monad with XOR Salt
      if Acc /= Val then
         declare
            -- C VM uses: res += (val ^ salt)
            -- Therefore: payload = (Target - Acc) ^ salt
            Diff            : constant U64 := Val - Acc;
            Salt            : constant U64 :=
              U64 (Iteration_Salt (Monads + 1));
            Obfuscated_Diff : constant U64 := Diff xor Salt;
         begin
            Append_To_Res
              (", "
               & To_Hex
                   (OP_ADD or (Obfuscated_Diff and 16#00FF_FFFF_FFFF_FFFF#)));
         end;
      end if;

      Append_To_Res (")");
      return Result (1 .. Pos);
   end To_Roman_Literal;

   -- Implementations for Secure Interface
   function Secure_Val (Val : U64) return U64
   is (if Secure_Mode then Val + 1 else Val);

   function Index_Offset_Suffix return String
   is (if Secure_Mode then " - 1" else "");

   ---------------------
   -- Crypt_Active    --
   ---------------------
   function Crypt_Active return Boolean is
     (Crypt_Strings or else Secure_Blocks_Used);

   --------------------------
   -- Crypt_Literal_Active --
   --------------------------
   function Crypt_Literal_Active return Boolean is
     (Crypt_Strings or else Secure_Depth > 0);

   ---------------------
   -- Next_Crypt_Key  --
   ---------------------
   function Next_Crypt_Key return U64 is
      Z : U64;
   begin
      if not Crypt_Seeded then
         Crypt_State  := Crypt_Seed;
         Crypt_Seeded := True;
      end if;
      Crypt_State := Crypt_State + 16#9E37_79B9_7F4A_7C15#;
      Z := Crypt_State;
      Z := (Z xor (Z / 2**30)) * 16#BF58_476D_1CE4_E5B9#;
      Z := (Z xor (Z / 2**27)) * 16#94D0_49BB_1331_11EB#;
      Z := Z xor (Z / 2**31);
      return Z;
   end Next_Crypt_Key;

   procedure Set_Crypt_Seed (S : U64) is
   begin
      Crypt_Seed   := S;
      Crypt_State  := S;
      Crypt_Seeded := True;
   end Set_Crypt_Seed;

end Code_Vault;

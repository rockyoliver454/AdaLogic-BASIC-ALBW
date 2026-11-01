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
with ALB_Oracle; use ALB_Oracle;

package Tokenizer is

   -- The Hybrid Lexicon: Merging BASIC, Prolog, and Hardware-Level Data!
   -- =============================================================================
   -- TOKEN KIND ENUMERATION
   -- =============================================================================
   -- TO BE IMPLEMENTED
   --  TOK_PEEK
   --  TOK_POKE
   --  TOK_DEREF
   --  TOK_STEP
   --  TOK_EXIT
   --  TOK_CONTINUE
   --  TOK_INPUT
   --  TOK_LINE
   --  TOK_CIRCLE
   --  TOK_BLIT
   --  TOK_SPRITE
   --  TOK_PLAY
   --  TOK_SOUND
   --  TOK_CONST
   --  TOK_ENUM
   --  TOK_ANDALSO
   --  TOK_ORELSE
   --  
   type Token_Kind is
     (
      -- =========================================================================
      -- KEYWORDS : MODULE SYSTEM
      -- =========================================================================
      TOK_DECLAREMODULE,
      TOK_MODULE,
      TOK_ENDMODULE,
      TOK_IMPORT,
      TOK_IMPORT_C,
      -- Parser-recognized foreign interop placeholders.
      -- Not implemented in any backends yet.
      TOK_IMPORT_DLL,
      TOK_IMPORT_SO,
      TOK_IMPORT_DYLIB,
      TOK_IMPORT_JAR,
      TOK_IMPORT_ES,
      TOK_IMPORT_WASM,
      TOK_EXPORT_DLL,
      TOK_EXPORT_SO,
      TOK_EXPORT_DYLIB,
      TOK_EXPORT_JAR,
      TOK_EXPORT_ES,
      TOK_EXPORT_WASM,
      -- Parser-recognized memory sandbox placeholders.
      -- Not implemented in any backends yet.
      Tok_Memory_Firewall,
      Tok_End_Firewall,
      Tok_Permit_Read,
      Tok_Permit_Write,
      Tok_Deny_All,
      Tok_Bound_To,
      -- Parser-recognized process-memory placeholders.
      -- Not implemented in any backends yet.
      Tok_Process_Handle,
      Tok_End_Process,
      Tok_Process_Pid,
      Tok_Process_Image,
      Tok_Process_Rights,
      Tok_Read_Process_Memory,
      Tok_Write_Process_Memory,
      Tok_Monitor_Process_Memory,
      Tok_Inject_Code_Memory,
      Tok_Hijack_Process_Memory,
      Tok_Dump_Process_Memory,
      Tok_Changed,
      Tok_At,
      -- Parser-recognized process/system control placeholders.
      -- Not implemented in any backends yet.
      Tok_Terminate_Process,
      Tok_Create_Process,
      Tok_Elevate_Privileges,
      Tok_Hack_Memory,
      Tok_Inject_Code,
      Tok_Inject_Payload_Type, -- INJECT_PAYLOAD_TYPE / INJECTPAYLOADTYPE
      Tok_Inject_Flags,        -- INJECT_FLAGS / INJECTFLAGS
      Tok_Inject_Syscall,      -- INJECT_SYSCALL / INJECTSYSCALL
      Tok_Inject_Page,         -- INJECT_PAGE / INJECTPAGE
      Tok_Sniff_Network,
      Tok_Encrypt_File,
      Tok_Decrypt_File,
      -- Network sniffer and packet parsing
      Tok_Network_Sniffer,
      Tok_End_Sniffer,
      Tok_Interface,
      Tok_Network_Sniff,
      Tok_Parse_Ethernet,
      Tok_Parse_IP,
      Tok_Parse_TCP,
      -- Parser-recognized networking and ML placeholders.
      -- Not implemented in any backends yet.
      Tok_Network_Socket,
      Tok_End_Socket,
      Tok_Network_Listen,
      Tok_Network_Accept,
      Tok_Network_Receive,
      Tok_Network_Send,
      Tok_Network_Close,
      Tok_Protocol,
      Tok_Port,
      Tok_Size,
      Tok_Buffer_Size,
      Tok_TCP,
      Tok_UDP,
      Tok_Markov_Model,
      Tok_States,
      Tok_Transition_Matrix,
      Tok_End_Matrix,
      Tok_End_Model,
      Tok_Predict_Markov,
      Tok_Neural_Topology,
      Tok_End_Topology,
      Tok_Layer,
      Tok_Activation,
      Tok_Infer_Network,
      Tok_Train_Network,
      Tok_With,
      Tok_Expected,
      Tok_Epochs,
      -- Emotion modifiers (FASM64): fixed U8 axes 0..255, max 8, per entity.
      Tok_Emotion,
      Tok_End_Emotion,
      Tok_Axes,
      Tok_Set_Axis,
      Tok_Add_Axis,
      Tok_Get_Axis,
      Tok_Blend_Emotion,
      Tok_Decay_Emotion,
      Tok_Dominant_Emotion,
      Tok_By,
      Tok_Bitmap_Font,
      Tok_System_Font,
      Tok_Glyph_Width,
      Tok_Glyph_Height,
      Tok_First_Char,
      Tok_Spacing,
      Tok_Weight,
      Tok_Anti_Alias,
      Tok_Character_Set,
      Tok_Use_Font,
      Tok_Static_Sprite,
      Tok_Static_Surface,
      Tok_Color_Lut,
      Tok_Visual_Rule,
      Tok_Render_Viewport,
      Tok_Source,
      Tok_Descriptor,
      Tok_Format,
      Tok_Width,
      Tok_Height,
      Tok_Frames,
      Tok_Entry,
      Tok_When,
      Tok_Default,
      Tok_Use,
      Tok_Frame,
      Tok_Bounds,
      Tok_Apply_Lut,
      Tok_Blit_Safe,
      Tok_Constrain_To,
      Tok_Mode,
      Tok_Set_Shoebox,
      -- Experimental precision, traversal, and dataflow blocks.
      -- These are parser-recognized frontend features for now.
      Tok_Fallback,
      Tok_Exact,
      Tok_Secure,
      Tok_Symbolic,
      Tok_Morton_Tile,
      Tok_Block,
      Tok_Stride,
      Tok_Ratio_Space,
      Tok_Pins,
      Tok_Export_PPM,
      Tok_File,
      Tok_Fits_Cube,
      Tok_Ini_Bind,
      Tok_Stream_Bypass,
      Tok_Synth_Bake,
      Tok_Mount_Archive,
      TOK_VERSION,
      
      -- =========================================================================
      -- ERRORS
      -- =========================================================================
      TOK_ERROR,

      -- =========================================================================
      -- LITERALS
      -- =========================================================================
      TOK_NUMBER,
      TOK_HEX_LITERAL,
      TOK_BIN_LITERAL,
      TOK_STRING,
      TOK_CONST_ID,
      Tok_Tile_Size, -- $8x8 / $16x16 tile literal used by MORTON_TILE
      

      -- =========================================================================
      -- LOGIC / PROLOG
      -- =========================================================================
      TOK_ATOM,
      TOK_LOGIC_VAR,
      Tok_Findall,
      Tok_Constraint,
      Tok_Predicate,
      Tok_Rule,
      Tok_Assert,
      Tok_Retract,
      Tok_Update,
      Tok_Match,
      Tok_Change,   -- For ON KNOWS_CHANGE

      -- =========================================================================
      -- PUNCTUATION
      -- =========================================================================
      TOK_L_PAREN,
      TOK_R_PAREN,
      TOK_L_SQUARE,
      TOK_R_SQUARE,
      TOK_COMMA,
      TOK_DOT,
      TOK_DOT_DOT,
      TOK_AddressOf,
      TOK_HORN_CLAUSE,
      TOK_QUERY,
      TOK_QUESTION,
      
      -- new
      Tok_Rnd,
      Tok_Delay,
      Tok_Locate,
      
      

      -- =========================================================================
      -- OPERATORS
      -- =========================================================================
      TOK_ASSIGN,
      TOK_PLUS,
      TOK_MINUS,
      TOK_MUL,
      TOK_DIV,
      TOK_MOD,
      TOK_POW,
      TOK_LESS,
      TOK_GREATER,
      TOK_LESS_EQUAL,
      TOK_GREATER_EQUAL,
      TOK_EQUAL,
      TOK_NOT_EQUAL,
      TOK_NOT,
      TOK_AND,
      TOK_OR,
      TOK_XOR,
      TOK_ANDALSO,
      TOK_ORELSE,
      TOK_SHL,
      TOK_SHR,

      -- =========================================================================
      -- KEYWORDS : VARIABLES AND TYPES
      -- =========================================================================
      TOK_LET,
      TOK_AS,
      TOK_TYPE,
      TOK_RANGE,

      -- =========================================================================
      -- KEYWORDS : OUTPUT
      -- =========================================================================
      TOK_PRINT,
      TOK_PRINT_STR,
      TOK_INPUT,
      TOK_ENDL,
      
      -- =========================================================================
      -- KEYWORDS : STRING MANIUPULATION
      -- =========================================================================
      Tok_Len,
      Tok_Mid,
      Tok_Left,
      Tok_Right,
      -- =========================================================================
      -- KEYWORDS : ERROR HANDLERS
      -- =========================================================================
      Tok_Try,
      Tok_Catch,
      Tok_Throw,

      -- =========================================================================
      -- KEYWORDS : CONTROL FLOW
      -- =========================================================================
      TOK_IF,
      TOK_ELSE,
      TOK_ELSEIF,
      TOK_THEN,
      --TOK_GOTO,
      TOK_FOR,
      TOK_TO,
      TOK_BEGIN,
      TOK_END,
      TOK_REPEAT,
      TOK_UNTIL,
      TOK_WHILE,
      TOK_COMPTIME,
      TOK_SELECT,
      TOK_CHOOSE,
      TOK_CASE,
      TOK_ARROW,
      TOK_PIPE,
      Tok_Ampersand,     -- Task B2: single '&' as a QBASIC/VB alias for TOK_PIPE
                         -- (string concatenation).  Lowered to the same AST node.
      TOK_RETURN,
      
      Tok_TRUE,
      Tok_FALSE,
      TOK_FOREACH,
      TOK_PROVE,
      Tok_IN,
      Tok_OUT,
      Tok_Ref,
      Tok_Routine,
      Tok_Lambda,
      Tok_Private,
      Tok_Invariant,
      TOK_SAVE_STATE,
      TOK_LOAD_STATE,
      Tok_REQUIRE,
      Tok_ENSURE,

      -- =========================================================================
      -- KEYWORDS : MEMORY
      -- =========================================================================
      TOK_STRICT,
      TOK_SLIDE,
      TOK_PARALLEL,
      Tok_SwapPop,
      
      -- DA DUMPTRUCK (Manual Garbage Collection Pool)
      TOK_CLAIM,   -- TOK_CLAIM Variable
      TOK_BIND,    -- TOK_BIND Parent TO Child1, Child2
      TOK_DROP,    -- TOK_DROP Variable
      TOK_SWEEP,   -- TOK_SWEEP Chunk_Size
      
      TOK_PEEK,
      TOK_POKE,
      TOK_DEREF,
      
      Tok_Step,
      Tok_SizeOf,
      Tok_OffsetOf,
      Tok_TypeOf,
      Tok_Octal_Literal,
      Tok_String_Type,
      Tok_U0,
      Tok_I8,
      Tok_I16,
      Tok_I32,
      Tok_I64,
      Tok_Readline,
      Tok_Bitfield,
      Tok_Colon,
      Tok_Cut, -- For the Prolog '!' operator

      -- =========================================================================
      -- KEYWORDS : PROCEDURES
      -- =========================================================================
      TOK_PROCEDURE,
      TOK_FUNCTION,
      TOK_CALL,

      -- =========================================================================
      -- KEYWORDS : FILE I/O
      -- =========================================================================
      TOK_LOAD,
      TOK_INTO,
      TOK_FROM,
      TOK_FLUSH,
      Tok_Open,
      Tok_Read,
      Tok_Write,
      Tok_Close,
      Tok_Filelen,
      Tok_Fileseek,

      -- =========================================================================
      -- KEYWORDS : STRUCTURES
      -- =========================================================================
      TOK_DEFINE,
      TOK_STRUCT,

      -- =========================================================================
      -- KEYWORDS : KNOWLEDGE BASE
      -- =========================================================================
      TOK_KNOWS,
      TOK_FIND,
      TOK_IS,

      -- =========================================================================
      -- KEYWORDS : PREPROCESSOR
      -- =========================================================================
      TOK_INCLUDE,
      
      Tok_Spawn,     -- SPAWN My_Func(X, Y)
      Tok_Sync,      -- SYNC (Waits for all spawned tasks in current scope)
      Tok_Atomic,    -- ATOMIC (For thread-safe variable mutation)
      
      -- ADVANCED FEATURES, ASSEMBLY ENABLE AND INLINE
      Tok_EnableASM,
      Tok_DisableASM,
      Tok_Asm_Block,        -- Entire ASM ... END ASM block, raw text
      Tok_Inline_Asm_Block, -- Entire INLINE ASM ... END ASM expression block
      Tok_Enable_Ada_Block, -- Entire ENABLE ADA ... END ENABLE block, raw text
      Tok_Inline_Ada_Block, -- Entire INLINE ADA ... END ENABLE expression block
      Tok_Enable_Java_Block, -- Entire ENABLE JAVA ... END ENABLE block, raw text
      Tok_Inline_Java_Block, -- Entire INLINE JAVA ... END ENABLE expression block
      Tok_Enable_Typescript_Block, -- Entire ENABLE TYPESCRIPT ... END ENABLE block, raw text
      Tok_Inline_Typescript_Block, -- Entire INLINE TYPESCRIPT ... END ENABLE expression block
      Tok_Enable_C_Block, -- Entire ENABLEC / ENABLE C ... END ENABLE block, raw text
      Tok_Inline_C_Block, -- Entire INLINEC / INLINE C ... END ENABLE expression block
      Tok_Enable_CSharp_Block, -- Entire ENABLE CSHARP ... END ENABLE block, raw text
      Tok_Inline_CSharp_Block, -- Entire INLINE CSHARP ... END ENABLE expression block
      -- Parser-recognized host language raw blocks.
      -- Not implemented in any backends yet.
      Tok_Enable_Python_Block, -- Entire ENABLEPYTHON / ENABLE PYTHON ... END ENABLE block, raw text
      Tok_Inline_Python_Block, -- Entire INLINEPYTHON / INLINE PYTHON ... END ENABLE expression block
      Tok_Enable_Lua54_Block, -- Entire ENABLELUA54 / ENABLE LUA54 ... END ENABLE block, raw text
      Tok_Inline_Lua_Block, -- Entire INLINELUA / INLINE LUA ... END ENABLE expression block
      Tok_Enable_Ruby_Block, -- Entire ENABLERUBY / ENABLE RUBY ... END ENABLE block, raw text
      Tok_Inline_Ruby_Block, -- Entire INLINERUBY / INLINE RUBY ... END ENABLE expression block
      Tok_Enable_Javascript_Block, -- Entire ENABLEJAVASCRIPT / ENABLE JAVASCRIPT ... END ENABLE block, raw text
      Tok_Inline_Javascript_Block, -- Entire INLINEJAVASCRIPT / INLINE JAVASCRIPT ... END ENABLE expression block
      Tok_Enable_Rust_Block, -- Entire ENABLERUST / ENABLE_RUST / ENABLE RUST ... END ENABLE block, raw text
      Tok_Inline_Rust_Block, -- Entire INLINERUST / INLINE_RUST / INLINE RUST ... END ENABLE expression block
      Tok_Enable_Wasm_Block, -- Entire ENABLEWASM / ENABLE_WASM / ENABLE WASM ... END ENABLE block, raw text.
                           -- WAT source assembled to a wasm module by the TS backend
                           -- (embedded bytes, synchronous instantiate — no fetch).
      Tok_Inline_Wasm_Block, -- Entire INLINEWASM / INLINE_WASM / INLINE WASM ... END ENABLE block.
                           -- Reserved: rejected loud by the TS backend (no expr form yet).

      -- BRAILLE / NEMETH raw multiline data blocks (ALBW only):
      -- a lone BRAILLE or NEMETH keyword at line start opens a verbatim
      -- text block terminated by a line holding only END <WORD> (or the
      -- glued END<WORD>); a bare END line stays verbatim content.
      -- The opener keyword itself must be the only non-blank content on
      -- its line (a trailing -- comment is allowed), so `braille` and
      -- `nemeth` remain usable as ordinary identifiers everywhere else.
      Tok_Braille_Block, -- Entire BRAILLE ... END BRAILLE block, raw text
      Tok_Nemeth_Block,  -- Entire NEMETH ... END NEMETH block, raw text

      -- BIJECTIVE ENGINE / REVERSIBLE STATE FORGE
      Tok_Reversible, -- REVERSIBLE ... END REVERSIBLE

      -- MCP (Model Context Protocol) server surface
      Tok_Mcp,          -- MCP SERVER ... END MCP / MCP TOOL / MCP RESOURCE
      Tok_Mcp_Pump,     -- MCP_PUMP: drain queued agent requests
      Tok_Mcp_Listen,   -- MCP_LISTEN: blocking serve loop

      Tok_RevAdd,     -- REVADD target, value
      Tok_RevSub,     -- REVSUB target, value
      Tok_RevXor,     -- REVXOR target, value
      Tok_RevRol,     -- REVROL target, amount
      Tok_RevRor,     -- REVROR target, amount
      Tok_RevSwap,    -- REVSWAP target_a, target_b
      Tok_RevNot,     -- REVNOT target
      Tok_RevNeg,     -- REVNEG target
      
      -- TEMPORAL STATE SYSTEM
      Tok_Temporal,
      Tok_Advance,
      Tok_History,
      Tok_Past,
      Tok_Now,
      Tok_Future,
      Tok_Timeline,


      
      
      -- =========================================================================
      -- KEYWORDS : SIMD & MATRIX MATH FORGE
      -- =========================================================================
      TOK_FLOAT2,
      TOK_FLOAT4,
      TOK_MAT2,
      TOK_MAT3,
      TOK_MAT4,
      TOK_SPLAT,
      TOK_FMA,
      TOK_LERP,
      TOK_CLAMP,
      TOK_DOT_PROD,
      TOK_CROSS,
      TOK_NORMALIZE,
      TOK_BLEND,

      -- =========================================================================
      -- RENDERING SECTION
      -- =========================================================================
      TOK_CREATE_WINDOW,
      TOK_SET_FULLSCREEN,
      TOK_SET_RESIZABLE,
      TOK_SET_STRETCHY,
      TOK_TICK,
      TOK_ON,
      TOK_PAINT,
      TOK_COLOR,
      TOK_CLEAR,
      TOK_DRAW,
      TOK_FILL,
      TOK_RECT,
      TOK_LINE,
      TOK_CIRCLE,
      TOK_TRIANGLE,
      TOK_POLY,
      TOK_PLOT,
      TOK_PIXEL,
      TOK_TEXT,
      
      TOK_READ_PIXEL,
      TOK_SET_ALPHA,
      TOK_SET_CLIP,
      TOK_SET_ORIGIN,
      
      TOK_SYS_RENDERER,
      
      TOK_KEY,
      TOK_MOUSE_X,     -- NEW: X Coord
      TOK_MOUSE_Y,     -- NEW: Y Coord
      TOK_MOUSE_WHEEL, -- Vertical wheel delta this frame (SDL-style, + away)
      TOK_MOUSE_CLICK, -- NEW: Button state
      TOK_SCREEN_WIDTH,
      TOK_SCREEN_HEIGHT,
      TOK_VIRTUAL_WIDTH,
      TOK_VIRTUAL_HEIGHT,
      TOK_VMOUSE_X,
      TOK_VMOUSE_Y,
      TOK_MOUSE,
      TOK_MSG_BOX,
      TOK_CEASE,
      TOK_LISTEN,
      -- DA NEW AUDIO TOKENS
      TOK_PLAY,
      TOK_SOUND,
      TOK_MUSIC,
      Tok_Break,
      Tok_Cls,
      Tok_Continue,
      Tok_Enum,
      Tok_Cast

      -- =========================================================================
      -- END OF TOKEN KIND ENUMERATION
      -- =========================================================================
     );

   -- The Zero-Copy Token (Now equipped with Absolute Coordinates!)
   type Token is record
      Kind   : Token_Kind := Tok_Error;
      Start  : Positive   := 1; 
      Length : Natural    := 0; 
      Line   : Positive   := 1; 
      Column : Positive   := 1; 
   end record;

   Max_Tokens : constant := 1048576; -- changed frae 32768
   type Token_Array is array (1 .. Max_Tokens) of Token;

   -- =========================================================================
   -- THE ORACLE DIAGNOSTIC (Tiny memory footprint, huge analytical power)
   -- =========================================================================
   type Lexer_Diagnostic is record
      Success    : Boolean := True;
      Error_Line : Positive := 1;
      Error_Col  : Positive := 1;
      Code       : Oracle_Code := Err_None;
   end record;

   procedure Tokenize (Input       : in String;
                       Tokens      : out Token_Array;
                       Token_Count : out Natural;
                       Diagnostic  : out Lexer_Diagnostic)
     with 
       Pre  => Input'Length <= 4194304 and Input'First = 1, -- was originally <= 4096 then 65536
       Post => Token_Count <= Max_Tokens;

end Tokenizer;

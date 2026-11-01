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

package AST is
   pragma Pure;

   -- Da absolute limit o' the tree tae prevent heap allocation (Rule 3)
   Max_Nodes : constant := 1048576; -- changed frae 32768 tae 1048576

   -- 0 represents a "Null" pointer in our index-based tree.
   -- 1 .. Max_Nodes are valid memory slots.
   subtype Node_Index is Integer range 0 .. Max_Nodes;

   -- Da Hybrid Syntax Lexicon (Upgraded wi' Strong Types)
   type Node_Kind is 
     (AST_Null,
      
      -- MODULE SYSTEM CONSTRUCTS
      AST_DeclareModule,  -- Left: Var_Expr (Name), Right: Block_Stmt
      AST_Module,         -- Left: Var_Expr (Name), Right: Block_Stmt
      AST_Import,         -- Left: Var_Expr (Target Module Name)
      AST_Import_C,       -- Left: AST_Function_Decl / AST_Procedure_Decl, Right: AST_String_Expr (Header or DLL/SO)
      -- Foreign interop surface nodes.
      -- DLL/SO/DYLIB variants lower on the native FASM and native C backends,
      -- and the TS/web backend resolves them through compatibility shims.
      -- ES/WASM variants lower on the TS/web backend as module-aware imports/exports.
      AST_Import_DLL,     -- Left: Decl, Right: AST_String_Expr (DLL path/name). Native backends load this directly; TS/web resolves it through a staged compatibility shim.
      AST_Import_SO,      -- Left: Decl, Right: AST_String_Expr (SO path/name). Native backends load this directly; TS/web resolves it through a staged compatibility shim.
      AST_Import_Dylib,   -- Left: Decl, Right: AST_String_Expr (DYLIB path/name). Native backends load this directly; TS/web resolves it through a staged compatibility shim.
      AST_Import_Jar,     -- Left: Decl, Right: AST_String_Expr (JAR path/name). TS/web resolves this through the compatibility import layer.
      AST_Import_ES,      -- Left: Decl, Right: AST_String_Expr (ES module path/name). Lowers on the TS/web backend as a real ES-module import.
      AST_Import_WASM,    -- Left: Decl, Right: AST_String_Expr (WASM module path/name). Lowers on the TS/web backend as a staged WebAssembly import.
      AST_Export_DLL,     -- Left: Decl. Native backends export this directly; TS/web surfaces it through the compatibility export table.
      AST_Export_SO,      -- Left: Decl. Native backends export this directly; TS/web surfaces it through the compatibility export table.
      AST_Export_Dylib,   -- Left: Decl. Native backends export this directly; TS/web surfaces it through the compatibility export table.
      AST_Export_Jar,     -- Left: Decl. TS/web surfaces this through the compatibility export table.
      AST_Export_ES,      -- Left: Decl. Lowers on the TS/web backend as a real ES-module export.
      AST_Export_WASM,    -- Left: Decl. Lowers on the TS/web backend as a stable WASM host import/export surface.
      -- Memory sandbox surface nodes.
      -- These currently lower on the native FASM and native C backends.
      AST_Memory_Firewall_Decl, -- Left: firewall name, Right: first rule. Currently lowers on native FASM and native C backends.
      AST_Firewall_Permit_Read, -- Left: permitted source/array expr. Currently lowers on native FASM and native C backends.
      AST_Firewall_Permit_Write, -- Left: permitted destination/array expr. Currently lowers on native FASM and native C backends.
      AST_Firewall_Deny_All,    -- No children. Currently lowers on native FASM and native C backends.
      AST_Bound_To_Clause,      -- Left: firewall/sandbox name expr. Currently lowers on native FASM and native C backends.
      -- Process-memory surface nodes.
      -- These currently lower on the native FASM backend in a safe/benign scope.
      AST_Process_Handle_Decl, -- Left: handle name, Right: first handle setting. Currently lowers on native FASM for self/owned-child safe process metadata.
      AST_Process_Pid,         -- Left: pid expression. Currently lowers on native FASM as part of safe PROCESS_HANDLE declarations.
      AST_Process_Image,       -- Left: image/path expression. Currently lowers on native FASM as part of safe PROCESS_HANDLE declarations.
      AST_Process_Rights,      -- Left: first rights entry expr/token holder. Currently lowers on native FASM as part of safe PROCESS_HANDLE declarations.
      AST_Read_Process_Memory_Expr, -- Left: handle expr, Right: address expr, Right.Next: scalar type expr. Currently lowers on native FASM for self/owned-child safe scalar reads.
      AST_Read_Process_Memory_Stmt, -- Left: handle expr, Right: address expr, Right.Next: destination buffer expr. Currently lowers on native FASM for self/owned-child safe buffer/scalar reads.
      AST_Write_Process_Memory_Stmt, -- Left: handle expr, Right: address expr, Right.Next: source expr/buffer. Currently lowers on native FASM for self/owned-child safe writes.
      AST_Monitor_Process_Memory_Stmt, -- Left: handle expr, Right: address expr, then type, target, changed-flag chained via Next_Sibling. Currently lowers on native FASM for self/owned-child safe polling.
      AST_Inject_Code_Memory_Stmt, -- Left: handle expr, Right: payload expr, Right.Next: remote entry target expr. Currently simulates benign no-op behavior on native FASM and zeroes the output target.
      AST_Hijack_Process_Memory_Stmt, -- Left: handle expr, Right: target address expr, then detour and trampoline chained via Next_Sibling. Lowers on native FASM to real VirtualProtect(RWX) + JMP rel32 detour write.
      AST_Dump_Process_Memory_Stmt, -- Left: handle expr, Right: base address expr, then size and output-path chained via Next_Sibling. Currently lowers on native FASM for self/owned-child safe dumps.
      AST_Terminate_Process_Stmt, -- Left: target process/handle expr. Currently lowers on native FASM for owned-child termination only.
      AST_Create_Process_Stmt, -- Left: image/path expr, Right: optional args expr, then output target expr chained via Next_Sibling. Currently lowers on native FASM for normal child-process launch only.
      AST_Elevate_Privileges_Stmt, -- Left: target process/handle expr, Right: optional INTO result variable (AdjustTokenPrivileges BOOL). Lowers on native FASM to real SeDebugPrivilege elevation via OpenProcessToken/LookupPrivilegeValueA/AdjustTokenPrivileges.
      AST_Hack_Memory_Stmt, -- Left: handle expr, Right: address expr, Right.Next: value expr. Lowers on native FASM to real WriteProcessMemory(self) to write the value at the given address.
      AST_Inject_Code_Stmt, -- Left: handle expr, Right: payload expr, Right.Next: output entry/handle expr. Currently emits table-driven mprotect syscall on native FASM and stores result in output target.
      AST_Inject_Payload_Type, -- Token_Index: payload kind (0=mprotect,1=mmap,2=mremap,3=execve,4=clone)
                              -- Left: parent inject node, Right: payload kind expr (optional, parsed as clause)
      AST_Inject_Flags_Clause, -- Left: parent inject node, Right: flags bitmask expr
      AST_Inject_Syscall_Clause, -- Left: parent inject node, Right: syscall number expr (0=auto)
      AST_Inject_Page_Clause,  -- Left: parent inject node, Right: page size expr (0=auto)
      AST_Sniff_Network_Stmt, -- Left: source (interface name) expr, Right: destination buffer expr. Legacy node, superseded by AST_Network_Sniffer_Decl + AST_Network_Sniff_Stmt.
      AST_Encrypt_File_Stmt, -- Left: source expr, Right: key expr, Right.Next: output path expr. Currently lowers on native FASM using a benign XOR file transform.
      AST_Decrypt_File_Stmt, -- Left: source expr, Right: key expr, Right.Next: output path expr. Currently lowers on native FASM using a benign XOR file transform.
      -- Network sniffer and packet parsing surface nodes.
      AST_Network_Sniffer_Decl, -- Left: sniffer name, Right: first setting. Block-declared sniffer with INTERFACE/PROTOCOL/PORT/BUFFER_SIZE. Lowers to Winsock2 raw socket on native FASM.
      AST_Sniffer_Interface,    -- Left: interface name string expr.
      AST_Sniffer_Protocol,     -- Left: protocol name expr (TCP/UDP/ALL).
      AST_Sniffer_Port,         -- Left: port expression.
      AST_Sniffer_Buffer_Size,  -- Left: buffer size expression.
      AST_Network_Sniff_Stmt,   -- Left: sniffer name expr, Right: destination buffer expr. Performs raw socket recv into strict buffer.
      AST_Parse_Ethernet_Stmt,  -- Left: source buffer expr, Right: dest vars chain (DestMac, SrcMac, EtherType via Next_Sibling). Emits offset-based field extraction.
      AST_Parse_IP_Stmt,        -- Left: source buffer expr, Right: dest vars chain (SrcIP, DstIP, Protocol, IpLen via Next_Sibling). Emits offset-based field extraction.
      AST_Parse_TCP_Stmt,       -- Left: source buffer expr, Right: dest vars chain (SrcPort, DstPort, SeqNum, AckNum via Next_Sibling). Emits offset-based field extraction.
      -- Networking and ML surface nodes.
      -- These lower on the native FASM and native C backends, and the TS/web
      -- backend provides browser-safe networking plus real Markov/neural support.
      AST_Network_Socket_Decl, -- Left: Name, Right: first socket setting. Native backends lower this directly; TS/web lowers it to a deterministic virtual socket handle.
      AST_Network_Protocol,    -- Left: protocol name expr/token holder. Shared by native and TS/web networking lowers.
      AST_Network_Port,        -- Left: port expression. Shared by native and TS/web networking lowers.
      AST_Network_Buffer_Size, -- Left: buffer size expression. Shared by native and TS/web networking lowers.
      AST_Network_Listen_Stmt, -- Left: socket handle expr. Native backends lower this directly; TS/web lowers it to virtual-listen setup.
      AST_Network_Accept_Stmt, -- Left: socket handle expr, Right: accepted client target expr. Native backends lower this directly; TS/web lowers it to deterministic virtual accept.
      AST_Network_Receive_Stmt, -- Left: socket/client expr, Right: destination buffer expr. Native backends lower this directly; TS/web lowers it to deterministic virtual receive.
      AST_Network_Send_Stmt,   -- Left: socket/client expr, Right: source buffer expr. Native backends lower this directly; TS/web lowers it to deterministic virtual send.
      AST_Network_Close_Stmt,  -- Left: socket/client expr. Native backends lower this directly; TS/web lowers it to virtual close.
      AST_Markov_Model_Decl,   -- Left: model name, Right: first model setting. Lowers on native backends and on TS/web as a real Markov runtime model.
      AST_Markov_States,       -- Left: state count expression. Shared by native and TS/web Markov lowering.
      AST_Markov_Transition_Matrix, -- Left: first AST_Markov_Matrix_Row. Shared by native and TS/web Markov lowering.
      AST_Markov_Matrix_Row,   -- Left: first row element expression. Shared by native and TS/web Markov lowering.
      AST_Predict_Markov_Stmt, -- Left: model expr, Right: current state expr, Right.Next: output target expr. Optional Right.Next.Next: emotion name for soft bias. FASM (+ C for markov).
      AST_Neural_Topology_Decl, -- Left: topology name, Right: first layer. Lowers on native backends and on TS/web as a real neural topology/runtime object.
      AST_Neural_Layer,        -- Token_Index: layer kind token, Left: size expr, Right: activation expr optional. Shared by native and TS/web neural lowering.
      AST_Infer_Network_Stmt,  -- Left: topology expr, Right: input expr, Right.Next: output target expr. Optional next: emotion name for soft bias. FASM.
      AST_Train_Network_Stmt,  -- Left: topology expr, Right: training input expr, Right.Next: expected expr, then optional epochs expr. Lowers on native backends and on TS/web as real training.
      -- Emotion modifiers (FASM64 only; FASM16 fail-loud). Fixed axes, U8 0..255, max 8.
      AST_Emotion_Decl,        -- Left: emotion name, Right: AST_Emotion_Axes
      AST_Emotion_Axes,        -- Left: first axis name (Var_Expr), siblings = more axes
      AST_Set_Axis_Stmt,       -- Left: emotion, Right: axis, axis.Next: value expr
      AST_Add_Axis_Stmt,       -- Left: emotion, Right: axis, axis.Next: delta expr
      AST_Get_Axis_Stmt,       -- Left: emotion, Right: axis, axis.Next: output target
      AST_Blend_Emotion_Stmt,  -- Left: emotion, Right: target axis, axis.Next: amount
      AST_Decay_Emotion_Stmt,  -- Left: emotion, Right: amount expr
      AST_Dominant_Emotion_Stmt, -- Left: emotion, Right: output target (1-based axis index)
      -- Font/text asset surface nodes.
      -- These are currently frontend-only nodes that will lower later as
      -- bitmap-font atlas assets and baked system-font resources.
      AST_Bitmap_Font_Decl,    -- Left: font name, Right: first setting node.
      AST_System_Font_Decl,    -- Left: font name, Right: first setting node.
      AST_Font_Descriptor,     -- Left: descriptor path expression for bitmap fonts.
      AST_Font_Glyph_Width,    -- Left: glyph width expression for bitmap fonts.
      AST_Font_Glyph_Height,   -- Left: glyph height expression for bitmap fonts.
      AST_Font_First_Char,     -- Left: first codepoint expression for bitmap fonts.
      AST_Font_Spacing,        -- Left: inter-character spacing expression.
      AST_Font_Size,           -- Left: point/pixel size expression for system fonts.
      AST_Font_Weight,         -- Left: weight/style expression for system fonts.
      AST_Font_Anti_Alias,     -- Left: boolean anti-alias expression for system fonts.
      AST_Font_Character_Set,  -- Left: first codepoint expr, Right: last codepoint expr.
      -- Asset/render surface nodes.
      -- These lower on the native FASM and native C backends, and on TS/web
      -- through compile-time asset embedding plus a canvas/static-surface runtime.
      AST_Static_Sprite_Decl,  -- Left: sprite name, Right: first setting node. Native backends bake this directly; TS/web embeds the source bytes and resolves it at runtime.
      AST_Static_Surface_Decl, -- Left: surface name, Right: first setting node. Native backends lower this directly; TS/web lowers it to an RGB565 surface object.
      AST_Static_Source,       -- Left: source path expr. Used by native and TS/web static asset baking.
      AST_Static_Format,       -- Left: format expr/token holder. Used by native and TS/web static asset baking.
      AST_Static_Width,        -- Left: width expr. Used by native and TS/web static asset baking.
      AST_Static_Height,       -- Left: height expr. Used by native and TS/web static asset baking.
      AST_Static_Frames,       -- Left: frame-count expr. Used by native and TS/web static asset baking.
      AST_Color_Lut_Decl,      -- Left: LUT name, Right: first AST_Color_Lut_Entry. Lowers on native backends and on TS/web as a concrete LUT table.
      AST_Color_Lut_Entry,     -- Left: index expr, Right: color expr. Shared by native and TS/web COLORLUT lowering.
      AST_Visual_Rule_Decl,    -- Left: rule name var expr (Right may hold AST_Arg_List params), Right: first clause. Lowers on native backends and on TS/web as a concrete visual resolver.
      AST_Visual_When_Clause,  -- Left: condition expr, Right: visual expr, Right.Next: frame expr. Shared by native and TS/web VISUALRULE lowering.
      AST_Visual_Default_Clause, -- Left: visual expr, Right: frame expr. Shared by native and TS/web VISUALRULE lowering.
      AST_Render_Viewport_Decl, -- Left: viewport name, Right: first setting node. Lowers on native backends and on TS/web as a clipping viewport object.
      AST_Viewport_Bounds,     -- Left: X expr, Right: Y expr, Right.Next: W expr, then H expr. Shared by native and TS/web viewport lowering.
      AST_With_Clause,         -- Left: context expr. Shared by native and TS/web APPLYLUT/BLITSAFE lowering.
      AST_Mode_Clause,         -- Left: mode expr. Shared by native and TS/web BLITSAFE lowering.
      AST_Constrain_To_Clause, -- Left: viewport/clipping expr. Shared by native and TS/web BLITSAFE lowering.
      AST_Blit_Position_Clause, -- Left: X expr, Right: Y expr. Shared by native and TS/web BLITSAFE lowering.
      AST_Apply_Lut_Stmt,      -- Left: LUT expr, Right: visual expr, visual.Next: optional AST_With_Clause. Lowers on native backends and on TS/web as active LUT binding.
      AST_Blit_Safe_Stmt,      -- Left: visual expr, Right: target expr, target.Next: AST_Blit_Position_Clause, then optional helper clauses. Lowers on native backends and on TS/web as a clipped canvas/static-surface blit.
      AST_Set_Shoebox_Stmt,    -- Left: archive root/path expr. Acts as a compile-time asset root directive on native backends and on TS/web.
      
      AST_Version,        -- Left: Number_Expr (The Version)
      
      -- ADA-LOGIC BASIC Constructs
      AST_Program,      -- Root node for a BASIC script
      AST_Let_Stmt,     -- Token: Type Name (if AS used), Left: Var_Expr, Right: BinOp/Expr
      AST_Range_Type_Decl, -- Left: New type var_expr, Right: Base type var_expr; base.left: low, Low.next: high
      AST_Print_Stmt,   -- Left: Expression tae print
      AST_Print_Str_Stmt,
      AST_Input_Stmt,
      AST_If_Stmt,      -- Left: Condition, Right: Block/Stmt
      AST_Choose,
      AST_For_Stmt,     -- Token: Loop Var, Left: Start, Right: End, Sibling: Stmt
      AST_Foreach_Stmt,
      AST_Step_Stmt,
      AST_Break_Stmt,   -- DA NEW LOOP CONTROL (No children)
      AST_Cls_Stmt,     -- Console clear (no children)
      AST_Continue_Stmt,-- DA NEW LOOP CONTROL (No children)
      AST_Cast_Expr,    -- Left: Expression, Token_Index: Type Token
      AST_Block_Stmt,   -- Left: First statement in the block (chained via Sibling)
      AST_Repeat_Stmt,  -- Left: Condition (Until), Right: Block/Stmt body
      
      AST_Strict_Stmt,  -- Left: Var_Expr, Var.Right optional element type, Right: Size_Expr
      AST_Slide_Stmt,   -- Left: Var_Expr, Var.Right optional element type, Right: Max_Expr, Right's Sibling: Active_Expr
      AST_Parallel_Decl, -- Left: Var_Expr (Name, Left = bounds), Right: First AST_Parallel_Field
      AST_Parallel_Field, -- Left: Var_Expr (Field Name, Right = optional element type)
      AST_SwapPop_Stmt, -- Left: indexed parallel group access, Right: live-count scalar
      
      --AST_Strict_Stmt,  -- Left: Var_Expr, Right: Size_Expr
      --AST_Slide_Stmt,   -- Left: Var_Expr, Right: Max_Expr, Right's Sibling: Active_Expr
      -- OLD SLIDE/STRICT SYNTAX STILL VALID ^^^^^^^^^^^^^^^^^^
      
      -- DA DUMPTRUCK PARADIGM
      AST_Claim_Stmt,   -- Left: Var_Expr (The handle we ir claimin' a node for)
      AST_Bind_Stmt,    -- Left: Var_Expr (Parent), Right: AST_Arg_List (Da Bairns)
      AST_Drop_Stmt,    -- Left: Var_Expr (The node we ir droppin' a reference to)
      AST_Sweep_Stmt,   -- Left: Number_Expr (Da Chunk_Size for da Steady Shovel)
      
      AST_Poke_Stmt,
      AST_Peek_Expr,
      AST_Deref_Expr,
      AST_Select_Stmt,  -- Left: Target_Expr, Right: First AST_Case_Stmt (chained via Sibling)
      AST_Case_Stmt,    -- Left: Condition_Expr, Right: Body_Stmt
      
      AST_Procedure_Decl, -- Left: Var_Expr (Name), Right: Body (Block_Stmt)
      AST_Function_Decl,
      AST_Call_Stmt,      -- Left: Var_Expr (Name of target procedure)
      
      -- STRING MANIPULATION
      AST_Str_Len,    -- Left: String Expression
      AST_Str_Left,   -- Left: String, Right: Count
      AST_Str_Right,  -- Left: String, Right: Count
      AST_Str_Mid,    -- Left: String, Right: Range (Start, Count)
      AST_Str_Concat,  -- Left: Expr, Right: Expr
      
      -- DA NEW COMPILE-TIME ORACLES
      AST_SizeOf_Expr,   -- Left: Var_Expr or Struct Name
      AST_OffsetOf_Expr, -- Left: Struct Name, Right: Field Name
      AST_TypeOf_Expr,   -- Left: Var_Expr
      
      -- DA NEW RUNTIME GUARD
      AST_Runtime_Assert,-- Left: Condition_Expr (ASSERT(expr) must evaluate tae TRUE). Currently lowers on native FASM and native C backends.
      AST_Comptime_Block, -- LEFT: AST_Block_Stmt
      AST_Save_State,     -- NO CHILDREN
      AST_Load_State,     -- NO CHILDREN
      
      -- new
      AST_Rnd_Expr,
      AST_Delay_Stmt,
      AST_Locate_Stmt,
      
      -- ERROR HANDLERS
      AST_Try_Stmt,
      AST_Throw_Stmt,
      
      -- KNOWEDGE BASE
      AST_Knows_Fact,   -- KNOWS atom IS value (Fact)
      AST_Knows_Query,  -- KNOWS atom (Simple Query)
      AST_Find_Query,   -- FIND atom (Logic Variable Lookup)
      AST_Findall_Query,   -- FINDALL x INTO y
      AST_Constraint_Decl, -- CONSTRAINT safe(P) :- ...
      AST_Predicate_Decl,  -- PREDICATE pressure(U32)
      AST_Rule_Decl,       -- RULE low :- ...
      AST_Assert_Stmt,     -- Logic ASSERT fact
      AST_Retract_Stmt,    -- RETRACT fact
      AST_Update_Stmt,     -- UPDATE fact TO val
      AST_Match_Stmt,      -- MATCH state OF ...
      AST_Knows_Change,  -- ON KNOWS_CHANGE ...
      
      -- SCOPE AND STRUCT NODES
      AST_Return_Stmt,    -- NEW: Left: Expression tae evaluate and return in RAX
      AST_Struct_Decl,    -- NEW: Left: Var_Expr (Struct Name), Right: Block_Stmt (Fields)
      AST_Struct_Field,
      AST_Member_Expr,    -- NEW: Left: Var_Expr (Instance), Right: Var_Expr (Field)
      AST_AddressOf,
      AST_Ref_Expr,       -- Left: Var_Expr / Member_Expr / indexed Var_Expr
      AST_Lambda_Expr,    -- Left: AST_Arg_List (params chain + ret type in Right);
                          -- Right: AST_Block_Stmt (block form) or expr (=> short form)
      AST_Not,
      AST_Unary_Minus,
      
      -- ADVANCED SYNTAX NODES
      AST_While_Stmt,   -- Left: Condition, Right: Block_Stmt
      AST_Func_Call,    -- Left: Target (Var or Member), Right: AST_Arg_List
      AST_Arg_List,      -- A linked list of Expressions (chained via Sibling)
      AST_Array_Access,  -- NEW: Left: Index_Expr
      AST_Array_Assign,  -- NEW: Left: Index_Expr, Right: Value_Expr
      -- =====================================================================
      
      -- FILE I/O
      AST_Load_Stmt,    -- Left: String_Expr (Filename), Right: Var_Expr (Array Buffer)
      AST_Flush_Stmt,   -- Left: Var_Expr (Array Buffer), optional Next_Sibling on Left: byte count, Right: String_Expr (Filename)
      AST_Include_Stmt, -- DA NEW INCLUDE NODE: Left: String_Expr (Filename)
      AST_File_Open,   -- Left: File Path (String), Right: Mode (String)
      AST_File_Read,   -- Left: File Handle, Right: Bytes to Read (or 0 for line)
      AST_File_Write,  -- Left: File Handle, Right: Data to Write
      AST_File_Close,  -- Left: File Handle
      AST_File_Len,    -- Left: File Path (String); 64-bit size, 0 on miss
      AST_File_Seek,   -- Left: File Handle, Right: Absolute offset from start
      
      -- EXPRESSION CONSTRUCTS (The New Literals & Constructors)
      AST_BinOp,        -- Left: Expr, Right: Expr, Token: Operator (+, -, <)
      AST_Number_Expr,  -- Token points tae the literal F64 number
      AST_Hex_Expr,     -- NEW: Token points tae $FF
      AST_Bin_Expr,     -- NEW: Token points tae %1010
      AST_Octal_Expr,
      AST_String_Expr,  -- NEW: Token points tae "hello" or `raw`
      AST_Const_Ref,    -- NEW: Token points tae #NAME
      AST_Const_Decl,   -- NEW: Left: AST_Const_Ref, Right: AST_Number_Expr
      AST_Var_Expr,     -- Token points tae the BASIC variable name
      AST_Constructor,  -- NEW: Token: Constructor Name (e.g. PURE), Left: First Arg
      
      
      -- BOOLEANS
      AST_True,
      AST_False,

      -- STRUCTS AND ENUMS   
      AST_Enum_Decl,      -- DA NEW PROPER ENUM NODE 
      
      -- PROCEDURES & CONTRACTS
      AST_Param_Decl,     -- NEW: For wrapping (Name, IN/OUT, Type) cleanly
      AST_Require_Clause, -- NEW: Contract Pre-condition
      AST_Ensure_Clause,  -- NEW: Contract Post-condition
      
      -- DA NEW MEMORY-SAFE TEXT & DATA NODES
      AST_String_Decl,   -- Left: Size/Bound Expr
      AST_Readline_Stmt, -- Left: Target Var/String Buffer
      AST_Bitfield_Decl, -- Left: Field Name, Right: Bit Width Expr

      -- DA PROLOG LOGIC SEVER
      AST_Cut_Stmt,      -- Pure logic sever, nae children needed
      
      AST_Spawn_Stmt,
      AST_Sync_Stmt,
      AST_Atomic_Block,
      
      -- ADVANCED FEATURES, ASSEMBLY ENABLE AND INLINE
      AST_Enable_Asm,       -- ENABLEASM / ENABLEASM_*: opens a native ASM family gate
      AST_Disable_Asm,      -- DISABLEASM: closes the current native ASM family gate
      AST_Asm_Block,        -- Token_Index points tae Tok_Asm_Block raw source
      AST_Inline_Asm_Expr,  -- Token_Index points tae Tok_Inline_Asm_Block, returns in target result register(s)
      AST_Enable_Ada_Block, -- Token_Index points tae Tok_Enable_Ada_Block raw source
      AST_Inline_Ada_Expr,  -- Token_Index points tae Tok_Inline_Ada_Block raw source
      AST_Enable_Java_Block, -- Token_Index points tae Tok_Enable_Java_Block raw source
      AST_Inline_Java_Expr,  -- Token_Index points tae Tok_Inline_Java_Block raw source
      AST_Enable_Typescript_Block, -- Token_Index points tae Tok_Enable_Typescript_Block raw source
      AST_Inline_Typescript_Expr,  -- Token_Index points tae Tok_Inline_Typescript_Block raw source
      AST_Enable_C_Block,   -- Token_Index points tae Tok_Enable_C_Block raw source
      AST_Inline_C_Expr,    -- Token_Index points tae Tok_Inline_C_Block raw source
      AST_Enable_CSharp_Block, -- Token_Index points tae Tok_Enable_CSharp_Block raw source
      AST_Inline_CSharp_Expr,  -- Token_Index points tae Tok_Inline_CSharp_Block raw source
      -- Parser-only host language bridge nodes.
      -- None of these are implemented in any backends yet.
      AST_Enable_Python_Block, -- Token_Index points tae Tok_Enable_Python_Block raw source. Not implemented in any backends yet.
      AST_Inline_Python_Expr,  -- Token_Index points tae Tok_Inline_Python_Block raw source. Not implemented in any backends yet.
      AST_Enable_Lua54_Block, -- Token_Index points tae Tok_Enable_Lua54_Block raw source. Not implemented in any backends yet.
      AST_Inline_Lua_Expr,    -- Token_Index points tae Tok_Inline_Lua_Block raw source. Not implemented in any backends yet.
      AST_Enable_Ruby_Block, -- Token_Index points tae Tok_Enable_Ruby_Block raw source. Not implemented in any backends yet.
      AST_Inline_Ruby_Expr,  -- Token_Index points tae Tok_Inline_Ruby_Block raw source. Not implemented in any backends yet.
      AST_Enable_Javascript_Block, -- Token_Index points tae Tok_Enable_Javascript_Block raw source. Not implemented in any backends yet.
      AST_Inline_Javascript_Expr,  -- Token_Index points tae Tok_Inline_Javascript_Block raw source. Not implemented in any backends yet.
      AST_Enable_Rust_Block, -- Token_Index points tae Tok_Enable_Rust_Block raw source. MALBR: verbatim file-scope Rust items.
      AST_Inline_Rust_Expr,  -- Token_Index points tae Tok_Inline_Rust_Block raw source. MALBR: rejected (use ENABLE RUST).
      AST_Enable_Wasm_Block, -- Token_Index points tae Tok_Enable_Wasm_Block raw source. ALBW: WAT assembled
                             -- to an embedded wasm module (synchronous instantiate, auto-bound exports).
      AST_Inline_Wasm_Expr,  -- Token_Index points tae Tok_Inline_Wasm_Block raw source. ALBW: rejected.

      -- MCP (Model Context Protocol) server surface. ALBW-only:
      -- the emitted program speaks newline-delimited JSON-RPC 2.0 on
      -- stdio so AI agents can call in via tools / read resources.
      AST_Mcp_Server,   -- Left: name String_Expr; Left.Next_Sibling:
                        --   optional version String_Expr;
                        -- Right: entry chain (Tool/Resource nodes).
      AST_Mcp_Tool,     -- Token_Index: bound proc ident;
                        -- Left: optional AS "alias" String_Expr;
                        -- Right: optional DESCRIPTION String_Expr.
      AST_Mcp_Resource, -- Token_Index: bound func ident;
                        -- Left: uri String_Expr;
                        -- Right: optional AS "name" String_Expr.
      AST_Mcp_Pump,     -- MCP_PUMP statement: drain request queue.
      AST_Mcp_Listen,   -- MCP_LISTEN statement: blocking serve loop.
      
      -- BIJECTIVE ENGINE / REVERSIBLE STATE FORGE
      AST_Reversible_Block, -- Left: AST_Block_Stmt containing reversible-safe statements

      AST_Rev_Add_Stmt,     -- Left: Target, Right: Value Expr. Inverse: AST_Rev_Sub_Stmt
      AST_Rev_Sub_Stmt,     -- Left: Target, Right: Value Expr. Inverse: AST_Rev_Add_Stmt
      AST_Rev_Xor_Stmt,     -- Left: Target, Right: Value Expr. Self-inverse
      AST_Rev_Rol_Stmt,     -- Left: Target, Right: Rotate Expr. Inverse: AST_Rev_Ror_Stmt
      AST_Rev_Ror_Stmt,     -- Left: Target, Right: Rotate Expr. Inverse: AST_Rev_Rol_Stmt
      AST_Rev_Swap_Stmt,    -- Left: Target A, Right: Target B. Self-inverse
      AST_Rev_Not_Stmt,     -- Left: Target. Self-inverse
      AST_Rev_Neg_Stmt,     -- Left: Target. Self-inverse in two's-complement space
      
      -- TEMPORAL STATE SYSTEM
      AST_Temporal_Decl,  -- TEMPORAL LET X AS T HISTORY N = Expr
                           -- Left: Var_Expr, Right: History_Expr, Right.Next_Sibling: Init_Expr
      AST_Temporal_Ref,   -- X@past / X@now / X@future / X@timeline
                           -- Left: Base Expr, Token_Index: temporal selector token
      AST_Advance_Stmt,   -- ADVANCE [N], Left: optional tick-count expression
      AST_Temporal_Block, -- TEMPORAL ... END TEMPORAL, Left: AST_Block_Stmt

      -- Experimental precision, traversal, and dataflow surface nodes.
      -- These are frontend-only contracts for now; backend lowering comes later.
      AST_Fallback_Block, -- Left: AST_Block_Stmt containing recovery statements.
      AST_Exact_Block,    -- Left: primary AST_Block_Stmt, Right: optional AST_Fallback_Block.
      AST_Symbolic_Block, -- Left: primary AST_Block_Stmt, Right: optional AST_Fallback_Block.
      AST_Secure_Block,   -- Left: AST_Block_Stmt; contents get vault-forged literals + crypt strings.
      AST_Morton_Tile_Block, -- Left: surface expr, Right: AST_Morton_Tile_Size. Size.Next = primary body, body.Next = optional AST_Fallback_Block.
      AST_Morton_Tile_Size,  -- Token_Index: Tok_Tile_Size raw literal, or Left/Right hold width/height expressions for expanded forms.
      AST_Branchless_Predicate_Block, -- Left: condition expr, Right: primary body block, body.Next = optional AST_Fallback_Block.
      AST_Stride_Block,   -- Left: stride width expr, Right: primary body block, body.Next = optional AST_Fallback_Block.
      AST_Ratio_Space_Block, -- Left: first AST_Ratio_Pin, Right: primary body block, body.Next = optional AST_Fallback_Block.
      AST_Ratio_Pin,      -- Left: pinned register / working rational channel expression.
      AST_Export_PPM_Block, -- Left: surface expr, Right: file expr. File.Next = format expr, then body, then optional fallback.
      AST_Fits_Cube_Block, -- Left: surface-array expr, Right: file-path expr. Path.Next = body, body.Next = optional fallback.
      AST_Ini_Bind_Block, -- Left: struct/config target expr, Right: file-path expr. Path.Next = body, body.Next = optional fallback.
      AST_Stream_Bypass_Block, -- Left: buffer expr, Right: file-handle expr. Handle.Next = size expr, then body, then optional fallback.
      AST_Synth_Bake_Block, -- Left: PCM target expr, Right: format expr. Format.Next = body, body.Next = optional fallback.
      AST_Mount_Archive_Block, -- Left: virtual-address expr, Right: file-path expr. Path.Next = body, body.Next = optional fallback.


      -- PROLOG / DATALOG Constructs
      AST_Horn_Clause,  -- Left: Head Predicate, Right: Body (Linked list o' Predicates)
      AST_Query,        -- Left: Goal (Linked list o' Predicates)
      AST_Fact,         -- Left: Predicate (No body)
      AST_Predicate,    -- Left: Atom name, Right: Args (Linked list o' Logic_Vars/Atoms)
      AST_Logic_Var,    -- Token points tae the Uppercase variable
      
      -- DA NEW SIMD MATRIX FORGE
      AST_Simd_Intrinsic, -- Token: Tok_Splat, Tok_FMA, etc. Left: AST_Arg_List
      -- =====================================================================
      -- WIN32 THICK BINDINGS (BORLAND-STYLE FORGE)
      -- Later on these will be abstracted to become multi backend
      -- OpenGL + DirectX + raw win32, but that's a long story there
      -- =====================================================================
      AST_Create_Window, -- Left: Title, Right: Dummy Node (Left: Width, Right: Height)
      AST_Set_Fullscreen, -- Left: Expr (TRUE/FALSE)
      AST_Set_Resizable,  -- Left: Expr (TRUE/FALSE)
      AST_Set_Stretchy,   -- Left: Expr (TRUE/FALSE)
      AST_Tick,          -- Left: Expr (ms)
      AST_On_Block,      -- Token: Tok_Paint or Tok_Tick, Left: Block_Stmt
      AST_Color,         -- Left: Expr (Color Value)
      AST_Clear,         -- Left: Expr for Color Value
      AST_Use_Font_Stmt, -- Left: font expression to make active for subsequent TEXT/DRAW TEXT.
      AST_Draw,          -- Token: Tok_Rect etc., Left: AST_Arg_List
      AST_FILL,
      AST_Plot,          -- Token: Tok_Pixel, Left: AST_Arg_List
      
      AST_READ_PIXEL,
      AST_SET_ALPHA,
      AST_SET_CLIP,
      AST_SET_ORIGIN,
      AST_SYS_RENDERER,
      
      AST_Key_State,
      AST_Mouse_X,       -- NEW: Reads X coord
      AST_Mouse_Y,       -- NEW: Reads Y coord
      AST_Mouse_Wheel,   -- Vertical wheel delta this frame
      AST_Mouse_Click,   -- NEW: Reads Mouse Button State
      AST_VMouse_X,
      AST_VMouse_y,
      AST_SCREEN_WIDTH,
      AST_SCREEN_HEIGHT,
      AST_VIRTUAL_WIDTH,
      AST_VIRTUAL_HEIGHT,
      AST_Text,          -- Left: AST_Arg_List (x, y, text expr...). Uses the active font/render state.
      AST_Msg_Box,       -- Left: Msg_Expr, Right: Title_Expr
      AST_Listen,        -- No children
      AST_Cease,         -- No children
      AST_Play_Sound,    -- Left: String_Expr (Path)
      AST_Play_Music,    -- Left: String_Expr (Inline MML)
      AST_Play_Music_From, -- Left: String_Expr (Compile-time .mml path)
      AST_Atom,          -- Token points tae the Lowercase atom
      AST_Routine_Type_Decl  -- TYPE X IS ROUTINE(params) AS ret.
                            -- Left: Var_Expr (alias name); Right:
                            -- AST_Arg_List whose Left = param chain
                            -- (AST_Param_Decl: Left name?, Right type),
                            -- Right = return type Var_Expr (0 = void)
    , AST_Private_Decl       -- PRIVATE <member decl> — Left: the decl.
    , AST_Module_Invariant   -- INVARIANT expr — module-scope predicate;
                            -- Left: the condition expr.
    , AST_Braille_Block      -- BRAILLE ... END BRAILLE raw verbatim text
                            -- block; Token_Index → Tok_Braille_Block.
                            -- ALBW emits Ueb_Transcribe(text) — literary
                            -- UEB G2.  Statement form, no implicit print.
    , AST_Nemeth_Block       -- NEMETH ... END NEMETH raw verbatim text
                            -- block; Token_Index → Tok_Nemeth_Block.
                            -- ALBW emits Nemeth_Transcribe(text).
     );

   type AST_Node is record
      Kind         : Node_Kind  := AST_Null;
      Token_Index  : Natural    := 0; 
      Left_Child   : Node_Index := 0; 
      Right_Child  : Node_Index := 0; 
      Next_Sibling : Node_Index := 0; 
   end record;

   type Node_Array is array (1 .. Max_Nodes) of AST_Node;

end AST;

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
with Ada.Text_IO;
with Code_Vault;
with Compiler_State; use Compiler_State;

package body Parser is

   procedure Parse_Statement (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Expression (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Lambda_Expr (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   
   --  procedure Set_Error (State : in out Parser_State; Tokens : in Token_Array; Code : Oracle_Code) is
   --     Tok : Token;
   --  begin
   --     if not State.Diag.Success then return; end if;
   --     State.Diag.Success := False;
   --  
   --     if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind /= Tok_Error then
   --        Tok := Tokens(State.Current_Token);
   --        State.Diag.Error_Line := Tok.Line;
   --        State.Diag.Error_Col  := Tok.Column;
   --     else
   --        -- DA EOF FIX: Point to the LAST valid token instead o' masking it wi' Line 1!
   --        if State.Current_Token > 1 then
   --           Tok := Tokens(State.Current_Token - 1);
   --           State.Diag.Error_Line := Tok.Line;
   --           State.Diag.Error_Col  := Tok.Column;
   --        else
   --           State.Diag.Error_Line := 1;
   --           State.Diag.Error_Col  := 1;
   --        end if;
   --     end if;
   --     State.Diag.Code := Code;
   --  end Set_Error;
   
   procedure Set_Error (State : in out Parser_State; Tokens : in Token_Array; Code : Oracle_Code) is
      Tok : Token;
      Line, Col : Positive := 1;
      Real_Code : Oracle_Code := Code;
   begin
      -- A "expected a value or statement" raised while sitting on a
      -- keyword token almost always means the keyword was used as an
      -- identifier (`LET key`, `FOR step`, `FUNCTION On`) — say that
      -- instead of the generic message.  Value-producing tokens
      -- (atoms, logic vars, literals) keep the generic diagnostic.
      if Code = Err_Parse_Expected_Value
        and then State.Current_Token <= Max_Tokens
        and then Tokens (State.Current_Token).Kind not in
          Tok_Atom | Tok_Logic_Var | Tok_Number | Tok_String
          | Tok_Hex_Literal | Tok_Bin_Literal | Tok_Octal_Literal
          | Tok_L_Paren | Tok_Error
      then
         Real_Code := Err_Parse_Reserved_Keyword;
      end if;
      -- We still mark Success := False for Panics, but we dinna return early anymore!
      -- We want to keep accumulating errors in our new ledger.
      if State.Diag.Success then
         State.Diag.Success := False;
         State.Diag.Code := Real_Code;
      end if;

      if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind /= Tok_Error then
         Tok := Tokens(State.Current_Token);
         Line := Tok.Line;
         Col  := Tok.Column;
      else
         if State.Current_Token > 1 then
            Tok := Tokens(State.Current_Token - 1);
            Line := Tok.Line;
            Col  := Tok.Column;
         end if;
      end if;

      -- Maintain the legacy fast-fail fields for the first error
      if State.Diag.Code = Real_Code then
         State.Diag.Error_Line := Line;
         State.Diag.Error_Col  := Col;
      end if;

      -- Add to the fixed ledger if there is room! (Rule 3: No Heap)
      if State.Diag.Error_Count < Max_Errors then
         State.Diag.Error_Count := State.Diag.Error_Count + 1;
         State.Diag.Errors(State.Diag.Error_Count) := 
           (Line => Line, Col => Col, Code => Real_Code, Severity => Fatal);
      end if;
   end Set_Error;


   -- DA NEW GHOST TOKEN LOGGER (Non-Fatal!)
   procedure Log_Warning (State : in out Parser_State; Tokens : in Token_Array; Code : Oracle_Code) is
      Tok : Token;
      Line, Col : Positive := 1;
   begin
      -- Warnings dinna touch State.Diag.Success! The parser keeps breathing!
      if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind /= Tok_Error then
         Tok := Tokens(State.Current_Token);
         Line := Tok.Line;
         Col  := Tok.Column;
      else
         if State.Current_Token > 1 then
            Tok := Tokens(State.Current_Token - 1);
            Line := Tok.Line;
            Col  := Tok.Column;
         end if;
      end if;

      if State.Diag.Error_Count < Max_Errors then
         State.Diag.Error_Count := State.Diag.Error_Count + 1;
         State.Diag.Errors(State.Diag.Error_Count) := 
           (Line => Line, Col => Col, Code => Code, Severity => Warning);
      end if;
   end Log_Warning;
   
   
   -- DA NEW PANIC MODE ANCHOR FORGE
   procedure Synchronize_Tokens (Tokens : in Token_Array; State : in out Parser_State) is
      T : Token;
   begin
      while State.Current_Token <= Max_Tokens loop
         T := Tokens(State.Current_Token);

         -- Absolute hard boundaries
         if T.Kind in Tok_Error | Tok_EndModule then
            exit;
         end if;

         -- Safe Anchors: Keywords that always start a brand new statement
         if T.Kind in Tok_Print | Tok_Print_Str | Tok_Let | Tok_If | Tok_While |
                      Tok_For | Tok_Repeat | Tok_Procedure | Tok_Function |
                      Tok_End | Tok_Return | Tok_Match | Tok_Assert | Tok_Retract |
                      Tok_Claim | Tok_Drop | Tok_Sweep | Tok_Bind | Tok_Type |
                      Tok_Struct | Tok_Define | Tok_Const_Id | Tok_Module |
                      Tok_DeclareModule | Tok_Import | Tok_Import_C |
                      Tok_Import_DLL | Tok_Import_SO | Tok_Import_Dylib |
                      Tok_Import_JAR | Tok_Import_ES | Tok_Import_WASM |
                      Tok_Export_DLL | Tok_Export_SO | Tok_Export_Dylib |
                      Tok_Export_JAR | Tok_Export_ES | Tok_Export_WASM |
                      Tok_Memory_Firewall | Tok_Process_Handle |
                      Tok_Read_Process_Memory | Tok_Write_Process_Memory |
                      Tok_Monitor_Process_Memory | Tok_Inject_Code_Memory |
                      Tok_Hijack_Process_Memory | Tok_Dump_Process_Memory |
                      Tok_Terminate_Process | Tok_Create_Process |
                      Tok_Elevate_Privileges | Tok_Hack_Memory |
                       Tok_Inject_Code | Tok_Sniff_Network |
                       Tok_Inject_Payload_Type | Tok_Inject_Flags |
                       Tok_Inject_Syscall | Tok_Inject_Page |
                      Tok_Encrypt_File | Tok_Decrypt_File |
                       Tok_Network_Socket | Tok_Network_Listen | Tok_Network_Accept |
                       Tok_Network_Receive | Tok_Network_Send | Tok_Network_Close |
                       Tok_Network_Sniffer | Tok_End_Sniffer | Tok_Network_Sniff |
                       Tok_Parse_Ethernet | Tok_Parse_IP | Tok_Parse_TCP |
                      Tok_Fallback | Tok_Exact | Tok_Symbolic | Tok_Morton_Tile |
                      Tok_Secure |
                      Tok_Stride | Tok_Ratio_Space | Tok_Export_PPM |
                      Tok_Fits_Cube | Tok_Ini_Bind | Tok_Stream_Bypass |
                      Tok_Synth_Bake | Tok_Mount_Archive | Tok_Predicate |
                      Tok_Markov_Model | Tok_Predict_Markov |
                      Tok_Neural_Topology | Tok_Infer_Network | Tok_Train_Network |
                      Tok_Emotion | Tok_Set_Axis | Tok_Add_Axis | Tok_Get_Axis |
                      Tok_Blend_Emotion | Tok_Decay_Emotion | Tok_Dominant_Emotion |
                      Tok_Bitmap_Font | Tok_System_Font | Tok_Static_Sprite |
                      Tok_Static_Surface | Tok_Color_Lut | Tok_Visual_Rule |
                      Tok_Render_Viewport | Tok_Use_Font | Tok_Apply_Lut |
                      Tok_Blit_Safe | Tok_Set_Shoebox |
                      Tok_Version
         then
            exit;
         end if;

         State.Current_Token := State.Current_Token + 1;
      end loop;

      -- The magic trick: We clear the panic and tell the compiler to keep breathing!
      State.Diag.Success := True;
   end Synchronize_Tokens;

   procedure Recover_After_Stmt_Error
     (Tokens       : in Token_Array;
      State        : in out Parser_State;
      Failed_Token : in Natural) is
   begin
      Synchronize_Tokens (Tokens, State);

      if State.Current_Token = Failed_Token
        and then State.Current_Token <= Max_Tokens
        and then Tokens (State.Current_Token).Kind /= Tok_Error
      then
         State.Current_Token := State.Current_Token + 1;
      end if;
   end Recover_After_Stmt_Error;

   procedure Allocate_Node (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Kind : in Node_Kind; Node : out Node_Index; Success : out Boolean) is
      RS_Stat : Boolean;
      Ival : RS_Interval;
   begin
      Create(0.0, Long_Float(Max_Nodes - 1), Ival, RS_Stat);
      pragma Assert (RS_Stat and then Contains(Ival, Long_Float(State.Last_Node)));

      if State.Last_Node < Max_Nodes then
         State.Last_Node := State.Last_Node + 1;
         Node := State.Last_Node; 
         
         -- DA FIX: Unconditionally wipe the node clean the moment it is born!
         Tree(Node) := (Kind => Kind, Token_Index => 0, Left_Child => 0, Right_Child => 0, Next_Sibling => 0);
         
         Success := True;
      else 
         Ada.Text_IO.Put_Line
           ("[parser-debug] Allocate_Node overflow at Last_Node=" &
            Integer'Image (State.Last_Node) &
            " Token=" & Integer'Image (State.Current_Token));
         Set_Error(State, Tokens, Err_Parse_Block_Overflow);
         Node := 0; Success := False; 
      end if;
   end Allocate_Node;

   procedure Clone_Subtree
     (Tokens  : in Token_Array;
      State   : in out Parser_State;
      Tree    : in out Node_Array;
      Source  : in Node_Index;
      Copy    : out Node_Index;
      Success : out Boolean)
   is
      Left_Copy  : Node_Index := 0;
      Right_Copy : Node_Index := 0;
      Next_Copy  : Node_Index := 0;
   begin
      if Source = 0 then
         Copy := 0;
         Success := True;
         return;
      end if;

      Allocate_Node(Tokens, State, Tree, Tree(Source).Kind, Copy, Success);
      if not Success then return; end if;

      Tree(Copy).Token_Index := Tree(Source).Token_Index;

      if Tree(Source).Left_Child /= 0 then
         Clone_Subtree(Tokens, State, Tree, Tree(Source).Left_Child, Left_Copy, Success);
         if not Success then return; end if;
         Tree(Copy).Left_Child := Left_Copy;
      end if;

      if Tree(Source).Right_Child /= 0 then
         Clone_Subtree(Tokens, State, Tree, Tree(Source).Right_Child, Right_Copy, Success);
         if not Success then return; end if;
         Tree(Copy).Right_Child := Right_Copy;
      end if;

      if Tree(Source).Next_Sibling /= 0 then
         Clone_Subtree(Tokens, State, Tree, Tree(Source).Next_Sibling, Next_Copy, Success);
         if not Success then return; end if;
         Tree(Copy).Next_Sibling := Next_Copy;
      end if;
   end Clone_Subtree;

   -- =========================================================================
   -- FORWARD DECLARATIONS
   -- =========================================================================
   procedure Parse_Module_Block (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean; Is_Declare : Boolean);
   procedure Parse_Import (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   
   -- Parser-only foreign binding surface syntax.
   -- The AST root kinds threaded through this helper are not implemented in any backends yet.
   procedure Parse_Foreign_Binding (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Root_Kind : in Node_Kind; Requires_From : in Boolean; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Import_C (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Memory_Firewall_Decl (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Optional_Bound_To_Clause (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Network_Socket_Decl (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Network_Listen_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Network_Accept_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Network_Receive_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Network_Send_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Network_Close_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Markov_Model_Decl (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Predict_Markov_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Neural_Topology_Decl (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
    procedure Parse_Infer_Network_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
    procedure Parse_Train_Network_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Emotion_Decl (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Set_Axis_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Add_Axis_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Get_Axis_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Blend_Emotion_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Decay_Emotion_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Dominant_Emotion_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Optional_With_Emotion
     (Tokens  : in Token_Array;
      State   : in out Parser_State;
      Tree    : in out Node_Array;
      Attach  : in Node_Index;
      Success : out Boolean);
    procedure Parse_Network_Sniffer_Decl (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
    procedure Parse_Network_Sniff_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
    procedure Parse_Parse_Ethernet_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
    procedure Parse_Parse_IP_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
    procedure Parse_Parse_TCP_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Bitmap_Font_Decl (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_System_Font_Decl (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Static_Sprite_Decl (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Static_Surface_Decl (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Color_Lut_Decl (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Visual_Rule_Decl (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Render_Viewport_Decl (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Use_Font_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Apply_Lut_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Blit_Safe_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Set_Shoebox_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Runtime_Assert_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   
   procedure Parse_Comptime_Block (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   
   procedure Parse_Temporal_Block (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Temporal_Decl (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Advance_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Fallback_Block (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Exact_Block (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Secure_Block (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Symbolic_Block (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Morton_Tile_Block (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Branchless_Predicate_Block (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Stride_Block (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Ratio_Space_Block (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Export_PPM_Block (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Fits_Cube_Block (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Ini_Bind_Block (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Stream_Bypass_Block (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Synth_Bake_Block (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Mount_Archive_Block (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);

   
   procedure Parse_Return (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Struct (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_While_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Find_Query (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   
   procedure Parse_Knows_Query (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Knows_Fact (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   
   procedure Parse_Findall_Query (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Constraint_Decl (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Predicate_Decl (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Predicate (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Rule_Decl (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Match_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   
   procedure Parse_Assignment (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Or         (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_And        (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Not        (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Equality   (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Comparison (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Shift      (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Additive   (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Multiplicative (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Unary      (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Power      (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   
   procedure Parse_Input_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);
   procedure Parse_Const_Decl (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean);

   -- =========================================================================
   -- EXPERIMENTAL FEATURE REFERENCE (Frontend-only for now)
   -- =========================================================================
   --  1. FALLBACK
   --     -- FALLBACK
   --     --    PRINT "recovery path"
   --     -- END FALLBACK
   --
   --  2. EXACT
   --     -- EXACT
   --     --    LET area = width * height
   --     --    LET ratio = numerator / denominator
   --     --    FALLBACK
   --     --       PRINT "exact arithmetic rejected the operation"
   --     -- END EXACT
   --
   --  3. SYMBOLIC
   --     -- SYMBOLIC
   --     --    LET formula = (a + b) * (a - b)
   --     --    PRINT formula
   --     -- END SYMBOLIC
   --
   --  4. MORTON_TILE
   --     -- MORTON_TILE [FrameBuffer] BLOCK $8x8
   --     --    CALL ShadeTile(FrameBuffer)
   --     -- END MORTON_TILE
   --
   --  5. PREDICATE
   --     -- PREDICATE [MaskValue > 0]
   --     --    CALL BlendHotPath(PixelLane)
   --     --    FALLBACK
   --     --       CALL BlendColdPath(PixelLane)
   --     -- END PREDICATE
   --
   --  6. STRIDE
   --     -- STRIDE 64
   --     --    CALL MarchPackedPixels(Buffer64)
   --     -- END STRIDE
   --
   --  7. RATIO_SPACE
   --     -- RATIO_SPACE PINS [RAX], [RDX]
   --     --    CALL EvaluatePinnedRational()
   --     -- END RATIO_SPACE
   --
   --  8. EXPORT_PPM
   --     -- EXPORT_PPM [Canvas] TO ["sniff_log.ppm"] FORMAT P6
   --     --    PRINT "surface export requested"
   --     -- END EXPORT_PPM
   --
   --  9. FITS_CUBE
   --     -- FITS_CUBE [SpectralCube] FILE ["sample.fits"]
   --     --    CALL VerifyCube(SpectralCube)
   --     --    FALLBACK
   --     --       CALL LoadDefaultCube(SpectralCube)
   --     -- END FITS_CUBE
   --
   -- 10. INI_BIND
   --     -- INI_BIND [EngineConfig] TO ["engine.ini"]
   --     --    LET EngineConfig.Ready = TRUE
   --     -- END INI_BIND
   --
   -- 11. STREAM_BYPASS
   --     -- STREAM_BYPASS [FrameBuffer] TO [LogHandle] SIZE [ByteCount]
   --     --    PRINT "non-temporal stream scheduled"
   --     -- END STREAM_BYPASS
   --
   -- 12. SYNTH_BAKE
   --     -- SYNTH_BAKE [StartupPcm] FORMAT "T180 O4 L16 C E G > C"
   --     --    LET StartupReady = TRUE
   --     -- END SYNTH_BAKE
   --
   -- 13. MOUNT_ARCHIVE
   --     -- MOUNT_ARCHIVE [$400000] FROM ["assets.pack"]
   --     --    CALL InspectArchive($400000)
   --     -- END MOUNT_ARCHIVE

   function Starts_Match_Arm
     (Tokens : in Token_Array;
      State  : in Parser_State) return Boolean
   is
      Arm_Line : Positive;
   begin
      if State.Current_Token > Max_Tokens
        or else Tokens (State.Current_Token).Kind = Tok_Error
      then
         return False;
      end if;

      Arm_Line := Tokens (State.Current_Token).Line;

      for Scan in State.Current_Token .. Max_Tokens loop
         exit when Tokens (Scan).Kind = Tok_Error
           or else Tokens (Scan).Line /= Arm_Line;

         if Tokens (Scan).Kind = Tok_Arrow then
            return True;
         end if;
      end loop;

      return False;
   end Starts_Match_Arm;

   function Same_Line_End_Tag
     (Tokens : in Token_Array;
      State  : in Parser_State;
      Tag    : in Token_Kind) return Boolean
   is
      End_Line : Positive := 1;
   begin
      if State.Current_Token = 0
        or else State.Current_Token > Max_Tokens
        or else Tokens (State.Current_Token).Kind /= Tok_End
      then
         return False;
      end if;

      End_Line := Tokens (State.Current_Token).Line;

      return State.Current_Token < Max_Tokens
        and then Tokens (State.Current_Token + 1).Line = End_Line
        and then Tokens (State.Current_Token + 1).Kind = Tag;
   end Same_Line_End_Tag;

   function Has_Typed_End_Tag
     (Tokens : in Token_Array;
      State  : in Parser_State) return Boolean
   is
   begin
      return Same_Line_End_Tag (Tokens, State, Tok_If)
        or else Same_Line_End_Tag (Tokens, State, Tok_For)
        or else Same_Line_End_Tag (Tokens, State, Tok_While)
        or else Same_Line_End_Tag (Tokens, State, Tok_Parallel)
        or else Same_Line_End_Tag (Tokens, State, Tok_Module)
        or else Same_Line_End_Tag (Tokens, State, Tok_DeclareModule)
        or else Same_Line_End_Tag (Tokens, State, Tok_Procedure)
        or else Same_Line_End_Tag (Tokens, State, Tok_Function)
        or else Same_Line_End_Tag (Tokens, State, Tok_Match)
        or else Same_Line_End_Tag (Tokens, State, Tok_Select)
        or else Same_Line_End_Tag (Tokens, State, Tok_Struct)
        or else Same_Line_End_Tag (Tokens, State, Tok_On)
        or else Same_Line_End_Tag (Tokens, State, Tok_Reversible)
        or else Same_Line_End_Tag (Tokens, State, Tok_Temporal)
        or else Same_Line_End_Tag (Tokens, State, Tok_Comptime)
        or else Same_Line_End_Tag (Tokens, State, Tok_Enum)
        or else Same_Line_End_Tag (Tokens, State, Tok_Atomic)
        or else Same_Line_End_Tag (Tokens, State, Tok_Bitmap_Font)
        or else Same_Line_End_Tag (Tokens, State, Tok_System_Font)
        or else Same_Line_End_Tag (Tokens, State, Tok_Static_Sprite)
        or else Same_Line_End_Tag (Tokens, State, Tok_Static_Surface)
        or else Same_Line_End_Tag (Tokens, State, Tok_Color_Lut)
        or else Same_Line_End_Tag (Tokens, State, Tok_Visual_Rule)
        or else Same_Line_End_Tag (Tokens, State, Tok_Render_Viewport)
        or else Same_Line_End_Tag (Tokens, State, Tok_Fallback)
        or else Same_Line_End_Tag (Tokens, State, Tok_Exact)
        or else Same_Line_End_Tag (Tokens, State, Tok_Secure)
        or else Same_Line_End_Tag (Tokens, State, Tok_Symbolic)
        or else Same_Line_End_Tag (Tokens, State, Tok_Morton_Tile)
        or else Same_Line_End_Tag (Tokens, State, Tok_Predicate)
        or else Same_Line_End_Tag (Tokens, State, Tok_Stride)
        or else Same_Line_End_Tag (Tokens, State, Tok_Ratio_Space)
        or else Same_Line_End_Tag (Tokens, State, Tok_Export_PPM)
        or else Same_Line_End_Tag (Tokens, State, Tok_Fits_Cube)
        or else Same_Line_End_Tag (Tokens, State, Tok_Ini_Bind)
        or else Same_Line_End_Tag (Tokens, State, Tok_Stream_Bypass)
        or else Same_Line_End_Tag (Tokens, State, Tok_Synth_Bake)
        or else Same_Line_End_Tag (Tokens, State, Tok_Mount_Archive)
        or else Same_Line_End_Tag (Tokens, State, Tok_Try);
   end Has_Typed_End_Tag;

   function Is_Bare_End
     (Tokens : in Token_Array;
      State  : in Parser_State) return Boolean
   is
   begin
      return State.Current_Token > 0
        and then State.Current_Token <= Max_Tokens
        and then Tokens (State.Current_Token).Kind = Tok_End
        and then not Has_Typed_End_Tag (Tokens, State);
   end Is_Bare_End;

   function Is_Contextual_Name_Token (Kind : in Token_Kind) return Boolean is
   begin
      return Kind in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing |
        Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source |
        Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer |
        Tok_Epochs | Tok_Bounds | Tok_States | Tok_I8 | Tok_I16 |
        Tok_I32 | Tok_I64;
   end Is_Contextual_Name_Token;

   function Is_Type_Name_Token (Kind : in Token_Kind) return Boolean is
   begin
      return Kind in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing |
        Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source |
        Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer |
        Tok_Epochs | Tok_Bounds | Tok_States | Tok_String_Type | Tok_I8 |
        Tok_I16 | Tok_I32 | Tok_I64 | Tok_U0 | Tok_Float2 | Tok_Float4 |
        Tok_Mat2 | Tok_Mat3 | Tok_Mat4;
   end Is_Type_Name_Token;

   function Find_Top_Level_Comma_Before_RParen
     (Tokens      : in Token_Array;
      Start_Token : in Natural) return Natural
   is
      Depth : Natural := 0;
   begin
      if Start_Token = 0 or else Start_Token > Max_Tokens then
         return 0;
      end if;

      for Scan in Start_Token .. Max_Tokens loop
         case Tokens (Scan).Kind is
            when Tok_Error =>
               exit;
            when Tok_L_Paren =>
               Depth := Depth + 1;
            when Tok_R_Paren =>
               if Depth = 0 then
                  exit;
               end if;
               Depth := Depth - 1;
            when Tok_Comma | Tok_Shr =>
               if Depth = 0 then
                  return Scan;
               end if;
            when others =>
               null;
         end case;
      end loop;

      return 0;
   end Find_Top_Level_Comma_Before_RParen;

   function Find_Top_Level_Comma_On_Line
     (Tokens      : in Token_Array;
      Start_Token : in Natural) return Natural
   is
      Paren_Depth  : Natural := 0;
      Square_Depth : Natural := 0;
      Start_Line   : Positive := 1;
   begin
      if Start_Token = 0 or else Start_Token > Max_Tokens then
         return 0;
      end if;

      if Tokens (Start_Token).Kind = Tok_Error then
         return 0;
      end if;

      Start_Line := Tokens (Start_Token).Line;

      for Scan in Start_Token .. Max_Tokens loop
         exit when Tokens (Scan).Kind = Tok_Error
           or else Tokens (Scan).Line /= Start_Line;

         case Tokens (Scan).Kind is
            when Tok_L_Paren =>
               Paren_Depth := Paren_Depth + 1;
            when Tok_R_Paren =>
               exit when Paren_Depth = 0;
               Paren_Depth := Paren_Depth - 1;
            when Tok_L_Square =>
               Square_Depth := Square_Depth + 1;
            when Tok_R_Square =>
               if Square_Depth > 0 then
                  Square_Depth := Square_Depth - 1;
               end if;
            when Tok_Comma | Tok_Shr =>
               if Paren_Depth = 0 and then Square_Depth = 0 then
                  return Scan;
               end if;
            when others =>
               null;
         end case;
      end loop;

      return 0;
   end Find_Top_Level_Comma_On_Line;

   function Looks_Like_Outer_Statement_Call_Paren
     (Tokens      : in Token_Array;
      Start_Token : in Natural) return Boolean
   is
      Depth       : Natural := 0;
      Close_Token : Natural := 0;
      Start_Line  : Positive := 1;
   begin
      if Start_Token = 0
        or else Start_Token > Max_Tokens
        or else Tokens (Start_Token).Kind /= Tok_L_Paren
      then
         return False;
      end if;

      Start_Line := Tokens (Start_Token).Line;

      for Scan in Start_Token .. Max_Tokens loop
         exit when Tokens (Scan).Kind = Tok_Error
           or else Tokens (Scan).Line /= Start_Line;

         case Tokens (Scan).Kind is
            when Tok_L_Paren =>
               Depth := Depth + 1;
            when Tok_R_Paren =>
               if Depth = 0 then
                  return False;
               end if;

               Depth := Depth - 1;
               if Depth = 0 then
                  Close_Token := Scan;
                  exit;
               end if;
            when others =>
               null;
         end case;
      end loop;

      if Close_Token = 0 then
         return False;
      end if;

      if Close_Token = Max_Tokens
        or else Tokens (Close_Token + 1).Kind = Tok_Error
        or else Tokens (Close_Token + 1).Line /= Start_Line
      then
         return True;
      end if;

      case Tokens (Close_Token + 1).Kind is
         when Tok_Comma | Tok_Plus | Tok_Minus | Tok_Mul | Tok_Div | Tok_Mod |
              Tok_Shl | Tok_Shr | Tok_Equal | Tok_Not_Equal |
              Tok_Less | Tok_Greater | Tok_Less_Equal | Tok_Greater_Equal |
              Tok_And | Tok_Or | Tok_Xor |
              Tok_Pipe | Tok_Ampersand |  -- Task B2: '&' is a pipe alias
              Tok_Dot | Tok_L_Square =>
            return False;
         when others =>
            return True;
      end case;
   end Looks_Like_Outer_Statement_Call_Paren;

   procedure Ensure_Decl_Arg_List
     (Tokens    : in Token_Array;
      State     : in out Parser_State;
      Tree      : in out Node_Array;
      Var_Node  : in Node_Index;
      List_Node : out Node_Index;
      Success   : out Boolean)
   is
   begin
      Success := False;
      List_Node := Tree (Var_Node).Right_Child;

      if List_Node = 0 then
         Allocate_Node (Tokens, State, Tree, AST_Arg_List, List_Node, Success);
         if not Success then
            return;
         end if;
         Tree (Var_Node).Right_Child := List_Node;
      else
         Success := True;
      end if;
   end Ensure_Decl_Arg_List;

   procedure Append_Chained_Node
     (Tree       : in out Node_Array;
      First_Node : in out Node_Index;
      Last_Node  : in out Node_Index;
      New_Node   : in Node_Index)
   is
   begin
      if New_Node = 0 then
         return;
      end if;

      if First_Node = 0 then
         First_Node := New_Node;
      else
         Tree (Last_Node).Next_Sibling := New_Node;
      end if;

      Last_Node := New_Node;
   end Append_Chained_Node;

   procedure Consume_Typed_End_Tag
     (Tokens  : in Token_Array;
      State   : in out Parser_State;
      Tag     : in Token_Kind;
      Success : out Boolean)
   is
   begin
      if Same_Line_End_Tag (Tokens, State, Tag) then
         State.Current_Token := State.Current_Token + 2;
         Success := True;
      else
         Set_Error (State, Tokens, Err_Parse_Expected_Block_End);
         Success := False;
      end if;
   end Consume_Typed_End_Tag;

   procedure Parse_Statement_Arg_List
     (Tokens        : in Token_Array;
      State         : in out Parser_State;
      Tree          : in out Node_Array;
      Owner_Node    : in Node_Index;
      Max_Arg_Count : in Positive;
      Success       : out Boolean)
   is
      List_Node   : Node_Index := 0;
      Arg_Node    : Node_Index := 0;
      Last_Arg    : Node_Index := 0;
      Uses_Parens : Boolean := False;

      procedure Parse_Text_Pipe_Arg
        (Expr_Node : in out Node_Index;
         Success   : out Boolean)
      is
         Pipe_Node    : Node_Index := 0;
         Next_Segment : Node_Index := 0;
      begin
         Success := True;

         -- Task B2: accept '&' as an alias for '|' (string concat).
         while State.Current_Token <= Max_Tokens
           and then Tokens (State.Current_Token).Kind in Tok_Pipe | Tok_Ampersand
         loop
            Allocate_Node (Tokens, State, Tree, AST_BinOp, Pipe_Node, Success);
            if not Success then
               return;
            end if;
            -- Token_Index points at the actual character the user typed
            -- ('|' or '&'), so downstream diagnostics can quote it.
            Tree (Pipe_Node).Token_Index := State.Current_Token;
            Tree (Pipe_Node).Left_Child := Expr_Node;

            State.Current_Token := State.Current_Token + 1; -- Consume '|' or '&'

            Parse_Expression (Tokens, State, Tree, Next_Segment, Success);
            if not Success then
               return;
            end if;

            Tree (Pipe_Node).Right_Child := Next_Segment;
            Expr_Node := Pipe_Node;
         end loop;
      end Parse_Text_Pipe_Arg;
   begin
      Success := False;

      if State.Current_Token <= Max_Tokens
        and then Tokens (State.Current_Token).Kind = Tok_L_Paren
        and then Looks_Like_Outer_Statement_Call_Paren
          (Tokens      => Tokens,
           Start_Token => State.Current_Token)
      then
         Uses_Parens := True;
         State.Current_Token := State.Current_Token + 1;
      end if;

      Allocate_Node (Tokens, State, Tree, AST_Arg_List, List_Node, Success);
      if not Success then
         return;
      end if;
      Tree (Owner_Node).Left_Child := List_Node;

      if Uses_Parens
        and then State.Current_Token <= Max_Tokens
        and then Tokens (State.Current_Token).Kind = Tok_R_Paren
      then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;

      for I in 1 .. Max_Arg_Count loop
         Parse_Expression (Tokens, State, Tree, Arg_Node, Success);
         if not Success then
            return;
         end if;

         if Tree (Owner_Node).Kind = AST_Text
           and then I = 3
           and then State.Current_Token <= Max_Tokens
           and then Tokens (State.Current_Token).Kind in Tok_Pipe | Tok_Ampersand
         then
            Parse_Text_Pipe_Arg (Arg_Node, Success);
            if not Success then
               return;
            end if;
         end if;

         if Last_Arg = 0 then
            Tree (List_Node).Left_Child := Arg_Node;
         else
            Tree (Last_Arg).Next_Sibling := Arg_Node;
         end if;
         Last_Arg := Arg_Node;

         if State.Current_Token <= Max_Tokens
           and then Tokens (State.Current_Token).Kind = Tok_Comma
         then
            State.Current_Token := State.Current_Token + 1;
         else
            exit;
         end if;
      end loop;

      if Uses_Parens then
         if State.Current_Token <= Max_Tokens
           and then Tokens (State.Current_Token).Kind = Tok_R_Paren
         then
            State.Current_Token := State.Current_Token + 1;
         else
            Set_Error (State, Tokens, Err_Parse_Missing_Bracket);
            Success := False;
            return;
         end if;
      end if;

      Success := True;
   end Parse_Statement_Arg_List;

   procedure Parse_Case_Body
     (Tokens             : in Token_Array;
      State              : in out Parser_State;
      Tree               : in out Node_Array;
      Body_Node          : out Node_Index;
      Stop_On_Case       : in Boolean;
      Stop_On_Else       : in Boolean;
      Stop_On_Match_Arm  : in Boolean;
      Success            : out Boolean)
   is
      Next_Stmt  : Node_Index := 0;
      Curr_Stmt  : Node_Index := 0;
      Stop_Found : Boolean := False;
   begin
      Success := False;
      Body_Node := 0;

      Allocate_Node (Tokens, State, Tree, AST_Block_Stmt, Body_Node, Success);
      if not Success then
         return;
      end if;

      for I in 1 .. 16384 loop
         if State.Current_Token > Max_Tokens
           or else Tokens (State.Current_Token).Kind = Tok_Error
         then
            exit;
         end if;

         if Is_Bare_End (Tokens, State)
           or else Same_Line_End_Tag (Tokens, State, Tok_Match)
           or else Same_Line_End_Tag (Tokens, State, Tok_Select)
         then
            Stop_Found := True;
            exit;
         end if;

         if Stop_On_Case
           and then Tokens (State.Current_Token).Kind = Tok_Case
         then
            Stop_Found := True;
            exit;
         end if;

         if Stop_On_Else
           and then Tokens (State.Current_Token).Kind = Tok_Else
         then
            Stop_Found := True;
            exit;
         end if;

         if Stop_On_Match_Arm
           and then Starts_Match_Arm (Tokens, State)
         then
            Stop_Found := True;
            exit;
         end if;

         Parse_Statement (Tokens, State, Tree, Next_Stmt, Success);
         if not Success then
            return;
         end if;

         if Next_Stmt = 0 then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         elsif Tree (Body_Node).Left_Child = 0 then
            Tree (Body_Node).Left_Child := Next_Stmt;
         else
            Tree (Curr_Stmt).Next_Sibling := Next_Stmt;
         end if;

         Curr_Stmt := Next_Stmt;
      end loop;

      if State.Current_Token > Max_Tokens
        or else Tokens (State.Current_Token).Kind = Tok_Error
      then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
      elsif Tree (Body_Node).Left_Child = 0 then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
      elsif not Stop_Found then
         Set_Error (State, Tokens, Err_Parse_Block_Overflow);
         Success := False;
      else
         Success := True;
      end if;
   end Parse_Case_Body;

   procedure Parse_Primary (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      T : Token;
   begin
      Success := False; Node := 0;
      if State.Current_Token > Max_Tokens then return; end if;
      T := Tokens(State.Current_Token);
      
      if Tokens(State.Current_Token).Kind = Tok_AddressOf then
         State.Current_Token := State.Current_Token + 1;
         Allocate_Node(Tokens, State, Tree, AST_AddressOf, Node, Success);
         if not Success then return; end if;
         Tree(Node).Token_Index := State.Current_Token - 1;
         declare Target_Node : Node_Index; begin
            Parse_Primary(Tokens, State, Tree, Target_Node, Success);
            if Success then Tree(Node).Left_Child := Target_Node; end if;
         end;
         return;
      end if;
      
      if Tokens(State.Current_Token).Kind = Tok_Ref then
         State.Current_Token := State.Current_Token + 1;
         Allocate_Node(Tokens, State, Tree, AST_Ref_Expr, Node, Success);
         if not Success then return; end if;
         Tree(Node).Token_Index := State.Current_Token - 1;

         declare
            Target_Node : Node_Index := 0;
         begin
            Parse_Primary(Tokens, State, Tree, Target_Node, Success);
            if not Success then return; end if;

            if Tree(Target_Node).Kind not in AST_Var_Expr | AST_Member_Expr then
               Set_Error(State, Tokens, Err_Parse_Expected_Value);
               Success := False;
               return;
            end if;

            Tree(Node).Left_Child := Target_Node;
         end;
         return;
      end if;

      
      -- DA NEW UNARY NOT FORGE!
      if Tokens(State.Current_Token).Kind = Tok_Not then
         State.Current_Token := State.Current_Token + 1;
         Allocate_Node(Tokens, State, Tree, AST_Not, Node, Success);
         if not Success then return; end if;
         Tree(Node).Token_Index := State.Current_Token - 1;
         declare Target_Node : Node_Index; begin
            Parse_Primary(Tokens, State, Tree, Target_Node, Success);
            if Success then Tree(Node).Left_Child := Target_Node; end if;
         end;
         return;
      end if;
      
      -- DA NEW UNARY MINUS FORGE!
      if Tokens(State.Current_Token).Kind = Tok_Minus then
         State.Current_Token := State.Current_Token + 1;
         Allocate_Node(Tokens, State, Tree, AST_Unary_Minus, Node, Success);
         if not Success then return; end if;
         Tree(Node).Token_Index := State.Current_Token - 1;
         declare Target_Node : Node_Index; begin
            -- We call Parse_Primary sae it can grab the immediate value/variable
            Parse_Primary(Tokens, State, Tree, Target_Node, Success);
            if Success then Tree(Node).Left_Child := Target_Node; end if;
         end;
         return;
      end if;

      -- =====================================================================
      -- DA LOGIC SUGAR: PROVE() and ?- Queries! (Expression Level)
      -- =====================================================================
      if T.Kind in Tok_Query | Tok_Prove then
         State.Current_Token := State.Current_Token + 1; -- Consume '?-' or 'PROVE'
         
         declare
            Has_Outer_Paren : Boolean := False;
            Expr_Node       : Node_Index := 0;
         begin
            -- Handle optional outer parens for PROVE(Predicate)
            if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_L_Paren then
               Has_Outer_Paren := True;
               State.Current_Token := State.Current_Token + 1;
            end if;
            
            Allocate_Node(Tokens, State, Tree, AST_Find_Query, Node, Success);
            if not Success then return; end if;
            
            -- 1. Grab the Predicate Name
            if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States then
               Tree(Node).Token_Index := State.Current_Token;
               State.Current_Token := State.Current_Token + 1;
            else
               Set_Error(State, Tokens, Err_Parse_Expected_Value);
               Success := False; return;
            end if;
            
            -- 2. Optional: Check for Argument (e.g., is_valid(1))
            if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_L_Paren then
               State.Current_Token := State.Current_Token + 1;
               Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
               if not Success then return; end if;
               Tree(Node).Left_Child := Expr_Node;
               
               if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_R_Paren then
                  State.Current_Token := State.Current_Token + 1;
               else
                  Set_Error(State, Tokens, Err_Parse_Expected_Value);
                  Success := False; return;
               end if;
            end if;
            
            -- Close outer paren if we had one!
            if Has_Outer_Paren then
               if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_R_Paren then
                  State.Current_Token := State.Current_Token + 1;
               else
                  Set_Error(State, Tokens, Err_Parse_Expected_Value);
                  Success := False; return;
               end if;
            end if;
         end;
         Success := True;
         return; -- Fast exit frae Parse_Primary!
      end if;
      
      
      -- DA NEW PROLOG CUT FORGE (!)
      if Tokens(State.Current_Token).Kind = Tok_Cut then
         Allocate_Node(Tokens, State, Tree, AST_Cut_Stmt, Node, Success);
         if not Success then return; end if;
         Tree(Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1; -- Consume '!'
         return;
      end if;
      

      -- =====================================================================
      -- DA LITERAL FORGE: Numbers, Hex, Strings, Binaries, and Booleans!
      -- =====================================================================
      -- DA FIX: Add Tok_Inline_Asm_Block tae the guard gate!
      if T.Kind in Tok_Number | Tok_Hex_Literal | Tok_Bin_Literal | 
                   Tok_String | Tok_Const_Id | Tok_True | Tok_False |
                   Tok_Inline_Asm_Block | Tok_Inline_Ada_Block |
                   Tok_Inline_Java_Block | Tok_Inline_Typescript_Block |
                   Tok_Inline_C_Block | Tok_Inline_CSharp_Block |
                   Tok_Inline_Python_Block |
                   Tok_Inline_Lua_Block | Tok_Inline_Ruby_Block |
                   Tok_Inline_Javascript_Block | Tok_Inline_Rust_Block then
         declare
            NKind : Node_Kind;
         begin
            case T.Kind is
               when Tok_Number      => NKind := AST_Number_Expr;
               when Tok_Hex_Literal => NKind := AST_Hex_Expr;
               when Tok_Bin_Literal => NKind := AST_Bin_Expr;
               when Tok_String      => NKind := AST_String_Expr;
               when Tok_Const_Id    => NKind := AST_Const_Ref;
               when Tok_True        => NKind := AST_True;   -- DA NEW TRUE
               when Tok_False       => NKind := AST_False;  -- DA NEW FALSE
               when Tok_Inline_Asm_Block => NKind := AST_Inline_Asm_Expr; -- DA NEW INLINE ASM
               when Tok_Inline_Ada_Block => NKind := AST_Inline_Ada_Expr; -- DA NEW INLINE ADA
               when Tok_Inline_Java_Block => NKind := AST_Inline_Java_Expr; -- DA NEW INLINE JAVA
               when Tok_Inline_Typescript_Block => NKind := AST_Inline_Typescript_Expr;
               when Tok_Inline_C_Block => NKind := AST_Inline_C_Expr;
               when Tok_Inline_CSharp_Block => NKind := AST_Inline_CSharp_Expr;
               when Tok_Inline_Python_Block => NKind := AST_Inline_Python_Expr;
               when Tok_Inline_Lua_Block => NKind := AST_Inline_Lua_Expr;
               when Tok_Inline_Ruby_Block => NKind := AST_Inline_Ruby_Expr;
               when Tok_Inline_Javascript_Block => NKind := AST_Inline_Javascript_Expr;
               when Tok_Inline_Rust_Block => NKind := AST_Inline_Rust_Expr;
               when others          => NKind := AST_Null;
            end case;
            
            Allocate_Node(Tokens, State, Tree, NKind, Node, Success);
            if Success then
               Tree(Node).Token_Index := State.Current_Token;
               State.Current_Token := State.Current_Token + 1; 
            end if;
         end;
         
         
      elsif T.Kind = Tok_Octal_Literal then
         Allocate_Node(Tokens, State, Tree, AST_Octal_Expr, Node, Success);
         if not Success then return; end if;
         Tree(Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1;

      -- =====================================================================
      -- DA LOGIC VARS AND ATOMS
      -- =====================================================================
      elsif Is_Contextual_Name_Token (T.Kind) then
         
         -- 1. Grab the Base Variable
         Allocate_Node(Tokens, State, Tree, AST_Var_Expr, Node, Success);
         if not Success then return; end if;
         Tree(Node).Token_Index := State.Current_Token; 
         State.Current_Token := State.Current_Token + 1;

         -- 2. Array Indexer (DA MULTIDIMENSIONAL EXPRESSION FORGE)
         if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_L_Square then
            State.Current_Token := State.Current_Token + 1;
            declare 
               Bound_List : Node_Index := 0;
               Last_Bound : Node_Index := 0;
               Current_Bound : Node_Index;
            begin
               -- Loop for Multidimensional Bounds! (e.g., [2, 3])
               loop
                  Parse_Expression(Tokens, State, Tree, Current_Bound, Success);
                  if not Success then return; end if;
                  
                  if Bound_List = 0 then
                     Bound_List := Current_Bound;
                  else
                     Tree(Last_Bound).Next_Sibling := Current_Bound;
                  end if;
                  Last_Bound := Current_Bound;
                  
                  exit when State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_Comma;
                  State.Current_Token := State.Current_Token + 1; -- Consume ','
               end loop;
               
               if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_R_Square then
                  State.Current_Token := State.Current_Token + 1;
               else 
                  Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
                  Success := False; 
                  return; 
               end if;
               
               Tree(Node).Left_Child := Bound_List;
            end;
         end if;
         
         -- 3. Dot-Notation
         while Success and then State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Dot loop
            declare 
               Member_Node, Field_Node : Node_Index;
               RS_Stat : Boolean;
               Token_Ival, Node_Ival : RS_Interval;
            begin
               Create(1.0, Long_Float(Max_Tokens), Token_Ival, RS_Stat);
               pragma Assert (RS_Stat and then Contains(Token_Ival, Long_Float(State.Current_Token)));

               State.Current_Token := State.Current_Token + 1; -- Consume '.'
               
               if State.Current_Token > Max_Tokens
                 or else not Is_Contextual_Name_Token
                   (Tokens(State.Current_Token).Kind)
               then
                  Set_Error(State, Tokens, Err_Parse_Expected_Value);
                  Success := False; return;
               end if;

               Allocate_Node(Tokens, State, Tree, AST_Var_Expr, Field_Node, Success);
               if not Success then return; end if;
               Create(1.0, Long_Float(Max_Nodes), Node_Ival, RS_Stat);
               pragma Assert (RS_Stat and then Contains(Node_Ival, Long_Float(Field_Node)));

               Tree(Field_Node).Token_Index := State.Current_Token; 
               State.Current_Token := State.Current_Token + 1;
               
               if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_L_Square then
                  State.Current_Token := State.Current_Token + 1;
                  declare 
                     Bound_List : Node_Index := 0;
                     Last_Bound : Node_Index := 0;
                     Current_Bound : Node_Index;
                  begin
                     loop
                        Parse_Expression(Tokens, State, Tree, Current_Bound, Success);
                        if not Success then return; end if;
                        
                        if Bound_List = 0 then
                           Bound_List := Current_Bound;
                        else
                           Tree(Last_Bound).Next_Sibling := Current_Bound;
                        end if;
                        Last_Bound := Current_Bound;
                        
                        exit when State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_Comma;
                        State.Current_Token := State.Current_Token + 1; -- Consume ','
                     end loop;
                     
                     if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_R_Square then
                        State.Current_Token := State.Current_Token + 1;
                     else 
                        Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
                        Success := False; 
                        return; 
                     end if;
                     
                     Tree(Field_Node).Left_Child := Bound_List;
                  end;
               end if;
               
               Allocate_Node(Tokens, State, Tree, AST_Null, Member_Node, Success);
               if not Success then return; end if;
               
               Tree(Member_Node) := Tree(Node);
               Tree(Node).Kind := AST_Member_Expr;
               Tree(Node).Left_Child := Member_Node;
               Tree(Node).Right_Child := Field_Node;
            end;
         end loop;

         -- 4. DA NEW FUNCTION CALL / CONSTRUCTOR MORPH
         if Success and then State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_L_Paren then
            State.Current_Token := State.Current_Token + 1; -- Consume '('
            
            declare 
               Func_Node, List_Node, Arg_Node, Last_Arg : Node_Index := 0; 
            begin
               -- DA FIX: Always build a standard AST_Func_Call sae albt.adb's emitter can extract the function name correctly!
               Allocate_Node(Tokens, State, Tree, AST_Func_Call, Func_Node, Success);
               if not Success then return; end if;
               Tree(Func_Node).Token_Index := Tree(Node).Token_Index;
               Tree(Func_Node).Left_Child := Node; -- Original target (the function name) is safely stored in Left_Child
               
               Allocate_Node(Tokens, State, Tree, AST_Arg_List, List_Node, Success);
               if not Success then return; end if;
               
               -- Func Calls attach the Arg_List node as Right_Child
               Tree(Func_Node).Right_Child := List_Node;
               
               if Tokens(State.Current_Token).Kind /= Tok_R_Paren then
                  for I in 1 .. 64 loop 
                     Parse_Expression(Tokens, State, Tree, Arg_Node, Success);
                     if not Success then return; end if;
                     
                     if Last_Arg = 0 then 
                        Tree(List_Node).Left_Child := Arg_Node;
                     else 
                        Tree(Last_Arg).Next_Sibling := Arg_Node;
                     end if;
                     Last_Arg := Arg_Node;
                     
                     if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Comma then 
                        State.Current_Token := State.Current_Token + 1;
                     elsif State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_R_Paren then 
                        exit;
                     else 
                        Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
                        Success := False; return; 
                     end if;
                  end loop;
               end if;
               if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_R_Paren then
                  State.Current_Token := State.Current_Token + 1;
                  Node := Func_Node; -- Morph complete!
               else 
                  Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
                  Success := False; return; 
               end if;
            end;
         end if;
         
      -- =====================================================================
      -- DA TYPE CASTING FORGE ( CAST(Expr AS Type) )
      -- =====================================================================
      elsif Tokens(State.Current_Token).Kind = Tok_Cast then
         Allocate_Node(Tokens, State, Tree, AST_Cast_Expr, Node, Success);
         if not Success then return; end if;
         State.Current_Token := State.Current_Token + 1; -- Consume CAST
         
         if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_L_Paren then
            Set_Error(State, Tokens, Err_Parse_Expected_Value); Success := False; return;
         end if;
         State.Current_Token := State.Current_Token + 1; -- Consume '('
         
         declare Expr_Node : Node_Index; begin
            Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
            if not Success then return; end if;
            Tree(Node).Left_Child := Expr_Node;
         end;
         
         if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_As then
            Set_Error(State, Tokens, Err_Parse_Expected_Value); Success := False; return;
         end if;
         State.Current_Token := State.Current_Token + 1; -- Consume AS
         
         -- DA FIX: Let Tok_String_Type pass the gate as a valid casting type!
         if State.Current_Token > Max_Tokens or else not Is_Type_Name_Token (Tokens(State.Current_Token).Kind) then
            Set_Error(State, Tokens, Err_Parse_Expected_Value); Success := False; return;
         end if;
         Tree(Node).Token_Index := State.Current_Token; -- Store Type token index
         State.Current_Token := State.Current_Token + 1; -- Consume Type
         
         if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_R_Paren then
            Set_Error(State, Tokens, Err_Parse_Missing_Bracket); Success := False; return;
         end if;
         State.Current_Token := State.Current_Token + 1; -- Consume ')'
         return;
         
      elsif Tokens(State.Current_Token).Kind = Tok_Rnd then
         Allocate_Node(Tokens, State, Tree, AST_Rnd_Expr, Node, Success);
         if not Success then return; end if;
         Tree(Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1; -- Consume RND
         
         if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_L_Paren then
            Set_Error(State, Tokens, Err_Parse_Expected_Value); Success := False; return;
         end if;
         State.Current_Token := State.Current_Token + 1;
         
         declare Expr_Node : Node_Index; begin
            Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
            if not Success then return; end if;
            Tree(Node).Left_Child := Expr_Node;
         end;
         
         if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_R_Paren then
            Set_Error(State, Tokens, Err_Parse_Missing_Bracket); Success := False; return;
         end if;
         State.Current_Token := State.Current_Token + 1;
         
      -- =========================================================================
      -- DA SIMD & MATRIX INTRINSICS FORGE
      -- =========================================================================
      elsif Tokens(State.Current_Token).Kind in Tok_Splat |
         Tok_FMA | Tok_Lerp | 
         Tok_Clamp | Tok_Dot_Prod | Tok_Cross | 
         Tok_Normalize |
         Tok_Blend 
      then
         declare
            Intrinsic_Tok : constant Natural := State.Current_Token;
            List_Node, Arg_Node, Last_Arg : Node_Index := 0;
         begin
            State.Current_Token := State.Current_Token + 1; -- Consume da keyword
            
            -- Guard: Expect '(' -- a bare intrinsic keyword in expression
            -- position means it was used as an identifier; say so.
            if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_L_Paren then
               Set_Error(State, Tokens, Err_Parse_Reserved_Keyword);
               Success := False; return;
            end if;
            State.Current_Token := State.Current_Token + 1; -- Consume '('
            
            -- Mint da master SIMD Node
            Allocate_Node(Tokens, State, Tree, AST_Simd_Intrinsic, Node, Success);
            if not Success then return; end if;
            Tree(Node).Token_Index := Intrinsic_Tok;
            
            -- Mint da Argument List Container
            Allocate_Node(Tokens, State, Tree, AST_Arg_List, List_Node, Success);
            if not Success then return; end if;
            Tree(Node).Left_Child := List_Node;
            
            -- Fixed-bound loop for arguments (SIMD ops winna hae mair than 8 args!)
            for I in 1 .. 8 loop
               Parse_Expression(Tokens, State, Tree, Arg_Node, Success);
               if not Success then return; end if;
               
               -- Stitch da sibling chain
               if Last_Arg = 0 then 
                  Tree(List_Node).Left_Child := Arg_Node;
               else 
                  Tree(Last_Arg).Next_Sibling := Arg_Node;
               end if;
               Last_Arg := Arg_Node;
               
               -- Check for continuing comma
               if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Comma then
                  State.Current_Token := State.Current_Token + 1;
               else
                  exit; -- Nae comma means end o' arguments
               end if;
            end loop;
            
            -- Guard: Expect ')'
            if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_R_Paren then
               Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
               Success := False; return;
            end if;
            State.Current_Token := State.Current_Token + 1; -- Consume ')'
         end;

      -- =========================================================================
      -- DA STRING INTRINSICS FORGE
      -- =========================================================================
      elsif Tokens(State.Current_Token).Kind in Tok_Len | Tok_Left | Tok_Right | Tok_Mid then
         declare
            Op_Token : constant Token_Kind := Tokens(State.Current_Token).Kind;
            Expr_1, Expr_2, Expr_3, Arg_List : Node_Index := 0;
         begin
            State.Current_Token := State.Current_Token + 1; -- Consume the Function Name
            
            if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_L_Paren then
               Set_Error(State, Tokens, Err_Parse_Reserved_Keyword); Success := False; return;
            end if;
            State.Current_Token := State.Current_Token + 1; -- Consume '('
            
            -- Arg 1: Always the string expression
            Parse_Expression(Tokens, State, Tree, Expr_1, Success);
            if not Success then return; end if;

            if Op_Token = Tok_Len then
               Allocate_Node(Tokens, State, Tree, AST_Str_Len, Node, Success);
               if not Success then return; end if;
               Tree(Node).Left_Child := Expr_1;
               
            elsif Op_Token in Tok_Left | Tok_Right then
               if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_Comma then
                  Set_Error(State, Tokens, Err_Parse_Expected_Value); Success := False; return;
               end if;
               State.Current_Token := State.Current_Token + 1; -- Consume ','
               
               -- Arg 2: Count
               Parse_Expression(Tokens, State, Tree, Expr_2, Success);
               if not Success then return; end if;
               
               if Op_Token = Tok_Left then Allocate_Node(Tokens, State, Tree, AST_Str_Left, Node, Success);
               else Allocate_Node(Tokens, State, Tree, AST_Str_Right, Node, Success); end if;
               if not Success then return; end if;
               
               Tree(Node).Left_Child := Expr_1;
               Tree(Node).Right_Child := Expr_2;
               
            elsif Op_Token = Tok_Mid then
               if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_Comma then
                  Set_Error(State, Tokens, Err_Parse_Expected_Value); Success := False; return;
               end if;
               State.Current_Token := State.Current_Token + 1; -- Consume ','
               
               -- Arg 2: Start
               Parse_Expression(Tokens, State, Tree, Expr_2, Success);
               if not Success then return; end if;
               
               if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_Comma then
                  Set_Error(State, Tokens, Err_Parse_Expected_Value); Success := False; return;
               end if;
               State.Current_Token := State.Current_Token + 1; -- Consume ','
               
               -- Arg 3: Length
               Parse_Expression(Tokens, State, Tree, Expr_3, Success);
               if not Success then return; end if;
               
               Allocate_Node(Tokens, State, Tree, AST_Str_Mid, Node, Success);
               if not Success then return; end if;
               
               Allocate_Node(Tokens, State, Tree, AST_Arg_List, Arg_List, Success);
               if not Success then return; end if;
               
               Tree(Arg_List).Left_Child := Expr_2;
               Tree(Expr_2).Next_Sibling := Expr_3;
               
               Tree(Node).Left_Child := Expr_1;
               Tree(Node).Right_Child := Arg_List;
            end if;

            if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_R_Paren then
               Set_Error(State, Tokens, Err_Parse_Missing_Bracket); Success := False; return;
            end if;
            State.Current_Token := State.Current_Token + 1; -- Consume ')'
         end;

         -- 3. Dot-Notation
         while Success and then State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Dot loop
            declare 
               Member_Node, Field_Node : Node_Index;
               RS_Stat : Boolean;
               Token_Ival, Node_Ival : RS_Interval;
            begin
               Create(1.0, Long_Float(Max_Tokens), Token_Ival, RS_Stat);
               pragma Assert (RS_Stat and then Contains(Token_Ival, Long_Float(State.Current_Token)));

               State.Current_Token := State.Current_Token + 1; -- Consume '.'
               
               -- DA FIX 1: The "Naked Dot" Armor! Verify it's an actual name!
               if State.Current_Token > Max_Tokens or else 
                 (Tokens(State.Current_Token).Kind /= Tok_Atom and Tokens(State.Current_Token).Kind /= Tok_Logic_Var) 
               then
                  Set_Error(State, Tokens, Err_Parse_Expected_Value); Success := False; return;
               end if;

               Allocate_Node(Tokens, State, Tree, AST_Var_Expr, Field_Node, Success);
               if not Success then return; end if;
               
               Create(1.0, Long_Float(Max_Nodes), Node_Ival, RS_Stat);
               pragma Assert (RS_Stat and then Contains(Node_Ival, Long_Float(Field_Node)));

               Tree(Field_Node).Token_Index := State.Current_Token; 
               State.Current_Token := State.Current_Token + 1;
               
               if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_L_Square then
                  State.Current_Token := State.Current_Token + 1;
                  declare 
                     Bound_List : Node_Index := 0;
                     Last_Bound : Node_Index := 0;
                     Current_Bound : Node_Index;
                  begin
                     loop
                        Parse_Expression(Tokens, State, Tree, Current_Bound, Success);
                        if not Success then return; end if;
                        
                        if Bound_List = 0 then
                           Bound_List := Current_Bound;
                        else
                           Tree(Last_Bound).Next_Sibling := Current_Bound;
                        end if;
                        Last_Bound := Current_Bound;
                        
                        exit when State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_Comma;
                        State.Current_Token := State.Current_Token + 1; -- Consume ','
                     end loop;
                     
                     if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_R_Square then
                        State.Current_Token := State.Current_Token + 1;
                     else 
                        Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
                        Success := False; 
                        return; 
                     end if;
                     
                     Tree(Field_Node).Left_Child := Bound_List;
                  end;
               end if;
               
               Allocate_Node(Tokens, State, Tree, AST_Null, Member_Node, Success);
               if not Success then return; end if;
               
               -- Preserve da types by copyin' da full node safely
               Tree(Member_Node) := Tree(Node); 
               Tree(Node).Kind := AST_Member_Expr;
               Tree(Node).Left_Child := Member_Node;
               Tree(Node).Right_Child := Field_Node;
            end;
         end loop;

         -- 4. DA NEW FUNCTION CALL / CONSTRUCTOR MORPH
         if Success and then State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_L_Paren then
            State.Current_Token := State.Current_Token + 1; -- Consume '('
            
            declare 
               Func_Node, List_Node, Arg_Node, Last_Arg : Node_Index := 0; 
            begin
               -- Decide on the Node Type and where to attach arguments
               if Tree(Node).Kind = AST_Var_Expr and then Tree(Node).Left_Child = 0 and then Tree(Node).Right_Child = 0 then
                  Allocate_Node(Tokens, State, Tree, AST_Constructor, Func_Node, Success);
                  if not Success then return; end if;
                  Tree(Func_Node).Token_Index := Tree(Node).Token_Index;
                  
                  -- Constructors attach arguments directly as Left_Child
                  List_Node := Func_Node; 
               else
                  Allocate_Node(Tokens, State, Tree, AST_Func_Call, Func_Node, Success);
                  if not Success then return; end if;
                  Tree(Func_Node).Token_Index := Tree(Node).Token_Index;
                  Tree(Func_Node).Left_Child := Node; -- Original target is Left_Child
                  
                  Allocate_Node(Tokens, State, Tree, AST_Arg_List, List_Node, Success);
                  if not Success then return; end if;
                  
                  -- Func Calls attach the Arg_List node as Right_Child
                  Tree(Func_Node).Right_Child := List_Node; 
               end if;
               
               -- DA FIX 2: Unified DRY Parameter Loop wi' expanded limits!
               if Tokens(State.Current_Token).Kind /= Tok_R_Paren then
                  for I in 1 .. 64 loop -- Expanded safely to 64 arguments
                     Parse_Expression(Tokens, State, Tree, Arg_Node, Success);
                     if not Success then return; end if;
                     
                     if Last_Arg = 0 then 
                        Tree(List_Node).Left_Child := Arg_Node; 
                     else 
                        Tree(Last_Arg).Next_Sibling := Arg_Node; 
                     end if;
                     Last_Arg := Arg_Node;
                     
                     if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Comma then 
                        State.Current_Token := State.Current_Token + 1;
                     elsif State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_R_Paren then 
                        exit;
                     else 
                        Set_Error(State, Tokens, Err_Parse_Missing_Bracket); Success := False; return; 
                     end if;
                  end loop;
               end if;
               
               if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_R_Paren then
                  State.Current_Token := State.Current_Token + 1;
                  Node := Func_Node; -- Morph complete!
               else 
                  Set_Error(State, Tokens, Err_Parse_Missing_Bracket); Success := False; return; 
               end if;
            end;
         end if;
         
         
      -- =========================================================================
      -- DA FILE I/O INTRINSICS FORGE (FUNCTIONS)
      -- =========================================================================
      elsif Tokens(State.Current_Token).Kind = Tok_Filelen then
         declare
            Expr_1 : Node_Index := 0;
         begin
            State.Current_Token := State.Current_Token + 1;

            if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_L_Paren then
               Set_Error(State, Tokens, Err_Parse_Missing_Bracket); Success := False; return;
            end if;
            State.Current_Token := State.Current_Token + 1;

            Parse_Expression(Tokens, State, Tree, Expr_1, Success);
            if not Success then return; end if;

            if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_R_Paren then
               Set_Error(State, Tokens, Err_Parse_Missing_Bracket); Success := False; return;
            end if;
            State.Current_Token := State.Current_Token + 1;

            Allocate_Node(Tokens, State, Tree, AST_File_Len, Node, Success);
            if not Success then return; end if;

            Tree(Node).Left_Child := Expr_1;
         end;

      elsif Tokens(State.Current_Token).Kind in Tok_Open | Tok_Read | Tok_Fileseek then
         declare
            Op_Token : constant Token_Kind := Tokens(State.Current_Token).Kind;
            Expr_1, Expr_2 : Node_Index := 0;
         begin
            State.Current_Token := State.Current_Token + 1; -- Consume OPEN, READ, or FILESEEK
            
            if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_L_Paren then
               Set_Error(State, Tokens, Err_Parse_Missing_Bracket); Success := False; return;
            end if;
            State.Current_Token := State.Current_Token + 1; -- Consume '('
            
            -- Arg 1: File Path (OPEN) / File Handle (READ, FILESEEK)
            Parse_Expression(Tokens, State, Tree, Expr_1, Success);
            if not Success then return; end if;

            if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_Comma then
               Set_Error(State, Tokens, Err_Parse_Expected_Value); Success := False; return;
            end if;
            State.Current_Token := State.Current_Token + 1; -- Consume ','
            
            -- Arg 2: Mode (OPEN) / Bytes (READ) / Absolute offset (FILESEEK)
            Parse_Expression(Tokens, State, Tree, Expr_2, Success);
            if not Success then return; end if;

            if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_R_Paren then
               Set_Error(State, Tokens, Err_Parse_Missing_Bracket); Success := False; return;
            end if;
            State.Current_Token := State.Current_Token + 1; -- Consume ')'

            if Op_Token = Tok_Open then
               Allocate_Node(Tokens, State, Tree, AST_File_Open, Node, Success);
            elsif Op_Token = Tok_Fileseek then
               Allocate_Node(Tokens, State, Tree, AST_File_Seek, Node, Success);
            else
               Allocate_Node(Tokens, State, Tree, AST_File_Read, Node, Success);
            end if;
            if not Success then return; end if;
            
            Tree(Node).Left_Child := Expr_1;
            Tree(Node).Right_Child := Expr_2;
         end;
       
      -- =====================================================================
      -- DA BARE-METAL READERS (PEEK and DEREF)
      -- =====================================================================
      elsif T.Kind = Tok_Peek or T.Kind = Tok_Deref then
         declare
            NKind : Node_Kind := (if T.Kind = Tok_Peek then AST_Peek_Expr else AST_Deref_Expr);
         begin
            Allocate_Node(Tokens, State, Tree, NKind, Node, Success);
            if not Success then return; end if;
            Tree(Node).Token_Index := State.Current_Token;
            State.Current_Token := State.Current_Token + 1; -- Consume PEEK/DEREF

            -- Guard: Expect '('
            if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_L_Paren then
               Set_Error(State, Tokens, Err_Parse_Expected_Value);
               Success := False; return;
            end if;
            State.Current_Token := State.Current_Token + 1;

            declare Expr_Node : Node_Index; begin
               Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
               if not Success then return; end if;
               Tree(Node).Left_Child := Expr_Node;
            end;

            -- Guard: Expect ')'
            if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_R_Paren then
               Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
               Success := False; return;
            end if;
            State.Current_Token := State.Current_Token + 1;
         end;
         
      -- =====================================================================
      -- DA COMPILE-TIME ORACLES (SIZEOF, OFFSETOF, TYPEOF)
      -- =====================================================================
      elsif T.Kind in Tok_SizeOf | Tok_TypeOf then
         declare
            NKind : Node_Kind := (if T.Kind = Tok_SizeOf then AST_SizeOf_Expr else AST_TypeOf_Expr);
         begin
            Allocate_Node(Tokens, State, Tree, NKind, Node, Success);
            if not Success then return; end if;
            Tree(Node).Token_Index := State.Current_Token;
            State.Current_Token := State.Current_Token + 1; -- Consume Operator

            -- Guard: Expect '('
            if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_L_Paren then
               Set_Error(State, Tokens, Err_Parse_Expected_Value); Success := False; return;
            end if;
            State.Current_Token := State.Current_Token + 1;

            declare Expr_Node : Node_Index; begin
               Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
               if not Success then return; end if;
               Tree(Node).Left_Child := Expr_Node;
            end;

            -- Guard: Expect ')'
            if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_R_Paren then
               Set_Error(State, Tokens, Err_Parse_Missing_Bracket); Success := False; return;
            end if;
            State.Current_Token := State.Current_Token + 1;
         end;

      elsif T.Kind = Tok_OffsetOf then
         Allocate_Node(Tokens, State, Tree, AST_OffsetOf_Expr, Node, Success);
         if not Success then return; end if;
         Tree(Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1; -- Consume OFFSETOF

         if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_L_Paren then
            Set_Error(State, Tokens, Err_Parse_Expected_Value); Success := False; return;
         end if;
         State.Current_Token := State.Current_Token + 1;

         -- DA FIX: Wrap the expression parsing in a declare block sae Expr_Node is defined!
         declare 
            Expr_Node : Node_Index; 
         begin
            -- 1. Struct Name (Left Child)
            Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
            if not Success then return; end if;
            Tree(Node).Left_Child := Expr_Node;

            if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_Comma then
               Set_Error(State, Tokens, Err_Parse_Expected_Value); Success := False; return;
            end if;
            State.Current_Token := State.Current_Token + 1;

            -- 2. Field Name (Right Child)
            Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
            if not Success then return; end if;
            Tree(Node).Right_Child := Expr_Node;
         end;

         if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_R_Paren then
            Set_Error(State, Tokens, Err_Parse_Missing_Bracket); Success := False; return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      -- =====================================================================
      -- DA BRANCHLESS 'CHOOSE' MACRO (Ternary Operator)
      -- =====================================================================
      elsif T.Kind = Tok_Choose then
         Allocate_Node(Tokens, State, Tree, AST_Choose, Node, Success);
         if not Success then return; end if;
         Tree(Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1;
         
         -- Guard: Expect '('
         if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_L_Paren then
            Set_Error(State, Tokens, Err_Parse_Expected_Value); Success := False; return; 
         end if;
         State.Current_Token := State.Current_Token + 1;
         
         declare 
            Cond_Node, True_Node, False_Node, Dummy_Node : Node_Index; 
         begin
            -- 1. Parse Condition
            Parse_Expression(Tokens, State, Tree, Cond_Node, Success);
            if not Success then return; end if;
            Tree(Node).Left_Child := Cond_Node;
            
            -- Guard: Expect ','
            if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_Comma then
               Set_Error(State, Tokens, Err_Parse_Expected_Value); Success := False; return; 
            end if;
            State.Current_Token := State.Current_Token + 1;
            
            -- 2. Parse True Value
            Parse_Expression(Tokens, State, Tree, True_Node, Success);
            if not Success then return; end if;
            
            -- Guard: Expect ','
            if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_Comma then
               Set_Error(State, Tokens, Err_Parse_Expected_Value); Success := False; return; 
            end if;
            State.Current_Token := State.Current_Token + 1;
            
            -- 3. Parse False Value
            Parse_Expression(Tokens, State, Tree, False_Node, Success);
            if not Success then return; end if;
            
            -- Guard: Expect ')'
            if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_R_Paren then
               Set_Error(State, Tokens, Err_Parse_Missing_Bracket); Success := False; return; 
            end if;
            State.Current_Token := State.Current_Token + 1;
            
            -- Assemble the AST_Null Dummy branch
            Allocate_Node(Tokens, State, Tree, AST_Null, Dummy_Node, Success);
            if not Success then return; end if;
            Tree(Dummy_Node).Left_Child := True_Node;
            Tree(Dummy_Node).Right_Child := False_Node;
            Tree(Node).Right_Child := Dummy_Node;
         end;
       
      -- =====================================================================
      -- DA KEYBOARD SENSOR
      -- =====================================================================
      elsif T.Kind = Tok_Key then
         Allocate_Node(Tokens, State, Tree, AST_Key_State, Node, Success);
         if not Success then return; end if;
         Tree(Node).Token_Index := State.Current_Token; 
         State.Current_Token := State.Current_Token + 1;
         
         -- Guard: Expect '('
         if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_L_Paren then
            Set_Error(State, Tokens, Err_Parse_Expected_Value); Success := False; return; 
         end if;
         State.Current_Token := State.Current_Token + 1;
         
         declare Expr_Node : Node_Index; begin
            Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
            if not Success then return; end if;
            Tree(Node).Left_Child := Expr_Node;
         end;
         
         -- Guard: Expect ')'
         if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_R_Paren then
            Set_Error(State, Tokens, Err_Parse_Missing_Bracket); Success := False; return; 
         end if;
         State.Current_Token := State.Current_Token + 1;
        
      -- =====================================================================
      -- DA MOUSE SENSORS
      -- =====================================================================
      elsif T.Kind in Tok_Mouse_X | Tok_Mouse_Y | Tok_Mouse_Wheel then
         declare
            NKind : Node_Kind := AST_Mouse_X;
         begin
            if T.Kind = Tok_Mouse_Y then
               NKind := AST_Mouse_Y;
            elsif T.Kind = Tok_Mouse_Wheel then
               NKind := AST_Mouse_Wheel;
            end if;
            Allocate_Node(Tokens, State, Tree, NKind, Node, Success);
            if not Success then return; end if;
            Tree(Node).Token_Index := State.Current_Token; 
            State.Current_Token := State.Current_Token + 1;
         end;
         
      -- DA NEW ENVIRONMENTAL ORACLE PARSING
      elsif T.Kind = Tok_VMouse_X then
         Allocate_Node(Tokens, State, Tree, AST_VMouse_X, Node, Success);
         State.Current_Token := State.Current_Token + 1;
      elsif T.Kind = Tok_VMouse_Y then
         Allocate_Node(Tokens, State, Tree, AST_VMouse_Y, Node, Success);
         State.Current_Token := State.Current_Token + 1;
      elsif T.Kind = Tok_Screen_Width then
         Allocate_Node(Tokens, State, Tree, AST_Screen_Width, Node, Success);
         State.Current_Token := State.Current_Token + 1;
      elsif T.Kind = Tok_Screen_Height then
         Allocate_Node(Tokens, State, Tree, AST_Screen_Height, Node, Success);
         State.Current_Token := State.Current_Token + 1;
      elsif T.Kind = Tok_Virtual_Width then
         Allocate_Node(Tokens, State, Tree, AST_Virtual_Width, Node, Success);
         State.Current_Token := State.Current_Token + 1;
      elsif T.Kind = Tok_Virtual_Height then
         Allocate_Node(Tokens, State, Tree, AST_Virtual_Height, Node, Success);
         State.Current_Token := State.Current_Token + 1;

      elsif T.Kind = Tok_Mouse_Click then
         Allocate_Node(Tokens, State, Tree, AST_Mouse_Click, Node, Success);
         if not Success then return; end if;
         Tree(Node).Token_Index := State.Current_Token; 
         State.Current_Token := State.Current_Token + 1;
         
         -- Guard: Expect '('
         if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_L_Paren then
            Set_Error(State, Tokens, Err_Parse_Expected_Value); Success := False; return; 
         end if;
         State.Current_Token := State.Current_Token + 1;
         
         declare 
            Expr_Node : Node_Index; 
         begin
            Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
            if not Success then return; end if;
            Tree(Node).Left_Child := Expr_Node;
         end;
         
         -- Guard: Expect ')'
         if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_R_Paren then
            Set_Error(State, Tokens, Err_Parse_Missing_Bracket); Success := False; return; 
         end if;
         State.Current_Token := State.Current_Token + 1;
         
         
      elsif T.Kind = Tok_Sys_Renderer then
         Allocate_Node(Tokens, State, Tree, AST_Sys_Renderer, Node, Success);
         State.Current_Token := State.Current_Token + 1;

      -- DA READ_PIXEL FORGE (Reads color frae backbuffer, requires (X,Y) parens!)
      elsif T.Kind = Tok_Read_Pixel then
         Allocate_Node(Tokens, State, Tree, AST_Read_Pixel, Node, Success);
         if not Success then return; end if;
         Tree(Node).Token_Index := State.Current_Token; 
         State.Current_Token := State.Current_Token + 1;
         
         -- Guard: Expect '('
         if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_L_Paren then
            Set_Error(State, Tokens, Err_Parse_Expected_Value); Success := False; return; 
         end if;
         State.Current_Token := State.Current_Token + 1;
         
         declare 
            List_Node, Arg_Node, Last_Arg : Node_Index := 0;
         begin
            Allocate_Node(Tokens, State, Tree, AST_Arg_List, List_Node, Success);
            if not Success then return; end if;
            Tree(Node).Left_Child := List_Node;
            
            for I in 1 .. 2 loop
               Parse_Expression(Tokens, State, Tree, Arg_Node, Success);
               if not Success then return; end if;
               
               if Last_Arg = 0 then Tree(List_Node).Left_Child := Arg_Node;
               else Tree(Last_Arg).Next_Sibling := Arg_Node; end if;
               Last_Arg := Arg_Node;
               
               if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Comma then
                  State.Current_Token := State.Current_Token + 1;
               else
                  exit;
               end if;
            end loop;
         end;
         
         -- Guard: Expect ')'
         if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_R_Paren then
            Set_Error(State, Tokens, Err_Parse_Missing_Bracket); Success := False; return; 
         end if;
         State.Current_Token := State.Current_Token + 1;

      -- DA PROCESS MEMORY READER FORGE (Scalar remote read, expression-style)
      elsif T.Kind = Tok_Read_Process_Memory then
         declare
            Handle_Node : Node_Index := 0;
            Addr_Node   : Node_Index := 0;
            Type_Node   : Node_Index := 0;
         begin
            Allocate_Node (Tokens, State, Tree, AST_Read_Process_Memory_Expr, Node, Success);
            if not Success then return; end if;
            Tree (Node).Token_Index := State.Current_Token;
            State.Current_Token := State.Current_Token + 1;

            if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_L_Paren then
               Set_Error (State, Tokens, Err_Parse_Expected_Value);
               Success := False;
               return;
            end if;
            State.Current_Token := State.Current_Token + 1;

            Parse_Expression (Tokens, State, Tree, Handle_Node, Success);
            if not Success then return; end if;

            if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Comma then
               Set_Error (State, Tokens, Err_Parse_Expected_Value);
               Success := False;
               return;
            end if;
            State.Current_Token := State.Current_Token + 1;

            Parse_Expression (Tokens, State, Tree, Addr_Node, Success);
            if not Success then return; end if;

            if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Comma then
               Set_Error (State, Tokens, Err_Parse_Expected_Value);
               Success := False;
               return;
            end if;
            State.Current_Token := State.Current_Token + 1;

            Parse_Expression (Tokens, State, Tree, Type_Node, Success);
            if not Success then return; end if;

            if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_R_Paren then
               Set_Error (State, Tokens, Err_Parse_Missing_Bracket);
               Success := False;
               return;
            end if;
            State.Current_Token := State.Current_Token + 1;

            Tree (Node).Left_Child := Handle_Node;
            Tree (Node).Right_Child := Addr_Node;
            Tree (Addr_Node).Next_Sibling := Type_Node;
         end;

         
      -- =====================================================================
      -- DA KNOWLEDGE BASE QUERIES (Primary Expressions)
      -- =====================================================================
      elsif T.Kind = Tok_Find then
         Parse_Find_Query(Tokens, State, Tree, Node, Success);
         if not Success then return; end if;
         
      elsif T.Kind = Tok_Knows then
         -- DA FIX: Peek ahead sae expressions can handle 'KNOWS X IS 1' inline!
         if State.Current_Token + 2 <= Max_Tokens and then Tokens(State.Current_Token + 2).Kind = Tok_Is then
            Parse_Knows_Fact(Tokens, State, Tree, Node, Success);
         else
            Parse_Knows_Query(Tokens, State, Tree, Node, Success);
         end if;
         if not Success then return; end if;
         
      -- =====================================================================
      -- DA GROUPING (Parentheses)
      -- =====================================================================
      elsif T.Kind = Tok_L_Paren then
         State.Current_Token := State.Current_Token + 1; -- Consume '('

         --  Parentheses shield the cout-style stream stop: a `SHL`/`<<`
         --  inside `( ... )` is a real shift, not a print-item separator.
         declare
            Prev_Stop : constant Boolean := State.Stop_At_Stream_Shl;
         begin
            State.Stop_At_Stream_Shl := False;
            Parse_Expression(Tokens, State, Tree, Node, Success);
            State.Stop_At_Stream_Shl := Prev_Stop;
         end;
         if not Success then return; end if;
         
         -- Guard: Expect ')'
         if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_R_Paren then
            Set_Error(State, Tokens, Err_Parse_Missing_Bracket); 
            Success := False; 
            return; 
         end if;
         
         State.Current_Token := State.Current_Token + 1; -- Consume ')'

      -- =====================================================================
      -- DA PHANTOM ERROR TRAP (Unrecognized Primary)
      -- =====================================================================
      else 
         Set_Error(State, Tokens, Err_Parse_Expected_Value); 
         Success := False; 
         return;
      end if;
      
   end Parse_Primary;
   
   procedure Parse_Postfix (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Base_Node : Node_Index := 0;
      Temp_Node : Node_Index := 0;
   begin
      Parse_Primary (Tokens, State, Tree, Base_Node, Success);
      if not Success then return; end if;

      while State.Current_Token <= Max_Tokens
        and then Tokens(State.Current_Token).Kind = Tok_AddressOf
      loop
         if State.Current_Token + 1 > Max_Tokens
           or else Tokens(State.Current_Token + 1).Kind not in Tok_Past | Tok_Now | Tok_Future | Tok_Timeline
         then
            Set_Error(State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;

         State.Current_Token := State.Current_Token + 1; -- Consume @

         Allocate_Node(Tokens, State, Tree, AST_Temporal_Ref, Temp_Node, Success);
         if not Success then return; end if;

         Tree(Temp_Node).Token_Index := State.Current_Token; -- past/now/future/timeline
         Tree(Temp_Node).Left_Child  := Base_Node;

         State.Current_Token := State.Current_Token + 1;
         Base_Node := Temp_Node;
      end loop;

      Node := Base_Node;
      Success := True;
   end Parse_Postfix;

   procedure Parse_Unary (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Target_Node : Node_Index := 0;
   begin
      if State.Current_Token <= Max_Tokens
        and then Tokens (State.Current_Token).Kind = Tok_Not
      then
         State.Current_Token := State.Current_Token + 1;
         Allocate_Node (Tokens, State, Tree, AST_Not, Node, Success);
         if not Success then
            return;
         end if;
         Tree (Node).Token_Index := State.Current_Token - 1;
         Parse_Unary (Tokens, State, Tree, Target_Node, Success);
         if Success then
            Tree (Node).Left_Child := Target_Node;
         end if;
         return;
      elsif State.Current_Token <= Max_Tokens
        and then Tokens (State.Current_Token).Kind = Tok_Minus
      then
         State.Current_Token := State.Current_Token + 1;
         Allocate_Node (Tokens, State, Tree, AST_Unary_Minus, Node, Success);
         if not Success then
            return;
         end if;
         Tree (Node).Token_Index := State.Current_Token - 1;
         Parse_Unary (Tokens, State, Tree, Target_Node, Success);
         if Success then
            Tree (Node).Left_Child := Target_Node;
         end if;
         return;
      end if;

      Parse_Power (Tokens, State, Tree, Node, Success);
   end Parse_Unary;

   procedure Parse_Power (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Left_Node, Right_Node, Op_Node : Node_Index := 0;
   begin
      Parse_Postfix (Tokens, State, Tree, Left_Node, Success);
      if not Success then
         return;
      end if;

      Node := Left_Node;

      if State.Current_Token <= Max_Tokens
        and then Tokens (State.Current_Token).Kind = Tok_Pow
      then
         Allocate_Node (Tokens, State, Tree, AST_BinOp, Op_Node, Success);
         if not Success then
            return;
         end if;

         Tree (Op_Node).Token_Index := State.Current_Token;
         Tree (Op_Node).Left_Child := Left_Node;
         State.Current_Token := State.Current_Token + 1;

         Parse_Unary (Tokens, State, Tree, Right_Node, Success);
         if not Success then
            return;
         end if;

         Tree (Op_Node).Right_Child := Right_Node;
         Node := Op_Node;
      end if;
   end Parse_Power;

   
   
   -- =========================================================================
   -- DA PRECEDENCE LADDER (Engineering Grade!)
   -- =========================================================================

   procedure Parse_Expression (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Cond_Node, True_Node, False_Node, Pair_Node, Choose_Node : Node_Index := 0;
   begin
      Parse_Or(Tokens, State, Tree, Cond_Node, Success);
      if not Success then return; end if;

      if State.Current_Token <= Max_Tokens
        and then Tokens(State.Current_Token).Kind = Tok_Question
      then
         Allocate_Node(Tokens, State, Tree, AST_Choose, Choose_Node, Success);
         if not Success then return; end if;

         Tree(Choose_Node).Token_Index := State.Current_Token;
         Tree(Choose_Node).Left_Child  := Cond_Node;
         State.Current_Token := State.Current_Token + 1; -- Consume '?'

         Parse_Expression(Tokens, State, Tree, True_Node, Success);
         if not Success then return; end if;

         if State.Current_Token > Max_Tokens
           or else Tokens(State.Current_Token).Kind /= Tok_Colon
         then
            Set_Error(State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1; -- Consume ':'

         Parse_Expression(Tokens, State, Tree, False_Node, Success);
         if not Success then return; end if;

         Allocate_Node(Tokens, State, Tree, AST_Null, Pair_Node, Success);
         if not Success then return; end if;
         Tree(Pair_Node).Left_Child  := True_Node;
         Tree(Pair_Node).Right_Child := False_Node;
         Tree(Choose_Node).Right_Child := Pair_Node;

         Node := Choose_Node;
      else
         Node := Cond_Node;
      end if;
   end Parse_Expression;

   procedure Parse_Assignment (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Left_Node, Right_Node, Op_Node : Node_Index;
   begin
      Parse_Or(Tokens, State, Tree, Left_Node, Success);
      if not Success then return; end if;
      Node := Left_Node;

      if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Assign then
         Allocate_Node(Tokens, State, Tree, AST_BinOp, Op_Node, Success);
         if not Success then return; end if;
         Tree(Op_Node).Token_Index := State.Current_Token;
         Tree(Op_Node).Left_Child  := Node;
         State.Current_Token := State.Current_Token + 1;
         Parse_Assignment(Tokens, State, Tree, Right_Node, Success); -- Right-associative
         if Success then Tree(Op_Node).Right_Child := Right_Node; Node := Op_Node; end if;
      end if;
   end Parse_Assignment;

   procedure Parse_Or (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Left_Node, Right_Node, Op_Node : Node_Index;
   begin
      Parse_And(Tokens, State, Tree, Left_Node, Success);
      if not Success then return; end if;
      Node := Left_Node;
      -- Task B2: Tok_Pipe / Tok_Ampersand are STRING CONCAT operators with
      -- the same precedence as bitwise OR / XOR.  They funnel into the same
      -- AST_BinOp node shape; emitter dispatches on the actual Token_Kind
      -- (TOK_PIPE branch in albt.adb maps to ALB_String_Concat).
      while State.Current_Token <= Max_Tokens
        and then Tokens(State.Current_Token).Kind in
                   Tok_Or | Tok_Xor | Tok_Pipe | Tok_Ampersand | Tok_Orelse
      loop
         Allocate_Node(Tokens, State, Tree, AST_BinOp, Op_Node, Success);
         if not Success then return; end if;
         Tree(Op_Node).Token_Index := State.Current_Token;
         Tree(Op_Node).Left_Child  := Node;
         State.Current_Token := State.Current_Token + 1;
         Parse_And(Tokens, State, Tree, Right_Node, Success);
         if not Success then return; end if;
         Tree(Op_Node).Right_Child := Right_Node; Node := Op_Node;
      end loop;
   end Parse_Or;

   procedure Parse_And (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Left_Node, Right_Node, Op_Node : Node_Index;
   begin
      Parse_Not(Tokens, State, Tree, Left_Node, Success);
      if not Success then return; end if;
      Node := Left_Node;
      while State.Current_Token <= Max_Tokens
        and then Tokens(State.Current_Token).Kind in Tok_And | Tok_Andalso
      loop
         Allocate_Node(Tokens, State, Tree, AST_BinOp, Op_Node, Success);
         if not Success then return; end if;
         Tree(Op_Node).Token_Index := State.Current_Token;
         Tree(Op_Node).Left_Child  := Node;
         State.Current_Token := State.Current_Token + 1;
         Parse_Not(Tokens, State, Tree, Right_Node, Success);
         if not Success then return; end if;
         Tree(Op_Node).Right_Child := Right_Node; Node := Op_Node;
      end loop;
   end Parse_And;

   --  Classic BASIC precedence: NOT binds looser than comparisons but
   --  tighter than AND — `NOT x = 5` is `NOT (x = 5)`, `NOT a AND b` is
   --  `(NOT a) AND b`.  Matches the FASM backend's whole-register `not`.
   procedure Parse_Not (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Target_Node : Node_Index := 0;
   begin
      if State.Current_Token <= Max_Tokens
        and then Tokens (State.Current_Token).Kind = Tok_Not
      then
         State.Current_Token := State.Current_Token + 1;
         Allocate_Node (Tokens, State, Tree, AST_Not, Node, Success);
         if not Success then
            return;
         end if;
         Tree (Node).Token_Index := State.Current_Token - 1;
         Parse_Not (Tokens, State, Tree, Target_Node, Success);  -- NOT NOT x
         if Success then
            Tree (Node).Left_Child := Target_Node;
         end if;
         return;
      end if;
      Parse_Equality (Tokens, State, Tree, Node, Success);
   end Parse_Not;

   procedure Parse_Equality (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Left_Node, Right_Node, Op_Node : Node_Index;
   begin
      Parse_Comparison(Tokens, State, Tree, Left_Node, Success);
      if not Success then return; end if;
      Node := Left_Node;
      while State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind in Tok_Equal | Tok_Not_Equal | Tok_Assign loop
         Allocate_Node(Tokens, State, Tree, AST_BinOp, Op_Node, Success);
         if not Success then return; end if;
         Tree(Op_Node).Token_Index := State.Current_Token;
         Tree(Op_Node).Left_Child  := Node;
         State.Current_Token := State.Current_Token + 1;
         Parse_Comparison(Tokens, State, Tree, Right_Node, Success);
         if not Success then return; end if;
         Tree(Op_Node).Right_Child := Right_Node; Node := Op_Node;
      end loop;
   end Parse_Equality;

   procedure Parse_Comparison (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Left_Node, Right_Node, Op_Node : Node_Index;
   begin
      Parse_Shift(Tokens, State, Tree, Left_Node, Success);
      if not Success then return; end if;
      Node := Left_Node;
      while State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind in Tok_Less | Tok_Greater | Tok_Less_Equal | Tok_Greater_Equal loop
         Allocate_Node(Tokens, State, Tree, AST_BinOp, Op_Node, Success);
         if not Success then return; end if;
         Tree(Op_Node).Token_Index := State.Current_Token;
         Tree(Op_Node).Left_Child  := Node;
         State.Current_Token := State.Current_Token + 1;
         Parse_Shift(Tokens, State, Tree, Right_Node, Success);
         if not Success then return; end if;
         Tree(Op_Node).Right_Child := Right_Node; Node := Op_Node;
      end loop;
   end Parse_Comparison;

   procedure Parse_Shift (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Left_Node, Right_Node, Op_Node : Node_Index;
   begin
      Parse_Additive(Tokens, State, Tree, Left_Node, Success);
      if not Success then return; end if;
      Node := Left_Node;
      while State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind in Tok_Shl | Tok_Shr loop
         exit when State.Stop_At_Stream_Shl
           and then Tokens(State.Current_Token).Kind = Tok_Shl;

         Allocate_Node(Tokens, State, Tree, AST_BinOp, Op_Node, Success);
         if not Success then return; end if;
         Tree(Op_Node).Token_Index := State.Current_Token;
         Tree(Op_Node).Left_Child  := Node;
         State.Current_Token := State.Current_Token + 1;
         Parse_Additive(Tokens, State, Tree, Right_Node, Success);
         if not Success then return; end if;
         Tree(Op_Node).Right_Child := Right_Node; Node := Op_Node;
      end loop;
   end Parse_Shift;

   procedure Parse_Additive (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Left_Node, Right_Node, Op_Node : Node_Index;
   begin
      Parse_Multiplicative(Tokens, State, Tree, Left_Node, Success);
      if not Success then return; end if;
      Node := Left_Node;
      while State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind in Tok_Plus | Tok_Minus loop
         Allocate_Node(Tokens, State, Tree, AST_BinOp, Op_Node, Success);
         if not Success then return; end if;
         Tree(Op_Node).Token_Index := State.Current_Token;
         Tree(Op_Node).Left_Child  := Node;
         State.Current_Token := State.Current_Token + 1;
         Parse_Multiplicative(Tokens, State, Tree, Right_Node, Success);
         if not Success then return; end if;
         Tree(Op_Node).Right_Child := Right_Node; Node := Op_Node;
      end loop;
   end Parse_Additive;

   procedure Parse_Multiplicative (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Left_Node, Right_Node, Op_Node : Node_Index;
   begin
      Parse_Unary(Tokens, State, Tree, Left_Node, Success);
      if not Success then return; end if;
      Node := Left_Node;
      while State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind in Tok_Mul | Tok_Div | Tok_Mod loop
         Allocate_Node(Tokens, State, Tree, AST_BinOp, Op_Node, Success);
         if not Success then return; end if;
         Tree(Op_Node).Token_Index := State.Current_Token;
         Tree(Op_Node).Left_Child  := Node;
         State.Current_Token := State.Current_Token + 1;
         Parse_Unary(Tokens, State, Tree, Right_Node, Success);
         if not Success then return; end if;
         Tree(Op_Node).Right_Child := Right_Node; Node := Op_Node;
      end loop;
   end Parse_Multiplicative;

   procedure Parse_Predicate (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      T : Token := Tokens(State.Current_Token);
      Arg_Node : Node_Index; Last_Arg : Node_Index := 0;
   begin
      Success := False; Node := 0;
      
      -- DA FIX: Allow Logic Vars (Uppercase) tae be Predicates tae!
      if T.Kind not in Tok_Atom | Tok_Logic_Var | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States then 
         return; -- Let the caller handle the failure/backtracking
      end if;
      
      Allocate_Node(Tokens, State, Tree, AST_Predicate, Node, Success);
      if not Success then return; end if;
      Tree(Node).Token_Index := State.Current_Token; 
      State.Current_Token := State.Current_Token + 1;
      
      if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_L_Paren then
         State.Current_Token := State.Current_Token + 1; -- Consume '('
         
         for I in 1 .. 64 loop -- Expanded limit tae 64 arguments!
            T := Tokens(State.Current_Token);
            
            -- DA FIX: Unified Membership Test + Added Binary Literals!
            if T.Kind in Tok_Atom | Tok_Logic_Var | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States | Tok_Number | Tok_String | Tok_Hex_Literal | Tok_Bin_Literal then
               
               declare 
                  NKind : Node_Kind; 
               begin
                  case T.Kind is
                     when Tok_Logic_Var   => NKind := AST_Logic_Var;
                     when Tok_Number      => NKind := AST_Number_Expr;
                     when Tok_String      => NKind := AST_String_Expr;
                     when Tok_Hex_Literal => NKind := AST_Hex_Expr;
                     when Tok_Bin_Literal => NKind := AST_Bin_Expr;
                     when others          => NKind := AST_Atom; -- Default fallback for Tok_Atom
                  end case;
                  
                  Allocate_Node(Tokens, State, Tree, NKind, Arg_Node, Success);
               end;
               
               if not Success then return; end if;
               Tree(Arg_Node).Token_Index := State.Current_Token; 
               State.Current_Token := State.Current_Token + 1;
               
               -- Bind Siblings
               if Last_Arg = 0 then 
                  Tree(Node).Left_Child := Arg_Node; 
               else 
                  Tree(Last_Arg).Next_Sibling := Arg_Node; 
               end if;
               Last_Arg := Arg_Node;
               
               -- Check for Comma or Close Paren
               T := Tokens(State.Current_Token);
               if T.Kind = Tok_Comma then 
                  State.Current_Token := State.Current_Token + 1;
               elsif T.Kind = Tok_R_Paren then 
                  State.Current_Token := State.Current_Token + 1;
                  Success := True; 
                  return; -- Early flat exit!
               else 
                  Set_Error(State, Tokens, Err_Parse_Missing_Bracket); 
                  Success := False; 
                  return; 
               end if;
            else 
               Set_Error(State, Tokens, Err_Parse_Expected_Value);
               Success := False; 
               return; 
            end if;
         end loop;
         
         -- If we hit the 64 arg limit without returning, we drop an error!
         Set_Error(State, Tokens, Err_Parse_Missing_Bracket); 
         Success := False;
      else 
         -- 0-Arity Predicate (e.g. `clearance.`)
         Success := True; 
      end if;
   end Parse_Predicate;
   
   procedure Parse_Block_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      First_Stmt, Curr_Stmt, Next_Stmt : Node_Index := 0;
      Failed_Token : Natural := 0;
   begin
      Success := False; 
      Node := 0;
      
      Allocate_Node(Tokens, State, Tree, AST_Block_Stmt, Node, Success);
      if not Success then return; end if;
      
      Tree(Node).Token_Index := State.Current_Token; 
      State.Current_Token := State.Current_Token + 1; -- Consume block opener
      
      for I in 1 .. 16384 loop
         -- 1. DA FIX: Guard against Premature EOF (Missing END)
         if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind = Tok_Error then
            -- They forgot the END tag!
            Set_Error(State, Tokens, Err_Parse_Expected_Value); 
            Success := False; 
            return;
         end if;
         
         -- 2. Check for Block Terminator
         if Is_Bare_End (Tokens, State) then
            State.Current_Token := State.Current_Token + 1; -- Consume 'END'
            Success := True; 
            return;
         end if;
         
         -- 3. Parse Next Statement
         Failed_Token := State.Current_Token;
         Parse_Statement(Tokens, State, Tree, Next_Stmt, Success);
         if not Success then 
            -- DA PANIC MODE INTERCEPT!
            Recover_After_Stmt_Error (Tokens, State, Failed_Token);
            Next_Stmt := 0; -- Prevent garbage frae entering the AST
            
            Success := True; -- DA MISSING LINK: Tell the block loop to keep going!
         end if;
         
         -- 4. Assemble the Sibling Chain (DA FIX: Guard against null nodes!)
         if Next_Stmt /= 0 then
            if First_Stmt = 0 then 
               First_Stmt := Next_Stmt; 
               Tree(Node).Left_Child := First_Stmt;
            else 
               Tree(Curr_Stmt).Next_Sibling := Next_Stmt; 
            end if;
            
            Curr_Stmt := Next_Stmt;
         end if;
      end loop;
      
      -- 5. True Block Overflow (Over 16,384 statements in one block!)
      Ada.Text_IO.Put_Line
        ("[parser-debug] Parse_Block_Stmt overflow Last_Node=" &
         Integer'Image (State.Last_Node) &
         " Token=" & Integer'Image (State.Current_Token));
      Set_Error(State, Tokens, Err_Parse_Block_Overflow);
      Success := False;
   end Parse_Block_Stmt;

   -- =========================================================================
   -- DA WHILE LOOP FORGE
   -- =========================================================================
   procedure Parse_While_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Cond_Node, Body_Node, Next_Stmt, First_Stmt, Curr_Stmt : Node_Index := 0;
   begin
      Allocate_Node(Tokens, State, Tree, AST_While_Stmt, Node, Success);
      if not Success then return; end if;
      Tree(Node).Token_Index := State.Current_Token; 
      State.Current_Token := State.Current_Token + 1; 

      -- 1. Parse Condition
      Parse_Expression(Tokens, State, Tree, Cond_Node, Success);
      if not Success then return; end if;
      Tree(Node).Left_Child := Cond_Node;

      if State.Current_Token <= Max_Tokens
        and then Tokens(State.Current_Token).Kind = Tok_Begin
      then
         Parse_Block_Stmt(Tokens, State, Tree, Body_Node, Success);
         if not Success then return; end if;
         Tree(Node).Right_Child := Body_Node;
         Success := True;
         return;
      end if;

      -- 2. Allocate Body Block
      Allocate_Node(Tokens, State, Tree, AST_Block_Stmt, Body_Node, Success);
      if not Success then return; end if;
      Tree(Node).Right_Child := Body_Node;

      -- 3. Parse Statements
      for I in 1 .. 16384 loop
         -- DA FIX: Guard against Premature EOF (Missing END)
         if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind = Tok_Error then
            Set_Error(State, Tokens, Err_Parse_Expected_Value); 
            Success := False; 
            return;
         end if;
         
         -- Check for Terminator
         if Is_Bare_End (Tokens, State)
           or else Same_Line_End_Tag (Tokens, State, Tok_While)
         then
            declare
               End_Line : Positive := Tokens(State.Current_Token).Line;
            begin
               State.Current_Token := State.Current_Token + 1; -- Consume 'END'
               -- MUST check for Tok_While here!
               if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_While
                  and then Tokens(State.Current_Token).Line = End_Line
               then
                  State.Current_Token := State.Current_Token + 1;
               end if;
               Success := True; 
               return;
            end;
         end if;
         
         Parse_Statement(Tokens, State, Tree, Next_Stmt, Success);
         if not Success then return; end if;
         
         if First_Stmt = 0 then 
            First_Stmt := Next_Stmt; 
            Tree(Body_Node).Left_Child := First_Stmt;
         else 
            Tree(Curr_Stmt).Next_Sibling := Next_Stmt; 
         end if;
         Curr_Stmt := Next_Stmt;
      end loop;
      
      -- True Block Overflow
      Ada.Text_IO.Put_Line
        ("[parser-debug] Parse_While_Stmt overflow Last_Node=" &
         Integer'Image (State.Last_Node) &
         " Token=" & Integer'Image (State.Current_Token));
      Success := False; 
      Set_Error(State, Tokens, Err_Parse_Block_Overflow);
   end Parse_While_Stmt;
   
   procedure Parse_Comptime_Block (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Block_Node, Next_Stmt, First_Stmt, Curr_Stmt : Node_Index := 0;
   begin
      Allocate_Node(Tokens, State, Tree, AST_Comptime_Block, Node, Success);
      if not Success then return; end if;

      Tree(Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume COMPTIME

      Allocate_Node(Tokens, State, Tree, AST_Block_Stmt, Block_Node, Success);
      if not Success then return; end if;
      Tree(Node).Left_Child := Block_Node;

      for I in 1 .. 16384 loop
         if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind = Tok_Error then
            Set_Error(State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;

         if Tokens(State.Current_Token).Kind = Tok_End then
            declare
               End_Line : Positive := Tokens(State.Current_Token).Line;
            begin
               State.Current_Token := State.Current_Token + 1; -- Consume END

               if State.Current_Token <= Max_Tokens
                 and then Tokens(State.Current_Token).Kind = Tok_Comptime
                 and then Tokens(State.Current_Token).Line = End_Line
               then
                  State.Current_Token := State.Current_Token + 1; -- Consume COMPTIME
                  Success := True;
                  return;
               else
                  Set_Error(State, Tokens, Err_Parse_Expected_Block_End);
                  Success := False;
                  return;
               end if;
            end;
         end if;

         Parse_Statement(Tokens, State, Tree, Next_Stmt, Success);
         if not Success then return; end if;

         if First_Stmt = 0 then
            First_Stmt := Next_Stmt;
            Tree(Block_Node).Left_Child := First_Stmt;
         else
            Tree(Curr_Stmt).Next_Sibling := Next_Stmt;
         end if;
         Curr_Stmt := Next_Stmt;
      end loop;

      Set_Error(State, Tokens, Err_Parse_Block_Overflow);
      Success := False;
   end Parse_Comptime_Block;
   
   procedure Parse_Advance_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Start_Line : Positive := Tokens(State.Current_Token).Line;
      Count_Node : Node_Index := 0;
      Uses_Parens : Boolean := False;
   begin
      Allocate_Node(Tokens, State, Tree, AST_Advance_Stmt, Node, Success);
      if not Success then return; end if;

      Tree(Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1;

      if State.Current_Token <= Max_Tokens
        and then Tokens(State.Current_Token).Kind = Tok_L_Paren
      then
         Uses_Parens := True;
         State.Current_Token := State.Current_Token + 1;
      end if;

      if Uses_Parens
        and then State.Current_Token <= Max_Tokens
        and then Tokens(State.Current_Token).Kind = Tok_R_Paren
      then
         State.Current_Token := State.Current_Token + 1;
      elsif State.Current_Token <= Max_Tokens
        and then Tokens(State.Current_Token).Line = Start_Line
        and then Tokens(State.Current_Token).Kind /= Tok_Error
      then
         Parse_Expression(Tokens, State, Tree, Count_Node, Success);
         if not Success then return; end if;
         Tree(Node).Left_Child := Count_Node;

         if Uses_Parens then
            if State.Current_Token <= Max_Tokens
              and then Tokens(State.Current_Token).Kind = Tok_R_Paren
            then
               State.Current_Token := State.Current_Token + 1;
            else
               Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
               Success := False;
               return;
            end if;
         end if;
      elsif Uses_Parens then
         Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
         Success := False;
         return;
      end if;

      Success := True;
   end Parse_Advance_Stmt;
   
   
   procedure Parse_Temporal_Decl (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Target_Node  : Node_Index := 0;
      History_Node : Node_Index := 0;
      Init_Node    : Node_Index := 0;
      Type_Token   : Natural := 0;
   begin
      Allocate_Node(Tokens, State, Tree, AST_Temporal_Decl, Node, Success);
      if not Success then return; end if;

      State.Current_Token := State.Current_Token + 1; -- TEMPORAL

      if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_Let then
         Set_Error(State, Tokens, Err_Parse_Expected_Value);
         Success := False; return;
      end if;
      State.Current_Token := State.Current_Token + 1;

      Parse_Primary(Tokens, State, Tree, Target_Node, Success);
      if not Success then return; end if;
      Tree(Node).Left_Child := Target_Node;

      if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_As then
         State.Current_Token := State.Current_Token + 1;
         if State.Current_Token > Max_Tokens
           or else not Is_Type_Name_Token (Tokens(State.Current_Token).Kind)
         then
            Set_Error(State, Tokens, Err_Parse_Missing_Type_Name);
            Success := False; return;
         end if;
         Type_Token := State.Current_Token;
         State.Current_Token := State.Current_Token + 1;
         -- Safety Trap: Variables and Fields cannot be Void
         if Tokens(State.Current_Token - 1).Kind = Tok_U0 then
            Set_Error(State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
      end if;

      Tree(Node).Token_Index := Type_Token;

      if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_History then
         Set_Error(State, Tokens, Err_Parse_Expected_Value);
         Success := False; return;
      end if;
      State.Current_Token := State.Current_Token + 1;

      -- HISTORY is a compile-time numeric expression, but it must not
      -- consume the initializer assignment in:
      -- TEMPORAL LET X HISTORY 4 = 10.
      Parse_Comparison(Tokens, State, Tree, History_Node, Success);

      if not Success then return; end if;
      Tree(Node).Right_Child := History_Node;

      if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_Assign then
         Set_Error(State, Tokens, Err_Parse_Missing_Assign);
         Success := False; return;
      end if;
      State.Current_Token := State.Current_Token + 1;

      Parse_Expression(Tokens, State, Tree, Init_Node, Success);
      if not Success then return; end if;
      Tree(History_Node).Next_Sibling := Init_Node;
   end Parse_Temporal_Decl;

   procedure Parse_Temporal_Block (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Block_Node, Next_Stmt, First_Stmt, Curr_Stmt : Node_Index := 0;
   begin
      Allocate_Node(Tokens, State, Tree, AST_Temporal_Block, Node, Success);
      if not Success then return; end if;

      Tree(Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1;

      Allocate_Node(Tokens, State, Tree, AST_Block_Stmt, Block_Node, Success);
      if not Success then return; end if;
      Tree(Node).Left_Child := Block_Node;

      for I in 1 .. 16384 loop
         if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind = Tok_Error then
            Set_Error(State, Tokens, Err_Parse_Expected_Value);
            Success := False; return;
         end if;

         if Tokens(State.Current_Token).Kind = Tok_End then
            declare
               End_Line : Positive := Tokens(State.Current_Token).Line;
            begin
               State.Current_Token := State.Current_Token + 1;
               if State.Current_Token <= Max_Tokens
                 and then Tokens(State.Current_Token).Kind = Tok_Temporal
                 and then Tokens(State.Current_Token).Line = End_Line
               then
                  State.Current_Token := State.Current_Token + 1;
                  Success := True; return;
               end if;

               Set_Error(State, Tokens, Err_Parse_Expected_Block_End);
               Success := False; return;
            end;
         end if;

         Parse_Statement(Tokens, State, Tree, Next_Stmt, Success);
         if not Success then return; end if;

         if First_Stmt = 0 then
            First_Stmt := Next_Stmt;
            Tree(Block_Node).Left_Child := First_Stmt;
         else
            Tree(Curr_Stmt).Next_Sibling := Next_Stmt;
         end if;
         Curr_Stmt := Next_Stmt;
      end loop;

      Set_Error(State, Tokens, Err_Parse_Block_Overflow);
      Success := False;
   end Parse_Temporal_Block;

   procedure Append_Parsed_Stmt
     (Tree       : in out Node_Array;
      Block_Node : in Node_Index;
      First_Stmt : in out Node_Index;
      Curr_Stmt  : in out Node_Index;
      Next_Stmt  : in Node_Index) is
   begin
      if Next_Stmt = 0 then
         return;
      end if;

      if First_Stmt = 0 then
         First_Stmt := Next_Stmt;
         Tree(Block_Node).Left_Child := First_Stmt;
      else
         Tree(Curr_Stmt).Next_Sibling := Next_Stmt;
      end if;

      Curr_Stmt := Next_Stmt;
   end Append_Parsed_Stmt;

   procedure Parse_Bracketed_Expression
     (Tokens  : in Token_Array;
      State   : in out Parser_State;
      Tree    : in out Node_Array;
      Node    : out Node_Index;
      Success : out Boolean) is
   begin
      Node := 0;
      Success := False;

      if State.Current_Token > Max_Tokens
        or else Tokens(State.Current_Token).Kind /= Tok_L_Square
      then
         Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
         return;
      end if;

      State.Current_Token := State.Current_Token + 1; -- Consume '['
      Parse_Expression(Tokens, State, Tree, Node, Success);
      if not Success then return; end if;

      if State.Current_Token > Max_Tokens
        or else Tokens(State.Current_Token).Kind /= Tok_R_Square
      then
         Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
         Success := False;
         return;
      end if;

      State.Current_Token := State.Current_Token + 1; -- Consume ']'
      Success := True;
   end Parse_Bracketed_Expression;

   procedure Attach_Optional_Fallback
     (Tree          : in out Node_Array;
      Anchor_Node   : in Node_Index;
      Fallback_Node : in Node_Index) is
   begin
      if Anchor_Node /= 0 and then Fallback_Node /= 0 then
         Tree(Anchor_Node).Next_Sibling := Fallback_Node;
      end if;
   end Attach_Optional_Fallback;

   procedure Parse_Feature_Block_Bodies
     (Tokens                : in Token_Array;
      State                 : in out Parser_State;
      Tree                  : in out Node_Array;
      End_Tag               : in Token_Kind;
      Allow_Inline_Fallback : in Boolean;
      Body_Node             : out Node_Index;
      Fallback_Node         : out Node_Index;
      Success               : out Boolean) is
      Next_Stmt      : Node_Index := 0;
      First_Stmt     : Node_Index := 0;
      Curr_Stmt      : Node_Index := 0;
      Fallback_Body  : Node_Index := 0;
      Fallback_First : Node_Index := 0;
      Fallback_Curr  : Node_Index := 0;
   begin
      Body_Node := 0;
      Fallback_Node := 0;
      Success := False;

      Allocate_Node(Tokens, State, Tree, AST_Block_Stmt, Body_Node, Success);
      if not Success then return; end if;
      Tree(Body_Node).Token_Index := State.Current_Token;

      for I in 1 .. 16384 loop
         if State.Current_Token > Max_Tokens
           or else Tokens(State.Current_Token).Kind = Tok_Error
         then
            Set_Error(State, Tokens, Err_Parse_Expected_Block_End);
            Success := False;
            return;
         end if;

         if Same_Line_End_Tag(Tokens, State, End_Tag) then
            State.Current_Token := State.Current_Token + 2; -- Consume END + tag
            Success := True;
            return;
         end if;

         if Allow_Inline_Fallback
           and then Fallback_Node = 0
           and then Tokens(State.Current_Token).Kind = Tok_Fallback
         then
            Allocate_Node(Tokens, State, Tree, AST_Fallback_Block, Fallback_Node, Success);
            if not Success then return; end if;
            Tree(Fallback_Node).Token_Index := State.Current_Token;
            State.Current_Token := State.Current_Token + 1; -- Consume FALLBACK

            Allocate_Node(Tokens, State, Tree, AST_Block_Stmt, Fallback_Body, Success);
            if not Success then return; end if;
            Tree(Fallback_Node).Left_Child := Fallback_Body;
            Tree(Fallback_Body).Token_Index := State.Current_Token;
         else
            Parse_Statement(Tokens, State, Tree, Next_Stmt, Success);
            if not Success then return; end if;

            if Fallback_Node = 0 then
               Append_Parsed_Stmt(Tree, Body_Node, First_Stmt, Curr_Stmt, Next_Stmt);
            else
               Append_Parsed_Stmt(Tree, Fallback_Body, Fallback_First, Fallback_Curr, Next_Stmt);
            end if;
         end if;
      end loop;

      Set_Error(State, Tokens, Err_Parse_Block_Overflow);
      Success := False;
   end Parse_Feature_Block_Bodies;

   procedure Parse_Fallback_Block (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Body_Node     : Node_Index := 0;
      Ignored_Node  : Node_Index := 0;
   begin
      Allocate_Node(Tokens, State, Tree, AST_Fallback_Block, Node, Success);
      if not Success then return; end if;

      Tree(Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume FALLBACK

      Parse_Feature_Block_Bodies
        (Tokens, State, Tree, Tok_Fallback, False, Body_Node, Ignored_Node, Success);
      if not Success then return; end if;

      Tree(Node).Left_Child := Body_Node;
   end Parse_Fallback_Block;

   procedure Parse_Exact_Block (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Body_Node     : Node_Index := 0;
      Fallback_Node : Node_Index := 0;
   begin
      Allocate_Node(Tokens, State, Tree, AST_Exact_Block, Node, Success);
      if not Success then return; end if;

      Tree(Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume EXACT

      Parse_Feature_Block_Bodies
        (Tokens, State, Tree, Tok_Exact, True, Body_Node, Fallback_Node, Success);
      if not Success then return; end if;

      Tree(Node).Left_Child := Body_Node;
      Tree(Node).Right_Child := Fallback_Node;
   end Parse_Exact_Block;

   procedure Parse_Secure_Block (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Body_Node     : Node_Index := 0;
      Ignored_Node  : Node_Index := 0;
   begin
      Allocate_Node(Tokens, State, Tree, AST_Secure_Block, Node, Success);
      if not Success then return; end if;

      Tree(Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume SECURE

      -- A SECURE block anywhere implies the crypt forge machinery must exist
      -- (decoder + table), even without --crypt-strings.
      Code_Vault.Secure_Blocks_Used := True;

      Parse_Feature_Block_Bodies
        (Tokens, State, Tree, Tok_Secure, False, Body_Node, Ignored_Node, Success);
      if not Success then return; end if;

      Tree(Node).Left_Child := Body_Node;
   end Parse_Secure_Block;

   procedure Parse_Symbolic_Block (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Body_Node     : Node_Index := 0;
      Fallback_Node : Node_Index := 0;
   begin
      Allocate_Node(Tokens, State, Tree, AST_Symbolic_Block, Node, Success);
      if not Success then return; end if;

      Tree(Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume SYMBOLIC

      Parse_Feature_Block_Bodies
        (Tokens, State, Tree, Tok_Symbolic, True, Body_Node, Fallback_Node, Success);
      if not Success then return; end if;

      Tree(Node).Left_Child := Body_Node;
      Tree(Node).Right_Child := Fallback_Node;
   end Parse_Symbolic_Block;

   procedure Parse_Morton_Tile_Block (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Surface_Node  : Node_Index := 0;
      Size_Node     : Node_Index := 0;
      Width_Node    : Node_Index := 0;
      Height_Node   : Node_Index := 0;
      Body_Node     : Node_Index := 0;
      Fallback_Node : Node_Index := 0;
   begin
      Allocate_Node(Tokens, State, Tree, AST_Morton_Tile_Block, Node, Success);
      if not Success then return; end if;

      Tree(Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume MORTON_TILE

      Parse_Bracketed_Expression(Tokens, State, Tree, Surface_Node, Success);
      if not Success then return; end if;
      Tree(Node).Left_Child := Surface_Node;

      if State.Current_Token > Max_Tokens
        or else Tokens(State.Current_Token).Kind /= Tok_Block
      then
         Set_Error(State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1; -- Consume BLOCK

      Allocate_Node(Tokens, State, Tree, AST_Morton_Tile_Size, Size_Node, Success);
      if not Success then return; end if;
      Tree(Size_Node).Token_Index := State.Current_Token;

      if State.Current_Token <= Max_Tokens
        and then Tokens(State.Current_Token).Kind = Tok_Tile_Size
      then
         State.Current_Token := State.Current_Token + 1;
      else
         Parse_Expression(Tokens, State, Tree, Width_Node, Success);
         if not Success then return; end if;
         Tree(Size_Node).Left_Child := Width_Node;

         if State.Current_Token <= Max_Tokens
           and then Tokens(State.Current_Token).Kind = Tok_Comma
         then
            State.Current_Token := State.Current_Token + 1;
            Parse_Expression(Tokens, State, Tree, Height_Node, Success);
            if not Success then return; end if;
            Tree(Size_Node).Right_Child := Height_Node;
         end if;
      end if;

      Parse_Feature_Block_Bodies
        (Tokens, State, Tree, Tok_Morton_Tile, True, Body_Node, Fallback_Node, Success);
      if not Success then return; end if;

      Tree(Node).Right_Child := Size_Node;
      Tree(Size_Node).Next_Sibling := Body_Node;
      Attach_Optional_Fallback(Tree, Body_Node, Fallback_Node);
   end Parse_Morton_Tile_Block;

   procedure Parse_Branchless_Predicate_Block (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Condition_Node : Node_Index := 0;
      Body_Node      : Node_Index := 0;
      Fallback_Node  : Node_Index := 0;
   begin
      Allocate_Node(Tokens, State, Tree, AST_Branchless_Predicate_Block, Node, Success);
      if not Success then return; end if;

      Tree(Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume PREDICATE

      Parse_Bracketed_Expression(Tokens, State, Tree, Condition_Node, Success);
      if not Success then return; end if;
      Tree(Node).Left_Child := Condition_Node;

      Parse_Feature_Block_Bodies
        (Tokens, State, Tree, Tok_Predicate, True, Body_Node, Fallback_Node, Success);
      if not Success then return; end if;

      Tree(Node).Right_Child := Body_Node;
      Attach_Optional_Fallback(Tree, Body_Node, Fallback_Node);
   end Parse_Branchless_Predicate_Block;

   procedure Parse_Stride_Block (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Width_Node     : Node_Index := 0;
      Body_Node      : Node_Index := 0;
      Fallback_Node  : Node_Index := 0;
   begin
      Allocate_Node(Tokens, State, Tree, AST_Stride_Block, Node, Success);
      if not Success then return; end if;

      Tree(Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume STRIDE

      Parse_Expression(Tokens, State, Tree, Width_Node, Success);
      if not Success then return; end if;
      Tree(Node).Left_Child := Width_Node;

      Parse_Feature_Block_Bodies
        (Tokens, State, Tree, Tok_Stride, True, Body_Node, Fallback_Node, Success);
      if not Success then return; end if;

      Tree(Node).Right_Child := Body_Node;
      Attach_Optional_Fallback(Tree, Body_Node, Fallback_Node);
   end Parse_Stride_Block;

   procedure Parse_Ratio_Space_Block (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Pin_Node       : Node_Index := 0;
      First_Pin      : Node_Index := 0;
      Last_Pin       : Node_Index := 0;
      Pinned_Expr    : Node_Index := 0;
      Body_Node      : Node_Index := 0;
      Fallback_Node  : Node_Index := 0;
   begin
      Allocate_Node(Tokens, State, Tree, AST_Ratio_Space_Block, Node, Success);
      if not Success then return; end if;

      Tree(Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume RATIO_SPACE

      if State.Current_Token > Max_Tokens
        or else Tokens(State.Current_Token).Kind /= Tok_Pins
      then
         Set_Error(State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1; -- Consume PINS

      for I in 1 .. 8 loop
         Parse_Bracketed_Expression(Tokens, State, Tree, Pinned_Expr, Success);
         if not Success then return; end if;

         Allocate_Node(Tokens, State, Tree, AST_Ratio_Pin, Pin_Node, Success);
         if not Success then return; end if;
         Tree(Pin_Node).Left_Child := Pinned_Expr;

         if First_Pin = 0 then
            First_Pin := Pin_Node;
         else
            Tree(Last_Pin).Next_Sibling := Pin_Node;
         end if;
         Last_Pin := Pin_Node;

         exit when State.Current_Token > Max_Tokens
           or else Tokens(State.Current_Token).Kind /= Tok_Comma;
         State.Current_Token := State.Current_Token + 1; -- Consume ','
      end loop;

      Tree(Node).Left_Child := First_Pin;

      Parse_Feature_Block_Bodies
        (Tokens, State, Tree, Tok_Ratio_Space, True, Body_Node, Fallback_Node, Success);
      if not Success then return; end if;

      Tree(Node).Right_Child := Body_Node;
      Attach_Optional_Fallback(Tree, Body_Node, Fallback_Node);
   end Parse_Ratio_Space_Block;

   procedure Parse_Export_PPM_Block (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Surface_Node   : Node_Index := 0;
      File_Node      : Node_Index := 0;
      Format_Node    : Node_Index := 0;
      Body_Node      : Node_Index := 0;
      Fallback_Node  : Node_Index := 0;
   begin
      Allocate_Node(Tokens, State, Tree, AST_Export_PPM_Block, Node, Success);
      if not Success then return; end if;

      Tree(Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume EXPORT_PPM

      Parse_Bracketed_Expression(Tokens, State, Tree, Surface_Node, Success);
      if not Success then return; end if;
      Tree(Node).Left_Child := Surface_Node;

      if State.Current_Token > Max_Tokens
        or else Tokens(State.Current_Token).Kind /= Tok_To
      then
         Set_Error(State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1; -- Consume TO

      Parse_Bracketed_Expression(Tokens, State, Tree, File_Node, Success);
      if not Success then return; end if;
      Tree(Node).Right_Child := File_Node;

      if State.Current_Token > Max_Tokens
        or else Tokens(State.Current_Token).Kind /= Tok_Format
      then
         Set_Error(State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1; -- Consume FORMAT

      Parse_Expression(Tokens, State, Tree, Format_Node, Success);
      if not Success then return; end if;
      Tree(File_Node).Next_Sibling := Format_Node;

      Parse_Feature_Block_Bodies
        (Tokens, State, Tree, Tok_Export_PPM, True, Body_Node, Fallback_Node, Success);
      if not Success then return; end if;

      Tree(Format_Node).Next_Sibling := Body_Node;
      Attach_Optional_Fallback(Tree, Body_Node, Fallback_Node);
   end Parse_Export_PPM_Block;

   procedure Parse_Fits_Cube_Block (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Surface_Node   : Node_Index := 0;
      File_Node      : Node_Index := 0;
      Body_Node      : Node_Index := 0;
      Fallback_Node  : Node_Index := 0;
   begin
      Allocate_Node(Tokens, State, Tree, AST_Fits_Cube_Block, Node, Success);
      if not Success then return; end if;

      Tree(Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume FITS_CUBE

      Parse_Bracketed_Expression(Tokens, State, Tree, Surface_Node, Success);
      if not Success then return; end if;
      Tree(Node).Left_Child := Surface_Node;

      if State.Current_Token > Max_Tokens
        or else Tokens(State.Current_Token).Kind /= Tok_File
      then
         Set_Error(State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1; -- Consume FILE

      Parse_Bracketed_Expression(Tokens, State, Tree, File_Node, Success);
      if not Success then return; end if;
      Tree(Node).Right_Child := File_Node;

      Parse_Feature_Block_Bodies
        (Tokens, State, Tree, Tok_Fits_Cube, True, Body_Node, Fallback_Node, Success);
      if not Success then return; end if;

      Tree(File_Node).Next_Sibling := Body_Node;
      Attach_Optional_Fallback(Tree, Body_Node, Fallback_Node);
   end Parse_Fits_Cube_Block;

   procedure Parse_Ini_Bind_Block (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Struct_Node    : Node_Index := 0;
      File_Node      : Node_Index := 0;
      Body_Node      : Node_Index := 0;
      Fallback_Node  : Node_Index := 0;
   begin
      Allocate_Node(Tokens, State, Tree, AST_Ini_Bind_Block, Node, Success);
      if not Success then return; end if;

      Tree(Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume INI_BIND

      Parse_Bracketed_Expression(Tokens, State, Tree, Struct_Node, Success);
      if not Success then return; end if;
      Tree(Node).Left_Child := Struct_Node;

      if State.Current_Token > Max_Tokens
        or else Tokens(State.Current_Token).Kind /= Tok_To
      then
         Set_Error(State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1; -- Consume TO

      Parse_Bracketed_Expression(Tokens, State, Tree, File_Node, Success);
      if not Success then return; end if;
      Tree(Node).Right_Child := File_Node;

      Parse_Feature_Block_Bodies
        (Tokens, State, Tree, Tok_Ini_Bind, True, Body_Node, Fallback_Node, Success);
      if not Success then return; end if;

      Tree(File_Node).Next_Sibling := Body_Node;
      Attach_Optional_Fallback(Tree, Body_Node, Fallback_Node);
   end Parse_Ini_Bind_Block;

   procedure Parse_Stream_Bypass_Block (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Buffer_Node    : Node_Index := 0;
      Handle_Node    : Node_Index := 0;
      Size_Node      : Node_Index := 0;
      Body_Node      : Node_Index := 0;
      Fallback_Node  : Node_Index := 0;
   begin
      Allocate_Node(Tokens, State, Tree, AST_Stream_Bypass_Block, Node, Success);
      if not Success then return; end if;

      Tree(Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume STREAM_BYPASS

      Parse_Bracketed_Expression(Tokens, State, Tree, Buffer_Node, Success);
      if not Success then return; end if;
      Tree(Node).Left_Child := Buffer_Node;

      if State.Current_Token > Max_Tokens
        or else Tokens(State.Current_Token).Kind /= Tok_To
      then
         Set_Error(State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1; -- Consume TO

      Parse_Bracketed_Expression(Tokens, State, Tree, Handle_Node, Success);
      if not Success then return; end if;
      Tree(Node).Right_Child := Handle_Node;

      if State.Current_Token > Max_Tokens
        or else Tokens(State.Current_Token).Kind /= Tok_Size
      then
         Set_Error(State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1; -- Consume SIZE

      if State.Current_Token <= Max_Tokens
        and then Tokens(State.Current_Token).Kind = Tok_L_Square
      then
         Parse_Bracketed_Expression(Tokens, State, Tree, Size_Node, Success);
      else
         Parse_Expression(Tokens, State, Tree, Size_Node, Success);
      end if;
      if not Success then return; end if;
      Tree(Handle_Node).Next_Sibling := Size_Node;

      Parse_Feature_Block_Bodies
        (Tokens, State, Tree, Tok_Stream_Bypass, True, Body_Node, Fallback_Node, Success);
      if not Success then return; end if;

      Tree(Size_Node).Next_Sibling := Body_Node;
      Attach_Optional_Fallback(Tree, Body_Node, Fallback_Node);
   end Parse_Stream_Bypass_Block;

   procedure Parse_Synth_Bake_Block (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Target_Node    : Node_Index := 0;
      Format_Node    : Node_Index := 0;
      Body_Node      : Node_Index := 0;
      Fallback_Node  : Node_Index := 0;
   begin
      Allocate_Node(Tokens, State, Tree, AST_Synth_Bake_Block, Node, Success);
      if not Success then return; end if;

      Tree(Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume SYNTH_BAKE

      Parse_Bracketed_Expression(Tokens, State, Tree, Target_Node, Success);
      if not Success then return; end if;
      Tree(Node).Left_Child := Target_Node;

      if State.Current_Token > Max_Tokens
        or else Tokens(State.Current_Token).Kind /= Tok_Format
      then
         Set_Error(State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1; -- Consume FORMAT

      Parse_Expression(Tokens, State, Tree, Format_Node, Success);
      if not Success then return; end if;
      Tree(Node).Right_Child := Format_Node;

      Parse_Feature_Block_Bodies
        (Tokens, State, Tree, Tok_Synth_Bake, True, Body_Node, Fallback_Node, Success);
      if not Success then return; end if;

      Tree(Format_Node).Next_Sibling := Body_Node;
      Attach_Optional_Fallback(Tree, Body_Node, Fallback_Node);
   end Parse_Synth_Bake_Block;

   procedure Parse_Mount_Archive_Block (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Address_Node   : Node_Index := 0;
      File_Node      : Node_Index := 0;
      Body_Node      : Node_Index := 0;
      Fallback_Node  : Node_Index := 0;
   begin
      Allocate_Node(Tokens, State, Tree, AST_Mount_Archive_Block, Node, Success);
      if not Success then return; end if;

      Tree(Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume MOUNT_ARCHIVE

      Parse_Bracketed_Expression(Tokens, State, Tree, Address_Node, Success);
      if not Success then return; end if;
      Tree(Node).Left_Child := Address_Node;

      if State.Current_Token > Max_Tokens
        or else Tokens(State.Current_Token).Kind /= Tok_From
      then
         Set_Error(State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1; -- Consume FROM

      Parse_Bracketed_Expression(Tokens, State, Tree, File_Node, Success);
      if not Success then return; end if;
      Tree(Node).Right_Child := File_Node;

      Parse_Feature_Block_Bodies
        (Tokens, State, Tree, Tok_Mount_Archive, True, Body_Node, Fallback_Node, Success);
      if not Success then return; end if;

      Tree(File_Node).Next_Sibling := Body_Node;
      Attach_Optional_Fallback(Tree, Body_Node, Fallback_Node);
   end Parse_Mount_Archive_Block;



   -- =========================================================================
   -- DA REPEAT LOOP FORGE
   -- =========================================================================
   procedure Parse_Repeat_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Block_Node, Cond_Node : Node_Index;
      First_Stmt, Curr_Stmt, Next_Stmt : Node_Index := 0;
      Found_Until : Boolean := False; -- DA FIX: Explicit tracking flag!
   begin
      Success := False; Node := 0;
      Allocate_Node(Tokens, State, Tree, AST_Repeat_Stmt, Node, Success);
      if not Success then return; end if;
      
      Tree(Node).Token_Index := State.Current_Token; 
      State.Current_Token := State.Current_Token + 1; 
      
      -- 1. Allocate Body Block (Executes first)
      Allocate_Node(Tokens, State, Tree, AST_Block_Stmt, Block_Node, Success);
      if not Success then return; end if;
      Tree(Node).Left_Child := Block_Node;
      
      -- 2. Parse Statements
      for I in 1 .. 16384 loop
         -- DA FIX: Guard against Premature EOF
         if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind = Tok_Error then
            Set_Error(State, Tokens, Err_Parse_Missing_Until); 
            Success := False; 
            return;
         end if;
         
         -- Check for Terminator
         if Tokens(State.Current_Token).Kind = Tok_Until then
            State.Current_Token := State.Current_Token + 1; -- Consume 'UNTIL'
            Found_Until := True; 
            exit;
         end if;
         
         Parse_Statement(Tokens, State, Tree, Next_Stmt, Success);
         if not Success then return; end if;
         
         if First_Stmt = 0 then 
            First_Stmt := Next_Stmt; 
            Tree(Block_Node).Left_Child := First_Stmt;
         else 
            Tree(Curr_Stmt).Next_Sibling := Next_Stmt; 
         end if;
         Curr_Stmt := Next_Stmt;
      end loop;
      
      -- DA FIX: Distinguish between missing UNTIL and genuine Overflow
      if not Found_Until then 
         Set_Error(State, Tokens, Err_Parse_Missing_Until); 
         Success := False;
         return; 
      end if;
      
      -- 3. Parse Condition (Evaluates last)
      Parse_Expression(Tokens, State, Tree, Cond_Node, Success);
      if not Success then return; end if;
      Tree(Node).Right_Child := Cond_Node;

      -- Optional readability closer: END REPEAT
      if State.Current_Token <= Max_Tokens
        and then Tokens(State.Current_Token).Kind = Tok_End
      then
         declare
            End_Line : constant Positive := Tokens(State.Current_Token).Line;
         begin
            State.Current_Token := State.Current_Token + 1; -- Consume END
            if State.Current_Token <= Max_Tokens
              and then Tokens(State.Current_Token).Kind = Tok_Repeat
              and then Tokens(State.Current_Token).Line = End_Line
            then
               State.Current_Token := State.Current_Token + 1; -- Consume REPEAT
            else
               State.Current_Token := State.Current_Token - 1; -- Not END REPEAT; restore END
            end if;
         end;
      end if;
   end Parse_Repeat_Stmt;

   -- =========================================================================
   -- DA PROCEDURE DECLARATION FORGE
   -- =========================================================================
   --  Contextual keyword match for the MCP grammar: SERVER / TOOL /
   --  RESOURCE / DESCRIPTION stay ordinary atoms everywhere else, so
   --  `description` can still be a variable name.
   function Lexeme_Is
     (Tokens : in Token_Array; Idx : Natural; Text : String)
      return Boolean
   is
      Tok : Token;
   begin
      if Idx = 0 or else Idx > Max_Tokens then
         return False;
      end if;
      Tok := Tokens (Idx);
      if Tok.Kind not in Tok_Atom | Tok_Logic_Var
        or else Tok.Length /= Text'Length
      then
         return False;
      end if;
      for I in 0 .. Text'Length - 1 loop
         declare
            C : constant Character := Input_Buffer (Tok.Start + I);
            U : constant Character :=
              (if C in 'a' .. 'z'
               then Character'Val (Character'Pos (C) - 32)
               else C);
         begin
            if U /= Text (Text'First + I) then
               return False;
            end if;
         end;
      end loop;
      return True;
   end Lexeme_Is;

   --  Optional `MCP TOOL [AS "alias"] [DESCRIPTION "d"]` suffix on a
   --  routine signature: registers the routine as an agent-callable
   --  tool.  The registration node rides at the tail of the arg-list
   --  child chain where all walks are kind-guarded.
   procedure Parse_Mcp_Attr
     (Tokens   : in Token_Array;
      State    : in out Parser_State;
      Tree     : in out Node_Array;
      Var_Node : in Node_Index;
      Success  : out Boolean)
   is
      Mcp_Node, Str_Node, List_Node, Tail_Node : Node_Index := 0;
   begin
      Success := True;
      if State.Current_Token > Max_Tokens
        or else Tokens (State.Current_Token).Kind /= Tok_Mcp
      then
         return;
      end if;
      State.Current_Token := State.Current_Token + 1;
      if not Lexeme_Is (Tokens, State.Current_Token, "TOOL") then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1;
      Allocate_Node (Tokens, State, Tree, AST_Mcp_Tool, Mcp_Node, Success);
      if not Success then return; end if;
      Tree (Mcp_Node).Token_Index := Tree (Var_Node).Token_Index;
      if State.Current_Token <= Max_Tokens
        and then Tokens (State.Current_Token).Kind = Tok_As
      then
         State.Current_Token := State.Current_Token + 1;
         if Tokens (State.Current_Token).Kind = Tok_String then
            Allocate_Node (Tokens, State, Tree, AST_String_Expr,
                           Str_Node, Success);
            if not Success then return; end if;
            Tree (Str_Node).Token_Index := State.Current_Token;
            State.Current_Token := State.Current_Token + 1;
            Tree (Mcp_Node).Left_Child := Str_Node;
         else
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
      end if;
      if State.Current_Token <= Max_Tokens
        and then (Tokens (State.Current_Token).Kind = Tok_Descriptor
                  or else Lexeme_Is (Tokens, State.Current_Token,
                                     "DESCRIPTION"))
      then
         State.Current_Token := State.Current_Token + 1;
         if Tokens (State.Current_Token).Kind = Tok_String then
            Allocate_Node (Tokens, State, Tree, AST_String_Expr,
                           Str_Node, Success);
            if not Success then return; end if;
            Tree (Str_Node).Token_Index := State.Current_Token;
            State.Current_Token := State.Current_Token + 1;
            Tree (Mcp_Node).Right_Child := Str_Node;
         else
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
      end if;
      Ensure_Decl_Arg_List
        (Tokens, State, Tree, Var_Node, List_Node, Success);
      if not Success then return; end if;
      if Tree (List_Node).Left_Child = 0 then
         Tree (List_Node).Left_Child := Mcp_Node;
      else
         Tail_Node := Tree (List_Node).Left_Child;
         while Tree (Tail_Node).Next_Sibling /= 0 loop
            Tail_Node := Tree (Tail_Node).Next_Sibling;
         end loop;
         Tree (Tail_Node).Next_Sibling := Mcp_Node;
      end if;
   end Parse_Mcp_Attr;

   procedure Parse_Procedure_Decl (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Var_Node, Body_Node : Node_Index;
      First_Stmt, Curr_Stmt, Next_Stmt : Node_Index := 0;
      Failed_Token : Natural := 0;
   begin
      Success := False; Node := 0;
      
      Allocate_Node(Tokens, State, Tree, AST_Procedure_Decl, Node, Success);
      if not Success then return; end if;
      
      Tree(Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; 

      -- 1. Parse Procedure Name (Guard against rogue tokens)
      if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind not in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States then
         Set_Error(State, Tokens, Err_Parse_Expected_Value); 
         Success := False; 
         return; 
      end if;

      Allocate_Node(Tokens, State, Tree, AST_Var_Expr, Var_Node, Success);
      if not Success then return; end if;
      
      Tree(Var_Node).Token_Index := State.Current_Token; 
      Tree(Node).Left_Child := Var_Node; 
      State.Current_Token := State.Current_Token + 1;

      -- 2. DA NEW PARAMETER LIST FORGE (Flat and expanded to 64 arguments)
      if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_L_Paren then
         State.Current_Token := State.Current_Token + 1; -- Consume '('
         
         declare 
            List_Node, Arg_Node, Last_Arg : Node_Index := 0; 
         begin
            Allocate_Node(Tokens, State, Tree, AST_Arg_List, List_Node, Success);
            if not Success then return; end if;
            Tree(Var_Node).Right_Child := List_Node;

            if Tokens(State.Current_Token).Kind /= Tok_R_Paren then
               for J in 1 .. 64 loop -- Limit synchronized wi' Parse_Expression!
                  
                  -- 1. Optional IN / OUT Parameter Mode
                  declare
                     Param_Mode : Natural := 0; 
                  begin
                     if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind in Tok_In | Tok_Out then
                        Param_Mode := State.Current_Token;
                        State.Current_Token := State.Current_Token + 1; -- Consume IN/OUT
                     end if;

                     -- 2. Allocate the AST_Param_Decl instead o' just a Var_Expr
                     Allocate_Node(Tokens, State, Tree, AST_Param_Decl, Arg_Node, Success);
                     if not Success then return; end if;
                     Tree(Arg_Node).Token_Index := Param_Mode; -- Store the mode token index here!

                     -- Parameter must be a valid name
                     if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind not in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States then
                        Set_Error(State, Tokens, Err_Parse_Expected_Value); 
                        Success := False; 
                        return; 
                     end if;
                     
                     declare 
                        Param_Var_Node : Node_Index; 
                     begin
                        Allocate_Node(Tokens, State, Tree, AST_Var_Expr, Param_Var_Node, Success);
                        Tree(Param_Var_Node).Token_Index := State.Current_Token;
                        Tree(Arg_Node).Left_Child := Param_Var_Node; -- Attach Name to Param Node
                     end;
                     State.Current_Token := State.Current_Token + 1;

                     -- DA FIX: Allow optional 'AS TYPE' in parameter lists!
                     if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_As then
                        State.Current_Token := State.Current_Token + 1; -- Consume AS
                        if State.Current_Token <= Max_Tokens and then Is_Type_Name_Token (Tokens(State.Current_Token).Kind)
                        then
                           declare 
                              Type_Node : Node_Index; 
                           begin
                              Allocate_Node(Tokens, State, Tree, AST_Var_Expr, Type_Node, Success);
                              Tree(Type_Node).Token_Index := State.Current_Token;
                              Tree(Arg_Node).Right_Child := Type_Node; -- Attach Type to Param Node
                           end;
                           State.Current_Token := State.Current_Token + 1; -- Consume the Type Name
                        else
                           Set_Error(State, Tokens, Err_Parse_Expected_Value);
                           Success := False; 
                           return;
                        end if;
                     end if;

                     if Last_Arg = 0 then
                        Tree(List_Node).Left_Child := Arg_Node;
                     else 
                        Tree(Last_Arg).Next_Sibling := Arg_Node; 
                     end if;
                     Last_Arg := Arg_Node;

                     -- Check for comma or closing paren
                     if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Comma then 
                        State.Current_Token := State.Current_Token + 1;
                     elsif State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_R_Paren then 
                        exit;
                     else 
                        Set_Error(State, Tokens, Err_Parse_Missing_Bracket); 
                        Success := False; 
                        return; 
                     end if;
                  end;
               end loop;
            end if;
            
            -- Guard: Expect closing paren
            if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_R_Paren then
               State.Current_Token := State.Current_Token + 1;
            else 
               Set_Error(State, Tokens, Err_Parse_Missing_Bracket); 
               Success := False; 
               return; 
            end if;
         end;
      end if;

      -- =========================================================================
      -- DA CONTRACT FORGE (REQUIRE / ENSURE)
      -- =========================================================================
      declare
         Bind_Node, Req_Node, Ens_Node, Expr_Node : Node_Index := 0;
         Anchor_Node, Tail_Node        : Node_Index := 0;
      begin
         Parse_Optional_Bound_To_Clause (Tokens, State, Tree, Bind_Node, Success);
         if not Success then return; end if;

         -- Parse REQUIRE
         if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Require then
            State.Current_Token := State.Current_Token + 1;
            Allocate_Node(Tokens, State, Tree, AST_Require_Clause, Req_Node, Success);
            if not Success then return; end if;
            
            Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
            if not Success then return; end if;
            Tree(Req_Node).Left_Child := Expr_Node;
         end if;

         -- Parse ENSURE
         if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Ensure then
            State.Current_Token := State.Current_Token + 1;
            Allocate_Node(Tokens, State, Tree, AST_Ensure_Clause, Ens_Node, Success);
            if not Success then return; end if;
            
            Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
            if not Success then return; end if;
            Tree(Ens_Node).Left_Child := Expr_Node;
         end if;
         
         -- DA FIX: Safely chain Contracts as Siblings to the Argument List!
         -- This prevents Var_Node frae thinking it's an Array Access!
         if Bind_Node > 0 or else Req_Node > 0 or else Ens_Node > 0 then
            Ensure_Decl_Arg_List (Tokens, State, Tree, Var_Node, Anchor_Node, Success);
            if not Success then return; end if;

            Tail_Node := Anchor_Node;
            while Tree (Tail_Node).Next_Sibling /= 0 loop
               Tail_Node := Tree (Tail_Node).Next_Sibling;
            end loop;

            if Bind_Node > 0 then
               Tree (Tail_Node).Next_Sibling := Bind_Node;
               Tail_Node := Bind_Node;
            end if;

            if Req_Node > 0 then
               Tree (Tail_Node).Next_Sibling := Req_Node;
               Tail_Node := Req_Node;
            end if;

            if Ens_Node > 0 then
               Tree (Tail_Node).Next_Sibling := Ens_Node;
            end if;
         end if;
      end;

      --  MCP TOOL attribute: register this routine as an agent tool
      Parse_Mcp_Attr (Tokens, State, Tree, Var_Node, Success);
      if not Success then return; end if;

      -- DA FIX: Consume optional BEGIN for Ada-style signatures!
      if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Begin then
         State.Current_Token := State.Current_Token + 1;
      end if;

      -- Parse Body Block
      Allocate_Node(Tokens, State, Tree, AST_Block_Stmt, Body_Node, Success);
      if not Success then return; end if;
      Tree(Node).Right_Child := Body_Node;
      
      for I in 1 .. 16384 loop
         -- DA INTERFACE AUTO-CLOSER!
         -- If we immediately hit anither declaration or a module terminator,
         -- this is just a signature.
         if Tokens(State.Current_Token).Kind in Tok_Function | Tok_Procedure | Tok_EndModule then
            Success := True; 
            return;
         end if;

         if Is_Bare_End (Tokens, State)
           or else Same_Line_End_Tag (Tokens, State, Tok_Procedure)
         then
            declare
               End_Line : constant Positive := Tokens (State.Current_Token).Line;
            begin
               State.Current_Token := State.Current_Token + 1;
               if State.Current_Token <= Max_Tokens
                 and then Tokens (State.Current_Token).Kind = Tok_Procedure
                 and then Tokens (State.Current_Token).Line = End_Line
               then
                  State.Current_Token := State.Current_Token + 1;
               end if;
               Success := True;
               return;
            end;
         elsif Same_Line_End_Tag (Tokens, State, Tok_Module)
           or else Same_Line_End_Tag (Tokens, State, Tok_DeclareModule)
         then
            Success := True;
            return;
         end if;
         
         Failed_Token := State.Current_Token;
         Parse_Statement(Tokens, State, Tree, Next_Stmt, Success);
         if not Success then 
            -- DA PANIC MODE INTERCEPT!
            Recover_After_Stmt_Error (Tokens, State, Failed_Token);
            Next_Stmt := 0;
            Success := True;
         end if;
         
         if Next_Stmt /= 0 then
            if First_Stmt = 0 then 
               First_Stmt := Next_Stmt;
               Tree(Body_Node).Left_Child := First_Stmt;
            else 
               Tree(Curr_Stmt).Next_Sibling := Next_Stmt;
            end if;
            Curr_Stmt := Next_Stmt;
         end if;
      end loop;
      
      -- True Block Overflow
      Success := False; 
      Set_Error(State, Tokens, Err_Parse_Block_Overflow);
   end Parse_Procedure_Decl;
   
   
   -- =========================================================================
   -- DA FUNCTION DECLARATION FORGE
   -- =========================================================================
   procedure Parse_Function_Decl (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Var_Node, Body_Node : Node_Index;
      First_Stmt, Curr_Stmt, Next_Stmt : Node_Index := 0;
      RS_Stat : Boolean;
      Ival : RS_Interval;
      Failed_Token : Natural := 0;
   begin
      Success := False; Node := 0;
      
      -- NASA/JPL Compliant Range Spec validation!
      Create(1.0, Long_Float(Max_Tokens), Ival, RS_Stat);
      pragma Assert (RS_Stat, "Token State out of bounds");

      Allocate_Node(Tokens, State, Tree, AST_Function_Decl, Node, Success);
      if not Success then return; end if;
      
      pragma Assert (Node > 0, "Failed tae allocate valid AST node");
      
      -- Stash a default type index of 0 just in case
      Tree(Node).Token_Index := 0; 
      State.Current_Token := State.Current_Token + 1; -- Consume FUNCTION

      -- 1. Parse Function Name
      if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind not in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States then
         Set_Error(State, Tokens, Err_Parse_Expected_Value); 
         Success := False; 
         return; 
      end if;

      Allocate_Node(Tokens, State, Tree, AST_Var_Expr, Var_Node, Success);
      if not Success then return; end if;
      
      Tree(Var_Node).Token_Index := State.Current_Token; 
      Tree(Node).Left_Child := Var_Node;
      State.Current_Token := State.Current_Token + 1;

      -- 2. Parameter List (Same as Procedures)
      if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_L_Paren then
         State.Current_Token := State.Current_Token + 1; -- Consume '('
         declare 
            List_Node, Arg_Node, Last_Arg : Node_Index := 0; 
         begin
            Allocate_Node(Tokens, State, Tree, AST_Arg_List, List_Node, Success);
            if not Success then return; end if;
            Tree(Var_Node).Right_Child := List_Node;

            if Tokens(State.Current_Token).Kind /= Tok_R_Paren then
               for J in 1 .. 64 loop 
                  -- 1. Optional IN / OUT Parameter Mode
                  declare
                     Param_Mode : Natural := 0; 
                  begin
                     if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind in Tok_In | Tok_Out then
                        Param_Mode := State.Current_Token;
                        State.Current_Token := State.Current_Token + 1; -- Consume IN/OUT
                     end if;

                     -- 2. Allocate the AST_Param_Decl instead o' just a Var_Expr
                     Allocate_Node(Tokens, State, Tree, AST_Param_Decl, Arg_Node, Success);
                     if not Success then return; end if;
                     Tree(Arg_Node).Token_Index := Param_Mode; -- Store the mode token index here!

                     -- Parameter must be a valid name
                     if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind not in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States then
                        Set_Error(State, Tokens, Err_Parse_Expected_Value); Success := False; return; 
                     end if;
                     
                     declare 
                        Param_Var_Node : Node_Index; 
                     begin
                        Allocate_Node(Tokens, State, Tree, AST_Var_Expr, Param_Var_Node, Success);
                        Tree(Param_Var_Node).Token_Index := State.Current_Token;
                        Tree(Arg_Node).Left_Child := Param_Var_Node; -- Attach Name to Param Node
                     end;
                     State.Current_Token := State.Current_Token + 1;

                     -- DA FIX: Allow optional 'AS TYPE' in parameter lists!
                     if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_As then
                        State.Current_Token := State.Current_Token + 1; -- Consume AS
                        if State.Current_Token <= Max_Tokens and then Is_Type_Name_Token (Tokens(State.Current_Token).Kind)
                        then
                           declare 
                              Type_Node : Node_Index; 
                           begin
                              Allocate_Node(Tokens, State, Tree, AST_Var_Expr, Type_Node, Success);
                              Tree(Type_Node).Token_Index := State.Current_Token;
                              Tree(Arg_Node).Right_Child := Type_Node; -- Attach Type to Param Node
                           end;
                           State.Current_Token := State.Current_Token + 1; -- Consume the Type Name
                        else
                           Set_Error(State, Tokens, Err_Parse_Expected_Value);
                           Success := False; 
                           return;
                        end if;
                     end if;

                     if Last_Arg = 0 then
                        Tree(List_Node).Left_Child := Arg_Node;
                     else Tree(Last_Arg).Next_Sibling := Arg_Node; end if;
                     Last_Arg := Arg_Node;

                     if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Comma then 
                        State.Current_Token := State.Current_Token + 1;
                     elsif State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_R_Paren then 
                        exit;
                     else 
                        Set_Error(State, Tokens, Err_Parse_Missing_Bracket); Success := False; return; 
                     end if;
                  end;
               end loop;
            end if;
            if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_R_Paren then
               State.Current_Token := State.Current_Token + 1;
            else 
               Set_Error(State, Tokens, Err_Parse_Missing_Bracket); Success := False; return; 
            end if;
         end;
      end if;

      -- 3. DA NEW RETURN TYPE FORGE (AS <Type>)
      if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_As then
         State.Current_Token := State.Current_Token + 1; -- Consume AS
         if State.Current_Token <= Max_Tokens and then Is_Type_Name_Token (Tokens(State.Current_Token).Kind)
         then
            Tree(Node).Token_Index := State.Current_Token; -- Store Return Type
            State.Current_Token := State.Current_Token + 1;
         else
            Set_Error(State, Tokens, Err_Parse_Expected_Value); Success := False; return;
         end if;
      end if;

      -- =========================================================================
      -- DA CONTRACT FORGE (REQUIRE / ENSURE)
      -- =========================================================================
      declare
         Bind_Node, Req_Node, Ens_Node, Expr_Node : Node_Index := 0;
         Anchor_Node, Tail_Node        : Node_Index := 0;
      begin
         Parse_Optional_Bound_To_Clause (Tokens, State, Tree, Bind_Node, Success);
         if not Success then return; end if;

         -- Parse REQUIRE
         if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Require then
            State.Current_Token := State.Current_Token + 1;
            Allocate_Node(Tokens, State, Tree, AST_Require_Clause, Req_Node, Success);
            if not Success then return; end if;
            
            Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
            if not Success then return; end if;
            Tree(Req_Node).Left_Child := Expr_Node;
         end if;

         -- Parse ENSURE
         if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Ensure then
            State.Current_Token := State.Current_Token + 1;
            Allocate_Node(Tokens, State, Tree, AST_Ensure_Clause, Ens_Node, Success);
            if not Success then return; end if;
            
            Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
            if not Success then return; end if;
            Tree(Ens_Node).Left_Child := Expr_Node;
         end if;
         
         -- DA FIX: Safely chain Contracts as Siblings to the Argument List!
         -- This prevents Var_Node frae thinking it's an Array Access!
         if Bind_Node > 0 or else Req_Node > 0 or else Ens_Node > 0 then
            Ensure_Decl_Arg_List (Tokens, State, Tree, Var_Node, Anchor_Node, Success);
            if not Success then return; end if;

            Tail_Node := Anchor_Node;
            while Tree (Tail_Node).Next_Sibling /= 0 loop
               Tail_Node := Tree (Tail_Node).Next_Sibling;
            end loop;

            if Bind_Node > 0 then
               Tree (Tail_Node).Next_Sibling := Bind_Node;
               Tail_Node := Bind_Node;
            end if;

            if Req_Node > 0 then
               Tree (Tail_Node).Next_Sibling := Req_Node;
               Tail_Node := Req_Node;
            end if;

            if Ens_Node > 0 then
               Tree (Tail_Node).Next_Sibling := Ens_Node;
            end if;
         end if;
      end;

      --  MCP TOOL attribute: register this routine as an agent tool
      Parse_Mcp_Attr (Tokens, State, Tree, Var_Node, Success);
      if not Success then return; end if;

      -- DA FIX: Consume optional BEGIN for Ada-style signatures!
      if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Begin then
         State.Current_Token := State.Current_Token + 1;
      end if;

      -- Parse Body Block
      Allocate_Node(Tokens, State, Tree, AST_Block_Stmt, Body_Node, Success);
      if not Success then return; end if;
      Tree(Node).Right_Child := Body_Node;

      for I in 1 .. 16384 loop
         -- DA INTERFACE AUTO-CLOSER!
         if Tokens(State.Current_Token).Kind in Tok_Function | Tok_Procedure | Tok_EndModule then
            Success := True; 
            return;
         end if;

         if Is_Bare_End (Tokens, State)
           or else Same_Line_End_Tag (Tokens, State, Tok_Function)
         then
            declare
               End_Line : constant Positive := Tokens (State.Current_Token).Line;
            begin
               State.Current_Token := State.Current_Token + 1;
               if State.Current_Token <= Max_Tokens
                 and then Tokens (State.Current_Token).Kind = Tok_Function
                 and then Tokens (State.Current_Token).Line = End_Line
               then
                  State.Current_Token := State.Current_Token + 1;
               end if;
               Success := True;
               return;
            end;
         elsif Same_Line_End_Tag (Tokens, State, Tok_Module)
           or else Same_Line_End_Tag (Tokens, State, Tok_DeclareModule)
         then
            Success := True;
            return;
         end if;
         
         Failed_Token := State.Current_Token;
         Parse_Statement(Tokens, State, Tree, Next_Stmt, Success);
         if not Success then 
            -- DA PANIC MODE INTERCEPT!
            Recover_After_Stmt_Error (Tokens, State, Failed_Token);
            Next_Stmt := 0;
            Success := True;
         end if;
         
         if Next_Stmt /= 0 then
            if First_Stmt = 0 then 
               First_Stmt := Next_Stmt;
               Tree(Body_Node).Left_Child := First_Stmt;
            else 
               Tree(Curr_Stmt).Next_Sibling := Next_Stmt;
            end if;
            Curr_Stmt := Next_Stmt;
         end if;
      end loop;
      
      Success := False;
      Set_Error(State, Tokens, Err_Parse_Block_Overflow);
   end Parse_Function_Decl;

   --  -- =========================================================================
   --  -- DA RETURN STATEMENT FORGE
   --  -- =========================================================================
   --  procedure Parse_Return (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
   --     Expr_Node : Node_Index;
   --  begin
   --     Allocate_Node(Tokens, State, Tree, AST_Return_Stmt, Node, Success);
   --     if not Success then return; end if;
   --     Tree(Node).Token_Index := State.Current_Token;
   --     State.Current_Token := State.Current_Token + 1; -- Consume RETURN
   --  
   --     Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
   --     if Success then
   --        Tree(Node).Left_Child := Expr_Node;
   --     end if;
   --  end Parse_Return;
   
   -- =========================================================================
   -- DA RETURN STATEMENT FORGE
   -- RETURN expr  => function/value return
   -- RETURN       => bare procedure early-exit
   -- =========================================================================
   procedure Parse_Return
     (Tokens  : in Token_Array;
      State   : in out Parser_State;
      Tree    : in out Node_Array;
      Node    : out Node_Index;
      Success : out Boolean)
   is
      Expr_Node   : Node_Index := 0;
      Return_Line : Positive := 1;
   begin
      Allocate_Node(Tokens, State, Tree, AST_Return_Stmt, Node, Success);
      if not Success then
         return;
      end if;

      Tree(Node).Token_Index := State.Current_Token;
      Return_Line := Tokens(State.Current_Token).Line;
      State.Current_Token := State.Current_Token + 1; -- Consume RETURN

      -- RETURN() is a valid explicit bare return.
      if State.Current_Token + 1 <= Max_Tokens
        and then Tokens(State.Current_Token).Kind = Tok_L_Paren
        and then Tokens(State.Current_Token + 1).Kind = Tok_R_Paren
      then
         State.Current_Token := State.Current_Token + 2;
         Tree(Node).Left_Child := 0;
         Success := True;
         return;
      end if;

      -- Bare RETURN is valid when the next token starts a new line or closes a block.
      if State.Current_Token > Max_Tokens
        or else Tokens(State.Current_Token).Kind = Tok_Error
        or else Tokens(State.Current_Token).Line > Return_Line
        or else Tokens(State.Current_Token).Kind in Tok_End | Tok_Else
      then
         Tree(Node).Left_Child := 0;
         Success := True;
         return;
      end if;

      Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
      if not Success then
         return;
      end if;

      Tree(Node).Left_Child := Expr_Node;
   end Parse_Return;


   -- =========================================================================
   -- DA STRUCT DECLARATION FORGE
   -- =========================================================================
   procedure Parse_Struct (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Name_Node, Block_Node : Node_Index;
   begin
      Allocate_Node(Tokens, State, Tree, AST_Struct_Decl, Node, Success);
      if not Success then return; end if;
      Tree(Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume STRUCT
      
      -- 1. Parse the Struct Name (Guard Clause)
      if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind not in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States then
         Set_Error(State, Tokens, Err_Parse_Expected_Value); 
         Success := False; 
         return; 
      end if;
      
      Allocate_Node(Tokens, State, Tree, AST_Var_Expr, Name_Node, Success);
      if not Success then return; end if;
      Tree(Name_Node).Token_Index := State.Current_Token; 
      State.Current_Token := State.Current_Token + 1;
      Tree(Node).Left_Child := Name_Node;
      
      -- 2. Allocate the Block Node for the fields
      Allocate_Node(Tokens, State, Tree, AST_Block_Stmt, Block_Node, Success);
      if not Success then return; end if;
      Tree(Node).Right_Child := Block_Node;
      
      declare 
         Prev : Node_Index := 0; 
         Curr : Node_Index;
      begin
         -- Bounded Loop: Max 1024 fields per Struct!
         for I in 1 .. 1024 loop 
            
            -- DA FIX 1: Explicit EOF Guard
            if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind = Tok_Error then
               Set_Error(State, Tokens, Err_Parse_Expected_Value); 
               Success := False; 
               return;
            end if;
            
            -- Exit loop when we hit END
            if Tokens(State.Current_Token).Kind = Tok_End then
               exit;
            end if;
            
            -- DA NEW BITFIELD INTERCEPTOR
            if Tokens(State.Current_Token).Kind = Tok_Bitfield then
               Allocate_Node(Tokens, State, Tree, AST_Bitfield_Decl, Curr, Success);
               if not Success then return; end if;
               Tree(Curr).Token_Index := State.Current_Token;
               State.Current_Token := State.Current_Token + 1; -- Consume BITFIELD
               
               -- 1. Parse Field Name
               declare Expr_Node : Node_Index; begin
                  Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
                  if not Success then return; end if;
                  Tree(Curr).Left_Child := Expr_Node;
               end;
               
               -- Guard: Expect ':' 
               if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_Colon then
                  Set_Error(State, Tokens, Err_Parse_Expected_Value); Success := False; return;
               end if;
               State.Current_Token := State.Current_Token + 1; -- Consume ':'
               
               -- 2. Parse Bit Width (Must evaluate tae a constant!)
               declare Expr_Node : Node_Index; begin
                  Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
                  if not Success then return; end if;
                  Tree(Curr).Right_Child := Expr_Node;
               end;
               
               -- Skip the rest o' the normal field parsing for this loop iteration
               goto Bind_Sibling; 
            end if;

            -- Allow optional 'LET' keyword for struct fields
            if Tokens(State.Current_Token).Kind = Tok_Let then
               State.Current_Token := State.Current_Token + 1;
            end if;
            
            -- Guard: Field name must be an Atom or Logic Var
            if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind not in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States then
               Set_Error(State, Tokens, Err_Parse_Expected_Value); 
               Success := False; 
               return; 
            end if;
            
            Allocate_Node(Tokens, State, Tree, AST_Null, Curr, Success);
            if not Success then return; end if;
            
            declare 
               Var_Node : Node_Index;
            begin
               Allocate_Node(Tokens, State, Tree, AST_Var_Expr, Var_Node, Success);
               if not Success then return; end if;
               Tree(Var_Node).Token_Index := State.Current_Token;
               Tree(Curr).Left_Child := Var_Node;
               State.Current_Token := State.Current_Token + 1;
            end;
            
            -- Optional AS Type
            if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_As then
               State.Current_Token := State.Current_Token + 1;
               
               if State.Current_Token <= Max_Tokens and then Is_Type_Name_Token (Tokens(State.Current_Token).Kind)
               then
                  Tree(Curr).Token_Index := State.Current_Token;
                  State.Current_Token := State.Current_Token + 1;
                  -- Safety Trap: Variables and Fields cannot be Void
                  if Tokens(State.Current_Token - 1).Kind = Tok_U0 then
                     Set_Error(State, Tokens, Err_Parse_Expected_Value);
                     Success := False;
                     return;
                  end if;
               else 
                  Set_Error(State, Tokens, Err_Parse_Expected_Value); 
                  Success := False; 
                  return; 
               end if;
            end if;
            
            -- Optional '= Expr' initialization
            if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Assign then
               State.Current_Token := State.Current_Token + 1;
               declare 
                  Dummy_Expr : Node_Index; 
               begin
                  Parse_Expression(Tokens, State, Tree, Dummy_Expr, Success);
                  if not Success then return; end if;
                  Tree(Curr).Right_Child := Dummy_Expr;
               end;
            end if;
            
            
            <<Bind_Sibling>> -- DA FIX: Jump here if it was a BITFIELD!
            -- Sibling Binding
            if Prev = 0 then 
               Tree(Block_Node).Left_Child := Curr; 
            else 
               Tree(Prev).Next_Sibling := Curr; 
            end if;
            Prev := Curr;
            
         end loop;
      end;
      
      -- 3. Parse END STRUCT
      -- DA FIX 2: Flattened Error Guards!
      if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_End then
         Set_Error(State, Tokens, Err_Parse_Expected_Value); 
         Success := False; 
         return; 
      end if;
      
      declare
         End_Line : Positive := Tokens(State.Current_Token).Line;
      begin
         State.Current_Token := State.Current_Token + 1; -- Consume END
         
         -- Consume optional 'STRUCT' token ONLY if it shares the same line!
         if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Struct 
            and then Tokens(State.Current_Token).Line = End_Line 
         then 
            State.Current_Token := State.Current_Token + 1;
         end if;
      end;
      
      Success := True;
   end Parse_Struct;
   
   -- --------------------------------------------------------------------
   -- DA KNOWLEDGE FACT FORGE (KNOWS atom IS value)
   -- --------------------------------------------------------------------
   procedure Parse_Knows_Fact (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Atom_Node, Val_Node : Node_Index;
   begin
      Allocate_Node(Tokens, State, Tree, AST_Knows_Fact, Node, Success);
      if not Success then return; end if;
      
      Tree(Node).Token_Index := State.Current_Token; 
      State.Current_Token := State.Current_Token + 1; -- Consume 'KNOWS'
      
      -- DA FIX: Use Parse_Primary sae it accepts Numbers, Strings, and Vars!
      Parse_Primary(Tokens, State, Tree, Atom_Node, Success);
      if not Success then return; end if;
      Tree(Node).Left_Child := Atom_Node;

      -- Guard: Expect 'IS'
      if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_Is then
         Set_Error(State, Tokens, Err_Parse_Expected_Value); 
         Success := False; 
         return;
      end if;
      State.Current_Token := State.Current_Token + 1; -- Consume 'IS'

      -- Parse Value (Right child)
      Parse_Primary(Tokens, State, Tree, Val_Node, Success);
      if Success then 
         Tree(Node).Right_Child := Val_Node; 
      end if;
   end Parse_Knows_Fact;

   -- --------------------------------------------------------------------
   -- DA KNOWLEDGE QUERY FORGE (KNOWS atom)
   -- --------------------------------------------------------------------
   procedure Parse_Knows_Query (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Atom_Node : Node_Index;
   begin
      Allocate_Node(Tokens, State, Tree, AST_Knows_Query, Node, Success);
      if not Success then return; end if;
      
      Tree(Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume 'KNOWS'
      
      -- DA FIX: Use Parse_Primary!
      Parse_Primary(Tokens, State, Tree, Atom_Node, Success);
      if not Success then return; end if;
      Tree(Node).Left_Child := Atom_Node;
   end Parse_Knows_Query;

   -- --------------------------------------------------------------------
   -- DA FIND QUERY FORGE (FIND logic_var)
   -- --------------------------------------------------------------------
   procedure Parse_Find_Query (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Var_Node : Node_Index;
   begin
      Allocate_Node(Tokens, State, Tree, AST_Find_Query, Node, Success);
      if not Success then return; end if;
      
      Tree(Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume 'FIND'
      
      -- DA FIX: Use Parse_Primary!
      Parse_Primary(Tokens, State, Tree, Var_Node, Success);
      if not Success then return; end if;
      Tree(Node).Left_Child := Var_Node;
   end Parse_Find_Query;
   
   -- --------------------------------------------------------------------
   -- DA FINDALL FORGE (FINDALL predicate(X) INTO array)
   -- --------------------------------------------------------------------
   procedure Parse_Findall_Query (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Pred_Node, Var_Node : Node_Index;
      Uses_Parens         : Boolean := False;
   begin
      Allocate_Node(Tokens, State, Tree, AST_Findall_Query, Node, Success);
      if not Success then return; end if;
      
      Tree(Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume 'FINDALL'

      if State.Current_Token <= Max_Tokens
        and then Tokens(State.Current_Token).Kind = Tok_L_Paren
      then
         Uses_Parens := True;
         State.Current_Token := State.Current_Token + 1;
      end if;

      -- 1. Parse Predicate (Left Child)
      Parse_Predicate(Tokens, State, Tree, Pred_Node, Success);
      if not Success then return; end if;
      Tree(Node).Left_Child := Pred_Node;

      -- 2. Accept legacy INTO or softer comma separator.
      if State.Current_Token > Max_Tokens
        or else Tokens(State.Current_Token).Kind not in Tok_Into | Tok_Comma
      then
         Set_Error(State, Tokens, Err_Parse_Expected_Value); 
         Success := False; 
         return;
      end if;
      State.Current_Token := State.Current_Token + 1; -- Consume 'INTO' or ','

      -- 3. Guard: Expect Target Array (Right Child)
      if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind not in Tok_Atom | Tok_Logic_Var | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States then
         Set_Error(State, Tokens, Err_Parse_Expected_Value); 
         Success := False; 
         return;
      end if;
      
      Allocate_Node(Tokens, State, Tree, AST_Var_Expr, Var_Node, Success);
      if not Success then return; end if;
      
      Tree(Var_Node).Token_Index := State.Current_Token;
      Tree(Node).Right_Child := Var_Node;
      State.Current_Token := State.Current_Token + 1;

      if Uses_Parens then
         if State.Current_Token <= Max_Tokens
           and then Tokens(State.Current_Token).Kind = Tok_R_Paren
         then
            State.Current_Token := State.Current_Token + 1;
         else
            Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
            Success := False;
            return;
         end if;
      end if;
   end Parse_Findall_Query;

   -- --------------------------------------------------------------------
   -- DA PREDICATE DECLARATION FORGE
   -- --------------------------------------------------------------------
   procedure Parse_Predicate_Decl (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Pred_Node : Node_Index;
   begin
      Allocate_Node(Tokens, State, Tree, AST_Predicate_Decl, Node, Success);
      if not Success then return; end if;
      
      Tree(Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume PREDICATE
      
      Parse_Predicate(Tokens, State, Tree, Pred_Node, Success);
      if Success then 
         Tree(Node).Left_Child := Pred_Node; 
      end if;
   end Parse_Predicate_Decl;
   
   -- --------------------------------------------------------------------
   -- DA RULE AND CONSTRAINT FORGE (Horn Clauses)
   -- --------------------------------------------------------------------
   procedure Parse_Rule_Decl (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Head_Node, Body_Node, Curr_Pred, Last_Pred : Node_Index := 0;
      Found_Terminator : Boolean := False; -- Dot or clean line end / EOF
   begin
      -- Determine if it's a RULE or a CONSTRAINT
      if Tokens(State.Current_Token).Kind = Tok_Rule then
         Allocate_Node(Tokens, State, Tree, AST_Rule_Decl, Node, Success);
      else
         Allocate_Node(Tokens, State, Tree, AST_Constraint_Decl, Node, Success);
      end if;
      if not Success then return; end if;
      
      Tree(Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1;

      Parse_Predicate(Tokens, State, Tree, Head_Node, Success);
      
      -- DA ARMOR FIX: Explicitly set the error if the Head Predicate is garbage!
      if not Success then 
         Set_Error(State, Tokens, Err_Parse_Expected_Value); 
         return; 
      end if;
      
      Tree(Node).Left_Child := Head_Node;

      -- Guard: Expect Horn Clause (':-')
      if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_Horn_Clause then
         Set_Error(State, Tokens, Err_Parse_Expected_Value); 
         Success := False; 
         return;
      end if;
      State.Current_Token := State.Current_Token + 1;

      Allocate_Node(Tokens, State, Tree, AST_Query, Body_Node, Success);
      if not Success then return; end if;
      Tree(Node).Right_Child := Body_Node;

      -- Parse Body Predicates (Expanded to 64)
      for I in 1 .. 64 loop
         if State.Current_Token <= Max_Tokens
           and then Tokens(State.Current_Token).Kind = Tok_Cut
         then
            --  `!` commit barrier: clause-commitment marker inside rule
            --  bodies (once all terms before it match, later rules for
            --  the same head are never tried).
            Allocate_Node(Tokens, State, Tree, AST_Cut_Stmt, Curr_Pred, Success);
            if not Success then return; end if;
            Tree(Curr_Pred).Token_Index := State.Current_Token;
            State.Current_Token := State.Current_Token + 1;
         else
            Parse_Expression(Tokens, State, Tree, Curr_Pred, Success);
            if not Success then return; end if;
         end if;

         if Last_Pred = 0 then 
            Tree(Body_Node).Left_Child := Curr_Pred;
         else 
            Tree(Last_Pred).Next_Sibling := Curr_Pred; 
         end if;
         Last_Pred := Curr_Pred;

         -- Check for Comma (continue), Dot (terminate), or clean line end / EOF.
         if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Comma then
            State.Current_Token := State.Current_Token + 1;
         elsif State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Dot then
            State.Current_Token := State.Current_Token + 1;
            Found_Terminator := True;
            exit;
         elsif State.Current_Token > Max_Tokens
           or else Tokens(State.Current_Token).Kind = Tok_Error
           or else (State.Current_Token > 1
             and then Tokens(State.Current_Token).Line /= Tokens(State.Current_Token - 1).Line)
         then
            Found_Terminator := True;
            exit;
         else
            Set_Error(State, Tokens, Err_Parse_Expected_Value); 
            Success := False; 
            return;
         end if;
      end loop;
      
      -- DA FIX: Ensure the rule actually finished cleanly.
      if not Found_Terminator then
         Set_Error(State, Tokens, Err_Parse_Block_Overflow); 
         Success := False;
         return;
      end if;
   end Parse_Rule_Decl;
   
   procedure Parse_Constraint_Decl (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
   begin
      Parse_Rule_Decl(Tokens, State, Tree, Node, Success);
   end Parse_Constraint_Decl;

   -- --------------------------------------------------------------------
   -- DA MATCH STATEMENT FORGE
   -- --------------------------------------------------------------------
   procedure Parse_Match_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Expr_Node, First_Case, Last_Case, Curr_Case : Node_Index := 0;
      Match_Line                                  : Positive := 1;
      Saw_Default                                 : Boolean := False;
   begin
      Allocate_Node(Tokens, State, Tree, AST_Match_Stmt, Node, Success);
      if not Success then return; end if;
      
      Tree(Node).Token_Index := State.Current_Token; 
      Match_Line := Tokens (State.Current_Token).Line;
      State.Current_Token := State.Current_Token + 1; -- Consume MATCH

      Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
      if not Success then return; end if;
      Tree(Node).Left_Child := Expr_Node;

      -- Optional "OF" on the MATCH header line only.
      if State.Current_Token <= Max_Tokens
        and then Tokens(State.Current_Token).Line = Match_Line
        and then Tokens(State.Current_Token).Kind in Tok_Atom | Tok_Logic_Var | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States | Tok_String_Type
        and then not Starts_Match_Arm (Tokens, State)
      then
         State.Current_Token := State.Current_Token + 1;
      end if;

      for I in 1 .. 128 loop
         -- DA FIX: Titanium EOF Guard
         if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind = Tok_Error then
            Set_Error(State, Tokens, Err_Parse_Expected_Value); 
            Success := False; 
            return;
         end if;
         
         if Tokens(State.Current_Token).Kind = Tok_End then
            State.Current_Token := State.Current_Token + 1;
            -- Optional 'MATCH' after 'END'
            if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Match then 
               State.Current_Token := State.Current_Token + 1; 
            end if;
            Success := True; 
            return;
         end if;

         if Saw_Default then
            Set_Error(State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         
         -- Parse Individual Case
         Allocate_Node(Tokens, State, Tree, AST_Case_Stmt, Curr_Case, Success);
         if not Success then return; end if;
         
         declare 
            Cond_Node, Body_Node : Node_Index := 0;
            Is_Default           : Boolean := False;
         begin
            if Tokens(State.Current_Token).Kind = Tok_Else then
               Is_Default := True;
               Saw_Default := True;
               State.Current_Token := State.Current_Token + 1;
            else
               Parse_Expression(Tokens, State, Tree, Cond_Node, Success);
               if not Success then return; end if;
               Tree(Curr_Case).Left_Child := Cond_Node;
            end if;
            
            -- Guard: Expect Arrow (=>)
            if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_Arrow then
               Set_Error(State, Tokens, Err_Parse_Expected_Value); 
               Success := False; 
               return; 
            end if;
            State.Current_Token := State.Current_Token + 1;

            Parse_Case_Body
              (Tokens            => Tokens,
               State             => State,
               Tree              => Tree,
               Body_Node         => Body_Node,
               Stop_On_Case      => False,
               Stop_On_Else      => True,
               Stop_On_Match_Arm => True,
               Success           => Success);
            if not Success then return; end if;
            Tree(Curr_Case).Right_Child := Body_Node;

            if Is_Default
              and then (State.Current_Token > Max_Tokens
                or else Tokens(State.Current_Token).Kind /= Tok_End)
            then
               Set_Error(State, Tokens, Err_Parse_Expected_Value);
               Success := False;
               return;
            end if;
         end;
         
         -- Bind Siblings
         if First_Case = 0 then 
            First_Case := Curr_Case; 
            Tree(Node).Right_Child := First_Case;
         else 
            Tree(Last_Case).Next_Sibling := Curr_Case; 
         end if;
         Last_Case := Curr_Case;
         
      end loop;
      
      -- If we hit 128 cases without an END
      Set_Error(State, Tokens, Err_Parse_Block_Overflow);
      Success := False;
   end Parse_Match_Stmt;
   
   -- =========================================================================
   -- MCP (Model Context Protocol) SERVER SURFACE
   --    MCP SERVER "name" [VERSION "x.y"]
   --        TOOL Proc [AS "alias"] [DESCRIPTION "d"]
   --        RESOURCE "uri" -> Func [AS "name"]
   --    END MCP
   --    MCP TOOL Proc ...        (standalone registration)
   --    MCP RESOURCE "uri" -> Func
   -- =========================================================================
   procedure Parse_Mcp_String (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
   begin
      Node := 0;
      if State.Current_Token > Max_Tokens
        or else Tokens (State.Current_Token).Kind /= Tok_String
      then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      Allocate_Node (Tokens, State, Tree, AST_String_Expr, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1;
   end Parse_Mcp_String;

   --  TOOL <ident> [AS "alias"] [DESCRIPTION "desc"]
   procedure Parse_Mcp_Tool (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Str_Node : Node_Index := 0;
   begin
      Node := 0;
      Allocate_Node (Tokens, State, Tree, AST_Mcp_Tool, Node, Success);
      if not Success then return; end if;
      State.Current_Token := State.Current_Token + 1; -- consume TOOL atom

      --  bound routine name
      if State.Current_Token > Max_Tokens
        or else Tokens (State.Current_Token).Kind not in
          Tok_Atom | Tok_Logic_Var
      then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1;

      --  optional AS "alias"
      if State.Current_Token <= Max_Tokens
        and then Tokens (State.Current_Token).Kind = Tok_As
      then
         State.Current_Token := State.Current_Token + 1;
         Parse_Mcp_String (Tokens, State, Tree, Str_Node, Success);
         if not Success then return; end if;
         Tree (Node).Left_Child := Str_Node;
      end if;

      --  optional DESCRIPTION "desc" (DESCRIPTOR accepted too)
      if State.Current_Token <= Max_Tokens
        and then (Tokens (State.Current_Token).Kind = Tok_Descriptor
                  or else Lexeme_Is (Tokens, State.Current_Token,
                                     "DESCRIPTION"))
      then
         State.Current_Token := State.Current_Token + 1;
         Parse_Mcp_String (Tokens, State, Tree, Str_Node, Success);
         if not Success then return; end if;
         Tree (Node).Right_Child := Str_Node;
      end if;
   end Parse_Mcp_Tool;

   --  RESOURCE "uri" -> <ident> [AS "name"]
   procedure Parse_Mcp_Resource (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Str_Node : Node_Index := 0;
   begin
      Node := 0;
      Allocate_Node (Tokens, State, Tree, AST_Mcp_Resource, Node, Success);
      if not Success then return; end if;
      State.Current_Token := State.Current_Token + 1; -- consume RESOURCE atom

      Parse_Mcp_String (Tokens, State, Tree, Str_Node, Success);
      if not Success then return; end if;
      Tree (Node).Left_Child := Str_Node; -- uri

      if State.Current_Token > Max_Tokens
        or else Tokens (State.Current_Token).Kind /= TOK_ARROW
      then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1; -- consume ->

      if State.Current_Token > Max_Tokens
        or else Tokens (State.Current_Token).Kind not in
          Tok_Atom | Tok_Logic_Var
      then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1;

      if State.Current_Token <= Max_Tokens
        and then Tokens (State.Current_Token).Kind = Tok_As
      then
         State.Current_Token := State.Current_Token + 1;
         Parse_Mcp_String (Tokens, State, Tree, Str_Node, Success);
         if not Success then return; end if;
         Tree (Node).Right_Child := Str_Node;
      end if;
   end Parse_Mcp_Resource;

   procedure Parse_Mcp_Decl (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Mcp_Tok  : constant Natural := State.Current_Token;
      Str_Node : Node_Index := 0;
      Ver_Node : Node_Index := 0;
      Item     : Node_Index := 0;
      First    : Node_Index := 0;
      Last     : Node_Index := 0;
   begin
      Node := 0;
      State.Current_Token := State.Current_Token + 1; -- consume MCP

      if State.Current_Token > Max_Tokens then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;

      if Lexeme_Is (Tokens, State.Current_Token, "TOOL") then
         Parse_Mcp_Tool (Tokens, State, Tree, Node, Success);
         return;
      elsif Lexeme_Is (Tokens, State.Current_Token, "RESOURCE") then
         Parse_Mcp_Resource (Tokens, State, Tree, Node, Success);
         return;
      elsif not Lexeme_Is (Tokens, State.Current_Token, "SERVER") then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;

      --  MCP SERVER "name" [VERSION "x.y"] ... END MCP
      Allocate_Node (Tokens, State, Tree, AST_Mcp_Server, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := Mcp_Tok;
      State.Current_Token := State.Current_Token + 1; -- consume SERVER

      Parse_Mcp_String (Tokens, State, Tree, Str_Node, Success);
      if not Success then return; end if;
      Tree (Node).Left_Child := Str_Node; -- server name

      if State.Current_Token <= Max_Tokens
        and then Tokens (State.Current_Token).Kind = Tok_Version
      then
         State.Current_Token := State.Current_Token + 1;
         Parse_Mcp_String (Tokens, State, Tree, Ver_Node, Success);
         if not Success then return; end if;
         Tree (Str_Node).Next_Sibling := Ver_Node;
      end if;

      --  entries until END MCP
      for I in 1 .. 16384 loop
         if State.Current_Token > Max_Tokens
           or else Tokens (State.Current_Token).Kind = Tok_Error
         then
            Set_Error (State, Tokens, Err_Parse_Block_Overflow);
            Success := False;
            return;
         end if;

         if Tokens (State.Current_Token).Kind = Tok_End then
            exit;
         elsif Lexeme_Is (Tokens, State.Current_Token, "TOOL") then
            Parse_Mcp_Tool (Tokens, State, Tree, Item, Success);
         elsif Lexeme_Is (Tokens, State.Current_Token, "RESOURCE") then
            Parse_Mcp_Resource (Tokens, State, Tree, Item, Success);
         else
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         if not Success then return; end if;

         if First = 0 then
            First := Item;
            Tree (Node).Right_Child := First;
         else
            Tree (Last).Next_Sibling := Item;
         end if;
         Last := Item;
      end loop;

      --  expect END MCP
      if State.Current_Token > Max_Tokens
        or else Tokens (State.Current_Token).Kind /= Tok_End
      then
         Set_Error (State, Tokens, Err_Parse_Expected_Block_End);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1;
      if State.Current_Token > Max_Tokens
        or else Tokens (State.Current_Token).Kind /= Tok_Mcp
      then
         Set_Error (State, Tokens, Err_Parse_Expected_Block_End);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1;
   end Parse_Mcp_Decl;

   -- =========================================================================
   -- DA MODULE VAULT FORGE (DECLAREMODULE & MODULE)
   -- =========================================================================
   procedure Parse_Module_Block (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean; Is_Declare : Boolean) is
      Name_Node, Body_Node : Node_Index;
      First_Stmt, Curr_Stmt, Next_Stmt : Node_Index := 0;
      NKind : Node_Kind := (if Is_Declare then AST_DeclareModule else AST_Module);
      Failed_Token : Natural := 0;
   begin
      Allocate_Node(Tokens, State, Tree, NKind, Node, Success);
      if not Success then return; end if;
      Tree(Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume MODULE / DECLAREMODULE

      -- 1. Guard: Expect Name (Atom or Logic Var)
      if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind not in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States then
         Set_Error(State, Tokens, Err_Parse_Expected_Value);
         Success := False; return;
      end if;

      Allocate_Node(Tokens, State, Tree, AST_Var_Expr, Name_Node, Success);
      if not Success then return; end if;
      Tree(Name_Node).Token_Index := State.Current_Token;
      Tree(Node).Left_Child := Name_Node;
      State.Current_Token := State.Current_Token + 1;

      -- DA FIX: Consume optional BEGIN for Module blocks!
      if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Begin then
         State.Current_Token := State.Current_Token + 1;
      end if;

      -- 2. Allocate the Block Node for the guts
      Allocate_Node(Tokens, State, Tree, AST_Block_Stmt, Body_Node, Success);
      if not Success then return; end if;
      Tree(Node).Right_Child := Body_Node;

      -- 3. Parse Statements until ENDMODULE
      for I in 1 .. 16384 loop
         if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind = Tok_Error then
            Set_Error(State, Tokens, Err_Parse_Block_Overflow); Success := False; return;
         end if;

         -- Accept legacy ENDMODULE, END MODULE, and END DECLARE MODULE.
         if Tokens(State.Current_Token).Kind = Tok_EndModule then
            State.Current_Token := State.Current_Token + 1; -- Consume ENDMODULE
            Success := True; 
            return; -- Exit perfectly clean!
         end if;

         if Tokens(State.Current_Token).Kind = Tok_End then
            declare
               End_Line : constant Positive := Tokens(State.Current_Token).Line;
            begin
               State.Current_Token := State.Current_Token + 1; -- Consume END
               if State.Current_Token <= Max_Tokens
                 and then Tokens(State.Current_Token).Line = End_Line
               then
                  if Tokens(State.Current_Token).Kind = Tok_Module then
                     State.Current_Token := State.Current_Token + 1; -- Consume MODULE
                     Success := True;
                     return;
                  elsif Is_Declare
                    and then Tokens(State.Current_Token).Kind = Tok_DeclareModule
                  then
                     State.Current_Token := State.Current_Token + 1; -- Consume DECLARE MODULE / DECLAREMODULE
                     Success := True;
                     return;
                  end if;
               end if;

               State.Current_Token := State.Current_Token - 1; -- Not a module terminator; restore END
            end;
         end if;

         Failed_Token := State.Current_Token;
         Parse_Statement(Tokens, State, Tree, Next_Stmt, Success);
         if not Success then 
            -- DA PANIC MODE INTERCEPT!
            Recover_After_Stmt_Error (Tokens, State, Failed_Token);
            Next_Stmt := 0;
            Success := True;
         end if;
         
         -- Only stitch the node if it's a valid statement
         if Next_Stmt /= 0 then
            if First_Stmt = 0 then
               First_Stmt := Next_Stmt;
               Tree(Body_Node).Left_Child := First_Stmt;
            else
               Tree(Curr_Stmt).Next_Sibling := Next_Stmt;
            end if;
            Curr_Stmt := Next_Stmt;
         end if;
      end loop;

      Set_Error(State, Tokens, Err_Parse_Block_Overflow);
      Success := False;
   end Parse_Module_Block;

   -- =========================================================================
   -- DA IMPORT FORGE (Dependencies)
   -- =========================================================================
   procedure Parse_Import (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Target_Node : Node_Index;
      Uses_Parens : Boolean := False;
   begin
      Allocate_Node(Tokens, State, Tree, AST_Import, Node, Success);
      if not Success then return; end if;
      Tree(Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume IMPORT

      if State.Current_Token <= Max_Tokens
        and then Tokens(State.Current_Token).Kind = Tok_L_Paren
      then
         Uses_Parens := True;
         State.Current_Token := State.Current_Token + 1;
      end if;

      if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind not in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States then
         Set_Error(State, Tokens, Err_Parse_Expected_Value);
         Success := False; return;
      end if;

      Allocate_Node(Tokens, State, Tree, AST_Var_Expr, Target_Node, Success);
      if not Success then return; end if;
      Tree(Target_Node).Token_Index := State.Current_Token;
      Tree(Node).Left_Child := Target_Node;
      State.Current_Token := State.Current_Token + 1;

      if Uses_Parens then
         if State.Current_Token <= Max_Tokens
           and then Tokens(State.Current_Token).Kind = Tok_R_Paren
         then
            State.Current_Token := State.Current_Token + 1;
         else
            Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
            Success := False;
            return;
         end if;
      end if;

      Success := True;
   end Parse_Import;
   
   -- Parser-only foreign binding surface syntax.
   -- Root_Kind selects the exact AST placeholder node; lowering remains unimplemented in all backends.
   procedure Parse_Foreign_Binding (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Root_Kind : in Node_Kind; Requires_From : in Boolean; Node : out Node_Index; Success : out Boolean) is
      Decl_Node  : Node_Index := 0;
      Name_Node  : Node_Index := 0;
      List_Node  : Node_Index := 0;
      Param_Node : Node_Index := 0;
      Last_Param : Node_Index := 0;
      Type_Node  : Node_Index := 0;
      Lib_Node   : Node_Index := 0;
      Sig_Kind   : Node_Kind  := AST_Procedure_Decl;
      Uses_Parens : Boolean := False;
      Uses_From_Parens : Boolean := False;
   begin
      Allocate_Node(Tokens, State, Tree, Root_Kind, Node, Success);
      if not Success then return; end if;
      Tree(Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume IMPORT* / EXPORT*

      if State.Current_Token <= Max_Tokens
        and then Tokens(State.Current_Token).Kind = Tok_L_Paren
      then
         Uses_Parens := True;
         State.Current_Token := State.Current_Token + 1;
      end if;

      if State.Current_Token > Max_Tokens then
         Set_Error(State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;

      if Tokens(State.Current_Token).Kind = Tok_Function then
         Sig_Kind := AST_Function_Decl;
      elsif Tokens(State.Current_Token).Kind = Tok_Procedure then
         Sig_Kind := AST_Procedure_Decl;
      else
         Set_Error(State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;

      State.Current_Token := State.Current_Token + 1; -- Consume FUNCTION / PROCEDURE

      Allocate_Node(Tokens, State, Tree, Sig_Kind, Decl_Node, Success);
      if not Success then return; end if;
      Tree(Decl_Node).Token_Index := 0;

      if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind not in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States then
         Set_Error(State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;

      Allocate_Node(Tokens, State, Tree, AST_Var_Expr, Name_Node, Success);
      if not Success then return; end if;
      Tree(Name_Node).Token_Index := State.Current_Token;
      Tree(Decl_Node).Left_Child := Name_Node;
      State.Current_Token := State.Current_Token + 1;

      if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_L_Paren then
         State.Current_Token := State.Current_Token + 1; -- Consume '('

         Allocate_Node(Tokens, State, Tree, AST_Arg_List, List_Node, Success);
         if not Success then return; end if;
         Tree(Name_Node).Right_Child := List_Node;

         if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind /= Tok_R_Paren then
            for J in 1 .. 64 loop
               Allocate_Node(Tokens, State, Tree, AST_Param_Decl, Param_Node, Success);
               if not Success then return; end if;
               Tree(Param_Node).Token_Index := 0;

               if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Ref then
                  Tree(Param_Node).Token_Index := State.Current_Token;
                  State.Current_Token := State.Current_Token + 1; -- Consume REF
               end if;

               if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind not in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States then
                  Set_Error(State, Tokens, Err_Parse_Expected_Value);
                  Success := False;
                  return;
               end if;

               declare
                  Param_Name_Node : Node_Index := 0;
               begin
                  Allocate_Node(Tokens, State, Tree, AST_Var_Expr, Param_Name_Node, Success);
                  if not Success then return; end if;
                  Tree(Param_Name_Node).Token_Index := State.Current_Token;
                  Tree(Param_Node).Left_Child := Param_Name_Node;
               end;
               State.Current_Token := State.Current_Token + 1;

               if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_As then
                  State.Current_Token := State.Current_Token + 1; -- Consume AS

                  if State.Current_Token <= Max_Tokens and then Is_Type_Name_Token (Tokens(State.Current_Token).Kind) then
                     Allocate_Node(Tokens, State, Tree, AST_Var_Expr, Type_Node, Success);
                     if not Success then return; end if;
                     Tree(Type_Node).Token_Index := State.Current_Token;
                     Tree(Param_Node).Right_Child := Type_Node;
                     State.Current_Token := State.Current_Token + 1;
                  else
                     Set_Error(State, Tokens, Err_Parse_Missing_Type_Name);
                     Success := False;
                     return;
                  end if;
               end if;

               if Last_Param = 0 then
                  Tree(List_Node).Left_Child := Param_Node;
               else
                  Tree(Last_Param).Next_Sibling := Param_Node;
               end if;
               Last_Param := Param_Node;

               if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Comma then
                  State.Current_Token := State.Current_Token + 1;
               elsif State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_R_Paren then
                  exit;
               else
                  Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
                  Success := False;
                  return;
               end if;
            end loop;
         end if;

         if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_R_Paren then
            State.Current_Token := State.Current_Token + 1;
         else
            Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
            Success := False;
            return;
         end if;
      end if;

      if Tree(Decl_Node).Kind = AST_Function_Decl then
         if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_As then
            State.Current_Token := State.Current_Token + 1;

            if State.Current_Token <= Max_Tokens and then Is_Type_Name_Token (Tokens(State.Current_Token).Kind) then
               Tree(Decl_Node).Token_Index := State.Current_Token;
               State.Current_Token := State.Current_Token + 1;
            else
               Set_Error(State, Tokens, Err_Parse_Missing_Type_Name);
               Success := False;
               return;
            end if;
         end if;
      end if;

      if Requires_From then
         if State.Current_Token > Max_Tokens then
            Set_Error(State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;

         if Tokens(State.Current_Token).Kind = Tok_From then
            State.Current_Token := State.Current_Token + 1; -- Consume FROM
         elsif Tokens(State.Current_Token).Kind in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States
           and then State.Current_Token < Max_Tokens
           and then Tokens(State.Current_Token + 1).Kind in Tok_String | Tok_L_Paren
         then
            --  Be tolerant here: some foreign-import spellings can still arrive
            --  as a plain identifier before the library string. Treat it as the
            --  separator and keep parsing the binding.
            State.Current_Token := State.Current_Token + 1;
         else
            Set_Error(State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;

         if State.Current_Token <= Max_Tokens
           and then Tokens(State.Current_Token).Kind = Tok_L_Paren
         then
            Uses_From_Parens := True;
            State.Current_Token := State.Current_Token + 1;
         end if;

         if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_String then
            Set_Error(State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;

         Allocate_Node(Tokens, State, Tree, AST_String_Expr, Lib_Node, Success);
         if not Success then return; end if;
         Tree(Lib_Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1;

         if Uses_From_Parens then
            if State.Current_Token <= Max_Tokens
              and then Tokens(State.Current_Token).Kind = Tok_R_Paren
            then
               State.Current_Token := State.Current_Token + 1;
            else
               Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
               Success := False;
               return;
            end if;
         end if;
      end if;

      Tree(Node).Left_Child  := Decl_Node;
      Tree(Node).Right_Child := Lib_Node;
      Success := True;
   end Parse_Foreign_Binding;

   procedure Parse_Import_C (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
   begin
      Parse_Foreign_Binding (Tokens, State, Tree, AST_Import_C, True, Node, Success);
   end Parse_Import_C;

   procedure Parse_Optional_Bound_To_Clause (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Target_Node : Node_Index := 0;
   begin
      Node := 0;
      Success := True;

      if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Bound_To then
         return;
      end if;

      Allocate_Node (Tokens, State, Tree, AST_Bound_To_Clause, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume BOUND_TO

      if State.Current_Token > Max_Tokens
        or else Tokens (State.Current_Token).Kind not in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States
      then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;

      Allocate_Node (Tokens, State, Tree, AST_Var_Expr, Target_Node, Success);
      if not Success then return; end if;
      Tree (Target_Node).Token_Index := State.Current_Token;
      Tree (Node).Left_Child := Target_Node;
      State.Current_Token := State.Current_Token + 1;
   end Parse_Optional_Bound_To_Clause;

   procedure Parse_Memory_Firewall_Decl (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Name_Node   : Node_Index := 0;
      Rule_Node   : Node_Index := 0;
      Target_Node : Node_Index := 0;
      First_Rule  : Node_Index := 0;
      Last_Rule   : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Memory_Firewall_Decl, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume MEMORY_FIREWALL

      if State.Current_Token > Max_Tokens
        or else Tokens (State.Current_Token).Kind not in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States
      then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;

      Allocate_Node (Tokens, State, Tree, AST_Var_Expr, Name_Node, Success);
      if not Success then return; end if;
      Tree (Name_Node).Token_Index := State.Current_Token;
      Tree (Node).Left_Child := Name_Node;
      State.Current_Token := State.Current_Token + 1;

      loop
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind = Tok_Error then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;

         exit when Tokens (State.Current_Token).Kind = Tok_End_Firewall;

         case Tokens (State.Current_Token).Kind is
            when Tok_Permit_Read =>
               Allocate_Node (Tokens, State, Tree, AST_Firewall_Permit_Read, Rule_Node, Success);
               if not Success then return; end if;
               Tree (Rule_Node).Token_Index := State.Current_Token;
               State.Current_Token := State.Current_Token + 1;

               Parse_Expression (Tokens, State, Tree, Target_Node, Success);
               if not Success then return; end if;
               Tree (Rule_Node).Left_Child := Target_Node;

            when Tok_Permit_Write =>
               Allocate_Node (Tokens, State, Tree, AST_Firewall_Permit_Write, Rule_Node, Success);
               if not Success then return; end if;
               Tree (Rule_Node).Token_Index := State.Current_Token;
               State.Current_Token := State.Current_Token + 1;

               Parse_Expression (Tokens, State, Tree, Target_Node, Success);
               if not Success then return; end if;
               Tree (Rule_Node).Left_Child := Target_Node;

            when Tok_Deny_All =>
               Allocate_Node (Tokens, State, Tree, AST_Firewall_Deny_All, Rule_Node, Success);
               if not Success then return; end if;
               Tree (Rule_Node).Token_Index := State.Current_Token;
               State.Current_Token := State.Current_Token + 1;

            when others =>
               Set_Error (State, Tokens, Err_Parse_Expected_Value);
               Success := False;
               return;
         end case;

         if First_Rule = 0 then
            First_Rule := Rule_Node;
            Tree (Node).Right_Child := First_Rule;
         else
            Tree (Last_Rule).Next_Sibling := Rule_Node;
         end if;
         Last_Rule := Rule_Node;
      end loop;

      State.Current_Token := State.Current_Token + 1; -- Consume END_FIREWALL
      Success := True;
   end Parse_Memory_Firewall_Decl;

   procedure Parse_Network_Socket_Decl (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Name_Node     : Node_Index := 0;
      Setting_Node  : Node_Index := 0;
      Value_Node    : Node_Index := 0;
      First_Setting : Node_Index := 0;
      Last_Setting  : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Network_Socket_Decl, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume NETWORK_SOCKET

      if State.Current_Token > Max_Tokens
        or else Tokens (State.Current_Token).Kind not in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States
      then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;

      Allocate_Node (Tokens, State, Tree, AST_Var_Expr, Name_Node, Success);
      if not Success then return; end if;
      Tree (Name_Node).Token_Index := State.Current_Token;
      Tree (Node).Left_Child := Name_Node;
      State.Current_Token := State.Current_Token + 1;

      loop
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind = Tok_Error then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;

         exit when Tokens (State.Current_Token).Kind = Tok_End_Socket;

         case Tokens (State.Current_Token).Kind is
            when Tok_Protocol =>
               Allocate_Node (Tokens, State, Tree, AST_Network_Protocol, Setting_Node, Success);
               if not Success then return; end if;
               Tree (Setting_Node).Token_Index := State.Current_Token;
               State.Current_Token := State.Current_Token + 1;

               if State.Current_Token > Max_Tokens
                 or else Tokens (State.Current_Token).Kind not in Tok_TCP | Tok_UDP | Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States
               then
                  Set_Error (State, Tokens, Err_Parse_Expected_Value);
                  Success := False;
                  return;
               end if;

               Allocate_Node (Tokens, State, Tree, AST_Var_Expr, Value_Node, Success);
               if not Success then return; end if;
               Tree (Value_Node).Token_Index := State.Current_Token;
               Tree (Setting_Node).Left_Child := Value_Node;
               State.Current_Token := State.Current_Token + 1;

            when Tok_Port =>
               Allocate_Node (Tokens, State, Tree, AST_Network_Port, Setting_Node, Success);
               if not Success then return; end if;
               Tree (Setting_Node).Token_Index := State.Current_Token;
               State.Current_Token := State.Current_Token + 1;

               Parse_Expression (Tokens, State, Tree, Value_Node, Success);
               if not Success then return; end if;
               Tree (Setting_Node).Left_Child := Value_Node;

            when Tok_Buffer_Size =>
               Allocate_Node (Tokens, State, Tree, AST_Network_Buffer_Size, Setting_Node, Success);
               if not Success then return; end if;
               Tree (Setting_Node).Token_Index := State.Current_Token;
               State.Current_Token := State.Current_Token + 1;

               Parse_Expression (Tokens, State, Tree, Value_Node, Success);
               if not Success then return; end if;
               Tree (Setting_Node).Left_Child := Value_Node;

            when others =>
               Set_Error (State, Tokens, Err_Parse_Expected_Value);
               Success := False;
               return;
         end case;

         if First_Setting = 0 then
            First_Setting := Setting_Node;
            Tree (Node).Right_Child := First_Setting;
         else
            Tree (Last_Setting).Next_Sibling := Setting_Node;
         end if;
         Last_Setting := Setting_Node;
      end loop;

      State.Current_Token := State.Current_Token + 1; -- Consume END_SOCKET
      Success := True;
   end Parse_Network_Socket_Decl;

   procedure Parse_Network_Listen_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Socket_Node : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Network_Listen_Stmt, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume NETWORK_LISTEN

      Parse_Expression (Tokens, State, Tree, Socket_Node, Success);
      if not Success then return; end if;
      Tree (Node).Left_Child := Socket_Node;
   end Parse_Network_Listen_Stmt;

   procedure Parse_Network_Accept_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Socket_Node : Node_Index := 0;
      Target_Node : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Network_Accept_Stmt, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume NETWORK_ACCEPT

      Parse_Expression (Tokens, State, Tree, Socket_Node, Success);
      if not Success then return; end if;
      Tree (Node).Left_Child := Socket_Node;

      if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Into then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1;

      Parse_Expression (Tokens, State, Tree, Target_Node, Success);
      if not Success then return; end if;
      Tree (Node).Right_Child := Target_Node;
   end Parse_Network_Accept_Stmt;

   procedure Parse_Network_Receive_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Socket_Node : Node_Index := 0;
      Buffer_Node : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Network_Receive_Stmt, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume NETWORK_RECEIVE

      Parse_Expression (Tokens, State, Tree, Socket_Node, Success);
      if not Success then return; end if;
      Tree (Node).Left_Child := Socket_Node;

      if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Into then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1;

      Parse_Expression (Tokens, State, Tree, Buffer_Node, Success);
      if not Success then return; end if;
      Tree (Node).Right_Child := Buffer_Node;
   end Parse_Network_Receive_Stmt;

   procedure Parse_Network_Send_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Socket_Node : Node_Index := 0;
      Buffer_Node : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Network_Send_Stmt, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume NETWORK_SEND

      Parse_Expression (Tokens, State, Tree, Socket_Node, Success);
      if not Success then return; end if;
      Tree (Node).Left_Child := Socket_Node;

      if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_From then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1;

      Parse_Expression (Tokens, State, Tree, Buffer_Node, Success);
      if not Success then return; end if;
      Tree (Node).Right_Child := Buffer_Node;
   end Parse_Network_Send_Stmt;

   procedure Parse_Network_Close_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Target_Node : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Network_Close_Stmt, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume NETWORK_CLOSE

      Parse_Expression (Tokens, State, Tree, Target_Node, Success);
      if not Success then return; end if;
      Tree (Node).Left_Child := Target_Node;
   end Parse_Network_Close_Stmt;

   procedure Parse_Process_Handle_Decl (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Name_Node      : Node_Index := 0;
      Setting_Node   : Node_Index := 0;
      Value_Node     : Node_Index := 0;
      Right_Node     : Node_Index := 0;
      First_Setting  : Node_Index := 0;
      Last_Setting   : Node_Index := 0;
      First_Right    : Node_Index := 0;
      Last_Right     : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Process_Handle_Decl, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume PROCESS_HANDLE

      if State.Current_Token > Max_Tokens
        or else Tokens (State.Current_Token).Kind not in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States
      then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;

      Allocate_Node (Tokens, State, Tree, AST_Var_Expr, Name_Node, Success);
      if not Success then return; end if;
      Tree (Name_Node).Token_Index := State.Current_Token;
      Tree (Node).Left_Child := Name_Node;
      State.Current_Token := State.Current_Token + 1;

      loop
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind = Tok_Error then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;

         exit when Tokens (State.Current_Token).Kind = Tok_End_Process;

         case Tokens (State.Current_Token).Kind is
            when Tok_Process_Pid =>
               Allocate_Node (Tokens, State, Tree, AST_Process_Pid, Setting_Node, Success);
               if not Success then return; end if;
               Tree (Setting_Node).Token_Index := State.Current_Token;
               State.Current_Token := State.Current_Token + 1;

               Parse_Expression (Tokens, State, Tree, Value_Node, Success);
               if not Success then return; end if;
               Tree (Setting_Node).Left_Child := Value_Node;

            when Tok_Process_Image =>
               Allocate_Node (Tokens, State, Tree, AST_Process_Image, Setting_Node, Success);
               if not Success then return; end if;
               Tree (Setting_Node).Token_Index := State.Current_Token;
               State.Current_Token := State.Current_Token + 1;

               Parse_Expression (Tokens, State, Tree, Value_Node, Success);
               if not Success then return; end if;
               Tree (Setting_Node).Left_Child := Value_Node;

            when Tok_Process_Rights =>
               Allocate_Node (Tokens, State, Tree, AST_Process_Rights, Setting_Node, Success);
               if not Success then return; end if;
               Tree (Setting_Node).Token_Index := State.Current_Token;
               State.Current_Token := State.Current_Token + 1;

               First_Right := 0;
               Last_Right  := 0;

               loop
                  if State.Current_Token > Max_Tokens
                    or else Tokens (State.Current_Token).Kind not in Tok_Read | Tok_Write | Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States
                  then
                     Set_Error (State, Tokens, Err_Parse_Expected_Value);
                     Success := False;
                     return;
                  end if;

                  Allocate_Node (Tokens, State, Tree, AST_Var_Expr, Right_Node, Success);
                  if not Success then return; end if;
                  Tree (Right_Node).Token_Index := State.Current_Token;
                  State.Current_Token := State.Current_Token + 1;

                  if First_Right = 0 then
                     First_Right := Right_Node;
                     Tree (Setting_Node).Left_Child := First_Right;
                  else
                     Tree (Last_Right).Next_Sibling := Right_Node;
                  end if;
                  Last_Right := Right_Node;

                  exit when State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Comma;
                  State.Current_Token := State.Current_Token + 1;
               end loop;

            when others =>
               Set_Error (State, Tokens, Err_Parse_Expected_Value);
               Success := False;
               return;
         end case;

         if First_Setting = 0 then
            First_Setting := Setting_Node;
            Tree (Node).Right_Child := First_Setting;
         else
            Tree (Last_Setting).Next_Sibling := Setting_Node;
         end if;
         Last_Setting := Setting_Node;
      end loop;

      State.Current_Token := State.Current_Token + 1; -- Consume END_PROCESS
      Success := True;
   end Parse_Process_Handle_Decl;

   procedure Parse_Read_Process_Memory_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Uses_Parens : Boolean := False;
      Handle_Node : Node_Index := 0;
      Addr_Node   : Node_Index := 0;
      Target_Node : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Read_Process_Memory_Stmt, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume READ_PROCESS_MEMORY

      if State.Current_Token <= Max_Tokens
        and then Tokens (State.Current_Token).Kind = Tok_L_Paren
      then
         Uses_Parens := True;
         State.Current_Token := State.Current_Token + 1;
      end if;

      Parse_Expression (Tokens, State, Tree, Handle_Node, Success);
      if not Success then return; end if;
      Tree (Node).Left_Child := Handle_Node;

      if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Comma then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1;

      Parse_Expression (Tokens, State, Tree, Addr_Node, Success);
      if not Success then return; end if;
      Tree (Node).Right_Child := Addr_Node;

      if Uses_Parens then
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Comma then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      else
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Into then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      end if;

      Parse_Expression (Tokens, State, Tree, Target_Node, Success);
      if not Success then return; end if;
      Tree (Addr_Node).Next_Sibling := Target_Node;

      if Uses_Parens then
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_R_Paren then
            Set_Error (State, Tokens, Err_Parse_Missing_Bracket);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      end if;
   end Parse_Read_Process_Memory_Stmt;

   procedure Parse_Write_Process_Memory_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Uses_Parens : Boolean := False;
      Handle_Node : Node_Index := 0;
      Addr_Node   : Node_Index := 0;
      Value_Node  : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Write_Process_Memory_Stmt, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume WRITE_PROCESS_MEMORY

      if State.Current_Token <= Max_Tokens
        and then Tokens (State.Current_Token).Kind = Tok_L_Paren
      then
         Uses_Parens := True;
         State.Current_Token := State.Current_Token + 1;
      end if;

      Parse_Expression (Tokens, State, Tree, Handle_Node, Success);
      if not Success then return; end if;
      Tree (Node).Left_Child := Handle_Node;

      if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Comma then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1;

      Parse_Expression (Tokens, State, Tree, Addr_Node, Success);
      if not Success then return; end if;
      Tree (Node).Right_Child := Addr_Node;

      if Uses_Parens then
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Comma then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      else
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_From then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      end if;

      Parse_Expression (Tokens, State, Tree, Value_Node, Success);
      if not Success then return; end if;
      Tree (Addr_Node).Next_Sibling := Value_Node;

      if Uses_Parens then
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_R_Paren then
            Set_Error (State, Tokens, Err_Parse_Missing_Bracket);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      end if;
   end Parse_Write_Process_Memory_Stmt;

   procedure Parse_Monitor_Process_Memory_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Uses_Parens  : Boolean := False;
      Handle_Node  : Node_Index := 0;
      Addr_Node    : Node_Index := 0;
      Type_Node    : Node_Index := 0;
      Target_Node  : Node_Index := 0;
      Changed_Node : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Monitor_Process_Memory_Stmt, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume MONITOR_PROCESS_MEMORY

      if State.Current_Token <= Max_Tokens
        and then Tokens (State.Current_Token).Kind = Tok_L_Paren
      then
         Uses_Parens := True;
         State.Current_Token := State.Current_Token + 1;
      end if;

      Parse_Expression (Tokens, State, Tree, Handle_Node, Success);
      if not Success then return; end if;
      Tree (Node).Left_Child := Handle_Node;

      if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Comma then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1;

      Parse_Expression (Tokens, State, Tree, Addr_Node, Success);
      if not Success then return; end if;
      Tree (Node).Right_Child := Addr_Node;

      if Uses_Parens then
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Comma then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      else
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_As then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      end if;

      Parse_Expression (Tokens, State, Tree, Type_Node, Success);
      if not Success then return; end if;
      Tree (Addr_Node).Next_Sibling := Type_Node;

      if Uses_Parens then
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Comma then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      else
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Into then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      end if;

      Parse_Expression (Tokens, State, Tree, Target_Node, Success);
      if not Success then return; end if;
      Tree (Type_Node).Next_Sibling := Target_Node;

      if Uses_Parens then
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Comma then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      else
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Changed then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      end if;

      Parse_Expression (Tokens, State, Tree, Changed_Node, Success);
      if not Success then return; end if;
      Tree (Target_Node).Next_Sibling := Changed_Node;

      if Uses_Parens then
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_R_Paren then
            Set_Error (State, Tokens, Err_Parse_Missing_Bracket);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      end if;
   end Parse_Monitor_Process_Memory_Stmt;

   procedure Parse_Inject_Code_Memory_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Uses_Parens : Boolean := False;
      Handle_Node : Node_Index := 0;
      Payload_Node : Node_Index := 0;
      Target_Node : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Inject_Code_Memory_Stmt, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume INJECT_CODE_MEMORY

      if State.Current_Token <= Max_Tokens
        and then Tokens (State.Current_Token).Kind = Tok_L_Paren
      then
         Uses_Parens := True;
         State.Current_Token := State.Current_Token + 1;
      end if;

      Parse_Expression (Tokens, State, Tree, Handle_Node, Success);
      if not Success then return; end if;
      Tree (Node).Left_Child := Handle_Node;

      if Uses_Parens then
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Comma then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      else
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_From then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      end if;

      Parse_Expression (Tokens, State, Tree, Payload_Node, Success);
      if not Success then return; end if;
      Tree (Node).Right_Child := Payload_Node;

      if Uses_Parens then
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Comma then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      else
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Into then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      end if;

      Parse_Expression (Tokens, State, Tree, Target_Node, Success);
      if not Success then return; end if;
      Tree (Payload_Node).Next_Sibling := Target_Node;

      if Uses_Parens then
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_R_Paren then
            Set_Error (State, Tokens, Err_Parse_Missing_Bracket);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      end if;
   end Parse_Inject_Code_Memory_Stmt;

   procedure Parse_Hijack_Process_Memory_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Uses_Parens : Boolean := False;
      Handle_Node : Node_Index := 0;
      Addr_Node   : Node_Index := 0;
      Detour_Node : Node_Index := 0;
      Target_Node : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Hijack_Process_Memory_Stmt, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume HIJACK_PROCESS_MEMORY

      if State.Current_Token <= Max_Tokens
        and then Tokens (State.Current_Token).Kind = Tok_L_Paren
      then
         Uses_Parens := True;
         State.Current_Token := State.Current_Token + 1;
      end if;

      Parse_Expression (Tokens, State, Tree, Handle_Node, Success);
      if not Success then return; end if;
      Tree (Node).Left_Child := Handle_Node;

      if Uses_Parens then
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Comma then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      else
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_At then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      end if;

      Parse_Expression (Tokens, State, Tree, Addr_Node, Success);
      if not Success then return; end if;
      Tree (Node).Right_Child := Addr_Node;

      if Uses_Parens then
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Comma then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      else
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_To then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      end if;

      Parse_Expression (Tokens, State, Tree, Detour_Node, Success);
      if not Success then return; end if;
      Tree (Addr_Node).Next_Sibling := Detour_Node;

      if Uses_Parens then
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Comma then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      else
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Into then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      end if;

      Parse_Expression (Tokens, State, Tree, Target_Node, Success);
      if not Success then return; end if;
      Tree (Detour_Node).Next_Sibling := Target_Node;

      if Uses_Parens then
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_R_Paren then
            Set_Error (State, Tokens, Err_Parse_Missing_Bracket);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      end if;
   end Parse_Hijack_Process_Memory_Stmt;

   procedure Parse_Dump_Process_Memory_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Uses_Parens : Boolean := False;
      Handle_Node : Node_Index := 0;
      Addr_Node   : Node_Index := 0;
      Size_Node   : Node_Index := 0;
      Path_Node   : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Dump_Process_Memory_Stmt, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume DUMP_PROCESS_MEMORY

      if State.Current_Token <= Max_Tokens
        and then Tokens (State.Current_Token).Kind = Tok_L_Paren
      then
         Uses_Parens := True;
         State.Current_Token := State.Current_Token + 1;
      end if;

      Parse_Expression (Tokens, State, Tree, Handle_Node, Success);
      if not Success then return; end if;
      Tree (Node).Left_Child := Handle_Node;

      if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Comma then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1;

      Parse_Expression (Tokens, State, Tree, Addr_Node, Success);
      if not Success then return; end if;
      Tree (Node).Right_Child := Addr_Node;

      if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Comma then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1;

      Parse_Expression (Tokens, State, Tree, Size_Node, Success);
      if not Success then return; end if;
      Tree (Addr_Node).Next_Sibling := Size_Node;

      if Uses_Parens then
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Comma then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      else
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Into then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      end if;

      Parse_Expression (Tokens, State, Tree, Path_Node, Success);
      if not Success then return; end if;
      Tree (Size_Node).Next_Sibling := Path_Node;

      if Uses_Parens then
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_R_Paren then
            Set_Error (State, Tokens, Err_Parse_Missing_Bracket);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      end if;
   end Parse_Dump_Process_Memory_Stmt;

   procedure Parse_Terminate_Process_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Target_Node : Node_Index := 0;
      Uses_Parens : Boolean := False;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Terminate_Process_Stmt, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume TERMINATE_PROCESS

      if State.Current_Token <= Max_Tokens
        and then Tokens (State.Current_Token).Kind = Tok_L_Paren
      then
         Uses_Parens := True;
         State.Current_Token := State.Current_Token + 1;
      end if;

      Parse_Expression (Tokens, State, Tree, Target_Node, Success);
      if not Success then return; end if;
      Tree (Node).Left_Child := Target_Node;

      if Uses_Parens then
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_R_Paren then
            Set_Error (State, Tokens, Err_Parse_Missing_Bracket);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      end if;
   end Parse_Terminate_Process_Stmt;

   procedure Parse_Create_Process_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Uses_Parens : Boolean := False;
      Image_Node  : Node_Index := 0;
      Args_Node   : Node_Index := 0;
      Target_Node : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Create_Process_Stmt, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume CREATE_PROCESS

      if State.Current_Token <= Max_Tokens
        and then Tokens (State.Current_Token).Kind = Tok_L_Paren
      then
         Uses_Parens := True;
         State.Current_Token := State.Current_Token + 1;
      end if;

      Parse_Expression (Tokens, State, Tree, Image_Node, Success);
      if not Success then return; end if;
      Tree (Node).Left_Child := Image_Node;

      if Uses_Parens then
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Comma then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;

         Parse_Expression (Tokens, State, Tree, Args_Node, Success);
         if not Success then return; end if;

         if State.Current_Token <= Max_Tokens and then Tokens (State.Current_Token).Kind = Tok_Comma then
            State.Current_Token := State.Current_Token + 1;
            Parse_Expression (Tokens, State, Tree, Target_Node, Success);
            if not Success then return; end if;
            Tree (Node).Right_Child := Args_Node;
            Tree (Args_Node).Next_Sibling := Target_Node;
         else
            Tree (Node).Right_Child := Args_Node;
         end if;

         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_R_Paren then
            Set_Error (State, Tokens, Err_Parse_Missing_Bracket);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      else
         if State.Current_Token <= Max_Tokens and then Tokens (State.Current_Token).Kind = Tok_With then
            State.Current_Token := State.Current_Token + 1;
            Parse_Expression (Tokens, State, Tree, Args_Node, Success);
            if not Success then return; end if;
         end if;

         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Into then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;

         Parse_Expression (Tokens, State, Tree, Target_Node, Success);
         if not Success then return; end if;

         if Args_Node /= 0 then
            Tree (Node).Right_Child := Args_Node;
            Tree (Args_Node).Next_Sibling := Target_Node;
         else
            Tree (Node).Right_Child := Target_Node;
         end if;
      end if;
   end Parse_Create_Process_Stmt;

    procedure Parse_Elevate_Privileges_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
       Target_Node   : Node_Index := 0;
       Result_Node   : Node_Index := 0;
       Uses_Parens   : Boolean := False;
    begin
       Allocate_Node (Tokens, State, Tree, AST_Elevate_Privileges_Stmt, Node, Success);
       if not Success then return; end if;
       Tree (Node).Token_Index := State.Current_Token;
       State.Current_Token := State.Current_Token + 1; -- Consume ELEVATE_PRIVILEGES

       if State.Current_Token <= Max_Tokens
         and then Tokens (State.Current_Token).Kind = Tok_L_Paren
       then
          Uses_Parens := True;
          State.Current_Token := State.Current_Token + 1;
       end if;

       Parse_Expression (Tokens, State, Tree, Target_Node, Success);
       if not Success then return; end if;
       Tree (Node).Left_Child := Target_Node;

       if not Uses_Parens
         and then State.Current_Token <= Max_Tokens
         and then Tokens (State.Current_Token).Kind = Tok_Into
       then
          State.Current_Token := State.Current_Token + 1; -- Consume INTO
          Parse_Expression (Tokens, State, Tree, Result_Node, Success);
          if not Success then return; end if;
          Tree (Node).Right_Child := Result_Node;
       end if;

       if Uses_Parens then
          if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_R_Paren then
             Set_Error (State, Tokens, Err_Parse_Missing_Bracket);
             Success := False;
             return;
          end if;
          State.Current_Token := State.Current_Token + 1;
       end if;
    end Parse_Elevate_Privileges_Stmt;

   procedure Parse_Hack_Memory_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Uses_Parens : Boolean := False;
      Handle_Node : Node_Index := 0;
      Addr_Node   : Node_Index := 0;
      Value_Node  : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Hack_Memory_Stmt, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume HACK_MEMORY

      if State.Current_Token <= Max_Tokens
        and then Tokens (State.Current_Token).Kind = Tok_L_Paren
      then
         Uses_Parens := True;
         State.Current_Token := State.Current_Token + 1;
      end if;

      Parse_Expression (Tokens, State, Tree, Handle_Node, Success);
      if not Success then return; end if;
      Tree (Node).Left_Child := Handle_Node;

      if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Comma then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1;

      Parse_Expression (Tokens, State, Tree, Addr_Node, Success);
      if not Success then return; end if;
      Tree (Node).Right_Child := Addr_Node;

      if Uses_Parens then
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Comma then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      else
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_From then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      end if;

      Parse_Expression (Tokens, State, Tree, Value_Node, Success);
      if not Success then return; end if;
      Tree (Addr_Node).Next_Sibling := Value_Node;

      if Uses_Parens then
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_R_Paren then
            Set_Error (State, Tokens, Err_Parse_Missing_Bracket);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      end if;
   end Parse_Hack_Memory_Stmt;

   procedure Parse_Inject_Code_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Uses_Parens  : Boolean := False;
      Handle_Node  : Node_Index := 0;
      Payload_Node : Node_Index := 0;
      Target_Node  : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Inject_Code_Stmt, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume INJECT_CODE

      if State.Current_Token <= Max_Tokens
        and then Tokens (State.Current_Token).Kind = Tok_L_Paren
      then
         Uses_Parens := True;
         State.Current_Token := State.Current_Token + 1;
      end if;

      Parse_Expression (Tokens, State, Tree, Handle_Node, Success);
      if not Success then return; end if;
      Tree (Node).Left_Child := Handle_Node;

      if Uses_Parens then
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Comma then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      else
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_From then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      end if;

      Parse_Expression (Tokens, State, Tree, Payload_Node, Success);
      if not Success then return; end if;
      Tree (Node).Right_Child := Payload_Node;

      if Uses_Parens then
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Comma then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      else
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Into then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      end if;

      Parse_Expression (Tokens, State, Tree, Target_Node, Success);
      if not Success then return; end if;
      Tree (Payload_Node).Next_Sibling := Target_Node;

      if Uses_Parens then
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_R_Paren then
            Set_Error (State, Tokens, Err_Parse_Missing_Bracket);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      end if;
   end Parse_Inject_Code_Stmt;

   procedure Parse_Inject_Payload_Type_Clause
     (Tokens : in Token_Array; State : in out Parser_State;
      Tree   : in out Node_Array; Node : out Node_Index;
      Success : out Boolean) is
   begin
      Allocate_Node (Tokens, State, Tree, AST_Inject_Payload_Type, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1;
      Parse_Expression (Tokens, State, Tree, Tree (Node).Right_Child, Success);
   end Parse_Inject_Payload_Type_Clause;

   procedure Parse_Inject_Flags_Clause
     (Tokens : in Token_Array; State : in out Parser_State;
      Tree   : in out Node_Array; Node : out Node_Index;
      Success : out Boolean) is
   begin
      Allocate_Node (Tokens, State, Tree, AST_Inject_Flags_Clause, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1;
      Parse_Expression (Tokens, State, Tree, Tree (Node).Right_Child, Success);
   end Parse_Inject_Flags_Clause;

   procedure Parse_Inject_Syscall_Clause
     (Tokens : in Token_Array; State : in out Parser_State;
      Tree   : in out Node_Array; Node : out Node_Index;
      Success : out Boolean) is
   begin
      Allocate_Node (Tokens, State, Tree, AST_Inject_Syscall_Clause, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1;
      Parse_Expression (Tokens, State, Tree, Tree (Node).Right_Child, Success);
   end Parse_Inject_Syscall_Clause;

   procedure Parse_Inject_Page_Clause
     (Tokens : in Token_Array; State : in out Parser_State;
      Tree   : in out Node_Array; Node : out Node_Index;
      Success : out Boolean) is
   begin
      Allocate_Node (Tokens, State, Tree, AST_Inject_Page_Clause, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1;
      Parse_Expression (Tokens, State, Tree, Tree (Node).Right_Child, Success);
   end Parse_Inject_Page_Clause;

   procedure Parse_Sniff_Network_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Uses_Parens : Boolean := False;
      Source_Node : Node_Index := 0;
      Buffer_Node : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Sniff_Network_Stmt, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume SNIFF_NETWORK

      if State.Current_Token <= Max_Tokens
        and then Tokens (State.Current_Token).Kind = Tok_L_Paren
      then
         Uses_Parens := True;
         State.Current_Token := State.Current_Token + 1;
      end if;

      Parse_Expression (Tokens, State, Tree, Source_Node, Success);
      if not Success then return; end if;
      Tree (Node).Left_Child := Source_Node;

      if Uses_Parens then
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Comma then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      else
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Into then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      end if;

      Parse_Expression (Tokens, State, Tree, Buffer_Node, Success);
      if not Success then return; end if;
      Tree (Node).Right_Child := Buffer_Node;

      if Uses_Parens then
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_R_Paren then
            Set_Error (State, Tokens, Err_Parse_Missing_Bracket);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      end if;
   end Parse_Sniff_Network_Stmt;

   procedure Parse_Network_Sniffer_Decl (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Name_Node     : Node_Index := 0;
      Setting_Node  : Node_Index := 0;
      Value_Node    : Node_Index := 0;
      First_Setting : Node_Index := 0;
      Last_Setting  : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Network_Sniffer_Decl, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume NETWORK_SNIFFER

      if State.Current_Token > Max_Tokens
        or else Tokens (State.Current_Token).Kind not in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States
      then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;

      Allocate_Node (Tokens, State, Tree, AST_Var_Expr, Name_Node, Success);
      if not Success then return; end if;
      Tree (Name_Node).Token_Index := State.Current_Token;
      Tree (Node).Left_Child := Name_Node;
      State.Current_Token := State.Current_Token + 1;

      loop
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind = Tok_Error then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;

         exit when Tokens (State.Current_Token).Kind = Tok_End_Sniffer;

         case Tokens (State.Current_Token).Kind is
            when Tok_Interface =>
               Allocate_Node (Tokens, State, Tree, AST_Sniffer_Interface, Setting_Node, Success);
               if not Success then return; end if;
               Tree (Setting_Node).Token_Index := State.Current_Token;
               State.Current_Token := State.Current_Token + 1;
               Parse_Expression (Tokens, State, Tree, Value_Node, Success);
               if not Success then return; end if;
               Tree (Setting_Node).Left_Child := Value_Node;

            when Tok_Protocol =>
               Allocate_Node (Tokens, State, Tree, AST_Sniffer_Protocol, Setting_Node, Success);
               if not Success then return; end if;
               Tree (Setting_Node).Token_Index := State.Current_Token;
               State.Current_Token := State.Current_Token + 1;
               if State.Current_Token > Max_Tokens
                 or else Tokens (State.Current_Token).Kind not in Tok_TCP | Tok_UDP | Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States
               then
                  Set_Error (State, Tokens, Err_Parse_Expected_Value);
                  Success := False;
                  return;
               end if;
               Allocate_Node (Tokens, State, Tree, AST_Var_Expr, Value_Node, Success);
               if not Success then return; end if;
               Tree (Value_Node).Token_Index := State.Current_Token;
               Tree (Setting_Node).Left_Child := Value_Node;
               State.Current_Token := State.Current_Token + 1;

            when Tok_Port =>
               Allocate_Node (Tokens, State, Tree, AST_Sniffer_Port, Setting_Node, Success);
               if not Success then return; end if;
               Tree (Setting_Node).Token_Index := State.Current_Token;
               State.Current_Token := State.Current_Token + 1;
               Parse_Expression (Tokens, State, Tree, Value_Node, Success);
               if not Success then return; end if;
               Tree (Setting_Node).Left_Child := Value_Node;

            when Tok_Buffer_Size =>
               Allocate_Node (Tokens, State, Tree, AST_Sniffer_Buffer_Size, Setting_Node, Success);
               if not Success then return; end if;
               Tree (Setting_Node).Token_Index := State.Current_Token;
               State.Current_Token := State.Current_Token + 1;
               Parse_Expression (Tokens, State, Tree, Value_Node, Success);
               if not Success then return; end if;
               Tree (Setting_Node).Left_Child := Value_Node;

            when others =>
               Set_Error (State, Tokens, Err_Parse_Expected_Value);
               Success := False;
               return;
         end case;

         if First_Setting = 0 then
            First_Setting := Setting_Node;
            Tree (Node).Right_Child := First_Setting;
         else
            Tree (Last_Setting).Next_Sibling := Setting_Node;
         end if;
         Last_Setting := Setting_Node;
      end loop;

      State.Current_Token := State.Current_Token + 1; -- Consume END_SNIFFER
      Success := True;
   end Parse_Network_Sniffer_Decl;

   procedure Parse_Network_Sniff_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Uses_Parens  : Boolean := False;
      Sniffer_Node : Node_Index := 0;
      Buffer_Node  : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Network_Sniff_Stmt, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume NETWORK_SNIFF

      if State.Current_Token <= Max_Tokens
        and then Tokens (State.Current_Token).Kind = Tok_L_Paren
      then
         Uses_Parens := True;
         State.Current_Token := State.Current_Token + 1;
      end if;

      Parse_Expression (Tokens, State, Tree, Sniffer_Node, Success);
      if not Success then return; end if;
      Tree (Node).Left_Child := Sniffer_Node;

      if Uses_Parens then
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Comma then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      else
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Into then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      end if;

      Parse_Expression (Tokens, State, Tree, Buffer_Node, Success);
      if not Success then return; end if;
      Tree (Node).Right_Child := Buffer_Node;

      if Uses_Parens then
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_R_Paren then
            Set_Error (State, Tokens, Err_Parse_Missing_Bracket);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      end if;
   end Parse_Network_Sniff_Stmt;

   procedure Parse_Parse_Ethernet_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Uses_Parens : Boolean := False;
      Src_Node    : Node_Index := 0;
      Dest_Node   : Node_Index := 0;
      First_Dest  : Node_Index := 0;
      Last_Dest   : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Parse_Ethernet_Stmt, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume PARSE_ETHERNET

      if State.Current_Token <= Max_Tokens
        and then Tokens (State.Current_Token).Kind = Tok_L_Paren
      then
         Uses_Parens := True;
         State.Current_Token := State.Current_Token + 1;
      end if;

      if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_From then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1; -- Consume FROM

      Parse_Expression (Tokens, State, Tree, Src_Node, Success);
      if not Success then return; end if;
      Tree (Node).Left_Child := Src_Node;

      if Uses_Parens then
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Comma then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      else
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Into then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      end if;

      loop
         Parse_Expression (Tokens, State, Tree, Dest_Node, Success);
         if not Success then return; end if;

         if First_Dest = 0 then
            First_Dest := Dest_Node;
            Tree (Node).Right_Child := First_Dest;
         else
            Tree (Last_Dest).Next_Sibling := Dest_Node;
         end if;
         Last_Dest := Dest_Node;

         exit when State.Current_Token > Max_Tokens
           or else Tokens (State.Current_Token).Kind = Tok_R_Paren
           or else Tokens (State.Current_Token).Kind not in Tok_Comma | Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States;
         if Tokens (State.Current_Token).Kind = Tok_Comma then
            State.Current_Token := State.Current_Token + 1;
         else
            exit;
         end if;
      end loop;

      if Uses_Parens then
         if State.Current_Token <= Max_Tokens and then Tokens (State.Current_Token).Kind = Tok_R_Paren then
            State.Current_Token := State.Current_Token + 1;
         end if;
      end if;
   end Parse_Parse_Ethernet_Stmt;

    procedure Parse_Parse_IP_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
       Uses_Parens : Boolean := False;
       Src_Node    : Node_Index := 0;
       Dest_Node   : Node_Index := 0;
       First_Dest  : Node_Index := 0;
       Last_Dest   : Node_Index := 0;
    begin
       Allocate_Node (Tokens, State, Tree, AST_Parse_IP_Stmt, Node, Success);
       if not Success then return; end if;
       Tree (Node).Token_Index := State.Current_Token;
       State.Current_Token := State.Current_Token + 1; -- Consume PARSE_IP

       if State.Current_Token <= Max_Tokens
         and then Tokens (State.Current_Token).Kind = Tok_L_Paren
       then
          Uses_Parens := True;
          State.Current_Token := State.Current_Token + 1;
       end if;

       if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_From then
          Set_Error (State, Tokens, Err_Parse_Expected_Value);
          Success := False;
          return;
       end if;
       State.Current_Token := State.Current_Token + 1; -- Consume FROM

       Parse_Expression (Tokens, State, Tree, Src_Node, Success);
       if not Success then return; end if;
       Tree (Node).Left_Child := Src_Node;

       if Uses_Parens then
          if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Comma then
             Set_Error (State, Tokens, Err_Parse_Expected_Value);
             Success := False;
             return;
          end if;
          State.Current_Token := State.Current_Token + 1;
       else
          if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Into then
             Set_Error (State, Tokens, Err_Parse_Expected_Value);
             Success := False;
             return;
          end if;
          State.Current_Token := State.Current_Token + 1;
       end if;

       loop
          Parse_Expression (Tokens, State, Tree, Dest_Node, Success);
          if not Success then return; end if;

          if First_Dest = 0 then
             First_Dest := Dest_Node;
             Tree (Node).Right_Child := First_Dest;
          else
             Tree (Last_Dest).Next_Sibling := Dest_Node;
          end if;
          Last_Dest := Dest_Node;

          exit when State.Current_Token > Max_Tokens
            or else Tokens (State.Current_Token).Kind = Tok_R_Paren
            or else Tokens (State.Current_Token).Kind not in Tok_Comma | Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States;
          if Tokens (State.Current_Token).Kind = Tok_Comma then
             State.Current_Token := State.Current_Token + 1;
          else
             exit;
          end if;
       end loop;

       if Uses_Parens then
          if State.Current_Token <= Max_Tokens and then Tokens (State.Current_Token).Kind = Tok_R_Paren then
             State.Current_Token := State.Current_Token + 1;
          end if;
       end if;
    end Parse_Parse_IP_Stmt;

    procedure Parse_Parse_TCP_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
       Uses_Parens : Boolean := False;
       Src_Node    : Node_Index := 0;
       Dest_Node   : Node_Index := 0;
       First_Dest  : Node_Index := 0;
       Last_Dest   : Node_Index := 0;
    begin
       Allocate_Node (Tokens, State, Tree, AST_Parse_TCP_Stmt, Node, Success);
       if not Success then return; end if;
       Tree (Node).Token_Index := State.Current_Token;
       State.Current_Token := State.Current_Token + 1; -- Consume PARSE_TCP

       if State.Current_Token <= Max_Tokens
         and then Tokens (State.Current_Token).Kind = Tok_L_Paren
       then
          Uses_Parens := True;
          State.Current_Token := State.Current_Token + 1;
       end if;

       if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_From then
          Set_Error (State, Tokens, Err_Parse_Expected_Value);
          Success := False;
          return;
       end if;
       State.Current_Token := State.Current_Token + 1; -- Consume FROM

       Parse_Expression (Tokens, State, Tree, Src_Node, Success);
       if not Success then return; end if;
       Tree (Node).Left_Child := Src_Node;

       if Uses_Parens then
          if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Comma then
             Set_Error (State, Tokens, Err_Parse_Expected_Value);
             Success := False;
             return;
          end if;
          State.Current_Token := State.Current_Token + 1;
       else
          if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Into then
             Set_Error (State, Tokens, Err_Parse_Expected_Value);
             Success := False;
             return;
          end if;
          State.Current_Token := State.Current_Token + 1;
       end if;

       loop
          Parse_Expression (Tokens, State, Tree, Dest_Node, Success);
          if not Success then return; end if;

          if First_Dest = 0 then
             First_Dest := Dest_Node;
             Tree (Node).Right_Child := First_Dest;
          else
             Tree (Last_Dest).Next_Sibling := Dest_Node;
          end if;
          Last_Dest := Dest_Node;

          exit when State.Current_Token > Max_Tokens
            or else Tokens (State.Current_Token).Kind = Tok_R_Paren
            or else Tokens (State.Current_Token).Kind not in Tok_Comma | Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States;
          if Tokens (State.Current_Token).Kind = Tok_Comma then
             State.Current_Token := State.Current_Token + 1;
          else
             exit;
          end if;
       end loop;

       if Uses_Parens then
          if State.Current_Token <= Max_Tokens and then Tokens (State.Current_Token).Kind = Tok_R_Paren then
             State.Current_Token := State.Current_Token + 1;
          end if;
       end if;
    end Parse_Parse_TCP_Stmt;

   procedure Parse_Encrypt_Or_Decrypt_File_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Kind : Node_Kind; Node : out Node_Index; Success : out Boolean) is
      Uses_Parens : Boolean := False;
      Source_Node : Node_Index := 0;
      Key_Node    : Node_Index := 0;
      Path_Node   : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, Kind, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1;

      if State.Current_Token <= Max_Tokens
        and then Tokens (State.Current_Token).Kind = Tok_L_Paren
      then
         Uses_Parens := True;
         State.Current_Token := State.Current_Token + 1;
      end if;

      Parse_Expression (Tokens, State, Tree, Source_Node, Success);
      if not Success then return; end if;
      Tree (Node).Left_Child := Source_Node;

      if Uses_Parens then
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Comma then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      else
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_With then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      end if;

      Parse_Expression (Tokens, State, Tree, Key_Node, Success);
      if not Success then return; end if;
      Tree (Node).Right_Child := Key_Node;

      if Uses_Parens then
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Comma then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      else
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Into then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      end if;

      Parse_Expression (Tokens, State, Tree, Path_Node, Success);
      if not Success then return; end if;
      Tree (Key_Node).Next_Sibling := Path_Node;

      if Uses_Parens then
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_R_Paren then
            Set_Error (State, Tokens, Err_Parse_Missing_Bracket);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      end if;
   end Parse_Encrypt_Or_Decrypt_File_Stmt;

   procedure Parse_Markov_Model_Decl (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Name_Node      : Node_Index := 0;
      Setting_Node   : Node_Index := 0;
      Value_Node     : Node_Index := 0;
      First_Setting  : Node_Index := 0;
      Last_Setting   : Node_Index := 0;
      Row_Node       : Node_Index := 0;
      First_Row      : Node_Index := 0;
      Last_Row       : Node_Index := 0;
      Elem_Node      : Node_Index := 0;
      First_Elem     : Node_Index := 0;
      Last_Elem      : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Markov_Model_Decl, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume MARKOV_MODEL

      if State.Current_Token > Max_Tokens
        or else Tokens (State.Current_Token).Kind not in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States
      then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;

      Allocate_Node (Tokens, State, Tree, AST_Var_Expr, Name_Node, Success);
      if not Success then return; end if;
      Tree (Name_Node).Token_Index := State.Current_Token;
      Tree (Node).Left_Child := Name_Node;
      State.Current_Token := State.Current_Token + 1;

      loop
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind = Tok_Error then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;

         exit when Tokens (State.Current_Token).Kind = Tok_End_Model;

         case Tokens (State.Current_Token).Kind is
            when Tok_States =>
               Allocate_Node (Tokens, State, Tree, AST_Markov_States, Setting_Node, Success);
               if not Success then return; end if;
               Tree (Setting_Node).Token_Index := State.Current_Token;
               State.Current_Token := State.Current_Token + 1;

               Parse_Expression (Tokens, State, Tree, Value_Node, Success);
               if not Success then return; end if;
               Tree (Setting_Node).Left_Child := Value_Node;

            when Tok_Transition_Matrix =>
               Allocate_Node (Tokens, State, Tree, AST_Markov_Transition_Matrix, Setting_Node, Success);
               if not Success then return; end if;
               Tree (Setting_Node).Token_Index := State.Current_Token;
               State.Current_Token := State.Current_Token + 1;

               First_Row := 0;
               Last_Row := 0;

               loop
                  if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind = Tok_Error then
                     Set_Error (State, Tokens, Err_Parse_Expected_Value);
                     Success := False;
                     return;
                  end if;

                  exit when Tokens (State.Current_Token).Kind = Tok_End_Matrix;

                  if Tokens (State.Current_Token).Kind /= Tok_L_Square then
                     Set_Error (State, Tokens, Err_Parse_Expected_Value);
                     Success := False;
                     return;
                  end if;
                  State.Current_Token := State.Current_Token + 1; -- Consume '['

                  Allocate_Node (Tokens, State, Tree, AST_Markov_Matrix_Row, Row_Node, Success);
                  if not Success then return; end if;
                  First_Elem := 0;
                  Last_Elem := 0;

                  loop
                     Parse_Expression (Tokens, State, Tree, Elem_Node, Success);
                     if not Success then return; end if;

                     if First_Elem = 0 then
                        First_Elem := Elem_Node;
                        Tree (Row_Node).Left_Child := First_Elem;
                     else
                        Tree (Last_Elem).Next_Sibling := Elem_Node;
                     end if;
                     Last_Elem := Elem_Node;

                     exit when State.Current_Token <= Max_Tokens
                       and then Tokens (State.Current_Token).Kind = Tok_R_Square;

                     if State.Current_Token <= Max_Tokens
                       and then Tokens (State.Current_Token).Kind = Tok_Comma
                     then
                        State.Current_Token := State.Current_Token + 1;
                     else
                        Set_Error (State, Tokens, Err_Parse_Expected_Value);
                        Success := False;
                        return;
                     end if;
                  end loop;

                  if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_R_Square then
                     Set_Error (State, Tokens, Err_Parse_Missing_Bracket);
                     Success := False;
                     return;
                  end if;
                  State.Current_Token := State.Current_Token + 1; -- Consume ']'

                  if First_Row = 0 then
                     First_Row := Row_Node;
                     Tree (Setting_Node).Left_Child := First_Row;
                  else
                     Tree (Last_Row).Next_Sibling := Row_Node;
                  end if;
                  Last_Row := Row_Node;
               end loop;

               State.Current_Token := State.Current_Token + 1; -- Consume END_MATRIX

            when others =>
               Set_Error (State, Tokens, Err_Parse_Expected_Value);
               Success := False;
               return;
         end case;

         if First_Setting = 0 then
            First_Setting := Setting_Node;
            Tree (Node).Right_Child := First_Setting;
         else
            Tree (Last_Setting).Next_Sibling := Setting_Node;
         end if;
         Last_Setting := Setting_Node;
      end loop;

      State.Current_Token := State.Current_Token + 1; -- Consume END_MODEL
      Success := True;
   end Parse_Markov_Model_Decl;

   procedure Parse_Predict_Markov_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Model_Node  : Node_Index := 0;
      Input_Node  : Node_Index := 0;
      Output_Node : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Predict_Markov_Stmt, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume PREDICT_MARKOV

      Parse_Expression (Tokens, State, Tree, Model_Node, Success);
      if not Success then return; end if;
      Tree (Node).Left_Child := Model_Node;

      if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_From then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1;

      Parse_Expression (Tokens, State, Tree, Input_Node, Success);
      if not Success then return; end if;

      if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Into then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1;

      Parse_Expression (Tokens, State, Tree, Output_Node, Success);
      if not Success then return; end if;

      Tree (Node).Right_Child := Input_Node;
      Tree (Input_Node).Next_Sibling := Output_Node;
      Parse_Optional_With_Emotion (Tokens, State, Tree, Output_Node, Success);
   end Parse_Predict_Markov_Stmt;

   procedure Parse_Neural_Topology_Decl (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Name_Node    : Node_Index := 0;
      Layer_Node   : Node_Index := 0;
      Size_Node    : Node_Index := 0;
      Act_Node     : Node_Index := 0;
      First_Layer  : Node_Index := 0;
      Last_Layer   : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Neural_Topology_Decl, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume NEURAL_TOPOLOGY

      if State.Current_Token > Max_Tokens
        or else Tokens (State.Current_Token).Kind not in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States
      then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;

      Allocate_Node (Tokens, State, Tree, AST_Var_Expr, Name_Node, Success);
      if not Success then return; end if;
      Tree (Name_Node).Token_Index := State.Current_Token;
      Tree (Node).Left_Child := Name_Node;
      State.Current_Token := State.Current_Token + 1;

      loop
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind = Tok_Error then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;

         exit when Tokens (State.Current_Token).Kind = Tok_End_Topology;

         if Tokens (State.Current_Token).Kind /= Tok_Layer then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1; -- Consume LAYER

         if State.Current_Token > Max_Tokens
           or else Tokens (State.Current_Token).Kind not in Tok_Input | Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States
         then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;

         Allocate_Node (Tokens, State, Tree, AST_Neural_Layer, Layer_Node, Success);
         if not Success then return; end if;
         Tree (Layer_Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1; -- Consume layer kind

         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Size then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1; -- Consume SIZE

         Parse_Expression (Tokens, State, Tree, Size_Node, Success);
         if not Success then return; end if;
         Tree (Layer_Node).Left_Child := Size_Node;

         if State.Current_Token <= Max_Tokens and then Tokens (State.Current_Token).Kind = Tok_Activation then
            State.Current_Token := State.Current_Token + 1; -- Consume ACTIVATION

            if State.Current_Token > Max_Tokens
              or else Tokens (State.Current_Token).Kind not in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States
            then
               Set_Error (State, Tokens, Err_Parse_Expected_Value);
               Success := False;
               return;
            end if;

            Allocate_Node (Tokens, State, Tree, AST_Var_Expr, Act_Node, Success);
            if not Success then return; end if;
            Tree (Act_Node).Token_Index := State.Current_Token;
            Tree (Layer_Node).Right_Child := Act_Node;
            State.Current_Token := State.Current_Token + 1;
         end if;

         if First_Layer = 0 then
            First_Layer := Layer_Node;
            Tree (Node).Right_Child := First_Layer;
         else
            Tree (Last_Layer).Next_Sibling := Layer_Node;
         end if;
         Last_Layer := Layer_Node;
      end loop;

      State.Current_Token := State.Current_Token + 1; -- Consume END_TOPOLOGY
      Success := True;
   end Parse_Neural_Topology_Decl;

   procedure Parse_Infer_Network_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Model_Node  : Node_Index := 0;
      Input_Node  : Node_Index := 0;
      Output_Node : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Infer_Network_Stmt, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume INFER_NETWORK

      Parse_Expression (Tokens, State, Tree, Model_Node, Success);
      if not Success then return; end if;
      Tree (Node).Left_Child := Model_Node;

      if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_From then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1;

      Parse_Expression (Tokens, State, Tree, Input_Node, Success);
      if not Success then return; end if;

      if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Into then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1;

      Parse_Expression (Tokens, State, Tree, Output_Node, Success);
      if not Success then return; end if;

      Tree (Node).Right_Child := Input_Node;
      Tree (Input_Node).Next_Sibling := Output_Node;
      Parse_Optional_With_Emotion (Tokens, State, Tree, Output_Node, Success);
   end Parse_Infer_Network_Stmt;

   procedure Parse_Optional_With_Emotion
     (Tokens  : in Token_Array;
      State   : in out Parser_State;
      Tree    : in out Node_Array;
      Attach  : in Node_Index;
      Success : out Boolean)
   is
      Emotion_Node : Node_Index := 0;
   begin
      Success := True;
      if State.Current_Token > Max_Tokens
        or else Tokens (State.Current_Token).Kind /= Tok_With
      then
         return;
      end if;
      State.Current_Token := State.Current_Token + 1;

      if State.Current_Token > Max_Tokens
        or else Tokens (State.Current_Token).Kind /= Tok_Emotion
      then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1;

      Parse_Expression (Tokens, State, Tree, Emotion_Node, Success);
      if not Success then
         return;
      end if;
      Tree (Attach).Next_Sibling := Emotion_Node;
   end Parse_Optional_With_Emotion;

   procedure Parse_Emotion_Decl
     (Tokens  : in Token_Array;
      State   : in out Parser_State;
      Tree    : in out Node_Array;
      Node    : out Node_Index;
      Success : out Boolean)
   is
      Name_Node  : Node_Index := 0;
      Axes_Node  : Node_Index := 0;
      Axis_Node  : Node_Index := 0;
      First_Axis : Node_Index := 0;
      Last_Axis  : Node_Index := 0;
      Axis_Count : Natural := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Emotion_Decl, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- EMOTION

      if State.Current_Token > Max_Tokens
        or else Tokens (State.Current_Token).Kind not in
          Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width |
          Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format |
          Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs |
          Tok_Bounds | Tok_States
      then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;

      Allocate_Node (Tokens, State, Tree, AST_Var_Expr, Name_Node, Success);
      if not Success then return; end if;
      Tree (Name_Node).Token_Index := State.Current_Token;
      Tree (Node).Left_Child := Name_Node;
      State.Current_Token := State.Current_Token + 1;

      if State.Current_Token > Max_Tokens
        or else Tokens (State.Current_Token).Kind /= Tok_Axes
      then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1;

      Allocate_Node (Tokens, State, Tree, AST_Emotion_Axes, Axes_Node, Success);
      if not Success then return; end if;
      Tree (Axes_Node).Token_Index := State.Current_Token;
      Tree (Node).Right_Child := Axes_Node;

      loop
         if State.Current_Token > Max_Tokens
           or else Tokens (State.Current_Token).Kind = Tok_Error
         then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;

         exit when Tokens (State.Current_Token).Kind = Tok_End_Emotion;

         if Tokens (State.Current_Token).Kind not in Tok_Logic_Var | Tok_Atom then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;

         if Axis_Count >= 8 then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;

         Allocate_Node (Tokens, State, Tree, AST_Var_Expr, Axis_Node, Success);
         if not Success then return; end if;
         Tree (Axis_Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1;
         Axis_Count := Axis_Count + 1;

         if First_Axis = 0 then
            First_Axis := Axis_Node;
            Tree (Axes_Node).Left_Child := First_Axis;
         else
            Tree (Last_Axis).Next_Sibling := Axis_Node;
         end if;
         Last_Axis := Axis_Node;
      end loop;

      if Axis_Count = 0 then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;

      State.Current_Token := State.Current_Token + 1; -- END_EMOTION
      Success := True;
   end Parse_Emotion_Decl;

   procedure Parse_Emotion_Axis_Pair_Stmt
     (Tokens     : in Token_Array;
      State      : in out Parser_State;
      Tree       : in out Node_Array;
      Kind       : Node_Kind;
      Node       : out Node_Index;
      Success    : out Boolean;
      Need_Into  : Boolean)
   is
      Emotion_Node : Node_Index := 0;
      Axis_Node    : Node_Index := 0;
      Value_Node   : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, Kind, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1;

      Parse_Expression (Tokens, State, Tree, Emotion_Node, Success);
      if not Success then return; end if;
      Tree (Node).Left_Child := Emotion_Node;

      Parse_Expression (Tokens, State, Tree, Axis_Node, Success);
      if not Success then return; end if;
      Tree (Node).Right_Child := Axis_Node;

      if Need_Into then
         if State.Current_Token > Max_Tokens
           or else Tokens (State.Current_Token).Kind /= Tok_Into
         then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      end if;

      Parse_Expression (Tokens, State, Tree, Value_Node, Success);
      if not Success then return; end if;
      Tree (Axis_Node).Next_Sibling := Value_Node;
   end Parse_Emotion_Axis_Pair_Stmt;

   procedure Parse_Set_Axis_Stmt
     (Tokens  : in Token_Array;
      State   : in out Parser_State;
      Tree    : in out Node_Array;
      Node    : out Node_Index;
      Success : out Boolean) is
   begin
      Parse_Emotion_Axis_Pair_Stmt
        (Tokens, State, Tree, AST_Set_Axis_Stmt, Node, Success, False);
   end Parse_Set_Axis_Stmt;

   procedure Parse_Add_Axis_Stmt
     (Tokens  : in Token_Array;
      State   : in out Parser_State;
      Tree    : in out Node_Array;
      Node    : out Node_Index;
      Success : out Boolean) is
   begin
      Parse_Emotion_Axis_Pair_Stmt
        (Tokens, State, Tree, AST_Add_Axis_Stmt, Node, Success, False);
   end Parse_Add_Axis_Stmt;

   procedure Parse_Get_Axis_Stmt
     (Tokens  : in Token_Array;
      State   : in out Parser_State;
      Tree    : in out Node_Array;
      Node    : out Node_Index;
      Success : out Boolean) is
   begin
      Parse_Emotion_Axis_Pair_Stmt
        (Tokens, State, Tree, AST_Get_Axis_Stmt, Node, Success, True);
   end Parse_Get_Axis_Stmt;

   procedure Parse_Blend_Emotion_Stmt
     (Tokens  : in Token_Array;
      State   : in out Parser_State;
      Tree    : in out Node_Array;
      Node    : out Node_Index;
      Success : out Boolean)
   is
      Emotion_Node : Node_Index := 0;
      Axis_Node    : Node_Index := 0;
      Amount_Node  : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Blend_Emotion_Stmt, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1;

      Parse_Expression (Tokens, State, Tree, Emotion_Node, Success);
      if not Success then return; end if;
      Tree (Node).Left_Child := Emotion_Node;

      if State.Current_Token > Max_Tokens
        or else Tokens (State.Current_Token).Kind /= Tok_To
      then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1;

      Parse_Expression (Tokens, State, Tree, Axis_Node, Success);
      if not Success then return; end if;
      Tree (Node).Right_Child := Axis_Node;

      if State.Current_Token > Max_Tokens
        or else Tokens (State.Current_Token).Kind /= Tok_By
      then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1;

      Parse_Expression (Tokens, State, Tree, Amount_Node, Success);
      if not Success then return; end if;
      Tree (Axis_Node).Next_Sibling := Amount_Node;
   end Parse_Blend_Emotion_Stmt;

   procedure Parse_Decay_Emotion_Stmt
     (Tokens  : in Token_Array;
      State   : in out Parser_State;
      Tree    : in out Node_Array;
      Node    : out Node_Index;
      Success : out Boolean)
   is
      Emotion_Node : Node_Index := 0;
      Amount_Node  : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Decay_Emotion_Stmt, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1;

      Parse_Expression (Tokens, State, Tree, Emotion_Node, Success);
      if not Success then return; end if;
      Tree (Node).Left_Child := Emotion_Node;

      if State.Current_Token > Max_Tokens
        or else Tokens (State.Current_Token).Kind /= Tok_By
      then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1;

      Parse_Expression (Tokens, State, Tree, Amount_Node, Success);
      if not Success then return; end if;
      Tree (Node).Right_Child := Amount_Node;
   end Parse_Decay_Emotion_Stmt;

   procedure Parse_Dominant_Emotion_Stmt
     (Tokens  : in Token_Array;
      State   : in out Parser_State;
      Tree    : in out Node_Array;
      Node    : out Node_Index;
      Success : out Boolean)
   is
      Emotion_Node : Node_Index := 0;
      Output_Node  : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Dominant_Emotion_Stmt, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1;

      Parse_Expression (Tokens, State, Tree, Emotion_Node, Success);
      if not Success then return; end if;
      Tree (Node).Left_Child := Emotion_Node;

      if State.Current_Token > Max_Tokens
        or else Tokens (State.Current_Token).Kind /= Tok_Into
      then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1;

      Parse_Expression (Tokens, State, Tree, Output_Node, Success);
      if not Success then return; end if;
      Tree (Node).Right_Child := Output_Node;
   end Parse_Dominant_Emotion_Stmt;

   procedure Parse_Train_Network_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Model_Node    : Node_Index := 0;
      Train_Node    : Node_Index := 0;
      Expect_Node   : Node_Index := 0;
      Epochs_Node   : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Train_Network_Stmt, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume TRAIN_NETWORK

      Parse_Expression (Tokens, State, Tree, Model_Node, Success);
      if not Success then return; end if;
      Tree (Node).Left_Child := Model_Node;

      if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_With then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1;

      Parse_Expression (Tokens, State, Tree, Train_Node, Success);
      if not Success then return; end if;

      if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Expected then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1;

      Parse_Expression (Tokens, State, Tree, Expect_Node, Success);
      if not Success then return; end if;

      Tree (Node).Right_Child := Train_Node;
      Tree (Train_Node).Next_Sibling := Expect_Node;

      if State.Current_Token <= Max_Tokens and then Tokens (State.Current_Token).Kind = Tok_Epochs then
         State.Current_Token := State.Current_Token + 1;
         Parse_Expression (Tokens, State, Tree, Epochs_Node, Success);
         if not Success then return; end if;
         Tree (Expect_Node).Next_Sibling := Epochs_Node;
      end if;
   end Parse_Train_Network_Stmt;

   procedure Parse_Bitmap_Font_Decl (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Name_Node     : Node_Index := 0;
      Setting_Node  : Node_Index := 0;
      Value_Node    : Node_Index := 0;
      First_Setting : Node_Index := 0;
      Last_Setting  : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Bitmap_Font_Decl, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1;

      if State.Current_Token > Max_Tokens
        or else Tokens (State.Current_Token).Kind not in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States
      then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;

      Allocate_Node (Tokens, State, Tree, AST_Var_Expr, Name_Node, Success);
      if not Success then return; end if;
      Tree (Name_Node).Token_Index := State.Current_Token;
      Tree (Node).Left_Child := Name_Node;
      State.Current_Token := State.Current_Token + 1;

      loop
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind = Tok_Error then
            Set_Error (State, Tokens, Err_Parse_Expected_Block_End);
            Success := False;
            return;
         end if;

         exit when Same_Line_End_Tag (Tokens, State, Tok_Bitmap_Font);

         case Tokens (State.Current_Token).Kind is
            when Tok_Source =>
               Allocate_Node (Tokens, State, Tree, AST_Static_Source, Setting_Node, Success);
            when Tok_Descriptor =>
               Allocate_Node (Tokens, State, Tree, AST_Font_Descriptor, Setting_Node, Success);
            when Tok_Format =>
               Allocate_Node (Tokens, State, Tree, AST_Static_Format, Setting_Node, Success);
            when Tok_Glyph_Width =>
               Allocate_Node (Tokens, State, Tree, AST_Font_Glyph_Width, Setting_Node, Success);
            when Tok_Glyph_Height =>
               Allocate_Node (Tokens, State, Tree, AST_Font_Glyph_Height, Setting_Node, Success);
            when Tok_First_Char =>
               Allocate_Node (Tokens, State, Tree, AST_Font_First_Char, Setting_Node, Success);
            when Tok_Spacing =>
               Allocate_Node (Tokens, State, Tree, AST_Font_Spacing, Setting_Node, Success);
            when others =>
               Set_Error (State, Tokens, Err_Parse_Expected_Value);
               Success := False;
               return;
         end case;
         if not Success then return; end if;

         Tree (Setting_Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1;

         Parse_Expression (Tokens, State, Tree, Value_Node, Success);
         if not Success then return; end if;
         Tree (Setting_Node).Left_Child := Value_Node;

         Append_Chained_Node (Tree, First_Setting, Last_Setting, Setting_Node);
      end loop;

      Tree (Node).Right_Child := First_Setting;
      Consume_Typed_End_Tag (Tokens, State, Tok_Bitmap_Font, Success);
   end Parse_Bitmap_Font_Decl;

   procedure Parse_System_Font_Decl (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Name_Node     : Node_Index := 0;
      Setting_Node  : Node_Index := 0;
      Value_Node    : Node_Index := 0;
      Range_End     : Node_Index := 0;
      First_Setting : Node_Index := 0;
      Last_Setting  : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_System_Font_Decl, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1;

      if State.Current_Token > Max_Tokens
        or else Tokens (State.Current_Token).Kind not in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States
      then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;

      Allocate_Node (Tokens, State, Tree, AST_Var_Expr, Name_Node, Success);
      if not Success then return; end if;
      Tree (Name_Node).Token_Index := State.Current_Token;
      Tree (Node).Left_Child := Name_Node;
      State.Current_Token := State.Current_Token + 1;

      loop
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind = Tok_Error then
            Set_Error (State, Tokens, Err_Parse_Expected_Block_End);
            Success := False;
            return;
         end if;

         exit when Same_Line_End_Tag (Tokens, State, Tok_System_Font);

         case Tokens (State.Current_Token).Kind is
            when Tok_Source =>
               Allocate_Node (Tokens, State, Tree, AST_Static_Source, Setting_Node, Success);
               if not Success then return; end if;
               Tree (Setting_Node).Token_Index := State.Current_Token;
               State.Current_Token := State.Current_Token + 1;

               Parse_Expression (Tokens, State, Tree, Value_Node, Success);
               if not Success then return; end if;
               Tree (Setting_Node).Left_Child := Value_Node;

            when Tok_Size =>
               Allocate_Node (Tokens, State, Tree, AST_Font_Size, Setting_Node, Success);
               if not Success then return; end if;
               Tree (Setting_Node).Token_Index := State.Current_Token;
               State.Current_Token := State.Current_Token + 1;

               Parse_Expression (Tokens, State, Tree, Value_Node, Success);
               if not Success then return; end if;
               Tree (Setting_Node).Left_Child := Value_Node;

            when Tok_Weight =>
               Allocate_Node (Tokens, State, Tree, AST_Font_Weight, Setting_Node, Success);
               if not Success then return; end if;
               Tree (Setting_Node).Token_Index := State.Current_Token;
               State.Current_Token := State.Current_Token + 1;

               Parse_Expression (Tokens, State, Tree, Value_Node, Success);
               if not Success then return; end if;
               Tree (Setting_Node).Left_Child := Value_Node;

            when Tok_Anti_Alias =>
               Allocate_Node (Tokens, State, Tree, AST_Font_Anti_Alias, Setting_Node, Success);
               if not Success then return; end if;
               Tree (Setting_Node).Token_Index := State.Current_Token;
               State.Current_Token := State.Current_Token + 1;

               Parse_Expression (Tokens, State, Tree, Value_Node, Success);
               if not Success then return; end if;
               Tree (Setting_Node).Left_Child := Value_Node;

            when Tok_Character_Set =>
               Allocate_Node (Tokens, State, Tree, AST_Font_Character_Set, Setting_Node, Success);
               if not Success then return; end if;
               Tree (Setting_Node).Token_Index := State.Current_Token;
               State.Current_Token := State.Current_Token + 1;

               Parse_Expression (Tokens, State, Tree, Value_Node, Success);
               if not Success then return; end if;
               Tree (Setting_Node).Left_Child := Value_Node;

               if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_To then
                  Set_Error (State, Tokens, Err_Parse_Expected_Value);
                  Success := False;
                  return;
               end if;
               State.Current_Token := State.Current_Token + 1;

               Parse_Expression (Tokens, State, Tree, Range_End, Success);
               if not Success then return; end if;
               Tree (Setting_Node).Right_Child := Range_End;

            when others =>
               Set_Error (State, Tokens, Err_Parse_Expected_Value);
               Success := False;
               return;
         end case;

         Append_Chained_Node (Tree, First_Setting, Last_Setting, Setting_Node);
      end loop;

      Tree (Node).Right_Child := First_Setting;
      Consume_Typed_End_Tag (Tokens, State, Tok_System_Font, Success);
   end Parse_System_Font_Decl;

   procedure Parse_Static_Sprite_Decl (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Name_Node     : Node_Index := 0;
      Setting_Node  : Node_Index := 0;
      Value_Node    : Node_Index := 0;
      First_Setting : Node_Index := 0;
      Last_Setting  : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Static_Sprite_Decl, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1;

      if State.Current_Token > Max_Tokens
        or else Tokens (State.Current_Token).Kind not in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States
      then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;

      Allocate_Node (Tokens, State, Tree, AST_Var_Expr, Name_Node, Success);
      if not Success then return; end if;
      Tree (Name_Node).Token_Index := State.Current_Token;
      Tree (Node).Left_Child := Name_Node;
      State.Current_Token := State.Current_Token + 1;

      loop
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind = Tok_Error then
            Set_Error (State, Tokens, Err_Parse_Expected_Block_End);
            Success := False;
            return;
         end if;

         exit when Same_Line_End_Tag (Tokens, State, Tok_Static_Sprite);

         case Tokens (State.Current_Token).Kind is
            when Tok_Source =>
               Allocate_Node (Tokens, State, Tree, AST_Static_Source, Setting_Node, Success);
            when Tok_Format =>
               Allocate_Node (Tokens, State, Tree, AST_Static_Format, Setting_Node, Success);
            when Tok_Width =>
               Allocate_Node (Tokens, State, Tree, AST_Static_Width, Setting_Node, Success);
            when Tok_Height =>
               Allocate_Node (Tokens, State, Tree, AST_Static_Height, Setting_Node, Success);
            when Tok_Frames =>
               Allocate_Node (Tokens, State, Tree, AST_Static_Frames, Setting_Node, Success);
            when others =>
               Set_Error (State, Tokens, Err_Parse_Expected_Value);
               Success := False;
               return;
         end case;
         if not Success then return; end if;

         Tree (Setting_Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1;

         Parse_Expression (Tokens, State, Tree, Value_Node, Success);
         if not Success then return; end if;
         Tree (Setting_Node).Left_Child := Value_Node;

         Append_Chained_Node (Tree, First_Setting, Last_Setting, Setting_Node);
      end loop;

      Tree (Node).Right_Child := First_Setting;
      Consume_Typed_End_Tag (Tokens, State, Tok_Static_Sprite, Success);
   end Parse_Static_Sprite_Decl;

   procedure Parse_Static_Surface_Decl (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Name_Node     : Node_Index := 0;
      Setting_Node  : Node_Index := 0;
      Value_Node    : Node_Index := 0;
      First_Setting : Node_Index := 0;
      Last_Setting  : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Static_Surface_Decl, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1;

      if State.Current_Token > Max_Tokens
        or else Tokens (State.Current_Token).Kind not in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States
      then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;

      Allocate_Node (Tokens, State, Tree, AST_Var_Expr, Name_Node, Success);
      if not Success then return; end if;
      Tree (Name_Node).Token_Index := State.Current_Token;
      Tree (Node).Left_Child := Name_Node;
      State.Current_Token := State.Current_Token + 1;

      loop
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind = Tok_Error then
            Set_Error (State, Tokens, Err_Parse_Expected_Block_End);
            Success := False;
            return;
         end if;

         exit when Same_Line_End_Tag (Tokens, State, Tok_Static_Surface);

         case Tokens (State.Current_Token).Kind is
            when Tok_Format =>
               Allocate_Node (Tokens, State, Tree, AST_Static_Format, Setting_Node, Success);
            when Tok_Width =>
               Allocate_Node (Tokens, State, Tree, AST_Static_Width, Setting_Node, Success);
            when Tok_Height =>
               Allocate_Node (Tokens, State, Tree, AST_Static_Height, Setting_Node, Success);
            when others =>
               Set_Error (State, Tokens, Err_Parse_Expected_Value);
               Success := False;
               return;
         end case;
         if not Success then return; end if;

         Tree (Setting_Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1;

         Parse_Expression (Tokens, State, Tree, Value_Node, Success);
         if not Success then return; end if;
         Tree (Setting_Node).Left_Child := Value_Node;

         Append_Chained_Node (Tree, First_Setting, Last_Setting, Setting_Node);
      end loop;

      Tree (Node).Right_Child := First_Setting;
      Consume_Typed_End_Tag (Tokens, State, Tok_Static_Surface, Success);
   end Parse_Static_Surface_Decl;

   procedure Parse_Color_Lut_Decl (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Name_Node   : Node_Index := 0;
      Entry_Node  : Node_Index := 0;
      Index_Node  : Node_Index := 0;
      Value_Node  : Node_Index := 0;
      First_Entry : Node_Index := 0;
      Last_Entry  : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Color_Lut_Decl, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1;

      if State.Current_Token > Max_Tokens
        or else Tokens (State.Current_Token).Kind not in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States
      then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;

      Allocate_Node (Tokens, State, Tree, AST_Var_Expr, Name_Node, Success);
      if not Success then return; end if;
      Tree (Name_Node).Token_Index := State.Current_Token;
      Tree (Node).Left_Child := Name_Node;
      State.Current_Token := State.Current_Token + 1;

      loop
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind = Tok_Error then
            Set_Error (State, Tokens, Err_Parse_Expected_Block_End);
            Success := False;
            return;
         end if;

         exit when Same_Line_End_Tag (Tokens, State, Tok_Color_Lut);

         if Tokens (State.Current_Token).Kind /= Tok_Entry then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;

         Allocate_Node (Tokens, State, Tree, AST_Color_Lut_Entry, Entry_Node, Success);
         if not Success then return; end if;
         Tree (Entry_Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1;

         Parse_Expression (Tokens, State, Tree, Index_Node, Success);
         if not Success then return; end if;
         Tree (Entry_Node).Left_Child := Index_Node;

         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Is then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;

         Parse_Expression (Tokens, State, Tree, Value_Node, Success);
         if not Success then return; end if;
         Tree (Entry_Node).Right_Child := Value_Node;

         Append_Chained_Node (Tree, First_Entry, Last_Entry, Entry_Node);
      end loop;

      Tree (Node).Right_Child := First_Entry;
      Consume_Typed_End_Tag (Tokens, State, Tok_Color_Lut, Success);
   end Parse_Color_Lut_Decl;

   procedure Parse_Visual_Rule_Decl (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Name_Node     : Node_Index := 0;
      List_Node     : Node_Index := 0;
      First_Arg     : Node_Index := 0;
      Arg_Node      : Node_Index := 0;
      Last_Arg      : Node_Index := 0;
      Clause_Node   : Node_Index := 0;
      Cond_Node     : Node_Index := 0;
      Visual_Node   : Node_Index := 0;
      Frame_Node    : Node_Index := 0;
      First_Clause  : Node_Index := 0;
      Last_Clause   : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Visual_Rule_Decl, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1;

      if State.Current_Token > Max_Tokens
        or else Tokens (State.Current_Token).Kind not in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States
      then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;

      Allocate_Node (Tokens, State, Tree, AST_Var_Expr, Name_Node, Success);
      if not Success then return; end if;
      Tree (Name_Node).Token_Index := State.Current_Token;
      Tree (Node).Left_Child := Name_Node;
      State.Current_Token := State.Current_Token + 1;

      if State.Current_Token <= Max_Tokens and then Tokens (State.Current_Token).Kind = Tok_L_Paren then
         State.Current_Token := State.Current_Token + 1;

         Allocate_Node (Tokens, State, Tree, AST_Arg_List, List_Node, Success);
         if not Success then return; end if;
         Tree (Name_Node).Right_Child := List_Node;

         if State.Current_Token <= Max_Tokens and then Tokens (State.Current_Token).Kind /= Tok_R_Paren then
            for I in 1 .. 64 loop
               Parse_Expression (Tokens, State, Tree, Arg_Node, Success);
               if not Success then return; end if;
               Append_Chained_Node (Tree, First_Arg, Last_Arg, Arg_Node);

               exit when State.Current_Token > Max_Tokens
                 or else Tokens (State.Current_Token).Kind /= Tok_Comma;
               State.Current_Token := State.Current_Token + 1;
            end loop;
         end if;

         Tree (List_Node).Left_Child := First_Arg;

         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_R_Paren then
            Set_Error (State, Tokens, Err_Parse_Missing_Bracket);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;
      end if;

      loop
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind = Tok_Error then
            Set_Error (State, Tokens, Err_Parse_Expected_Block_End);
            Success := False;
            return;
         end if;

         exit when Same_Line_End_Tag (Tokens, State, Tok_Visual_Rule);

         if Tokens (State.Current_Token).Kind = Tok_When then
            Allocate_Node (Tokens, State, Tree, AST_Visual_When_Clause, Clause_Node, Success);
            if not Success then return; end if;
            Tree (Clause_Node).Token_Index := State.Current_Token;
            State.Current_Token := State.Current_Token + 1;

            Parse_Expression (Tokens, State, Tree, Cond_Node, Success);
            if not Success then return; end if;
            Tree (Clause_Node).Left_Child := Cond_Node;

            if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Use then
               Set_Error (State, Tokens, Err_Parse_Expected_Value);
               Success := False;
               return;
            end if;
            State.Current_Token := State.Current_Token + 1;

            Parse_Expression (Tokens, State, Tree, Visual_Node, Success);
            if not Success then return; end if;
            Tree (Clause_Node).Right_Child := Visual_Node;

            if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Frame then
               Set_Error (State, Tokens, Err_Parse_Expected_Value);
               Success := False;
               return;
            end if;
            State.Current_Token := State.Current_Token + 1;

            Parse_Expression (Tokens, State, Tree, Frame_Node, Success);
            if not Success then return; end if;
            Tree (Visual_Node).Next_Sibling := Frame_Node;

         elsif Tokens (State.Current_Token).Kind = Tok_Default then
            Allocate_Node (Tokens, State, Tree, AST_Visual_Default_Clause, Clause_Node, Success);
            if not Success then return; end if;
            Tree (Clause_Node).Token_Index := State.Current_Token;
            State.Current_Token := State.Current_Token + 1;

            if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Use then
               Set_Error (State, Tokens, Err_Parse_Expected_Value);
               Success := False;
               return;
            end if;
            State.Current_Token := State.Current_Token + 1;

            Parse_Expression (Tokens, State, Tree, Visual_Node, Success);
            if not Success then return; end if;
            Tree (Clause_Node).Left_Child := Visual_Node;

            if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Frame then
               Set_Error (State, Tokens, Err_Parse_Expected_Value);
               Success := False;
               return;
            end if;
            State.Current_Token := State.Current_Token + 1;

            Parse_Expression (Tokens, State, Tree, Frame_Node, Success);
            if not Success then return; end if;
            Tree (Clause_Node).Right_Child := Frame_Node;

         else
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;

         Append_Chained_Node (Tree, First_Clause, Last_Clause, Clause_Node);
      end loop;

      Tree (Node).Right_Child := First_Clause;
      Consume_Typed_End_Tag (Tokens, State, Tok_Visual_Rule, Success);
   end Parse_Visual_Rule_Decl;

   procedure Parse_Render_Viewport_Decl (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Name_Node      : Node_Index := 0;
      Setting_Node   : Node_Index := 0;
      X_Node         : Node_Index := 0;
      Y_Node         : Node_Index := 0;
      W_Node         : Node_Index := 0;
      H_Node         : Node_Index := 0;
      First_Setting  : Node_Index := 0;
      Last_Setting   : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Render_Viewport_Decl, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1;

      if State.Current_Token > Max_Tokens
        or else Tokens (State.Current_Token).Kind not in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States
      then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;

      Allocate_Node (Tokens, State, Tree, AST_Var_Expr, Name_Node, Success);
      if not Success then return; end if;
      Tree (Name_Node).Token_Index := State.Current_Token;
      Tree (Node).Left_Child := Name_Node;
      State.Current_Token := State.Current_Token + 1;

      loop
         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind = Tok_Error then
            Set_Error (State, Tokens, Err_Parse_Expected_Block_End);
            Success := False;
            return;
         end if;

         exit when Same_Line_End_Tag (Tokens, State, Tok_Render_Viewport);

         if Tokens (State.Current_Token).Kind /= Tok_Bounds then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;

         Allocate_Node (Tokens, State, Tree, AST_Viewport_Bounds, Setting_Node, Success);
         if not Success then return; end if;
         Tree (Setting_Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1;

         Parse_Expression (Tokens, State, Tree, X_Node, Success);
         if not Success then return; end if;
         Tree (Setting_Node).Left_Child := X_Node;

         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Comma then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;

         Parse_Expression (Tokens, State, Tree, Y_Node, Success);
         if not Success then return; end if;
         Tree (Setting_Node).Right_Child := Y_Node;

         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Comma then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;

         Parse_Expression (Tokens, State, Tree, W_Node, Success);
         if not Success then return; end if;
         Tree (Y_Node).Next_Sibling := W_Node;

         if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Comma then
            Set_Error (State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;

         Parse_Expression (Tokens, State, Tree, H_Node, Success);
         if not Success then return; end if;
         Tree (W_Node).Next_Sibling := H_Node;

         Append_Chained_Node (Tree, First_Setting, Last_Setting, Setting_Node);
      end loop;

      Tree (Node).Right_Child := First_Setting;
      Consume_Typed_End_Tag (Tokens, State, Tok_Render_Viewport, Success);
   end Parse_Render_Viewport_Decl;

   procedure Parse_Use_Font_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Font_Node    : Node_Index := 0;
      Uses_Parens  : Boolean := False;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Use_Font_Stmt, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1;

      if State.Current_Token <= Max_Tokens
        and then Tokens (State.Current_Token).Kind = Tok_L_Paren
      then
         Uses_Parens := True;
         State.Current_Token := State.Current_Token + 1;
      end if;

      Parse_Expression (Tokens, State, Tree, Font_Node, Success);
      if not Success then return; end if;
      Tree (Node).Left_Child := Font_Node;

      if Uses_Parens then
         if State.Current_Token <= Max_Tokens
           and then Tokens (State.Current_Token).Kind = Tok_R_Paren
         then
            State.Current_Token := State.Current_Token + 1;
         else
            Set_Error (State, Tokens, Err_Parse_Missing_Bracket);
            Success := False;
            return;
         end if;
      end if;

      Success := True;
   end Parse_Use_Font_Stmt;

   procedure Parse_Apply_Lut_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Lut_Node    : Node_Index := 0;
      Visual_Node : Node_Index := 0;
      With_Node   : Node_Index := 0;
      Value_Node  : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Apply_Lut_Stmt, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1;

      Parse_Expression (Tokens, State, Tree, Lut_Node, Success);
      if not Success then return; end if;
      Tree (Node).Left_Child := Lut_Node;

      if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_To then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1;

      Parse_Expression (Tokens, State, Tree, Visual_Node, Success);
      if not Success then return; end if;
      Tree (Node).Right_Child := Visual_Node;

      if State.Current_Token <= Max_Tokens and then Tokens (State.Current_Token).Kind = Tok_With then
         Allocate_Node (Tokens, State, Tree, AST_With_Clause, With_Node, Success);
         if not Success then return; end if;
         Tree (With_Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1;

         Parse_Expression (Tokens, State, Tree, Value_Node, Success);
         if not Success then return; end if;
         Tree (With_Node).Left_Child := Value_Node;
         Tree (Visual_Node).Next_Sibling := With_Node;
      end if;
   end Parse_Apply_Lut_Stmt;

   procedure Parse_Blit_Safe_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Visual_Node    : Node_Index := 0;
      With_Node      : Node_Index := 0;
      Target_Node    : Node_Index := 0;
      Position_Node  : Node_Index := 0;
      X_Node         : Node_Index := 0;
      Y_Node         : Node_Index := 0;
      Clause_Node    : Node_Index := 0;
      Value_Node     : Node_Index := 0;
      Tail_Node      : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Blit_Safe_Stmt, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1;

      Parse_Expression (Tokens, State, Tree, Visual_Node, Success);
      if not Success then return; end if;
      Tree (Node).Left_Child := Visual_Node;

      if State.Current_Token <= Max_Tokens and then Tokens (State.Current_Token).Kind = Tok_With then
         Allocate_Node (Tokens, State, Tree, AST_With_Clause, With_Node, Success);
         if not Success then return; end if;
         Tree (With_Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1;

         Parse_Expression (Tokens, State, Tree, Value_Node, Success);
         if not Success then return; end if;
         Tree (With_Node).Left_Child := Value_Node;
         Tree (Visual_Node).Next_Sibling := With_Node;
      end if;

      if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_To then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1;

      Parse_Expression (Tokens, State, Tree, Target_Node, Success);
      if not Success then return; end if;
      Tree (Node).Right_Child := Target_Node;

      if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_At then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1;

      Allocate_Node (Tokens, State, Tree, AST_Blit_Position_Clause, Position_Node, Success);
      if not Success then return; end if;
      Tree (Position_Node).Token_Index := State.Current_Token - 1;

      Parse_Expression (Tokens, State, Tree, X_Node, Success);
      if not Success then return; end if;
      Tree (Position_Node).Left_Child := X_Node;

      if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_Comma then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1;

      Parse_Expression (Tokens, State, Tree, Y_Node, Success);
      if not Success then return; end if;
      Tree (Position_Node).Right_Child := Y_Node;

      Tree (Target_Node).Next_Sibling := Position_Node;
      Tail_Node := Position_Node;

      if State.Current_Token <= Max_Tokens and then Tokens (State.Current_Token).Kind = Tok_Constrain_To then
         Allocate_Node (Tokens, State, Tree, AST_Constrain_To_Clause, Clause_Node, Success);
         if not Success then return; end if;
         Tree (Clause_Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1;

         Parse_Expression (Tokens, State, Tree, Value_Node, Success);
         if not Success then return; end if;
         Tree (Clause_Node).Left_Child := Value_Node;
         Tree (Tail_Node).Next_Sibling := Clause_Node;
         Tail_Node := Clause_Node;
      end if;

      if State.Current_Token <= Max_Tokens and then Tokens (State.Current_Token).Kind = Tok_Mode then
         Allocate_Node (Tokens, State, Tree, AST_Mode_Clause, Clause_Node, Success);
         if not Success then return; end if;
         Tree (Clause_Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1;

         Parse_Expression (Tokens, State, Tree, Value_Node, Success);
         if not Success then return; end if;
         Tree (Clause_Node).Left_Child := Value_Node;
         Tree (Tail_Node).Next_Sibling := Clause_Node;
      end if;
   end Parse_Blit_Safe_Stmt;

   procedure Parse_Set_Shoebox_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Uses_Parens : Boolean := False;
      Expr_Node   : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Set_Shoebox_Stmt, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1;

      if State.Current_Token <= Max_Tokens and then Tokens (State.Current_Token).Kind = Tok_L_Paren then
         Uses_Parens := True;
         State.Current_Token := State.Current_Token + 1;
      end if;

      Parse_Expression (Tokens, State, Tree, Expr_Node, Success);
      if not Success then return; end if;
      Tree (Node).Left_Child := Expr_Node;

      if Uses_Parens then
         if State.Current_Token <= Max_Tokens and then Tokens (State.Current_Token).Kind = Tok_R_Paren then
            State.Current_Token := State.Current_Token + 1;
         else
            Set_Error (State, Tokens, Err_Parse_Missing_Bracket);
            Success := False;
            return;
         end if;
      end if;
   end Parse_Set_Shoebox_Stmt;

   procedure Parse_Runtime_Assert_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Expr_Node : Node_Index := 0;
   begin
      Allocate_Node (Tokens, State, Tree, AST_Runtime_Assert, Node, Success);
      if not Success then return; end if;
      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1;

      if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_L_Paren then
         Set_Error (State, Tokens, Err_Parse_Missing_Bracket);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1;

      Parse_Expression (Tokens, State, Tree, Expr_Node, Success);
      if not Success then return; end if;
      Tree (Node).Left_Child := Expr_Node;

      if State.Current_Token > Max_Tokens or else Tokens (State.Current_Token).Kind /= Tok_R_Paren then
         Set_Error (State, Tokens, Err_Parse_Missing_Bracket);
         Success := False;
         return;
      end if;
      State.Current_Token := State.Current_Token + 1;
   end Parse_Runtime_Assert_Stmt;

   function Is_Logic_Assert_Predicate_Token (Kind : Token_Kind) return Boolean is
   begin
      return Kind in Tok_Logic_Var
        | Tok_Atom
        | Tok_Mode
        | Tok_Spacing
        | Tok_Width
        | Tok_Height
        | Tok_Frames
        | Tok_Frame
        | Tok_Source
        | Tok_Format
        | Tok_Weight
        | Tok_Buffer_Size
        | Tok_Size
        | Tok_Layer
        | Tok_Epochs
        | Tok_Bounds
        | Tok_States;
   end Is_Logic_Assert_Predicate_Token;

   function Looks_Like_Parenthesized_Logic_Assert
     (Tokens      : Token_Array;
      Token_Index : Natural) return Boolean
   is
      Scan  : Natural := Token_Index + 2;
      Depth : Natural := 0;
   begin
      if Token_Index + 1 > Max_Tokens
        or else Tokens (Token_Index + 1).Kind /= Tok_L_Paren
      then
         return False;
      end if;

      if Scan > Max_Tokens
        or else not Is_Logic_Assert_Predicate_Token (Tokens (Scan).Kind)
      then
         return False;
      end if;

      Scan := Scan + 1;

      if Scan <= Max_Tokens and then Tokens (Scan).Kind = Tok_L_Paren then
         Depth := 1;
         Scan := Scan + 1;

         while Scan <= Max_Tokens and then Depth > 0 loop
            if Tokens (Scan).Kind = Tok_L_Paren then
               Depth := Depth + 1;
            elsif Tokens (Scan).Kind = Tok_R_Paren then
               Depth := Depth - 1;
            end if;

            Scan := Scan + 1;
         end loop;

         if Depth /= 0 then
            return False;
         end if;
      end if;

      return Scan <= Max_Tokens and then Tokens (Scan).Kind = Tok_R_Paren;
   end Looks_Like_Parenthesized_Logic_Assert;

   -- =========================================================================
   -- DA NATIVE INPUT FORGE (INPUT "Prompt", Var)
   -- =========================================================================
   procedure Parse_Input_Stmt (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      Prompt_Node, Var_Node : Node_Index := 0;
      Prompt_Comma          : Natural := 0;
      Uses_Parens           : Boolean := False;
   begin
      Allocate_Node(Tokens, State, Tree, AST_Input_Stmt, Node, Success);
      if not Success then return; end if;
      Tree(Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume INPUT

      if State.Current_Token <= Max_Tokens
        and then Tokens(State.Current_Token).Kind = Tok_Shr
      then
         State.Current_Token := State.Current_Token + 1; -- Consume cin-style >>
         Prompt_Comma := 0;
      elsif State.Current_Token <= Max_Tokens
        and then Tokens(State.Current_Token).Kind = Tok_L_Paren
      then
         Uses_Parens := True;
         State.Current_Token := State.Current_Token + 1;
         Prompt_Comma := Find_Top_Level_Comma_Before_RParen(Tokens, State.Current_Token);
      else
         Prompt_Comma := Find_Top_Level_Comma_On_Line(Tokens, State.Current_Token);
      end if;

      -- INPUT can use any prompt expression before a top-level comma.
      if Prompt_Comma /= 0 then
         Parse_Expression(Tokens, State, Tree, Prompt_Node, Success);
         if not Success then return; end if;
         Tree(Node).Left_Child := Prompt_Node;

         if State.Current_Token > Max_Tokens
           or else Tokens(State.Current_Token).Kind not in Tok_Comma | Tok_Shr
         then
            Set_Error(State, Tokens, Err_Parse_Expected_Value);
            Success := False; return;
         end if;
         State.Current_Token := State.Current_Token + 1; -- Consume comma or >>
      end if;

      -- Parse the Target Variable (Right Child)
      if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind not in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States then
         Set_Error(State, Tokens, Err_Parse_Expected_Value);
         Success := False; return;
      end if;

      Allocate_Node(Tokens, State, Tree, AST_Var_Expr, Var_Node, Success);
      if not Success then return; end if;
      Tree(Var_Node).Token_Index := State.Current_Token;
      Tree(Node).Right_Child := Var_Node;
      State.Current_Token := State.Current_Token + 1;

      if Uses_Parens then
         if State.Current_Token <= Max_Tokens
           and then Tokens(State.Current_Token).Kind = Tok_R_Paren
         then
            State.Current_Token := State.Current_Token + 1;
         else
            Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
            Success := False;
            return;
         end if;
      end if;
   end Parse_Input_Stmt;

   --  LAMBDA (p AS T, ...) [AS ret] => expr          (short form)
   --  LAMBDA (p AS T, ...) [AS ret] <stmts> END LAMBDA  (block form)
   --  Only reachable as the RHS of a LET/CONST/assignment binding —
   --  the caller checks Tokens(..).Kind = Tok_Lambda before entering.
   --  Node.Left  = AST_Arg_List: Left = AST_Param_Decl chain
   --               (Left=name Var_Expr, Right=type Var_Expr),
   --               Right = return-type Var_Expr (0 = void).
   --  Node.Right = AST_Block_Stmt (block) or expression (short).
   procedure Parse_Lambda_Expr
     (Tokens  : in Token_Array;
      State   : in out Parser_State;
      Tree    : in out Node_Array;
      Node    : out Node_Index;
      Success : out Boolean)
   is
      List_Node    : Node_Index := 0;
      Param_Node   : Node_Index := 0;
      Last_Param   : Node_Index := 0;
      PName        : Node_Index := 0;
      PType        : Node_Index := 0;
      Ret_Node     : Node_Index := 0;
      Block_Node   : Node_Index := 0;
      Expr_Node    : Node_Index := 0;
      Next_Stmt    : Node_Index := 0;
      First_Stmt   : Node_Index := 0;
      Curr_Stmt    : Node_Index := 0;
      Failed_Token : Natural := 0;
   begin
      Success := False;
      Node := 0;

      Allocate_Node (Tokens, State, Tree, AST_Lambda_Expr, Node, Success);
      if not Success then return; end if;

      Tree (Node).Token_Index := State.Current_Token;
      State.Current_Token := State.Current_Token + 1; -- Consume LAMBDA

      -- 1. Parameter list: `name AS type` pairs, types required.
      if State.Current_Token > Max_Tokens
        or else Tokens (State.Current_Token).Kind /= Tok_L_Paren
      then
         Set_Error (State, Tokens, Err_Parse_Missing_Bracket);
         return;
      end if;
      State.Current_Token := State.Current_Token + 1; -- Consume '('

      Allocate_Node (Tokens, State, Tree, AST_Arg_List, List_Node, Success);
      if not Success then return; end if;
      Tree (Node).Left_Child := List_Node;

      while State.Current_Token <= Max_Tokens
        and then Tokens (State.Current_Token).Kind /= Tok_R_Paren
      loop
         Allocate_Node (Tokens, State, Tree, AST_Param_Decl, Param_Node, Success);
         if not Success then return; end if;

         -- Param name, then mandatory `AS <type>`
         if State.Current_Token > Max_Tokens
           or else Tokens (State.Current_Token).Kind not in
             Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width |
             Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format |
             Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer |
             Tok_Epochs | Tok_Bounds | Tok_States
           or else State.Current_Token + 1 > Max_Tokens
           or else Tokens (State.Current_Token + 1).Kind /= Tok_As
         then
            Set_Error (State, Tokens, Err_Parse_Expected_Var);
            return;
         end if;
         Allocate_Node (Tokens, State, Tree, AST_Var_Expr, PName, Success);
         if not Success then return; end if;
         Tree (PName).Token_Index := State.Current_Token;
         Tree (Param_Node).Left_Child := PName;
         State.Current_Token := State.Current_Token + 2; -- name + AS

         if State.Current_Token > Max_Tokens
           or else not Is_Type_Name_Token (Tokens (State.Current_Token).Kind)
         then
            Set_Error (State, Tokens, Err_Parse_Expected_Type);
            return;
         end if;
         Allocate_Node (Tokens, State, Tree, AST_Var_Expr, PType, Success);
         if not Success then return; end if;
         Tree (PType).Token_Index := State.Current_Token;
         Tree (Param_Node).Right_Child := PType;
         State.Current_Token := State.Current_Token + 1;

         if Last_Param = 0 then
            Tree (List_Node).Left_Child := Param_Node;
         else
            Tree (Last_Param).Next_Sibling := Param_Node;
         end if;
         Last_Param := Param_Node;

         if Tokens (State.Current_Token).Kind = Tok_Comma then
            State.Current_Token := State.Current_Token + 1;
         elsif Tokens (State.Current_Token).Kind /= Tok_R_Paren then
            Set_Error (State, Tokens, Err_Parse_Missing_Bracket);
            return;
         end if;
      end loop;

      if State.Current_Token <= Max_Tokens
        and then Tokens (State.Current_Token).Kind = Tok_R_Paren
      then
         State.Current_Token := State.Current_Token + 1;
      else
         Set_Error (State, Tokens, Err_Parse_Missing_Bracket);
         return;
      end if;

      -- 2. Optional return type: `AS <type>` -> List.Right_Child
      if State.Current_Token <= Max_Tokens
        and then Tokens (State.Current_Token).Kind = Tok_As
      then
         State.Current_Token := State.Current_Token + 1;
         if State.Current_Token <= Max_Tokens
           and then Is_Type_Name_Token (Tokens (State.Current_Token).Kind)
         then
            Allocate_Node (Tokens, State, Tree, AST_Var_Expr, Ret_Node, Success);
            if not Success then return; end if;
            Tree (Ret_Node).Token_Index := State.Current_Token;
            Tree (List_Node).Right_Child := Ret_Node;
            State.Current_Token := State.Current_Token + 1;
         else
            Set_Error (State, Tokens, Err_Parse_Missing_Type_Name);
            return;
         end if;
      end if;

      -- 3. Body: `=> expr` short form or statement block to END LAMBDA.
      if State.Current_Token <= Max_Tokens
        and then Tokens (State.Current_Token).Kind = Tok_Arrow
      then
         -- `=>` always means "return this": requires a declared ret type.
         if Tree (List_Node).Right_Child = 0 then
            Set_Error (State, Tokens, Err_Parse_Missing_Type_Name);
            return;
         end if;
         State.Current_Token := State.Current_Token + 1; -- Consume '=>'
         Parse_Expression (Tokens, State, Tree, Expr_Node, Success);
         if not Success then return; end if;
         Tree (Node).Right_Child := Expr_Node;
         Success := True;
         return;
      end if;

      Allocate_Node (Tokens, State, Tree, AST_Block_Stmt, Block_Node, Success);
      if not Success then return; end if;
      Tree (Node).Right_Child := Block_Node;

      for I in 1 .. 16384 loop
         if State.Current_Token > Max_Tokens
           or else Tokens (State.Current_Token).Kind = Tok_Error
         then
            Set_Error (State, Tokens, Err_Parse_Expected_Block_End);
            return;
         end if;

         -- END LAMBDA on one line closes the body; bare END is NOT accepted.
         if Tokens (State.Current_Token).Kind = Tok_End
           and then State.Current_Token + 1 <= Max_Tokens
           and then Tokens (State.Current_Token + 1).Kind = Tok_Lambda
           and then Tokens (State.Current_Token + 1).Line =
                    Tokens (State.Current_Token).Line
         then
            State.Current_Token := State.Current_Token + 2;
            Success := True;
            return;
         end if;

         Failed_Token := State.Current_Token;
         Parse_Statement (Tokens, State, Tree, Next_Stmt, Success);
         if not Success then
            Recover_After_Stmt_Error (Tokens, State, Failed_Token);
            Next_Stmt := 0;
            Success := True;
         end if;

         if Next_Stmt /= 0 then
            if First_Stmt = 0 then
               First_Stmt := Next_Stmt;
               Tree (Block_Node).Left_Child := First_Stmt;
            else
               Tree (Curr_Stmt).Next_Sibling := Next_Stmt;
            end if;
            Curr_Stmt := Next_Stmt;
         end if;
      end loop;

      Set_Error (State, Tokens, Err_Parse_Block_Overflow);
   end Parse_Lambda_Expr;

   procedure Parse_Const_Decl
     (Tokens  : in Token_Array;
      State   : in out Parser_State;
      Tree    : in out Node_Array;
      Node    : out Node_Index;
      Success : out Boolean)
   is
      Ref_Node  : Node_Index := 0;
      Expr_Node : Node_Index := 0;
   begin
      Success := False;
      Node := 0;

      Allocate_Node (Tokens, State, Tree, AST_Const_Decl, Node, Success);
      if not Success then
         return;
      end if;

      Tree (Node).Token_Index := State.Current_Token;

      Allocate_Node (Tokens, State, Tree, AST_Const_Ref, Ref_Node, Success);
      if not Success then
         return;
      end if;

      Tree (Ref_Node).Token_Index := State.Current_Token;
      Tree (Node).Left_Child := Ref_Node;
      State.Current_Token := State.Current_Token + 1; -- Consume #NAME

      if State.Current_Token > Max_Tokens
        or else Tokens (State.Current_Token).Kind /= Tok_Assign
      then
         Set_Error (State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return;
      end if;

      State.Current_Token := State.Current_Token + 1; -- Consume '='

      Parse_Expression (Tokens, State, Tree, Expr_Node, Success);
      if not Success then
         return;
      end if;

      Tree (Node).Right_Child := Expr_Node;
      Success := True;
   end Parse_Const_Decl;

   procedure Parse_Statement (Tokens : in Token_Array; State : in out Parser_State; Tree : in out Node_Array; Node : out Node_Index; Success : out Boolean) is
      T : Token := Tokens(State.Current_Token);
      Expr_Node, Var_Node, Pred_Node : Node_Index;
   begin
      Success := False; Node := 0;
      
      -- =========================================================
      -- DA MAIN ROUTER (Delegated Statements)
      -- =========================================================
      
       -- HolyC-style naked string print: "ready\n";
       if T.Kind = Tok_String then
          Allocate_Node(Tokens, State, Tree, AST_Print_Str_Stmt, Node, Success);
          if not Success then return; end if;
          Tree(Node).Token_Index := State.Current_Token;

          Allocate_Node(Tokens, State, Tree, AST_String_Expr, Expr_Node, Success);
          if not Success then return; end if;
          Tree(Expr_Node).Token_Index := State.Current_Token;
          Tree(Node).Left_Child := Expr_Node;

          State.Current_Token := State.Current_Token + 1;
          Success := True;

       -- DA RANGE TYPE FORGE
       elsif T.Kind = Tok_Type then
          declare
             Type_Name_Node : Node_Index := 0;
             Base_Node      : Node_Index := 0;
             Low_Node       : Node_Index := 0;
             High_Node      : Node_Index := 0;
          begin
             Allocate_Node(Tokens, State, Tree, AST_Range_Type_Decl, Node, Success);
             if not Success then return; end if;

             Tree(Node).Token_Index := State.Current_Token;
             State.Current_Token := State.Current_Token + 1; -- Consume TYPE

             if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind not in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States then
                Set_Error(State, Tokens, Err_Parse_Expected_Value);
                Success := False;
                return;
             end if;

             Allocate_Node(Tokens, State, Tree, AST_Var_Expr, Type_Name_Node, Success);
             if not Success then return; end if;
             Tree(Type_Name_Node).Token_Index := State.Current_Token;
             Tree(Node).Left_Child := Type_Name_Node;
             State.Current_Token := State.Current_Token + 1;

             if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_Is then
                Set_Error(State, Tokens, Err_Parse_Expected_Value);
                Success := False;
                return;
             end if;
             State.Current_Token := State.Current_Token + 1; -- Consume IS

             if State.Current_Token <= Max_Tokens
               and then Tokens (State.Current_Token).Kind = Tok_Routine
             then
                --  TYPE Name IS ROUTINE (params) [AS ret]
                --  Typed routine-reference alias (Phase 3).
                Tree (Node).Kind := AST_Routine_Type_Decl;
                State.Current_Token := State.Current_Token + 1; -- ROUTINE
                declare
                   List_Node  : Node_Index := 0;
                   Param_Node : Node_Index := 0;
                   Last_Param : Node_Index := 0;
                   PName      : Node_Index := 0;
                   PType      : Node_Index := 0;
                   Ret_Node   : Node_Index := 0;
                begin
                   Allocate_Node(Tokens, State, Tree, AST_Arg_List, List_Node, Success);
                   if not Success then return; end if;
                   Tree (Node).Right_Child := List_Node;

                   if State.Current_Token <= Max_Tokens
                     and then Tokens (State.Current_Token).Kind = Tok_L_Paren
                   then
                      State.Current_Token := State.Current_Token + 1;
                      while State.Current_Token <= Max_Tokens
                        and then Tokens (State.Current_Token).Kind /= Tok_R_Paren
                      loop
                         Allocate_Node(Tokens, State, Tree, AST_Param_Decl, Param_Node, Success);
                         if not Success then return; end if;

                         --  Param form: `name AS type` or bare `type`.
                         if Tokens (State.Current_Token).Kind in
                              Tok_Logic_Var | Tok_Atom
                           and then State.Current_Token + 1 <= Max_Tokens
                           and then Tokens (State.Current_Token + 1).Kind = Tok_As
                         then
                            Allocate_Node(Tokens, State, Tree, AST_Var_Expr, PName, Success);
                            if not Success then return; end if;
                            Tree (PName).Token_Index := State.Current_Token;
                            Tree (Param_Node).Left_Child := PName;
                            State.Current_Token := State.Current_Token + 2;
                         end if;

                         if State.Current_Token > Max_Tokens
                           or else not Is_Type_Name_Token (Tokens (State.Current_Token).Kind)
                         then
                            Set_Error (State, Tokens, Err_Parse_Expected_Value);
                            Success := False; return;
                         end if;
                         Allocate_Node(Tokens, State, Tree, AST_Var_Expr, PType, Success);
                         if not Success then return; end if;
                         Tree (PType).Token_Index := State.Current_Token;
                         Tree (Param_Node).Right_Child := PType;
                         State.Current_Token := State.Current_Token + 1;

                         if Last_Param = 0 then
                            Tree (List_Node).Left_Child := Param_Node;
                         else
                            Tree (Last_Param).Next_Sibling := Param_Node;
                         end if;
                         Last_Param := Param_Node;

                         if Tokens (State.Current_Token).Kind = Tok_Comma then
                            State.Current_Token := State.Current_Token + 1;
                         elsif Tokens (State.Current_Token).Kind /= Tok_R_Paren then
                            Set_Error (State, Tokens, Err_Parse_Expected_Value);
                            Success := False; return;
                         end if;
                      end loop;
                      if State.Current_Token <= Max_Tokens
                        and then Tokens (State.Current_Token).Kind = Tok_R_Paren
                      then
                         State.Current_Token := State.Current_Token + 1;
                      else
                         Set_Error (State, Tokens, Err_Parse_Missing_Bracket);
                         Success := False; return;
                      end if;
                   end if;

                   if State.Current_Token <= Max_Tokens
                     and then Tokens (State.Current_Token).Kind = Tok_As
                   then
                      State.Current_Token := State.Current_Token + 1;
                      if State.Current_Token <= Max_Tokens
                        and then Is_Type_Name_Token (Tokens (State.Current_Token).Kind)
                      then
                         Allocate_Node(Tokens, State, Tree, AST_Var_Expr, Ret_Node, Success);
                         if not Success then return; end if;
                         Tree (Ret_Node).Token_Index := State.Current_Token;
                         Tree (List_Node).Right_Child := Ret_Node;
                         State.Current_Token := State.Current_Token + 1;
                      else
                         Set_Error (State, Tokens, Err_Parse_Missing_Type_Name);
                         Success := False; return;
                      end if;
                   end if;
                end;
             else
             if State.Current_Token > Max_Tokens or else not Is_Type_Name_Token (Tokens(State.Current_Token).Kind) then
                Set_Error(State, Tokens, Err_Parse_Expected_Value);
                Success := False;
                return;
             end if;

             Allocate_Node(Tokens, State, Tree, AST_Var_Expr, Base_Node, Success);
             if not Success then return; end if;
             Tree(Base_Node).Token_Index := State.Current_Token;
             Tree(Node).Right_Child := Base_Node;
             State.Current_Token := State.Current_Token + 1;
             -- Safety Trap: Variables and Fields cannot be Void
             if Tokens(State.Current_Token - 1).Kind = Tok_U0 then
                Set_Error(State, Tokens, Err_Parse_Expected_Value);
                Success := False;
                return;
             end if;

             if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_Range then
                Set_Error(State, Tokens, Err_Parse_Expected_Value);
                Success := False;
                return;
             end if;
             State.Current_Token := State.Current_Token + 1; -- Consume RANGE

             Parse_Expression(Tokens, State, Tree, Low_Node, Success);
             if not Success then return; end if;

             if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_Dot_Dot then
                Set_Error(State, Tokens, Err_Parse_Expected_Value);
                Success := False;
                return;
             end if;
             State.Current_Token := State.Current_Token + 1; -- Consume ..

             Parse_Expression(Tokens, State, Tree, High_Node, Success);
             if not Success then return; end if;

             Tree(Base_Node).Left_Child := Low_Node;
             Tree(Low_Node).Next_Sibling := High_Node;
             end if;
          end;

       elsif T.Kind = Tok_Const_Id then
          Parse_Const_Decl (Tokens, State, Tree, Node, Success);

       -- DA NEW ASM BLOCK FORGE
       elsif T.Kind = Tok_EnableASM then

         Allocate_Node (Tokens, State, Tree, AST_Enable_Asm, Node, Success);
         if not Success then
            return;
         end if;
         Tree (Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1;

      elsif T.Kind = Tok_DisableASM then
         Allocate_Node (Tokens, State, Tree, AST_Disable_Asm, Node, Success);
         if not Success then
            return;
         end if;
         Tree (Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1;

      elsif T.Kind = Tok_Asm_Block then
         Allocate_Node (Tokens, State, Tree, AST_Asm_Block, Node, Success);
         if not Success then
            return;
         end if;
         Tree (Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1;

      elsif T.Kind = Tok_Enable_Ada_Block then
         Allocate_Node (Tokens, State, Tree, AST_Enable_Ada_Block, Node, Success);
         if not Success then
            return;
         end if;
         Tree (Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1;

      elsif T.Kind = Tok_Enable_Java_Block then
         Allocate_Node (Tokens, State, Tree, AST_Enable_Java_Block, Node, Success);
         if not Success then
            return;
         end if;
         Tree (Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1;

      elsif T.Kind = Tok_Enable_Typescript_Block then
         Allocate_Node (Tokens, State, Tree, AST_Enable_Typescript_Block, Node, Success);
         if not Success then
            return;
         end if;
         Tree (Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1;

      elsif T.Kind = Tok_Enable_C_Block then
         Allocate_Node (Tokens, State, Tree, AST_Enable_C_Block, Node, Success);
         if not Success then
            return;
         end if;
         Tree (Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1;

      elsif T.Kind = Tok_Enable_CSharp_Block then
         Allocate_Node (Tokens, State, Tree, AST_Enable_CSharp_Block, Node, Success);
         if not Success then
            return;
         end if;
         Tree (Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1;

      elsif T.Kind = Tok_Enable_Python_Block then
         Allocate_Node (Tokens, State, Tree, AST_Enable_Python_Block, Node, Success);
         if not Success then
            return;
         end if;
         Tree (Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1;

      elsif T.Kind = Tok_Enable_Lua54_Block then
         Allocate_Node (Tokens, State, Tree, AST_Enable_Lua54_Block, Node, Success);
         if not Success then
            return;
         end if;
         Tree (Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1;

      elsif T.Kind = Tok_Enable_Ruby_Block then
         Allocate_Node (Tokens, State, Tree, AST_Enable_Ruby_Block, Node, Success);
         if not Success then
            return;
         end if;
         Tree (Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1;

      elsif T.Kind = Tok_Enable_Javascript_Block then
         Allocate_Node (Tokens, State, Tree, AST_Enable_Javascript_Block, Node, Success);
         if not Success then
            return;
         end if;
         Tree (Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1;

      elsif T.Kind = Tok_Enable_Rust_Block then
         Allocate_Node (Tokens, State, Tree, AST_Enable_Rust_Block, Node, Success);
         if not Success then
            return;
         end if;
         Tree (Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1;

      -- BRAILLE / NEMETH raw data blocks: standalone statements whose
      -- entire verbatim text lives in the token's source span (static,
      -- zero-allocation — the AST carries only Token_Index).
      elsif T.Kind = Tok_Braille_Block then
         Allocate_Node (Tokens, State, Tree, AST_Braille_Block, Node, Success);
         if not Success then
            return;
         end if;
         Tree (Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1;

      elsif T.Kind = Tok_Nemeth_Block then
         Allocate_Node (Tokens, State, Tree, AST_Nemeth_Block, Node, Success);
         if not Success then
            return;
         end if;
         Tree (Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1;

      -- MCP server surface: block + standalone registrations
      elsif T.Kind = Tok_Mcp then
         Parse_Mcp_Decl (Tokens, State, Tree, Node, Success);

      elsif T.Kind = Tok_Mcp_Pump then
         Allocate_Node (Tokens, State, Tree, AST_Mcp_Pump, Node, Success);
         if not Success then return; end if;
         Tree (Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1;

      elsif T.Kind = Tok_Mcp_Listen then
         Allocate_Node (Tokens, State, Tree, AST_Mcp_Listen, Node, Success);
         if not Success then return; end if;
         Tree (Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1;

      elsif T.Kind = Tok_Reversible then
         Allocate_Node (Tokens, State, Tree, AST_Reversible_Block, Node, Success);
         if not Success then return; end if;

         Tree (Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1; -- Consume REVERSIBLE

         declare
            Body_Node  : Node_Index := 0;
            First_Stmt : Node_Index := 0;
            Curr_Stmt  : Node_Index := 0;
            Next_Stmt  : Node_Index := 0;
         begin
            Allocate_Node (Tokens, State, Tree, AST_Block_Stmt, Body_Node, Success);
            if not Success then return; end if;

            Tree (Node).Left_Child := Body_Node;

            for I in 1 .. 16384 loop
               if State.Current_Token > Max_Tokens or else
                  Tokens (State.Current_Token).Kind = Tok_Error
               then
                  Set_Error (State, Tokens, Err_Parse_Expected_Value);
                  Success := False;
                  return;
               end if;

               -- END REVERSIBLE
               if Tokens (State.Current_Token).Kind = Tok_End then
                  declare
                     End_Line : constant Positive := Tokens (State.Current_Token).Line;
                  begin
                     State.Current_Token := State.Current_Token + 1; -- Consume END

                     if State.Current_Token <= Max_Tokens and then
                        Tokens (State.Current_Token).Kind = Tok_Reversible and then
                        Tokens (State.Current_Token).Line = End_Line
                     then
                        State.Current_Token := State.Current_Token + 1; -- Consume REVERSIBLE
                     end if;

                     Success := True;
                     return;
                  end;
               end if;

               Parse_Statement (Tokens, State, Tree, Next_Stmt, Success);
               if not Success then return; end if;

               if First_Stmt = 0 then
                  First_Stmt := Next_Stmt;
                  Tree (Body_Node).Left_Child := First_Stmt;
               else
                  Tree (Curr_Stmt).Next_Sibling := Next_Stmt;
               end if;

               Curr_Stmt := Next_Stmt;
            end loop;

            Set_Error (State, Tokens, Err_Parse_Block_Overflow);
            Success := False;
            return;
         end;
         
      elsif T.Kind in Tok_RevAdd | Tok_RevSub | Tok_RevXor | Tok_RevRol | Tok_RevRor then
         declare
            Op_Kind     : Node_Kind := AST_Rev_Add_Stmt;
            Target_Node : Node_Index := 0;
            Value_Node  : Node_Index := 0;
         begin
            case T.Kind is
               when Tok_RevAdd => Op_Kind := AST_Rev_Add_Stmt;
               when Tok_RevSub => Op_Kind := AST_Rev_Sub_Stmt;
               when Tok_RevXor => Op_Kind := AST_Rev_Xor_Stmt;
               when Tok_RevRol => Op_Kind := AST_Rev_Rol_Stmt;
               when Tok_RevRor => Op_Kind := AST_Rev_Ror_Stmt;
               when others     => Op_Kind := AST_Rev_Add_Stmt;
            end case;

            Allocate_Node (Tokens, State, Tree, Op_Kind, Node, Success);
            if not Success then return; end if;

            Tree (Node).Token_Index := State.Current_Token;
            State.Current_Token := State.Current_Token + 1; -- Consume REV*

            Parse_Primary (Tokens, State, Tree, Target_Node, Success);
            if not Success then return; end if;
            Tree (Node).Left_Child := Target_Node;

            if State.Current_Token > Max_Tokens or else
               Tokens (State.Current_Token).Kind /= Tok_Comma
            then
               Set_Error (State, Tokens, Err_Parse_Expected_Value);
               Success := False;
               return;
            end if;

            State.Current_Token := State.Current_Token + 1; -- Consume comma

            Parse_Expression (Tokens, State, Tree, Value_Node, Success);
            if not Success then return; end if;
            Tree (Node).Right_Child := Value_Node;
         end;

      elsif T.Kind = Tok_RevSwap then
         declare
            Left_Target  : Node_Index := 0;
            Right_Target : Node_Index := 0;
         begin
            Allocate_Node (Tokens, State, Tree, AST_Rev_Swap_Stmt, Node, Success);
            if not Success then return; end if;

            Tree (Node).Token_Index := State.Current_Token;
            State.Current_Token := State.Current_Token + 1; -- Consume REVSWAP

            Parse_Primary (Tokens, State, Tree, Left_Target, Success);
            if not Success then return; end if;
            Tree (Node).Left_Child := Left_Target;

            if State.Current_Token > Max_Tokens or else
               Tokens (State.Current_Token).Kind /= Tok_Comma
            then
               Set_Error (State, Tokens, Err_Parse_Expected_Value);
               Success := False;
               return;
            end if;

            State.Current_Token := State.Current_Token + 1; -- Consume comma

            Parse_Primary (Tokens, State, Tree, Right_Target, Success);
            if not Success then return; end if;
            Tree (Node).Right_Child := Right_Target;
         end;
         
         
      elsif T.Kind in Tok_RevNot | Tok_RevNeg then
         declare
            Op_Kind     : Node_Kind := AST_Rev_Not_Stmt;
            Target_Node : Node_Index := 0;
         begin
            if T.Kind = Tok_RevNeg then
               Op_Kind := AST_Rev_Neg_Stmt;
            end if;

            Allocate_Node (Tokens, State, Tree, Op_Kind, Node, Success);
            if not Success then return; end if;

            Tree (Node).Token_Index := State.Current_Token;
            State.Current_Token := State.Current_Token + 1; -- Consume REVNOT/REVNEG

            Parse_Primary (Tokens, State, Tree, Target_Node, Success);
            if not Success then return; end if;

            Tree (Node).Left_Child := Target_Node;
         end;


      
      elsif T.Kind = Tok_Begin then 
         Parse_Block_Stmt(Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Input then
         Parse_Input_Stmt(Tokens, State, Tree, Node, Success); -- DA NEW INPUT DELEGATE
      elsif T.Kind = Tok_Repeat then 
         Parse_Repeat_Stmt(Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_While then 
         Parse_While_Stmt(Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Comptime then
         Parse_Comptime_Block(Tokens, State, Tree, Node, Success);
         
      elsif T.Kind = Tok_Temporal then
         if State.Current_Token + 1 <= Max_Tokens
           and then Tokens(State.Current_Token + 1).Kind = Tok_Let
           and then Tokens(State.Current_Token + 1).Line = T.Line
         then
            Parse_Temporal_Decl(Tokens, State, Tree, Node, Success);
         else
            Parse_Temporal_Block(Tokens, State, Tree, Node, Success);
         end if;

      elsif T.Kind = Tok_Advance then
         Parse_Advance_Stmt(Tokens, State, Tree, Node, Success);

      elsif T.Kind = Tok_Fallback then
         Parse_Fallback_Block(Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Exact then
         Parse_Exact_Block(Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Secure then
         Parse_Secure_Block(Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Symbolic then
         Parse_Symbolic_Block(Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Morton_Tile then
         Parse_Morton_Tile_Block(Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Predicate
        and then State.Current_Token + 1 <= Max_Tokens
        and then Tokens(State.Current_Token + 1).Kind = Tok_L_Square
        and then Tokens(State.Current_Token + 1).Line = T.Line
      then
         Parse_Branchless_Predicate_Block(Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Stride then
         Parse_Stride_Block(Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Ratio_Space then
         Parse_Ratio_Space_Block(Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Export_PPM then
         Parse_Export_PPM_Block(Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Fits_Cube then
         Parse_Fits_Cube_Block(Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Ini_Bind then
         Parse_Ini_Bind_Block(Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Stream_Bypass then
         Parse_Stream_Bypass_Block(Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Synth_Bake then
         Parse_Synth_Bake_Block(Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Mount_Archive then
         Parse_Mount_Archive_Block(Tokens, State, Tree, Node, Success);

         
      elsif T.Kind = Tok_Procedure then 
         Parse_Procedure_Decl(Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Function then 
         Parse_Function_Decl(Tokens, State, Tree, Node, Success);
         
      -- DA NEW MODULE ROUTERS
      elsif T.Kind = Tok_DeclareModule then 
         Parse_Module_Block(Tokens, State, Tree, Node, Success, True);
      elsif T.Kind = Tok_Module then 
         Parse_Module_Block(Tokens, State, Tree, Node, Success, False);
      elsif T.Kind = Tok_Import then 
         Parse_Import(Tokens, State, Tree, Node, Success);
         
      elsif T.Kind = Tok_Import_C then
         Parse_Import_C(Tokens, State, Tree, Node, Success);

      -- Parser-only foreign interop placeholders.
      -- These AST roots are intentionally accepted here before any backend support exists.
      elsif T.Kind = Tok_Import_DLL then
         Parse_Foreign_Binding(Tokens, State, Tree, AST_Import_DLL, True, Node, Success);
      elsif T.Kind = Tok_Import_SO then
         Parse_Foreign_Binding(Tokens, State, Tree, AST_Import_SO, True, Node, Success);
      elsif T.Kind = Tok_Import_Dylib then
         Parse_Foreign_Binding(Tokens, State, Tree, AST_Import_Dylib, True, Node, Success);
      elsif T.Kind = Tok_Import_JAR then
         Parse_Foreign_Binding(Tokens, State, Tree, AST_Import_Jar, True, Node, Success);
      elsif T.Kind = Tok_Import_ES then
         Parse_Foreign_Binding(Tokens, State, Tree, AST_Import_ES, True, Node, Success);
      elsif T.Kind = Tok_Import_WASM then
         Parse_Foreign_Binding(Tokens, State, Tree, AST_Import_WASM, True, Node, Success);
      elsif T.Kind = Tok_Export_DLL then
         Parse_Foreign_Binding(Tokens, State, Tree, AST_Export_DLL, False, Node, Success);
      elsif T.Kind = Tok_Export_SO then
         Parse_Foreign_Binding(Tokens, State, Tree, AST_Export_SO, False, Node, Success);
      elsif T.Kind = Tok_Export_Dylib then
         Parse_Foreign_Binding(Tokens, State, Tree, AST_Export_Dylib, False, Node, Success);
      elsif T.Kind = Tok_Export_JAR then
         Parse_Foreign_Binding(Tokens, State, Tree, AST_Export_Jar, False, Node, Success);
      elsif T.Kind = Tok_Export_ES then
         Parse_Foreign_Binding(Tokens, State, Tree, AST_Export_ES, False, Node, Success);
      elsif T.Kind = Tok_Export_WASM then
         Parse_Foreign_Binding(Tokens, State, Tree, AST_Export_WASM, False, Node, Success);

      elsif T.Kind = Tok_Memory_Firewall then
         Parse_Memory_Firewall_Decl (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Process_Handle then
         Parse_Process_Handle_Decl (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Read_Process_Memory then
         Parse_Read_Process_Memory_Stmt (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Write_Process_Memory then
         Parse_Write_Process_Memory_Stmt (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Monitor_Process_Memory then
         Parse_Monitor_Process_Memory_Stmt (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Inject_Code_Memory then
         Parse_Inject_Code_Memory_Stmt (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Hijack_Process_Memory then
         Parse_Hijack_Process_Memory_Stmt (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Dump_Process_Memory then
         Parse_Dump_Process_Memory_Stmt (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Terminate_Process then
         Parse_Terminate_Process_Stmt (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Create_Process then
         Parse_Create_Process_Stmt (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Elevate_Privileges then
         Parse_Elevate_Privileges_Stmt (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Hack_Memory then
         Parse_Hack_Memory_Stmt (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Inject_Code then
         Parse_Inject_Code_Stmt (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Inject_Payload_Type then
         Parse_Inject_Payload_Type_Clause (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Inject_Flags then
         Parse_Inject_Flags_Clause (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Inject_Syscall then
         Parse_Inject_Syscall_Clause (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Inject_Page then
         Parse_Inject_Page_Clause (Tokens, State, Tree, Node, Success);
       elsif T.Kind = Tok_Sniff_Network then
          Parse_Sniff_Network_Stmt (Tokens, State, Tree, Node, Success);
       elsif T.Kind = Tok_Network_Sniffer then
          Parse_Network_Sniffer_Decl (Tokens, State, Tree, Node, Success);
       elsif T.Kind = Tok_Network_Sniff then
          Parse_Network_Sniff_Stmt (Tokens, State, Tree, Node, Success);
       elsif T.Kind = Tok_Parse_Ethernet then
          Parse_Parse_Ethernet_Stmt (Tokens, State, Tree, Node, Success);
       elsif T.Kind = Tok_Parse_IP then
          Parse_Parse_IP_Stmt (Tokens, State, Tree, Node, Success);
       elsif T.Kind = Tok_Parse_TCP then
          Parse_Parse_TCP_Stmt (Tokens, State, Tree, Node, Success);
       elsif T.Kind = Tok_Encrypt_File then
         Parse_Encrypt_Or_Decrypt_File_Stmt (Tokens, State, Tree, AST_Encrypt_File_Stmt, Node, Success);
      elsif T.Kind = Tok_Decrypt_File then
         Parse_Encrypt_Or_Decrypt_File_Stmt (Tokens, State, Tree, AST_Decrypt_File_Stmt, Node, Success);

      -- Parser-only networking and ML placeholders.
      -- These AST roots are accepted here before any backend lowering exists.
      elsif T.Kind = Tok_Network_Socket then
         Parse_Network_Socket_Decl (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Network_Listen then
         Parse_Network_Listen_Stmt (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Network_Accept then
         Parse_Network_Accept_Stmt (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Network_Receive then
         Parse_Network_Receive_Stmt (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Network_Send then
         Parse_Network_Send_Stmt (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Network_Close then
         Parse_Network_Close_Stmt (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Markov_Model then
         Parse_Markov_Model_Decl (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Predict_Markov then
         Parse_Predict_Markov_Stmt (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Neural_Topology then
         Parse_Neural_Topology_Decl (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Infer_Network then
         Parse_Infer_Network_Stmt (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Train_Network then
         Parse_Train_Network_Stmt (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Emotion then
         Parse_Emotion_Decl (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Set_Axis then
         Parse_Set_Axis_Stmt (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Add_Axis then
         Parse_Add_Axis_Stmt (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Get_Axis then
         Parse_Get_Axis_Stmt (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Blend_Emotion then
         Parse_Blend_Emotion_Stmt (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Decay_Emotion then
         Parse_Decay_Emotion_Stmt (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Dominant_Emotion then
         Parse_Dominant_Emotion_Stmt (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Bitmap_Font then
         Parse_Bitmap_Font_Decl (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_System_Font then
         Parse_System_Font_Decl (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Static_Sprite then
         Parse_Static_Sprite_Decl (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Static_Surface then
         Parse_Static_Surface_Decl (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Color_Lut then
         Parse_Color_Lut_Decl (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Visual_Rule then
         Parse_Visual_Rule_Decl (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Render_Viewport then
         Parse_Render_Viewport_Decl (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Use_Font then
         Parse_Use_Font_Stmt (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Apply_Lut then
         Parse_Apply_Lut_Stmt (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Blit_Safe then
         Parse_Blit_Safe_Stmt (Tokens, State, Tree, Node, Success);
      elsif T.Kind = Tok_Set_Shoebox then
         Parse_Set_Shoebox_Stmt (Tokens, State, Tree, Node, Success);

         
      -- =========================================================
      -- DA NEW VERSION METADATA FORGE
      -- =========================================================
      elsif T.Kind = Tok_Version then
         Allocate_Node(Tokens, State, Tree, AST_Version, Node, Success);
         if not Success then return; end if;
         Tree(Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1; -- Consume VERSION
         
         -- 1. Guard: Expect a Number Literal (e.g., 1.0)
         if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_Number then
            Set_Error(State, Tokens, Err_Parse_Expected_Value);
            Success := False; 
            return;
         end if;
         
         -- 2. Safely bind the version number as the left child
         declare 
            Ver_Num_Node : Node_Index;
         begin
            Allocate_Node(Tokens, State, Tree, AST_Number_Expr, Ver_Num_Node, Success);
            if not Success then return; end if;
            Tree(Ver_Num_Node).Token_Index := State.Current_Token;
            Tree(Node).Left_Child := Ver_Num_Node;
         end;
         State.Current_Token := State.Current_Token + 1; -- Consume the number

         declare
            Version_Line : constant Positive :=
              Tokens (Tree (Tree (Node).Left_Child).Token_Index).Line;
         begin
            while State.Current_Token + 1 <= Max_Tokens
              and then Tokens (State.Current_Token).Kind = Tok_Dot
              and then Tokens (State.Current_Token).Line = Version_Line
              and then Tokens (State.Current_Token + 1).Kind = Tok_Number
              and then Tokens (State.Current_Token + 1).Line = Version_Line
            loop
               State.Current_Token := State.Current_Token + 2;
            end loop;
         end;
         
      elsif T.Kind = Tok_Struct then
         Parse_Struct(Tokens, State, Tree, Node, Success);
         
      -- =====================================================================
      -- DA NEW FORGE: USER-DEFINED TYPES (STRUCTS)
      -- =====================================================================
      elsif T.Kind = Tok_Define then
         State.Current_Token := State.Current_Token + 1;
         if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Struct then
            State.Current_Token := State.Current_Token + 1;
            -- Expect Struct Name
            if State.Current_Token <= Max_Tokens and then (Tokens(State.Current_Token).Kind = Tok_Logic_Var or Tokens(State.Current_Token).Kind = Tok_Atom) then
               declare
                  Struct_Name_Node : constant Node_Index := State.Current_Token;
                  Struct_Node      : Node_Index;
                  First_Field      : Node_Index := 0;
                  Last_Field       : Node_Index := 0;
                  Field_Node       : Node_Index;
               begin
                  -- Proper Procedural Allocation
                  Allocate_Node(Tokens, State, Tree, AST_Struct_Decl, Node, Success);
                  if not Success then return; end if;
                  
                  -- Left Child is the Struct Name (Var_Expr)
                  Allocate_Node(Tokens, State, Tree, AST_Var_Expr, Struct_Node, Success);
                  if not Success then return; end if;
                  
                  Tree(Struct_Node).Token_Index := Struct_Name_Node;
                  Tree(Node).Left_Child := Struct_Node;
                  State.Current_Token := State.Current_Token + 1;
                  
                  -- Parse Fields until END
                  while State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind /= Tok_End loop
                     -- Expect Field Name
                     if Tokens(State.Current_Token).Kind = Tok_Logic_Var or Tokens(State.Current_Token).Kind = Tok_Atom then
                        
                        Allocate_Node(Tokens, State, Tree, AST_Struct_Field, Field_Node, Success);
                        if not Success then return; end if;
                        
                        -- Left Child is the Field Name
                        declare
                           Child_Node : Node_Index;
                        begin
                           Allocate_Node(Tokens, State, Tree, AST_Var_Expr, Child_Node, Success);
                           if not Success then return; end if;
                           
                           Tree(Child_Node).Token_Index := State.Current_Token;
                           Tree(Field_Node).Left_Child := Child_Node;
                        end;
                        
                        State.Current_Token := State.Current_Token + 1;
                        
                        -- Expect AS Keyword
                        if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_As then
                           State.Current_Token := State.Current_Token + 1;
                           -- Expect Type (Store the token directly in the field node for easy access)
                           Tree(Field_Node).Token_Index := State.Current_Token;
                           State.Current_Token := State.Current_Token + 1;
                        else
                           Set_Error(State, Tokens, Err_Parse_Expected_Type);
                           Success := False; return;
                        end if;
                        
                        -- Chain the fields together via Sibling pointers!
                        if First_Field = 0 then
                           First_Field := Field_Node;
                        else
                           Tree(Last_Field).Next_Sibling := Field_Node;
                        end if;
                        Last_Field := Field_Node;
                     else
                        Set_Error(State, Tokens, Err_Parse_Expected_Var);
                        Success := False; return;
                     end if;
                  end loop;
                  
                  -- The Right_Child of the Struct points tae a dummy node that holds the Field List
                  declare
                     Null_Node : Node_Index;
                  begin
                     Allocate_Node(Tokens, State, Tree, AST_Null, Null_Node, Success);
                     if not Success then return; end if;
                     
                     Tree(Null_Node).Left_Child := First_Field;
                     Tree(Node).Right_Child := Null_Node;
                  end;
                  
                  -- Expect END STRUCT
                  if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_End then
                     State.Current_Token := State.Current_Token + 1;
                     if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Struct then
                        State.Current_Token := State.Current_Token + 1;
                     else
                        Set_Error(State, Tokens, Err_Parse_Expected_Block_End);
                        Success := False; return;
                     end if;
                  else
                     Set_Error(State, Tokens, Err_Parse_Expected_Block_End);
                     Success := False; return;
                  end if;
               end;
            else
               Set_Error(State, Tokens, Err_Parse_Expected_Var);
               Success := False; return;
            end if;
         else
            Set_Error(State, Tokens, Err_Parse_Rogue_Syntax);
            Success := False; return;
         end if;
         
         
      elsif T.Kind = Tok_Return then 
         Parse_Return(Tokens, State, Tree, Node, Success);
         
      elsif T.Kind = Tok_Delay then
         declare
            Uses_Parens : Boolean := False;
         begin
            Allocate_Node(Tokens, State, Tree, AST_Delay_Stmt, Node, Success);
            if not Success then return; end if;
            Tree(Node).Token_Index := State.Current_Token;
            State.Current_Token := State.Current_Token + 1; -- Consume DELAY

            if State.Current_Token <= Max_Tokens
              and then Tokens(State.Current_Token).Kind = Tok_L_Paren
            then
               Uses_Parens := True;
               State.Current_Token := State.Current_Token + 1;
            end if;

            Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
            if not Success then return; end if;
            Tree(Node).Left_Child := Expr_Node;

            if Uses_Parens then
               if State.Current_Token <= Max_Tokens
                 and then Tokens(State.Current_Token).Kind = Tok_R_Paren
               then
                  State.Current_Token := State.Current_Token + 1;
               else
                  Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
                  Success := False;
                  return;
               end if;
            end if;
         end;

      elsif T.Kind = Tok_Locate then
         declare
            Uses_Parens : Boolean := False;
         begin
            Allocate_Node(Tokens, State, Tree, AST_Locate_Stmt, Node, Success);
            if not Success then return; end if;
            Tree(Node).Token_Index := State.Current_Token;
            State.Current_Token := State.Current_Token + 1; -- Consume LOCATE
            
            if State.Current_Token <= Max_Tokens
              and then Tokens(State.Current_Token).Kind = Tok_L_Paren
            then
               Uses_Parens := True;
               State.Current_Token := State.Current_Token + 1;
            end if;
            
            Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
            if not Success then return; end if;
            Tree(Node).Left_Child := Expr_Node;
            
            if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_Comma then
               Set_Error(State, Tokens, Err_Parse_Expected_Value); Success := False; return;
            end if;
            State.Current_Token := State.Current_Token + 1; -- Consume Comma
            
            Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
            if not Success then return; end if;
            Tree(Node).Right_Child := Expr_Node;

            if Uses_Parens then
               if State.Current_Token <= Max_Tokens
                 and then Tokens(State.Current_Token).Kind = Tok_R_Paren
               then
                  State.Current_Token := State.Current_Token + 1;
               else
                  Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
                  Success := False;
                  return;
               end if;
            end if;
         end;
         
      -- =====================================================================
      -- DA LOOP CONTROL FORGE
      -- =====================================================================
      elsif T.Kind = Tok_Cls then
         Allocate_Node(Tokens, State, Tree, AST_Cls_Stmt, Node, Success);
         if not Success then return; end if;
         Tree(Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1;

         if State.Current_Token <= Max_Tokens
           and then Tokens(State.Current_Token).Kind = Tok_L_Paren
         then
            State.Current_Token := State.Current_Token + 1;
            if State.Current_Token <= Max_Tokens
              and then Tokens(State.Current_Token).Kind = Tok_R_Paren
            then
               State.Current_Token := State.Current_Token + 1;
            else
               Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
               Success := False;
               return;
            end if;
         end if;

      elsif T.Kind = Tok_Break then
         Allocate_Node(Tokens, State, Tree, AST_Break_Stmt, Node, Success);
         if not Success then return; end if;
         Tree(Node).Token_Index := State.Current_Token; 
         State.Current_Token := State.Current_Token + 1;

         if State.Current_Token <= Max_Tokens
           and then Tokens(State.Current_Token).Kind = Tok_L_Paren
         then
            State.Current_Token := State.Current_Token + 1;
            if State.Current_Token <= Max_Tokens
              and then Tokens(State.Current_Token).Kind = Tok_R_Paren
            then
               State.Current_Token := State.Current_Token + 1;
            else
               Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
               Success := False;
               return;
            end if;
         end if;

      elsif T.Kind = Tok_Continue then
         Allocate_Node(Tokens, State, Tree, AST_Continue_Stmt, Node, Success);
         if not Success then return; end if;
         Tree(Node).Token_Index := State.Current_Token; 
         State.Current_Token := State.Current_Token + 1;

         if State.Current_Token <= Max_Tokens
           and then Tokens(State.Current_Token).Kind = Tok_L_Paren
         then
            State.Current_Token := State.Current_Token + 1;
            if State.Current_Token <= Max_Tokens
              and then Tokens(State.Current_Token).Kind = Tok_R_Paren
            then
               State.Current_Token := State.Current_Token + 1;
            else
               Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
               Success := False;
               return;
            end if;
         end if;
         
      elsif T.Kind = Tok_Save_State then
         Allocate_Node(Tokens, State, Tree, AST_Save_State, Node, Success);
         if not Success then return; end if;
         Tree(Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1;

         if State.Current_Token <= Max_Tokens
           and then Tokens(State.Current_Token).Kind = Tok_L_Paren
         then
            State.Current_Token := State.Current_Token + 1;
            if State.Current_Token <= Max_Tokens
              and then Tokens(State.Current_Token).Kind = Tok_R_Paren
            then
               State.Current_Token := State.Current_Token + 1;
            else
               Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
               Success := False;
               return;
            end if;
         end if;

      elsif T.Kind = Tok_Load_State then
         Allocate_Node(Tokens, State, Tree, AST_Load_State, Node, Success);
         if not Success then return; end if;
         Tree(Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1;

         if State.Current_Token <= Max_Tokens
           and then Tokens(State.Current_Token).Kind = Tok_L_Paren
         then
            State.Current_Token := State.Current_Token + 1;
            if State.Current_Token <= Max_Tokens
              and then Tokens(State.Current_Token).Kind = Tok_R_Paren
            then
               State.Current_Token := State.Current_Token + 1;
            else
               Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
               Success := False;
               return;
            end if;
         end if;

         
         
      -- =====================================================================
      -- DA MULTI-CORE DISPATCH FORGE (SPAWN, SYNC, ATOMIC)
      -- =====================================================================
      elsif T.Kind = Tok_Spawn then
         declare
            Spawn_Target : Node_Index := 0;
            Uses_Parens  : Boolean := False;
         begin
            Allocate_Node(Tokens, State, Tree, AST_Spawn_Stmt, Node, Success);
            if not Success then return; end if;
            Tree(Node).Token_Index := State.Current_Token; 
            State.Current_Token := State.Current_Token + 1; -- Consume SPAWN

            if State.Current_Token <= Max_Tokens
              and then Tokens(State.Current_Token).Kind = Tok_L_Paren
            then
               Uses_Parens := True;
               State.Current_Token := State.Current_Token + 1;
            end if;

            Parse_Primary(Tokens, State, Tree, Spawn_Target, Success);
            if not Success then return; end if;

            if Spawn_Target = 0 then
               Set_Error(State, Tokens, Err_Parse_Expected_Value);
               Success := False;
               return;
            elsif Tree(Spawn_Target).Kind = AST_Func_Call then
               Tree(Node).Left_Child := Tree(Spawn_Target).Left_Child;
               Tree(Node).Right_Child := Tree(Spawn_Target).Right_Child;
            elsif Tree(Spawn_Target).Kind in AST_Var_Expr | AST_Member_Expr then
               Tree(Node).Left_Child := Spawn_Target;
               Tree(Node).Right_Child := 0;
            else
               Set_Error(State, Tokens, Err_Parse_Expected_Value);
               Success := False;
               return;
            end if;

            if Uses_Parens then
               if State.Current_Token <= Max_Tokens
                 and then Tokens(State.Current_Token).Kind = Tok_R_Paren
               then
                  State.Current_Token := State.Current_Token + 1;
               else
                  Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
                  Success := False;
                  return;
               end if;
            end if;
         end;

      elsif T.Kind = Tok_Sync then
         Allocate_Node(Tokens, State, Tree, AST_Sync_Stmt, Node, Success);
         if not Success then return; end if;
         Tree(Node).Token_Index := State.Current_Token; 
         State.Current_Token := State.Current_Token + 1; -- Consume SYNC

         if State.Current_Token <= Max_Tokens
           and then Tokens(State.Current_Token).Kind = Tok_L_Paren
         then
            State.Current_Token := State.Current_Token + 1;
            if State.Current_Token <= Max_Tokens
              and then Tokens(State.Current_Token).Kind = Tok_R_Paren
            then
               State.Current_Token := State.Current_Token + 1;
            else
               Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
               Success := False;
               return;
            end if;
         end if;

      elsif T.Kind = Tok_Atomic then
         Allocate_Node(Tokens, State, Tree, AST_Atomic_Block, Node, Success);
         if not Success then return; end if;
         Tree(Node).Token_Index := State.Current_Token; 
         State.Current_Token := State.Current_Token + 1; -- Consume ATOMIC
         
         declare 
            Body_Node, First_Stmt, Curr_Stmt, Next_Stmt : Node_Index := 0; 
         begin
            Allocate_Node(Tokens, State, Tree, AST_Block_Stmt, Body_Node, Success);
            if not Success then return; end if;
            Tree(Node).Left_Child := Body_Node;
            
            for I in 1 .. 16384 loop
               -- Guard against premature EOF
               if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind = Tok_Error then
                  Set_Error(State, Tokens, Err_Parse_Expected_Value); 
                  Success := False; 
                  return;
               end if;
               
               -- Terminate on END
               if Tokens(State.Current_Token).Kind = Tok_End then
                  declare
                     End_Line : Positive := Tokens(State.Current_Token).Line;
                  begin
                     State.Current_Token := State.Current_Token + 1; -- Consume END
                     -- Consume optional 'ATOMIC' safely
                     if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Atomic 
                        and then Tokens(State.Current_Token).Line = End_Line
                     then
                        State.Current_Token := State.Current_Token + 1;
                     end if;
                     Success := True; 
                     return;
                  end;
               end if;
               
               Parse_Statement(Tokens, State, Tree, Next_Stmt, Success);
               if not Success then return; end if;
               
               if First_Stmt = 0 then 
                  First_Stmt := Next_Stmt; 
                  Tree(Body_Node).Left_Child := First_Stmt;
               else 
                  Tree(Curr_Stmt).Next_Sibling := Next_Stmt; 
               end if;
               Curr_Stmt := Next_Stmt;
            end loop;
            
            Set_Error(State, Tokens, Err_Parse_Block_Overflow); 
            Success := False;
         end;
         
      -- =====================================================================
      -- DA PURE ENUM FORGE (Generates an AST_Block_Stmt marked with Tok_Enum)
      -- =====================================================================
      elsif T.Kind = Tok_Enum then
         Allocate_Node(Tokens, State, Tree, AST_Enum_Decl, Node, Success);
         if not Success then return; end if;
         Tree(Node).Token_Index := State.Current_Token; -- Mark as ENUM block
         declare
            Enum_Line : constant Positive := Tokens(State.Current_Token).Line;
         begin
            State.Current_Token := State.Current_Token + 1; -- Consume ENUM

            -- Optional ENUM Name (Skip it if it exists) — only when it is
            -- on the SAME line as ENUM, otherwise a member listed on the
            -- next line would be swallowed as the name.
            if State.Current_Token <= Max_Tokens and then
               (Tokens(State.Current_Token).Kind = Tok_Logic_Var or Tokens(State.Current_Token).Kind = Tok_Atom) and then
               Tokens(State.Current_Token).Line = Enum_Line
            then
               State.Current_Token := State.Current_Token + 1;
            end if;
         end;
         
         declare
            First_Var, Curr_Var, New_Var : Node_Index := 0;
            Item_Line                    : Positive := 1;
         begin
            while State.Current_Token <= Max_Tokens loop
               if Tokens(State.Current_Token).Kind = Tok_Error then
                  Set_Error(State, Tokens, Err_Parse_Expected_Value);
                  Success := False;
                  return;
               end if;

               if Tokens(State.Current_Token).Kind = Tok_End then
                  State.Current_Token := State.Current_Token + 1; -- Consume END
                  if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Enum then
                     State.Current_Token := State.Current_Token + 1; -- Consume ENUM
                  end if;
                  if First_Var = 0 then
                     Set_Error(State, Tokens, Err_Parse_Expected_Value);
                     Success := False;
                     return;
                  end if;
                  exit; -- Successfully parsed!
               end if;
               
               if Tokens(State.Current_Token).Kind not in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States then
                  Set_Error(State, Tokens, Err_Parse_Expected_Value);
                  Success := False;
                  return;
               end if;

               Allocate_Node(Tokens, State, Tree, AST_Var_Expr, New_Var, Success);
               if not Success then return; end if;
               Tree(New_Var).Token_Index := State.Current_Token;
               Item_Line := Tokens(State.Current_Token).Line;
               
               if First_Var = 0 then
                  First_Var := New_Var;
                  Tree(Node).Left_Child := First_Var;
               else
                  Tree(Curr_Var).Next_Sibling := New_Var;
               end if;
               Curr_Var := New_Var;
               State.Current_Token := State.Current_Token + 1;

               if State.Current_Token <= Max_Tokens
                 and then Tokens(State.Current_Token).Kind = Tok_Comma
               then
                  State.Current_Token := State.Current_Token + 1;
               elsif State.Current_Token <= Max_Tokens
                 and then Tokens(State.Current_Token).Kind /= Tok_End
                 and then Tokens(State.Current_Token).Kind /= Tok_Error
                 and then Tokens(State.Current_Token).Line = Item_Line
               then
                  Set_Error(State, Tokens, Err_Parse_Expected_Value);
                  Success := False;
                  return;
               end if;
            end loop;

            if State.Current_Token > Max_Tokens then
               Set_Error(State, Tokens, Err_Parse_Block_Overflow);
               Success := False;
               return;
            end if;
         end;
         
      -- =====================================================================
      -- DA BARE-METAL POKE (POKE address, value)
      -- =====================================================================
      elsif T.Kind = Tok_Poke then
         declare
            Uses_Parens : Boolean := False;
         begin
            Allocate_Node(Tokens, State, Tree, AST_Poke_Stmt, Node, Success);
            if not Success then return; end if;
            Tree(Node).Token_Index := State.Current_Token;
            State.Current_Token := State.Current_Token + 1; -- Consume POKE

            if State.Current_Token <= Max_Tokens
              and then Tokens(State.Current_Token).Kind = Tok_L_Paren
            then
               Uses_Parens := True;
               State.Current_Token := State.Current_Token + 1;
            end if;

            -- 1. Parse Address Expression
            Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
            if not Success then return; end if;
            Tree(Node).Left_Child := Expr_Node;

            -- 2. Guard: Expect Comma
            if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_Comma then
               Set_Error(State, Tokens, Err_Parse_Expected_Value);
               Success := False; return;
            end if;
            State.Current_Token := State.Current_Token + 1; -- Consume ','

            -- 3. Parse Value Expression
            Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
            if not Success then return; end if;
            Tree(Node).Right_Child := Expr_Node;

            if Uses_Parens then
               if State.Current_Token <= Max_Tokens
                 and then Tokens(State.Current_Token).Kind = Tok_R_Paren
               then
                  State.Current_Token := State.Current_Token + 1;
               else
                  Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
                  Success := False;
                  return;
               end if;
            end if;
         end;
         
      -- =========================================================
      -- DA KNOWLEDGE BASE ROUTER
      -- =========================================================
      elsif T.Kind = Tok_Knows then
         -- Peek ahead safely to determine if it's a Fact or a Query
         if State.Current_Token + 2 <= Max_Tokens and then Tokens(State.Current_Token + 2).Kind = Tok_Is then
            Parse_Knows_Fact(Tokens, State, Tree, Node, Success); -- KNOWS atom IS value
         else
            Parse_Knows_Query(Tokens, State, Tree, Node, Success); -- KNOWS atom
         end if;
      
      elsif T.Kind = Tok_Find then
         Parse_Find_Query(Tokens, State, Tree, Node, Success); -- FIND atom
         
      -- =========================================================
      -- DA MUTABLE KNOWLEDGE BASE & RUNTIME ASSERT FORGE
      -- =========================================================
      
      --  elsif T.Kind in Tok_Assert | Tok_Retract then
      --     -- DA HYBRID FIX: Is it Procedural ASSERT(expr) or Prolog ASSERT pred(X). ?
      --     if T.Kind = Tok_Assert and then State.Current_Token < Max_Tokens and then Tokens(State.Current_Token + 1).Kind = Tok_L_Paren then
      --  
      --        -- DA RUNTIME ASSERT FORGE
      --        Allocate_Node(Tokens, State, Tree, AST_Runtime_Assert, Node, Success);
      --        if not Success then return; end if;
      --        Tree(Node).Token_Index := State.Current_Token;
      --        State.Current_Token := State.Current_Token + 1; -- Consume ASSERT
      --        State.Current_Token := State.Current_Token + 1; -- Consume '('
      --  
      --        Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
      --        if Success then Tree(Node).Left_Child := Expr_Node; end if;
      --  
      --        if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_R_Paren then
      --           Set_Error(State, Tokens, Err_Parse_Missing_Bracket); Success := False; return;
      --        end if;
      --        State.Current_Token := State.Current_Token + 1;
      --  
      --     else
      --        -- DA PROLOG ASSERT / RETRACT FORGE
      --        declare
      --           NKind : Node_Kind := (if T.Kind = Tok_Assert then AST_Assert_Stmt else AST_Retract_Stmt);
      --        begin
      --           Allocate_Node(Tokens, State, Tree, NKind, Node, Success);
      --           if not Success then return; end if;
      --  
      --           Tree(Node).Token_Index := State.Current_Token;
      --           State.Current_Token := State.Current_Token + 1;
      --  
      --           Parse_Predicate(Tokens, State, Tree, Pred_Node, Success);
      --           if Success then
      --              Tree(Node).Left_Child := Pred_Node;
      --           else
      --              Set_Error(State, Tokens, Err_Parse_Expected_Value);
      --              return;
      --           end if;
      --        end;
      --     end if;
      
      -- =====================================================================
      -- DA PROLOG ENGINE (ASSERT / RETRACT wi' Dynamic Arguments!)
      -- =====================================================================
      elsif T.Kind = Tok_Assert
        and then State.Current_Token < Max_Tokens
        and then Tokens(State.Current_Token + 1).Kind = Tok_L_Paren
        and then not Looks_Like_Parenthesized_Logic_Assert
          (Tokens, State.Current_Token)
      then
         Parse_Runtime_Assert_Stmt (Tokens, State, Tree, Node, Success);

      elsif T.Kind in Tok_Assert | Tok_Retract then
         declare
            Is_Assert : Boolean := (T.Kind = Tok_Assert);
            Expr_Node : Node_Index := 0;
            Uses_Parens : Boolean := False;
         begin
            State.Current_Token := State.Current_Token + 1;

            if State.Current_Token <= Max_Tokens
              and then Tokens(State.Current_Token).Kind = Tok_L_Paren
            then
               Uses_Parens := True;
               State.Current_Token := State.Current_Token + 1;
            end if;

            Allocate_Node(Tokens, State, Tree, (if Is_Assert then AST_Assert_Stmt else AST_Retract_Stmt), Node, Success);
            if not Success then return; end if;
            
            -- 1. Grab the Predicate Name
            if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States then
               Tree(Node).Token_Index := State.Current_Token;
               State.Current_Token := State.Current_Token + 1;
            else
               Set_Error(State, Tokens, Err_Parse_Expected_Value);
               Success := False; return;
            end if;
            
            -- 2. Optional: Grab the Dynamic Argument (e.g., ASSERT is_valid(1) )
            if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = TOK_L_PAREN then
               State.Current_Token := State.Current_Token + 1;
               Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
               if not Success then return; end if;
               Tree(Node).Left_Child := Expr_Node; -- Left_Child holds the Argument!
               
               if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = TOK_R_PAREN then
                  State.Current_Token := State.Current_Token + 1;
               else
                  Set_Error(State, Tokens, Err_Parse_Expected_Value);
                  Success := False; return;
               end if;
            end if;

            if Uses_Parens then
               if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_R_Paren then
                  State.Current_Token := State.Current_Token + 1;
               else
                  Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
                  Success := False; return;
               end if;
            end if;
            
            -- 3. Optional: Consume a dot '.' for authentic Prolog syntax!
            if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Dot then
               State.Current_Token := State.Current_Token + 1;
            end if;
            
            Success := True;
         end;

      -- DA FIX 2: Flattened Update Forge!
      elsif T.Kind = Tok_Update then
         declare
            Uses_Parens : Boolean := False;
         begin
            Allocate_Node(Tokens, State, Tree, AST_Update_Stmt, Node, Success);
            if not Success then return; end if;
            Tree(Node).Token_Index := State.Current_Token; 
            State.Current_Token := State.Current_Token + 1;

            if State.Current_Token <= Max_Tokens
              and then Tokens(State.Current_Token).Kind = Tok_L_Paren
            then
               Uses_Parens := True;
               State.Current_Token := State.Current_Token + 1;
            end if;
            
            -- 1. Get the atom we're updatin' (Left Child)
            Parse_Primary(Tokens, State, Tree, Expr_Node, Success);
            if not Success then return; end if;
            Tree(Node).Left_Child := Expr_Node;

            -- 2. Guard: Expect 'TO' or a comma for call-style syntax
            if State.Current_Token <= Max_Tokens
              and then Tokens(State.Current_Token).Kind in Tok_To | Tok_Comma
            then 
               State.Current_Token := State.Current_Token + 1;
            else
               Set_Error(State, Tokens, Err_Parse_Expected_Value); 
               Success := False; 
               return; 
            end if;

            -- 3. Get da new value (Right Child)
            Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
            if not Success then return; end if;
            Tree(Node).Right_Child := Expr_Node;

            if Uses_Parens then
               if State.Current_Token <= Max_Tokens
                 and then Tokens(State.Current_Token).Kind = Tok_R_Paren
               then
                  State.Current_Token := State.Current_Token + 1;
               else
                  Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
                  Success := False;
                  return;
               end if;
            end if;
         end;
      
      -- =========================================================
      -- DA REMAINING DELEGATES
      -- =========================================================
      elsif T.Kind = Tok_Findall then
         Parse_Findall_Query(Tokens, State, Tree, Node, Success);

      elsif T.Kind = Tok_Predicate then
         Parse_Predicate_Decl(Tokens, State, Tree, Node, Success);

      -- DA FIX 3: Unified Membership Test
      elsif T.Kind in Tok_Rule | Tok_Constraint then
         Parse_Rule_Decl(Tokens, State, Tree, Node, Success);

      elsif T.Kind = Tok_Match then
         Parse_Match_Stmt(Tokens, State, Tree, Node, Success);
      
      -- =====================================================================
      -- DA CALL, LOAD, AND FLUSH FORGE
      -- =====================================================================
      --  elsif T.Kind = Tok_Call then
      --     Allocate_Node(Tokens, State, Tree, AST_Call_Stmt, Node, Success);
      --     if not Success then return; end if;
      --     Tree(Node).Token_Index := State.Current_Token;
      --     State.Current_Token := State.Current_Token + 1;
      --     -- Consume CALL
      --  
      --     -- 1. Guard: Expect Procedure Name
      --     if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind not in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States then
      --        Set_Error(State, Tokens, Err_Parse_Expected_Value);
      --        Success := False;
      --        return;
      --     end if;
      --  
      --     Allocate_Node(Tokens, State, Tree, AST_Var_Expr, Var_Node, Success);
      --     if not Success then return; end if;
      --  
      --     Tree(Var_Node).Token_Index := State.Current_Token;
      --     Tree(Node).Left_Child := Var_Node;
      --     State.Current_Token := State.Current_Token + 1;
      --  
      --     -- 2. Parse Optional Argument List intae Right_Child!
      --     if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_L_Paren then
      --        State.Current_Token := State.Current_Token + 1; -- Consume '('
      --  
      --        declare
      --           List_Node, Arg_Node, Last_Arg : Node_Index := 0;
      --        begin
      --           Allocate_Node(Tokens, State, Tree, AST_Arg_List, List_Node, Success);
      --           if not Success then return; end if;
      --           Tree(Node).Right_Child := List_Node; -- DA FIX: Attach directly tae Right_Child!
      --  
      --           if Tokens(State.Current_Token).Kind /= Tok_R_Paren then
      --              for I in 1 .. 64 loop
      --                 Parse_Expression(Tokens, State, Tree, Arg_Node, Success);
      --                 if not Success then return; end if;
      --  
      --                 if Last_Arg = 0 then
      --                    Tree(List_Node).Left_Child := Arg_Node;
      --                 else
      --                    Tree(Last_Arg).Next_Sibling := Arg_Node;
      --                 end if;
      --                 Last_Arg := Arg_Node;
      --  
      --                 if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Comma then
      --                    State.Current_Token := State.Current_Token + 1;
      --                 elsif State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_R_Paren then
      --                    exit;
      --                 else
      --                    Set_Error(State, Tokens, Err_Parse_Missing_Bracket); Success := False; return;
      --                 end if;
      --              end loop;
      --           end if;
      --  
      --           if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_R_Paren then
      --              State.Current_Token := State.Current_Token + 1;
      --           else
      --              Set_Error(State, Tokens, Err_Parse_Missing_Bracket); Success := False; return;
      --           end if;
      --        end;
      --     end if;
      
      elsif T.Kind = Tok_Call then
         Allocate_Node(Tokens, State, Tree, AST_Call_Stmt, Node, Success);
         if not Success then return; end if;
         Tree(Node).Token_Index := State.Current_Token; 
         State.Current_Token := State.Current_Token + 1; -- Consume CALL
         
         -- DA FIX: Use Parse_Primary tae grab da target.
         -- Handles local names, Module.Sub syntax, and parentheses automatically!
         declare
            Target_Node : Node_Index;
         begin
            Parse_Primary(Tokens, State, Tree, Target_Node, Success);
            if not Success then return; end if;
            Tree(Node).Left_Child := Target_Node;
         end;
         
      -- =========================================================
      -- DA PROLOG CUT (!) & BOUNDED READLINE
      -- =========================================================
      elsif T.Kind = Tok_Cut then
         Allocate_Node(Tokens, State, Tree, AST_Cut_Stmt, Node, Success);
         if not Success then return; end if;
         Tree(Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1; -- Consume '!'
         
      elsif T.Kind = Tok_Readline then
         declare
            Start_Line : constant Positive := T.Line;
            Uses_Parens : Boolean := False;
         begin
            Allocate_Node(Tokens, State, Tree, AST_Readline_Stmt, Node, Success);
            if not Success then return; end if;
            
            Tree(Node).Token_Index := State.Current_Token;
            State.Current_Token := State.Current_Token + 1; -- Consume READLINE

            if State.Current_Token <= Max_Tokens
              and then Tokens(State.Current_Token).Kind = Tok_L_Paren
            then
               Uses_Parens := True;
               State.Current_Token := State.Current_Token + 1;
            end if;

            -- DA NEW NAKED ARMOR: Only speir for a variable if it's on da same line!
            if Uses_Parens
              and then State.Current_Token <= Max_Tokens
              and then Tokens(State.Current_Token).Kind = Tok_R_Paren
            then
               State.Current_Token := State.Current_Token + 1;
               Success := True;
            elsif State.Current_Token <= Max_Tokens and then 
               Tokens(State.Current_Token).Line = Start_Line 
            then
               Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
               if not Success then return; end if;
               Tree(Node).Left_Child := Expr_Node;

               if Uses_Parens then
                  if State.Current_Token <= Max_Tokens
                    and then Tokens(State.Current_Token).Kind = Tok_R_Paren
                  then
                     State.Current_Token := State.Current_Token + 1;
                     Success := True;
                  else
                     Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
                     Success := False;
                     return;
                  end if;
               else
                  Success := True;
               end if;
            else
               -- Nae target found, it's a naked readline. We're fine!
               if Uses_Parens then
                  Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
                  Success := False;
                  return;
               end if;
               Success := True; 
            end if;
         end;

      elsif T.Kind = Tok_Load then
         declare
            Uses_Parens : Boolean := False;
         begin
            Allocate_Node(Tokens, State, Tree, AST_Load_Stmt, Node, Success);
            if not Success then return; end if;
            Tree(Node).Token_Index := State.Current_Token; 
            State.Current_Token := State.Current_Token + 1; -- Consume LOAD

            if State.Current_Token <= Max_Tokens
              and then Tokens(State.Current_Token).Kind = Tok_L_Paren
            then
               Uses_Parens := True;
               State.Current_Token := State.Current_Token + 1;
            end if;
            
            Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
            if not Success then return; end if;
            Tree(Node).Left_Child := Expr_Node;
            
            -- Guard: Expect INTO or comma
            if State.Current_Token <= Max_Tokens and then
              (Tokens(State.Current_Token).Kind = Tok_Into or else
               Tokens(State.Current_Token).Kind = Tok_Comma)
            then
               State.Current_Token := State.Current_Token + 1;
            else
               Set_Error(State, Tokens, Err_Parse_Expected_Value); Success := False; return; 
            end if;
            
            -- Guard: Expect Target Variable
            if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind not in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States then
               Set_Error(State, Tokens, Err_Parse_Expected_Value); Success := False; return; 
            end if;
            
            Allocate_Node(Tokens, State, Tree, AST_Var_Expr, Var_Node, Success);
            if not Success then return; end if;
            Tree(Var_Node).Token_Index := State.Current_Token; 
            Tree(Node).Right_Child := Var_Node; 
            State.Current_Token := State.Current_Token + 1;

            if Uses_Parens then
               if State.Current_Token <= Max_Tokens
                 and then Tokens(State.Current_Token).Kind = Tok_R_Paren
               then
                  State.Current_Token := State.Current_Token + 1;
               else
                  Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
                  Success := False;
                  return;
               end if;
            end if;
         end;

      elsif T.Kind = Tok_Flush then
         declare
            Uses_Parens : Boolean := False;
         begin
            Allocate_Node(Tokens, State, Tree, AST_Flush_Stmt, Node, Success);
            if not Success then return; end if;
            Tree(Node).Token_Index := State.Current_Token;
            State.Current_Token := State.Current_Token + 1;

            if State.Current_Token <= Max_Tokens
              and then Tokens(State.Current_Token).Kind = Tok_L_Paren
            then
               Uses_Parens := True;
               State.Current_Token := State.Current_Token + 1;
            end if;

            Parse_Expression(Tokens, State, Tree, Var_Node, Success);
            if not Success then return; end if;
            Tree(Node).Left_Child := Var_Node;

            if State.Current_Token <= Max_Tokens
              and then Tokens (State.Current_Token).Kind = Tok_Size
            then
               State.Current_Token := State.Current_Token + 1;
               Parse_Expression (Tokens, State, Tree, Expr_Node, Success);
               if not Success then return; end if;
               Tree (Var_Node).Next_Sibling := Expr_Node;
            end if;

            if State.Current_Token <= Max_Tokens and then
              (Tokens(State.Current_Token).Kind = Tok_Into or else
               Tokens(State.Current_Token).Kind = Tok_Comma)
            then
               State.Current_Token := State.Current_Token + 1;
            else
               Set_Error(State, Tokens, Err_Parse_Expected_Value);
               Success := False;
               return;
            end if;

            Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
            if not Success then return; end if;
            Tree(Node).Right_Child := Expr_Node;

            if Uses_Parens then
               if State.Current_Token <= Max_Tokens
                 and then Tokens(State.Current_Token).Kind = Tok_R_Paren
               then
                  State.Current_Token := State.Current_Token + 1;
               else
                  Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
                  Success := False;
                  return;
               end if;
            end if;
         end;

      -- =====================================================================
      -- DA BORLAND-STYLE WINDOW FORGE (CREATE_WINDOW "Title", W, H)
      -- =====================================================================
      elsif T.Kind = Tok_Create_Window then
         declare
            Uses_Parens        : Boolean := False;
            W_Node, H_Node     : Node_Index := 0;
            Dummy              : Node_Index := 0;
         begin
            Allocate_Node(Tokens, State, Tree, AST_Create_Window, Node, Success);
            if not Success then return; end if;
            Tree(Node).Token_Index := State.Current_Token; 
            State.Current_Token := State.Current_Token + 1;

            if State.Current_Token <= Max_Tokens
              and then Tokens(State.Current_Token).Kind = Tok_L_Paren
            then
               Uses_Parens := True;
               State.Current_Token := State.Current_Token + 1;
            end if;
            
            -- 1. Parse Title
            Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
            if not Success then return; end if;
            Tree(Node).Left_Child := Expr_Node;
            
            -- 2. Guard: Comma
            if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_Comma then
               Set_Error(State, Tokens, Err_Parse_Expected_Value); Success := False; return; 
            end if;
            State.Current_Token := State.Current_Token + 1;
            
            -- 3. Parse Width
            Parse_Expression(Tokens, State, Tree, W_Node, Success);
            if not Success then return; end if;
            
            -- 4. Guard: Comma
            if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_Comma then
               Set_Error(State, Tokens, Err_Parse_Expected_Value); Success := False; return; 
            end if;
            State.Current_Token := State.Current_Token + 1;
            
            -- 5. Parse Height
            Parse_Expression(Tokens, State, Tree, H_Node, Success);
            if not Success then return; end if;

            if Uses_Parens then
               if State.Current_Token <= Max_Tokens
                 and then Tokens(State.Current_Token).Kind = Tok_R_Paren
               then
                  State.Current_Token := State.Current_Token + 1;
               else
                  Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
                  Success := False;
                  return;
               end if;
            end if;
            
            Allocate_Node(Tokens, State, Tree, AST_Null, Dummy, Success);
            if not Success then return; end if;
            Tree(Dummy).Left_Child := W_Node;
            Tree(Dummy).Right_Child := H_Node;
            Tree(Node).Right_Child := Dummy;
         end;

      -- =====================================================================
      -- DA WINDOW POLICY FORGE
      -- =====================================================================
      elsif T.Kind in TOK_SET_FULLSCREEN | TOK_SET_RESIZABLE | TOK_SET_STRETCHY then
         declare
            Uses_Parens : Boolean := False;
            Value_Node  : Node_Index := 0;
            New_Kind    : Node_Kind := AST_Set_Fullscreen;
         begin
            if T.Kind = TOK_SET_RESIZABLE then
               New_Kind := AST_Set_Resizable;
            elsif T.Kind = TOK_SET_STRETCHY then
               New_Kind := AST_Set_Stretchy;
            end if;

            Allocate_Node (Tokens, State, Tree, New_Kind, Node, Success);
            if not Success then return; end if;
            Tree (Node).Token_Index := State.Current_Token;
            State.Current_Token := State.Current_Token + 1;

            if State.Current_Token <= Max_Tokens
              and then Tokens (State.Current_Token).Kind = Tok_L_Paren
            then
               Uses_Parens := True;
               State.Current_Token := State.Current_Token + 1;
            end if;

            Parse_Expression (Tokens, State, Tree, Value_Node, Success);
            if not Success then return; end if;
            Tree (Node).Left_Child := Value_Node;

            if Uses_Parens then
               if State.Current_Token <= Max_Tokens
                 and then Tokens (State.Current_Token).Kind = Tok_R_Paren
               then
                  State.Current_Token := State.Current_Token + 1;
               else
                  Set_Error (State, Tokens, Err_Parse_Missing_Bracket);
                  Success := False;
                  return;
               end if;
            end if;
         end;

      elsif T.Kind = Tok_Tick then
         declare
            Uses_Parens : Boolean := False;
         begin
            Allocate_Node(Tokens, State, Tree, AST_Tick, Node, Success);
            if not Success then return; end if;
            Tree(Node).Token_Index := State.Current_Token; 
            State.Current_Token := State.Current_Token + 1;

            if State.Current_Token <= Max_Tokens
              and then Tokens(State.Current_Token).Kind = Tok_L_Paren
            then
               Uses_Parens := True;
               State.Current_Token := State.Current_Token + 1;
            end if;
            
            Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
            if not Success then return; end if;
            Tree(Node).Left_Child := Expr_Node;

            if Uses_Parens then
               if State.Current_Token <= Max_Tokens
                 and then Tokens(State.Current_Token).Kind = Tok_R_Paren
               then
                  State.Current_Token := State.Current_Token + 1;
               else
                  Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
                  Success := False;
                  return;
               end if;
            end if;
         end;

      -- =====================================================================
      -- DA EVENT DISPATCH FORGE (ON TICK/PAINT/KNOWS_CHANGE)
      -- =====================================================================
      elsif T.Kind = Tok_On then
         Allocate_Node(Tokens, State, Tree, AST_On_Block, Node, Success);
         if not Success then return; end if;
         State.Current_Token := State.Current_Token + 1; -- Consume 'ON'
         
         -- Guard: Check Event Type
         if State.Current_Token > Max_Tokens then
            Set_Error(State, Tokens, Err_Parse_Expected_Value); Success := False; return; 
         end if;

         if Tokens(State.Current_Token).Kind in Tok_Paint | Tok_Tick | Tok_Key then
            Tree(Node).Token_Index := State.Current_Token;
            State.Current_Token := State.Current_Token + 1;

         elsif Tokens(State.Current_Token).Kind = Tok_Change then
            Tree(Node).Kind := AST_Knows_Change; -- Morph the node!
            Tree(Node).Token_Index := State.Current_Token;
            State.Current_Token := State.Current_Token + 1;
            
            declare 
               Target_Pred : Node_Index; 
            begin
               Parse_Predicate(Tokens, State, Tree, Target_Pred, Success);
               if not Success then return; end if;
               Tree(Node).Right_Child := Target_Pred; -- Store watched predicate!
            end;
         else
            Set_Error(State, Tokens, Err_Parse_Expected_Value);
            Success := False; return;
         end if;
         
         declare 
            Body_Node, First_Stmt, Curr_Stmt, Next_Stmt : Node_Index := 0;
         begin
            Allocate_Node(Tokens, State, Tree, AST_Block_Stmt, Body_Node, Success);
            if not Success then return; end if;
            Tree(Node).Left_Child := Body_Node;
            
            for I in 1 .. 16384 loop
               -- DA FIX: Titanium EOF Guard for missing END
               if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind = Tok_Error then
                  Set_Error(State, Tokens, Err_Parse_Expected_Value); Success := False; return;
               end if;
               
               if Is_Bare_End (Tokens, State)
                 or else Same_Line_End_Tag (Tokens, State, Tok_On)
               then
                  declare 
                     End_Line : Positive := Tokens(State.Current_Token).Line;
                  begin
                     State.Current_Token := State.Current_Token + 1;
                     -- Hybrid Check: Only consume 'ON' if it's on the exact same line as 'END'!
                     if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_On 
                        and then Tokens(State.Current_Token).Line = End_Line 
                     then 
                        State.Current_Token := State.Current_Token + 1; 
                     end if;
                     Success := True; exit;
                  end;
               end if;
               
               Parse_Statement(Tokens, State, Tree, Next_Stmt, Success);
               if not Success then return; end if;
               
               if First_Stmt = 0 then 
                  First_Stmt := Next_Stmt; 
                  Tree(Body_Node).Left_Child := First_Stmt;
               else 
                  Tree(Curr_Stmt).Next_Sibling := Next_Stmt; 
               end if;
               Curr_Stmt := Next_Stmt;
            end loop;
         end;

      -- =====================================================================
      -- DA GRAPHICS PLOTTER (COLOR, DRAW, PLOT)
      -- =====================================================================
      elsif T.Kind = Tok_Color then
         declare
            Uses_Parens : Boolean := False;
         begin
            Allocate_Node(Tokens, State, Tree, AST_Color, Node, Success);
            if not Success then return; end if;
            Tree(Node).Token_Index := State.Current_Token; 
            State.Current_Token := State.Current_Token + 1;

            if State.Current_Token <= Max_Tokens
              and then Tokens(State.Current_Token).Kind = Tok_L_Paren
            then
               Uses_Parens := True;
               State.Current_Token := State.Current_Token + 1;
            end if;
            
            Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
            if not Success then return; end if;
            Tree(Node).Left_Child := Expr_Node;

            if Uses_Parens then
               if State.Current_Token <= Max_Tokens
                 and then Tokens(State.Current_Token).Kind = Tok_R_Paren
               then
                  State.Current_Token := State.Current_Token + 1;
               else
                  Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
                  Success := False;
                  return;
               end if;
            end if;
         end;
         
      elsif T.Kind = Tok_Clear then
         declare
            Uses_Parens : Boolean := False;
         begin
            Allocate_Node(Tokens, State, Tree, AST_Clear, Node, Success);
            if not Success then return; end if;
            State.Current_Token := State.Current_Token + 1; -- Consume CLEAR

            if State.Current_Token <= Max_Tokens
              and then Tokens(State.Current_Token).Kind = Tok_L_Paren
            then
               Uses_Parens := True;
               State.Current_Token := State.Current_Token + 1;
            end if;
            
            -- Harvest the color expression!
            Parse_Expression(Tokens, State, Tree, Tree(Node).Left_Child, Success);
            if not Success then
               Set_Error(State, Tokens, Err_Parse_Expected_Value);
               return;
            end if;

            if Uses_Parens then
               if State.Current_Token <= Max_Tokens
                 and then Tokens(State.Current_Token).Kind = Tok_R_Paren
               then
                  State.Current_Token := State.Current_Token + 1;
               else
                  Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
                  Success := False;
                  return;
               end if;
            end if;
         end;

      elsif T.Kind in Tok_Draw | Tok_Plot | Tok_Fill then
         declare 
            Is_Draw : Boolean := (T.Kind = Tok_Draw);
            Is_Fill : Boolean := (T.Kind = Tok_Fill);
         begin
            Allocate_Node(Tokens, State, Tree, (if Is_Draw then AST_Draw elsif Is_Fill then AST_Fill else AST_Plot), Node, Success);
            if not Success then return; end if;
            State.Current_Token := State.Current_Token + 1;
            -- Consume DRAW, PLOT, or FILL
            
            -- Check for sub-commands
            if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind in Tok_Rect | Tok_Poly | Tok_Pixel | Tok_Line | Tok_Circle | Tok_Triangle then
               Tree(Node).Token_Index := State.Current_Token;
               State.Current_Token := State.Current_Token + 1;
            elsif State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Text then
               Tree(Node).Kind := AST_Text;
               -- Morph into text
               Tree(Node).Token_Index := State.Current_Token;
               State.Current_Token := State.Current_Token + 1;
            else
               if Is_Draw or Is_Fill then
                  Set_Error(State, Tokens, Err_Parse_Expected_Value);
                  Success := False; return;
               end if;
               -- If it's a PLOT without a sub-keyword, just proceed!
            end if;

            Parse_Statement_Arg_List
              (Tokens        => Tokens,
               State         => State,
               Tree          => Tree,
               Owner_Node    => Node,
               Max_Arg_Count => 8,
               Success       => Success);
            if not Success then return; end if;
         end;
         
      -- =====================================================================
      -- DA RENDER STATE FORGE (ALPHA, CLIP, ORIGIN)
      -- =====================================================================
      elsif T.Kind in Tok_Set_Alpha | Tok_Set_Clip | Tok_Set_Origin then
         declare 
            Is_Alpha : Boolean := (T.Kind = Tok_Set_Alpha);
            Is_Clip  : Boolean := (T.Kind = Tok_Set_Clip);
         begin
            Allocate_Node(Tokens, State, Tree, (if Is_Alpha then AST_Set_Alpha elsif Is_Clip then AST_Set_Clip else AST_Set_Origin), Node, Success);
            if not Success then return; end if;
            Tree(Node).Token_Index := State.Current_Token;
            State.Current_Token := State.Current_Token + 1; -- Consume the keyword

            Parse_Statement_Arg_List
              (Tokens        => Tokens,
               State         => State,
               Tree          => Tree,
               Owner_Node    => Node,
               Max_Arg_Count => 8,
               Success       => Success);
            if not Success then return; end if;
         end;
         
      -- =====================================================================
      -- DA STANDALONE TEXT FORGE (TEXT x, y, "String")
      -- =====================================================================
      elsif T.Kind = Tok_Text then
         Allocate_Node(Tokens, State, Tree, AST_Text, Node, Success);
         if not Success then return; end if;
         Tree(Node).Token_Index := State.Current_Token; 
         State.Current_Token := State.Current_Token + 1; -- Consume TEXT

         Parse_Statement_Arg_List
           (Tokens        => Tokens,
            State         => State,
            Tree          => Tree,
            Owner_Node    => Node,
            Max_Arg_Count => 8,
            Success       => Success);
         if not Success then return; end if;

      -- =====================================================================
      -- DA MESSAGE BOX FORGE (MSG_BOX "Message", "Optional Title")
      -- =====================================================================
      elsif T.Kind = Tok_Msg_Box then
         declare
            Uses_Parens : Boolean := False;
         begin
            Allocate_Node(Tokens, State, Tree, AST_Msg_Box, Node, Success);
            if not Success then return; end if;
            Tree(Node).Token_Index := State.Current_Token; 
            State.Current_Token := State.Current_Token + 1; -- Consume MSG_BOX

            if State.Current_Token <= Max_Tokens
              and then Tokens(State.Current_Token).Kind = Tok_L_Paren
            then
               Uses_Parens := True;
               State.Current_Token := State.Current_Token + 1;
            end if;
            
            -- 1. Parse Main Message
            Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
            if not Success then return; end if;
            Tree(Node).Left_Child := Expr_Node;
            
            -- 2. Check for Optional Title (DA FIX: Guarded EOF Check!)
            if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Comma then 
               State.Current_Token := State.Current_Token + 1; -- Consume Comma
               
               Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
               if not Success then return; end if;
               Tree(Node).Right_Child := Expr_Node; 
            end if;

            if Uses_Parens then
               if State.Current_Token <= Max_Tokens
                 and then Tokens(State.Current_Token).Kind = Tok_R_Paren
               then
                  State.Current_Token := State.Current_Token + 1;
               else
                  Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
                  Success := False;
                  return;
               end if;
            else
               Success := True; -- Title is optional, so we succeed regardless!
            end if;
         end;

      -- =====================================================================
      -- DA LISTEN & CEASE FORGE (System Halts)
      -- =====================================================================
      elsif T.Kind = Tok_Listen then
         Allocate_Node(Tokens, State, Tree, AST_Listen, Node, Success);
         if not Success then return; end if;
         Tree(Node).Token_Index := State.Current_Token; 
         State.Current_Token := State.Current_Token + 1;

         if State.Current_Token <= Max_Tokens
           and then Tokens(State.Current_Token).Kind = Tok_L_Paren
         then
            State.Current_Token := State.Current_Token + 1;
            if State.Current_Token <= Max_Tokens
              and then Tokens(State.Current_Token).Kind = Tok_R_Paren
            then
               State.Current_Token := State.Current_Token + 1;
            else
               Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
               Success := False;
               return;
            end if;
         end if;
         
      -- =====================================================================
      -- DA LOOP CONTROL FORGE
      -- =====================================================================
      elsif T.Kind = Tok_Cls then
         Allocate_Node(Tokens, State, Tree, AST_Cls_Stmt, Node, Success);
         if not Success then return; end if;
         Tree(Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1;

      elsif T.Kind = Tok_Break then
         Allocate_Node(Tokens, State, Tree, AST_Break_Stmt, Node, Success);
         if not Success then return; end if;
         Tree(Node).Token_Index := State.Current_Token; 
         State.Current_Token := State.Current_Token + 1;

      elsif T.Kind = Tok_Continue then
         Allocate_Node(Tokens, State, Tree, AST_Continue_Stmt, Node, Success);
         if not Success then return; end if;
         Tree(Node).Token_Index := State.Current_Token; 
         State.Current_Token := State.Current_Token + 1;
         
      -- =====================================================================
      -- DA MUSIC FORGE
      -- =====================================================================
      elsif T.Kind = Tok_Play then
         declare
            Play_Tok_Idx : constant Natural := State.Current_Token;
            Uses_Parens : Boolean := False;
            Play_Kind   : Node_Kind := AST_Play_Sound;
         begin
            State.Current_Token := State.Current_Token + 1; -- Consume PLAY

            if State.Current_Token > Max_Tokens then
               Set_Error(State, Tokens, Err_Parse_Expected_Value);
               Success := False;
               return;
            end if;

            if Tokens(State.Current_Token).Kind = Tok_Sound then
               Play_Kind := AST_Play_Sound;
               State.Current_Token := State.Current_Token + 1; -- Consume SOUND
            elsif Tokens(State.Current_Token).Kind = Tok_Music then
               Play_Kind := AST_Play_Music;
               State.Current_Token := State.Current_Token + 1; -- Consume MUSIC

               if State.Current_Token <= Max_Tokens
                 and then Tokens(State.Current_Token).Kind = Tok_From
               then
                  Play_Kind := AST_Play_Music_From;
                  State.Current_Token := State.Current_Token + 1; -- Consume FROM
               end if;
            else
               Set_Error(State, Tokens, Err_Parse_Expected_Value);
               Success := False;
               return;
            end if;

            Allocate_Node(Tokens, State, Tree, Play_Kind, Node, Success);
            if not Success then return; end if;
            Tree(Node).Token_Index := Play_Tok_Idx;

            if State.Current_Token <= Max_Tokens
              and then Tokens(State.Current_Token).Kind = Tok_L_Paren
            then
               Uses_Parens := True;
               State.Current_Token := State.Current_Token + 1;
            end if;
            
            declare 
               Expr_Node : Node_Index;
            begin
               Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
               if not Success then return; end if;
               Tree(Node).Left_Child := Expr_Node; 
            end;

            if Uses_Parens then
               if State.Current_Token <= Max_Tokens
                 and then Tokens(State.Current_Token).Kind = Tok_R_Paren
               then
                  State.Current_Token := State.Current_Token + 1;
               else
                  Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
                  Success := False;
                  return;
               end if;
            end if;
         end;
         
      elsif T.Kind = Tok_Cease then
         Allocate_Node(Tokens, State, Tree, AST_Cease, Node, Success);
         if not Success then return; end if;
         Tree(Node).Token_Index := State.Current_Token; 
         State.Current_Token := State.Current_Token + 1;

         if State.Current_Token <= Max_Tokens
           and then Tokens(State.Current_Token).Kind = Tok_L_Paren
         then
            State.Current_Token := State.Current_Token + 1;
            if State.Current_Token <= Max_Tokens
              and then Tokens(State.Current_Token).Kind = Tok_R_Paren
            then
               State.Current_Token := State.Current_Token + 1;
            else
               Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
               Success := False;
               return;
            end if;
         end if;
         
      -- =====================================================================
      -- DA INCLUDE FORGE (INCLUDE "file.albi")
      -- =====================================================================
      elsif T.Kind = Tok_Include then
         declare
            Uses_Parens : Boolean := False;
         begin
            Allocate_Node(Tokens, State, Tree, AST_Include_Stmt, Node, Success);
            if not Success then return; end if;
         
            Tree(Node).Token_Index := State.Current_Token; 
            State.Current_Token := State.Current_Token + 1;

            if State.Current_Token <= Max_Tokens
              and then Tokens(State.Current_Token).Kind = Tok_L_Paren
            then
               Uses_Parens := True;
               State.Current_Token := State.Current_Token + 1;
            end if;
         
            -- We expect a String Expression for the filename!
            Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
            if not Success then return; end if;
            Tree(Node).Left_Child := Expr_Node;

            if Uses_Parens then
               if State.Current_Token <= Max_Tokens
                 and then Tokens(State.Current_Token).Kind = Tok_R_Paren
               then
                  State.Current_Token := State.Current_Token + 1;
               else
                  Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
                  Success := False;
                  return;
               end if;
            end if;
         end;
         
      -- =====================================================================
      -- PRIVATE <member> — module-private member decl (drops `pub`)
      -- =====================================================================
      elsif T.Kind = Tok_Private then
         declare
            Inner      : Node_Index := 0;
            Priv_Tok   : constant Natural := State.Current_Token;
         begin
            State.Current_Token := State.Current_Token + 1; -- PRIVATE
            Parse_Statement (Tokens, State, Tree, Inner, Success);
            if not Success then return; end if;
            if Inner = 0 then
               Set_Error (State, Tokens, Err_Parse_Expected_Value);
               Success := False; return;
            end if;
            Allocate_Node(Tokens, State, Tree, AST_Private_Decl, Node, Success);
            if not Success then return; end if;
            Tree (Node).Token_Index := Priv_Tok;
            Tree (Node).Left_Child := Inner;
         end;

      -- =====================================================================
      -- INVARIANT expr — module-scope invariant (established at module
      -- init, re-verified at every public member exit)
      -- =====================================================================
      elsif T.Kind = Tok_Invariant then
         State.Current_Token := State.Current_Token + 1; -- INVARIANT
         Allocate_Node(Tokens, State, Tree, AST_Module_Invariant, Node, Success);
         if not Success then return; end if;
         Tree (Node).Token_Index := State.Current_Token;
         declare
            Uses_Parens : Boolean := False;
         begin
            if State.Current_Token <= Max_Tokens
              and then Tokens (State.Current_Token).Kind = Tok_L_Paren
            then
               Uses_Parens := True;
               State.Current_Token := State.Current_Token + 1;
            end if;
            Parse_Expression (Tokens, State, Tree, Expr_Node, Success);
            if not Success then return; end if;
            Tree (Node).Left_Child := Expr_Node;
            if Uses_Parens then
               if State.Current_Token <= Max_Tokens
                 and then Tokens (State.Current_Token).Kind = Tok_R_Paren
               then
                  State.Current_Token := State.Current_Token + 1;
               else
                  Set_Error (State, Tokens, Err_Parse_Missing_Bracket);
                  Success := False; return;
               end if;
            end if;
         end;

      -- =====================================================================
      -- DA STRICT ARRAY FORGE
      -- =====================================================================
      elsif T.Kind = Tok_Parallel then
         Allocate_Node(Tokens, State, Tree, AST_Parallel_Decl, Node, Success);
         if not Success then return; end if;
         Tree(Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1; -- Consume PARALLEL

         -- 1. Guard: Expect Group Name
         if State.Current_Token > Max_Tokens
           or else Tokens(State.Current_Token).Kind not in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States
         then
            Set_Error(State, Tokens, Err_Parse_Expected_Value);
            Success := False;
            return;
         end if;

         Allocate_Node(Tokens, State, Tree, AST_Var_Expr, Var_Node, Success);
         if not Success then return; end if;

         Tree(Var_Node).Token_Index := State.Current_Token;
         Tree(Node).Left_Child := Var_Node;
         State.Current_Token := State.Current_Token + 1;

         -- 2. Guard: Expect '['
         if State.Current_Token > Max_Tokens
           or else Tokens(State.Current_Token).Kind /= Tok_L_Square
         then
            Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;

         -- 3. Parse Shared Capacity Expression List
         declare
            Bound_List    : Node_Index := 0;
            Last_Bound    : Node_Index := 0;
            Current_Bound : Node_Index := 0;
         begin
            loop
               Parse_Expression(Tokens, State, Tree, Current_Bound, Success);
               if not Success then return; end if;

               if Bound_List = 0 then
                  Bound_List := Current_Bound;
               else
                  Tree(Last_Bound).Next_Sibling := Current_Bound;
               end if;
               Last_Bound := Current_Bound;

               exit when State.Current_Token > Max_Tokens
                 or else Tokens(State.Current_Token).Kind /= Tok_Comma;
               State.Current_Token := State.Current_Token + 1; -- Consume ','
            end loop;

            Tree(Var_Node).Left_Child := Bound_List;
         end;

         -- 4. Guard: Expect ']'
         if State.Current_Token > Max_Tokens
           or else Tokens(State.Current_Token).Kind /= Tok_R_Square
         then
            Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
            Success := False;
            return;
         end if;
         State.Current_Token := State.Current_Token + 1;

         -- 5. Parse Field List until END PARALLEL
         declare
            First_Field : Node_Index := 0;
            Last_Field  : Node_Index := 0;
            Field_Node  : Node_Index := 0;
         begin
            while State.Current_Token <= Max_Tokens
              and then Tokens(State.Current_Token).Kind /= Tok_End
            loop
               if Tokens(State.Current_Token).Kind not in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States then
                  Set_Error(State, Tokens, Err_Parse_Expected_Var);
                  Success := False;
                  return;
               end if;

               Allocate_Node(Tokens, State, Tree, AST_Parallel_Field, Field_Node, Success);
               if not Success then return; end if;

               declare
                  Field_Name_Node : Node_Index := 0;
               begin
                  Allocate_Node(Tokens, State, Tree, AST_Var_Expr, Field_Name_Node, Success);
                  if not Success then return; end if;

                  Tree(Field_Name_Node).Token_Index := State.Current_Token;
                  Tree(Field_Node).Left_Child := Field_Name_Node;
               end;

               State.Current_Token := State.Current_Token + 1;

               if State.Current_Token <= Max_Tokens
                 and then Tokens(State.Current_Token).Kind = Tok_As
               then
                  State.Current_Token := State.Current_Token + 1;

                  if State.Current_Token > Max_Tokens
                    or else not Is_Type_Name_Token (Tokens(State.Current_Token).Kind)
                  then
                     Set_Error(State, Tokens, Err_Parse_Expected_Type);
                     Success := False;
                     return;
                  end if;

                  declare
                     Type_Node : Node_Index := 0;
                  begin
                     Allocate_Node(Tokens, State, Tree, AST_Var_Expr, Type_Node, Success);
                     if not Success then return; end if;

                     Tree(Type_Node).Token_Index := State.Current_Token;
                     Tree(Tree(Field_Node).Left_Child).Right_Child := Type_Node;
                  end;

                  State.Current_Token := State.Current_Token + 1;
                  -- Safety Trap: Variables and Fields cannot be Void
                  if Tokens(State.Current_Token - 1).Kind = Tok_U0 then
                     Set_Error(State, Tokens, Err_Parse_Expected_Value);
                     Success := False;
                     return;
                  end if;
               end if;

               if First_Field = 0 then
                  First_Field := Field_Node;
               else
                  Tree(Last_Field).Next_Sibling := Field_Node;
               end if;
               Last_Field := Field_Node;
            end loop;

            Tree(Node).Right_Child := First_Field;
         end;

         -- 6. Expect END PARALLEL
         if State.Current_Token <= Max_Tokens
           and then Tokens(State.Current_Token).Kind = Tok_End
         then
            State.Current_Token := State.Current_Token + 1;

            if State.Current_Token <= Max_Tokens
              and then Tokens(State.Current_Token).Kind = Tok_Parallel
            then
               State.Current_Token := State.Current_Token + 1;
            else
               Set_Error(State, Tokens, Err_Parse_Expected_Block_End);
               Success := False;
               return;
            end if;
         else
            Set_Error(State, Tokens, Err_Parse_Expected_Block_End);
            Success := False;
            return;
         end if;

      elsif T.Kind = Tok_SwapPop then
         Allocate_Node(Tokens, State, Tree, AST_SwapPop_Stmt, Node, Success);
         if not Success then return; end if;
         Tree(Node).Token_Index := State.Current_Token;
         State.Current_Token := State.Current_Token + 1; -- Consume SWAPPOP

         declare
            Target_Node : Node_Index := 0;
            Count_Node  : Node_Index := 0;
         begin
            Parse_Primary(Tokens, State, Tree, Target_Node, Success);
            if not Success then return; end if;
            Tree(Node).Left_Child := Target_Node;

            if State.Current_Token > Max_Tokens
              or else Tokens(State.Current_Token).Kind /= Tok_Comma
            then
               Set_Error(State, Tokens, Err_Parse_Expected_Value);
               Success := False;
               return;
            end if;
            State.Current_Token := State.Current_Token + 1; -- Consume comma

            Parse_Expression(Tokens, State, Tree, Count_Node, Success);
            if not Success then return; end if;
            Tree(Node).Right_Child := Count_Node;
         end;

      elsif T.Kind = Tok_Strict then
         Allocate_Node(Tokens, State, Tree, AST_Strict_Stmt, Node, Success);
         if not Success then return; end if;
         Tree(Node).Token_Index := State.Current_Token; 
         State.Current_Token := State.Current_Token + 1; -- Consume STRICT
         
         -- 1. Guard: Expect Array Name
         if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind not in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States then
            Set_Error(State, Tokens, Err_Parse_Expected_Value); 
            Success := False; 
            return; 
         end if;
         
         Allocate_Node(Tokens, State, Tree, AST_Var_Expr, Var_Node, Success);
         if not Success then return; end if;
         
         Tree(Var_Node).Token_Index := State.Current_Token; 
         Tree(Node).Left_Child := Var_Node; 
         State.Current_Token := State.Current_Token + 1;
         
         -- 2. Guard: Expect '['
         if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_L_Square then
            Set_Error(State, Tokens, Err_Parse_Missing_Bracket); 
            Success := False; 
            return; 
         end if;
         State.Current_Token := State.Current_Token + 1;
         
         -- 3. Parse Size Expression (Multidimensional)
         declare
            Bound_List : Node_Index := 0;
            Last_Bound : Node_Index := 0;
            Current_Bound : Node_Index;
         begin
            loop
               Parse_Expression(Tokens, State, Tree, Current_Bound, Success);
               if not Success then return; end if;
               
               if Bound_List = 0 then Bound_List := Current_Bound;
               else Tree(Last_Bound).Next_Sibling := Current_Bound; end if;
               Last_Bound := Current_Bound;
               
               exit when State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_Comma;
               State.Current_Token := State.Current_Token + 1; -- Consume ','
            end loop;
            Tree(Node).Right_Child := Bound_List;
         end;
         
         -- 4. Guard: Expect ']'
         if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_R_Square then
            Set_Error(State, Tokens, Err_Parse_Missing_Bracket); 
            Success := False; 
            return; 
         end if;
         State.Current_Token := State.Current_Token + 1;
         
         -- 5. Optional element contract: STRICT A[8] AS Engine_Temp
         if State.Current_Token <= Max_Tokens
           and then Tokens(State.Current_Token).Kind = Tok_As
         then
            State.Current_Token := State.Current_Token + 1;

            if State.Current_Token > Max_Tokens
              or else not Is_Type_Name_Token (Tokens(State.Current_Token).Kind)
            then
               Set_Error(State, Tokens, Err_Parse_Expected_Value);
               Success := False;
               return;
            end if;

            declare
               Type_Node : Node_Index := 0;
            begin
               Allocate_Node(Tokens, State, Tree, AST_Var_Expr, Type_Node, Success);
               if not Success then return; end if;

               Tree(Type_Node).Token_Index := State.Current_Token;
               Tree(Var_Node).Right_Child := Type_Node;

               State.Current_Token := State.Current_Token + 1;
               -- Safety Trap: Variables and Fields cannot be Void
               if Tokens(State.Current_Token - 1).Kind = Tok_U0 then
                  Set_Error(State, Tokens, Err_Parse_Expected_Value);
                  Success := False;
                  return;
               end if;
            end;
         end if;

      -- =====================================================================
      -- DA SLIDE ARRAY FORGE
      -- =====================================================================
      elsif T.Kind = Tok_Slide then
         Allocate_Node(Tokens, State, Tree, AST_Slide_Stmt, Node, Success);
         if not Success then return; end if;
         Tree(Node).Token_Index := State.Current_Token; 
         State.Current_Token := State.Current_Token + 1; -- Consume SLIDE
         
         -- 1. Guard: Expect Array Name
         if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind not in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States then
            Set_Error(State, Tokens, Err_Parse_Expected_Value); 
            Success := False; 
            return; 
         end if;
         
         Allocate_Node(Tokens, State, Tree, AST_Var_Expr, Var_Node, Success);
         if not Success then return; end if;
         
         Tree(Var_Node).Token_Index := State.Current_Token; 
         Tree(Node).Left_Child := Var_Node; 
         State.Current_Token := State.Current_Token + 1;
         
         -- 2. Guard: Expect '['
         if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_L_Square then
            Set_Error(State, Tokens, Err_Parse_Missing_Bracket); 
            Success := False; 
            return; 
         end if;
         State.Current_Token := State.Current_Token + 1;
         
         -- 3. Parse Total Capacity Expression
         Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
         if not Success then return; end if;
         Tree(Node).Right_Child := Expr_Node;
         
         -- 4. Guard: Expect ','
         if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_Comma then
            Set_Error(State, Tokens, Err_Parse_Missing_Bracket); -- Using missing bracket/comma error
            Success := False; 
            return; 
         end if;
         State.Current_Token := State.Current_Token + 1;
         
         -- 5. Parse Active Sliding Size Expression
         declare 
            Active_Expr_Node : Node_Index; 
         begin
            Parse_Expression(Tokens, State, Tree, Active_Expr_Node, Success);
            if not Success then return; end if;
            Tree(Expr_Node).Next_Sibling := Active_Expr_Node;
         end;
         
         -- 6. Guard: Expect ']'
         if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_R_Square then
            Set_Error(State, Tokens, Err_Parse_Missing_Bracket); 
            Success := False; 
            return; 
         end if;
         State.Current_Token := State.Current_Token + 1;
         
         
         -- 7. Optional element contract: SLIDE A[64, 8] AS Engine_Temp
         if State.Current_Token <= Max_Tokens
           and then Tokens(State.Current_Token).Kind = Tok_As
         then
            State.Current_Token := State.Current_Token + 1;

            if State.Current_Token > Max_Tokens
              or else not Is_Type_Name_Token (Tokens(State.Current_Token).Kind)
            then
               Set_Error(State, Tokens, Err_Parse_Expected_Value);
               Success := False;
               return;
            end if;

            declare
               Type_Node : Node_Index := 0;
            begin
               Allocate_Node(Tokens, State, Tree, AST_Var_Expr, Type_Node, Success);
               if not Success then return; end if;

               Tree(Type_Node).Token_Index := State.Current_Token;
               Tree(Var_Node).Right_Child := Type_Node;

               State.Current_Token := State.Current_Token + 1;
               -- Safety Trap: Variables and Fields cannot be Void
               if Tokens(State.Current_Token - 1).Kind = Tok_U0 then
                  Set_Error(State, Tokens, Err_Parse_Expected_Value);
                  Success := False;
                  return;
               end if;
            end;
         end if;
         
      -- =========================================================================
      -- DA DUMPTRUCK (Manual Garbage Collection Pool)
      -- =========================================================================
      
      -- 1. CLAIM Var
      elsif Tokens (State.Current_Token).Kind = Tok_Claim then
         declare
            Uses_Parens : Boolean := False;
            L_Node      : Node_Index := 0;
         begin
            State.Current_Token := State.Current_Token + 1; -- Consume CLAIM
            Allocate_Node (Tokens, State, Tree, AST_Claim_Stmt, Node, Success);
            if not Success then return; end if;

            if State.Current_Token <= Max_Tokens
              and then Tokens(State.Current_Token).Kind = Tok_L_Paren
            then
               Uses_Parens := True;
               State.Current_Token := State.Current_Token + 1;
            end if;
            
            Parse_Expression (Tokens, State, Tree, L_Node, Success);
            if not Success then return; end if;
            Tree (Node).Left_Child := L_Node;

            if Uses_Parens then
               if State.Current_Token <= Max_Tokens
                 and then Tokens(State.Current_Token).Kind = Tok_R_Paren
               then
                  State.Current_Token := State.Current_Token + 1;
               else
                  Set_Error (State, Tokens, Err_Parse_Missing_Bracket);
                  Success := False;
                  return;
               end if;
            end if;
         end;

      -- 2. DROP Var
      elsif Tokens (State.Current_Token).Kind = Tok_Drop then
         declare
            Uses_Parens : Boolean := False;
            L_Node      : Node_Index := 0;
         begin
            State.Current_Token := State.Current_Token + 1; -- Consume DROP
            Allocate_Node (Tokens, State, Tree, AST_Drop_Stmt, Node, Success);
            if not Success then return; end if;

            if State.Current_Token <= Max_Tokens
              and then Tokens(State.Current_Token).Kind = Tok_L_Paren
            then
               Uses_Parens := True;
               State.Current_Token := State.Current_Token + 1;
            end if;
            
            Parse_Expression (Tokens, State, Tree, L_Node, Success);
            if not Success then return; end if;
            Tree (Node).Left_Child := L_Node;

            if Uses_Parens then
               if State.Current_Token <= Max_Tokens
                 and then Tokens(State.Current_Token).Kind = Tok_R_Paren
               then
                  State.Current_Token := State.Current_Token + 1;
               else
                  Set_Error (State, Tokens, Err_Parse_Missing_Bracket);
                  Success := False;
                  return;
               end if;
            end if;
         end;

      -- 3. SWEEP Chunk_Size
      elsif Tokens (State.Current_Token).Kind = Tok_Sweep then
         declare
            Uses_Parens : Boolean := False;
            L_Node      : Node_Index := 0;
         begin
            State.Current_Token := State.Current_Token + 1; -- Consume SWEEP
            Allocate_Node (Tokens, State, Tree, AST_Sweep_Stmt, Node, Success);
            if not Success then return; end if;

            if State.Current_Token <= Max_Tokens
              and then Tokens(State.Current_Token).Kind = Tok_L_Paren
            then
               Uses_Parens := True;
               State.Current_Token := State.Current_Token + 1;
            end if;
            
            -- Parse da mathematical expression for da Chunk Size
            Parse_Expression (Tokens, State, Tree, L_Node, Success);
            if not Success then return; end if;
            Tree (Node).Left_Child := L_Node;

            if Uses_Parens then
               if State.Current_Token <= Max_Tokens
                 and then Tokens(State.Current_Token).Kind = Tok_R_Paren
               then
                  State.Current_Token := State.Current_Token + 1;
               else
                  Set_Error (State, Tokens, Err_Parse_Missing_Bracket);
                  Success := False;
                  return;
               end if;
            end if;
         end;

      -- 4. BIND Parent TO Child1, Child2
      elsif Tokens (State.Current_Token).Kind = Tok_Bind then
         declare
            Uses_Parens : Boolean := False;
            L_Node      : Node_Index := 0;
         begin
            State.Current_Token := State.Current_Token + 1; -- Consume BIND
            Allocate_Node (Tokens, State, Tree, AST_Bind_Stmt, Node, Success);
            if not Success then return; end if;

            if State.Current_Token <= Max_Tokens
              and then Tokens(State.Current_Token).Kind = Tok_L_Paren
            then
               Uses_Parens := True;
               State.Current_Token := State.Current_Token + 1;
            end if;
            
            -- First, parse da Parent Node expression
            Parse_Expression (Tokens, State, Tree, L_Node, Success);
            if not Success then return; end if;
            Tree (Node).Left_Child := L_Node;
         
            -- Accept legacy TO or soft comma separator
            if State.Current_Token <= Max_Tokens and then
              (Tokens (State.Current_Token).Kind = Tok_To or else
               Tokens (State.Current_Token).Kind = Tok_Comma)
            then
               State.Current_Token := State.Current_Token + 1;
            else
               Set_Error (State, Tokens, Err_Parse_Expected_Value);
               Success := False;
               return;
            end if;
         
            -- Noo we parse da list o' Bairns
            declare 
               List_Node, Arg_Node, Last_Arg : Node_Index := 0;
            begin
               Allocate_Node(Tokens, State, Tree, AST_Arg_List, List_Node, Success);
               if not Success then return; end if;
               Tree(Node).Right_Child := List_Node;
            
               for I in 1 .. 64 loop
                  Parse_Expression(Tokens, State, Tree, Arg_Node, Success);
                  if not Success then return; end if;
               
                  if Last_Arg = 0 then Tree(List_Node).Left_Child := Arg_Node;
                  else Tree(Last_Arg).Next_Sibling := Arg_Node; end if;
                  Last_Arg := Arg_Node;
               
                  if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Comma then
                     State.Current_Token := State.Current_Token + 1;
                  else
                     exit; -- End of child list
                  end if;
               end loop;
            end;

            if Uses_Parens then
               if State.Current_Token <= Max_Tokens
                 and then Tokens(State.Current_Token).Kind = Tok_R_Paren
               then
                  State.Current_Token := State.Current_Token + 1;
               else
                  Set_Error (State, Tokens, Err_Parse_Missing_Bracket);
                  Success := False;
                  return;
               end if;
            end if;
         end;
         
      -- =====================================================================
      -- DA SELECT / CASE FORGE
      -- =====================================================================
      elsif T.Kind = Tok_Select then
         Allocate_Node(Tokens, State, Tree, AST_Select_Stmt, Node, Success);
         if not Success then return; end if;
         Tree(Node).Token_Index := State.Current_Token; 
         State.Current_Token := State.Current_Token + 1; -- Consume SELECT
         
         Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
         if not Success then return; end if;
         Tree(Node).Left_Child := Expr_Node;
         
         declare 
            First_Case, Last_Case, Curr_Case : Node_Index := 0; 
         begin
            for I in 1 .. 128 loop
               -- DA FIX: Titanium EOF Guard for missing END SELECT!
               if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind = Tok_Error then
                  Set_Error(State, Tokens, Err_Parse_Expected_Value); 
                  Success := False; 
                  return;
               end if;
               
               if Tokens(State.Current_Token).Kind = Tok_End then
                  State.Current_Token := State.Current_Token + 1;
                  -- Optional 'SELECT'
                  if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Select then 
                     State.Current_Token := State.Current_Token + 1; 
                  end if;
                  Success := True; 
                  return;
               end if;

               if Last_Case /= 0 and then Tree (Last_Case).Left_Child = 0 then
                  Set_Error(State, Tokens, Err_Parse_Expected_Value);
                  Success := False;
                  return;
               end if;
               
               -- Guard: Must be a CASE statement or ELSE default.
               if Tokens(State.Current_Token).Kind not in Tok_Case | Tok_Else then
                  Set_Error(State, Tokens, Err_Parse_Expected_Value); 
                  Success := False; 
                  return; 
               end if;
               
               Allocate_Node(Tokens, State, Tree, AST_Case_Stmt, Curr_Case, Success);
               if not Success then return; end if;
               
               declare 
                  Cond_Node, Body_Node : Node_Index := 0;
                  Is_Default           : Boolean := False;
               begin
                  if Tokens(State.Current_Token).Kind = Tok_Else then
                     Is_Default := True;
                     State.Current_Token := State.Current_Token + 1;
                  else
                     State.Current_Token := State.Current_Token + 1; -- Consume CASE
                     if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Else then
                        Is_Default := True;
                        State.Current_Token := State.Current_Token + 1;
                     else
                        Parse_Expression(Tokens, State, Tree, Cond_Node, Success);
                        if not Success then return; end if;
                        Tree(Curr_Case).Left_Child := Cond_Node;
                     end if;
                  end if;

                  if State.Current_Token <= Max_Tokens
                    and then Tokens(State.Current_Token).Kind = Tok_Arrow
                  then
                     State.Current_Token := State.Current_Token + 1;
                  end if;

                  Parse_Case_Body
                    (Tokens            => Tokens,
                     State             => State,
                     Tree              => Tree,
                     Body_Node         => Body_Node,
                     Stop_On_Case      => True,
                     Stop_On_Else      => True,
                     Stop_On_Match_Arm => False,
                     Success           => Success);
                  if not Success then return; end if;
                  Tree(Curr_Case).Right_Child := Body_Node;

                  if Is_Default
                    and then (State.Current_Token > Max_Tokens
                      or else Tokens(State.Current_Token).Kind /= Tok_End)
                  then
                     Set_Error(State, Tokens, Err_Parse_Expected_Value);
                     Success := False;
                     return;
                  end if;
               end;
               
               -- Bind Siblings
               if First_Case = 0 then 
                  First_Case := Curr_Case; 
                  Tree(Node).Right_Child := First_Case;
               else 
                  Tree(Last_Case).Next_Sibling := Curr_Case; 
               end if;
               Last_Case := Curr_Case;
            end loop;
            
            -- True Block Overflow
            Set_Error(State, Tokens, Err_Parse_Block_Overflow); 
            Success := False;
         end;

      --  -- =====================================================================
      --  -- DA OMNI-ROUTER: NAKED CALLS, INFERRED ASSIGNMENTS & BARE FACTS
      --  -- =====================================================================
      --  elsif T.Kind in Tok_Let | Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States then
      --     declare
      --        Is_Let       : Boolean := False;
      --        Target_Node  : Node_Index;
      --        Is_Fact      : Boolean := False;
      --     begin
      --        -- DA FIX: Peek ahead tae save Prolog Facts frae being swallowed!
      --        if T.Kind = Tok_Atom then
      --           for Scan in State.Current_Token .. State.Current_Token + 32 loop
      --              exit when Scan > Max_Tokens or else Tokens(Scan).Line /= T.Line;
      --              if Tokens(Scan).Kind = Tok_Dot then
      --                 Is_Fact := True; exit;
      --              elsif Tokens(Scan).Kind = Tok_Assign then
      --                 exit; -- Definitely an assignment
      --              end if;
      --           end loop;
      --        end if;
      --  
      --        if Is_Fact then
      --           -- Route back tae the original AST_Fact logic!
      --           Allocate_Node(Tokens, State, Tree, AST_Fact, Node, Success);
      --           if not Success then return; end if;
      --           Tree(Node).Token_Index := State.Current_Token;
      --           Parse_Predicate(Tokens, State, Tree, Pred_Node, Success);
      --           if not Success then return; end if;
      --           Tree(Node).Left_Child := Pred_Node;
      --           if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Dot then
      --              State.Current_Token := State.Current_Token + 1;
      --           end if;
      --        else
      --           -- It's a Let, Naked Assignment, or Naked Call!
      --           if T.Kind = Tok_Let then
      --              Is_Let := True;
      --              State.Current_Token := State.Current_Token + 1;
      --           end if;
      --  
      --           -- Parse_Primary perfectly consumes vars, arrays, dot-notation, AND function calls!
      --           Parse_Primary(Tokens, State, Tree, Target_Node, Success);
      --           if not Success then return; end if;
      --  
      --           -- Optional 'AS <Type>'
      --           declare
      --              Has_Type   : Boolean := False;
      --              Type_Token : Natural := 0;
      --           begin
      --              if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_As then
      --                 State.Current_Token := State.Current_Token + 1;
      --                 if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind in Tok_Atom | Tok_Logic_Var | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States | Tok_String_Type then
      --                    Has_Type := True;
      --                    Type_Token := State.Current_Token;
      --                    State.Current_Token := State.Current_Token + 1;
      --                 else
      --                    Set_Error(State, Tokens, Err_Parse_Missing_Type_Name);
      --                    Success := False; return;
      --                 end if;
      --              end if;
      --  
      --              if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Assign then
      --                 -- [ PATH A: ASSIGNMENT ]
      --                 Allocate_Node(Tokens, State, Tree, AST_Let_Stmt, Node, Success);
      --                 if not Success then return; end if;
      --  
      --                 Tree(Node).Token_Index := Type_Token; -- 0 means 'Infer ma type!'
      --                 Tree(Node).Left_Child := Target_Node;
      --                 State.Current_Token := State.Current_Token + 1; -- Consume '='
      --  
      --                 declare
      --                    RHS_Node : Node_Index;
      --                 begin
      --                    Parse_Expression(Tokens, State, Tree, RHS_Node, Success);
      --                    if Success then Tree(Node).Right_Child := RHS_Node; end if;
      --                 end;
      --              else
      --                 -- [ PATH B: NAKED CALL OR BARE DECLARATION ]
      --                 if Is_Let or Has_Type then
      --                    if Is_Let and Has_Type then
      --                       -- Bare declaration (e.g. LET X AS U64)
      --                       Allocate_Node(Tokens, State, Tree, AST_Let_Stmt, Node, Success);
      --                       if not Success then return; end if;
      --                       Tree(Node).Token_Index := Type_Token;
      --                       Tree(Node).Left_Child := Target_Node;
      --                       Success := True;
      --                    else
      --                       Set_Error(State, Tokens, Err_Parse_Missing_Assign);
      --                       Success := False; return;
      --                    end if;
      --                 else
      --                    -- DA MAGIC: Naked Call! (e.g. Audio.PlayTheme())
      --                    Allocate_Node(Tokens, State, Tree, AST_Call_Stmt, Node, Success);
      --                    if not Success then return; end if;
      --                    Tree(Node).Token_Index := Tree(Target_Node).Token_Index;
      --                    Tree(Node).Left_Child := Target_Node;
      --                    Success := True;
      --                 end if;
      --              end if;
      --           end;
      --        end if;
      --     end;
      
         
      -- =====================================================================
      -- DA OMNI-ROUTER: NAKED CALLS, INFERRED ASSIGNMENTS & BARE FACTS
      -- =====================================================================
      elsif T.Kind in Tok_Let | Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States | Tok_Const_Id then
         declare
            Is_Let       : Boolean := False;
            Is_Const     : Boolean := False;
            Target_Node  : Node_Index;
            Is_Fact      : Boolean := False;
         begin
            -- DA FIX: Peek ahead tae save Prolog Facts frae being swallowed!
            -- We check both Atoms AND Logic Vars since Predicates can be uppercase noo!
            if T.Kind in Tok_Atom | Tok_Logic_Var | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States then
               for Scan in State.Current_Token .. State.Current_Token + 32 loop
                  exit when Scan > Max_Tokens or else Tokens(Scan).Line /= T.Line;
                  
                  if Tokens(Scan).Kind = Tok_Dot then
                     -- DA TRUE ARMOR: A dot only means it's a Prolog fact if it ENDS the statement!
                     if Scan = Max_Tokens or else Tokens(Scan + 1).Line /= T.Line then
                        Is_Fact := True;
                        exit;
                     end if;
                     -- If it's nae the end o' the line, it's just a struct/module access! Keep lookin'!
                  elsif Tokens(Scan).Kind = Tok_Assign then
                     exit; -- Definitely an assignment, stop lookin'
                  end if;
               end loop;
            end if;
            
            if Is_Fact then
               -- Route back tae the original AST_Fact logic!
               Allocate_Node(Tokens, State, Tree, AST_Fact, Node, Success);
               if not Success then return; end if;
               Tree(Node).Token_Index := State.Current_Token;
               
               Parse_Predicate(Tokens, State, Tree, Pred_Node, Success);
               if not Success then return; end if;
               Tree(Node).Left_Child := Pred_Node;
               
               if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Dot then 
                  State.Current_Token := State.Current_Token + 1;
               end if;
            else
               -- It's an optional Let, Naked Assignment, or Naked Call!
               if T.Kind = Tok_Let then 
                  Is_Let := True;
                  State.Current_Token := State.Current_Token + 1; -- Consume LET
               elsif T.Kind = Tok_Const_Id then
                  Is_Const := True;
               end if;
               
               -- Parse_Primary perfectly consumes vars, arrays, dot-notation, AND function calls!
               Parse_Primary(Tokens, State, Tree, Target_Node, Success);
               if not Success then return; end if;
               
               -- Optional 'AS <Type>'
               declare
                  Has_Type     : Boolean := False;
                  Type_Token   : Natural := 0;
                  Type_Is_Void : Boolean := False;
               begin
                  if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_As then
                     State.Current_Token := State.Current_Token + 1; -- Consume AS
                     
                     if State.Current_Token <= Max_Tokens and then Is_Type_Name_Token (Tokens(State.Current_Token).Kind) then
                        Has_Type   := True;
                        Type_Token := State.Current_Token;
                        Type_Is_Void := Tokens(State.Current_Token).Kind = Tok_U0;
                        State.Current_Token := State.Current_Token + 1; -- Consume Type
                     else
                        Set_Error(State, Tokens, Err_Parse_Missing_Type_Name);
                        Success := False; return;
                     end if;
                  end if;
                  
                  if not Is_Const
                    and then not Is_Let
                    and then not Has_Type
                    and then State.Current_Token + 1 <= Max_Tokens
                    and then Tokens(State.Current_Token).Kind in Tok_Plus | Tok_Minus
                    and then Tokens(State.Current_Token + 1).Kind = Tokens(State.Current_Token).Kind
                    and then Tokens(State.Current_Token + 1).Line = Tokens(State.Current_Token).Line
                  then
                     -- C-style postfix ++/-- lowers through the existing ADVANCE statement node.
                     Allocate_Node(Tokens, State, Tree, AST_Advance_Stmt, Node, Success);
                     if not Success then return; end if;
                     Tree(Node).Token_Index := State.Current_Token;
                     Tree(Node).Left_Child  := Target_Node;
                     State.Current_Token := State.Current_Token + 2;
                     Success := True;

                  elsif State.Current_Token + 1 <= Max_Tokens
                    and then Tokens(State.Current_Token).Kind in Tok_Plus | Tok_Minus | Tok_Mul | Tok_Div
                    and then Tokens(State.Current_Token + 1).Kind = Tok_Assign
                    and then Tokens(State.Current_Token + 1).Line = Tokens(State.Current_Token).Line
                  then
                     -- x += y becomes x = x + y, reusing the backend's normal BinOp path.
                     if Is_Const or else Is_Let or else Has_Type then
                        Set_Error(State, Tokens, Err_Parse_Missing_Assign);
                        Success := False;
                        return;
                     end if;

                     declare
                        Op_Token    : constant Natural := State.Current_Token;
                        Target_Copy : Node_Index := 0;
                        RHS_Node    : Node_Index := 0;
                        Bin_Node    : Node_Index := 0;
                     begin
                        Allocate_Node(Tokens, State, Tree, AST_Let_Stmt, Node, Success);
                        if not Success then return; end if;
                        Tree(Node).Token_Index := 0;
                        Tree(Node).Left_Child  := Target_Node;

                        Clone_Subtree(Tokens, State, Tree, Target_Node, Target_Copy, Success);
                        if not Success then return; end if;

                        Allocate_Node(Tokens, State, Tree, AST_BinOp, Bin_Node, Success);
                        if not Success then return; end if;
                        Tree(Bin_Node).Token_Index := Op_Token;
                        Tree(Bin_Node).Left_Child  := Target_Copy;

                        State.Current_Token := State.Current_Token + 2; -- Consume op and '='
                        Parse_Expression(Tokens, State, Tree, RHS_Node, Success);
                        if not Success then return; end if;

                        Tree(Bin_Node).Right_Child := RHS_Node;
                        Tree(Node).Right_Child := Bin_Node;
                     end;

                  elsif State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Assign then
                     -- [ PATH A: ASSIGNMENT WITH OR WITHOUT 'LET' ]
                     if Type_Is_Void then
                        Set_Error(State, Tokens, Err_Parse_Expected_Value);
                        Success := False;
                        return;
                     end if;

                     if Is_Const then
                        if Has_Type then
                           Set_Error(State, Tokens, Err_Parse_Expected_Value);
                           Success := False; return;
                        end if;

                        Allocate_Node(Tokens, State, Tree, AST_Const_Decl, Node, Success);
                        if not Success then return; end if;

                        Tree(Node).Token_Index := Tree(Target_Node).Token_Index;
                        Tree(Node).Left_Child  := Target_Node;
                     else
                        Allocate_Node(Tokens, State, Tree, AST_Let_Stmt, Node, Success);
                        if not Success then return; end if;
                        
                        Tree(Node).Token_Index := Type_Token; -- 0 means 'Infer ma type!'
                        Tree(Node).Left_Child  := Target_Node;
                     end if;
                     State.Current_Token    := State.Current_Token + 1; -- Consume '='

                     declare
                        RHS_Node : Node_Index;
                     begin
                        -- LAMBDA is only legal as the direct RHS of a
                        -- LET/CONST/assignment binding — nowhere else in
                        -- the grammar (hard-blocked per language spec).
                        if Tokens (State.Current_Token).Kind = Tok_Lambda then
                           Parse_Lambda_Expr (Tokens, State, Tree, RHS_Node, Success);
                        else
                           Parse_Expression(Tokens, State, Tree, RHS_Node, Success);
                        end if;
                        if Success then Tree(Node).Right_Child := RHS_Node; end if;
                     end;
                  else
                     -- [ PATH B: NAKED CALL OR BARE DECLARATION ]
                     if Is_Const then
                        Set_Error(State, Tokens, Err_Parse_Missing_Assign);
                        Success := False; return;
                     elsif Is_Let or Has_Type then
                        if Has_Type then
                           -- Bare declaration (e.g. X AS U64 or LET X AS U64)
                           Allocate_Node(Tokens, State, Tree, AST_Let_Stmt, Node, Success);
                           if not Success then return; end if;
                           Tree(Node).Token_Index := Type_Token;
                           Tree(Node).Left_Child  := Target_Node;
                           Success := True;
                        else
                           Set_Error(State, Tokens, Err_Parse_Missing_Assign);
                           Success := False; return;
                        end if;
                     else
                        -- DA MAGIC: Naked Call! (e.g. Audio.PlayTheme())
                        Allocate_Node(Tokens, State, Tree, AST_Call_Stmt, Node, Success);
                        if not Success then return; end if;
                        
                        Tree(Node).Token_Index := Tree(Target_Node).Token_Index;
                        Tree(Node).Left_Child  := Target_Node;
                        Success := True;
                     end if;
                  end if;
               end;
            end if;
         end;
         
      -- =====================================================================
      -- DA LINUX-STYLE PRINT PIPELINE (PRINT$ "Score: " | score | "!")
      -- =====================================================================
      elsif T.Kind in Tok_Print | Tok_Print_Str then
         declare
            Is_String_Print : Boolean := (T.Kind = Tok_Print_Str);
            First_Node      : Node_Index;
            Current_Pipe    : Node_Index;
            Next_Pipe       : Node_Index;
            Expr_Node       : Node_Index;
            Uses_Parens     : Boolean := False;
            Prev_Stop_At_Stream_Shl : Boolean := False;
          begin
            State.Current_Token := State.Current_Token + 1; -- Consume PRINT / PRINT$

             if State.Current_Token <= Max_Tokens
               and then Tokens(State.Current_Token).Kind = Tok_L_Paren
             then
                Uses_Parens := True;
                State.Current_Token := State.Current_Token + 1;
             end if;

             if State.Current_Token <= Max_Tokens
               and then Tokens(State.Current_Token).Kind = Tok_Shl
             then
                State.Current_Token := State.Current_Token + 1; -- Consume cout-style <<
             end if;
             
             Allocate_Node(Tokens, State, Tree, (if Is_String_Print then AST_Print_Str_Stmt else AST_Print_Stmt), First_Node, Success);
             if not Success then return; end if;
            
            Prev_Stop_At_Stream_Shl := State.Stop_At_Stream_Shl;
            --  A wrapped arg `PRINT (x SHL 3)` treats the paren group as
            --  ONE expression — SHL inside it is a shift, not a stream
            --  separator.  Bare args keep the separator behavior.
            State.Stop_At_Stream_Shl := not Uses_Parens;
            Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
            State.Stop_At_Stream_Shl := Prev_Stop_At_Stream_Shl;
            if not Success then return; end if;
            Tree(First_Node).Left_Child := Expr_Node;
            
            -- Right_Child > 0 means it points tae the NEXT item in the pipe!
            Tree(First_Node).Right_Child := 0; 
            
            Current_Pipe := First_Node;
            
             -- 2. DA PIPE LOOP: Keep chaining as lang as we see '|', '&', or '<<'
             -- (Task B2: '&' is a QBASIC/VB-style alias for '|'.)
             while State.Current_Token <= Max_Tokens
               and then Tokens(State.Current_Token).Kind in
                          Tok_Pipe | Tok_Ampersand | Tok_Shl
             loop
                State.Current_Token := State.Current_Token + 1; -- Consume '|', '&' or '<<'

                if State.Current_Token <= Max_Tokens
                  and then Tokens(State.Current_Token).Kind = Tok_Endl
                then
                   Tree(First_Node).Kind := AST_Print_Stmt;
                   State.Current_Token := State.Current_Token + 1;
                   exit;
                end if;
                
                Allocate_Node(Tokens, State, Tree, AST_Print_Stmt, Next_Pipe, Success);
                if not Success then return; end if;
               
               Tree(Next_Pipe).Right_Child := 0; -- Assumes this is da last one
               
               Prev_Stop_At_Stream_Shl := State.Stop_At_Stream_Shl;
               State.Stop_At_Stream_Shl := True;
               Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
               State.Stop_At_Stream_Shl := Prev_Stop_At_Stream_Shl;
               if not Success then return; end if;
               Tree(Next_Pipe).Left_Child := Expr_Node;
               
               -- DA FIX: Chain the pipe via Right_Child sae it stays as ONE statement block!
               Tree(Current_Pipe).Right_Child := Next_Pipe;
               Current_Pipe := Next_Pipe;
            end loop;

            if Uses_Parens then
               if State.Current_Token <= Max_Tokens
                 and then Tokens(State.Current_Token).Kind = Tok_R_Paren
               then
                  State.Current_Token := State.Current_Token + 1;
               else
                  Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
                  Success := False;
                  return;
               end if;
            end if;
            
            Node := First_Node;
            Success := True;
         end;
         
      -- =========================================================================
      -- DA NATIVE ERROR FORGE (TRY / CATCH / THROW)
      -- =========================================================================
      elsif T.Kind = Tok_Throw then
         State.Current_Token := State.Current_Token + 1; -- Consume THROW
         declare
            Err_Expr    : Node_Index := 0;
            Uses_Parens : Boolean := False;
         begin
            if State.Current_Token <= Max_Tokens
              and then Tokens(State.Current_Token).Kind = Tok_L_Paren
            then
               Uses_Parens := True;
               State.Current_Token := State.Current_Token + 1;
            end if;

            Parse_Expression(Tokens, State, Tree, Err_Expr, Success);
            if not Success then return; end if;

            if Uses_Parens then
               if State.Current_Token <= Max_Tokens
                 and then Tokens(State.Current_Token).Kind = Tok_R_Paren
               then
                  State.Current_Token := State.Current_Token + 1;
               else
                  Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
                  Success := False;
                  return;
               end if;
            end if;

            Allocate_Node(Tokens, State, Tree, AST_Throw_Stmt, Node, Success);
            if not Success then return; end if;
            Tree(Node).Left_Child := Err_Expr;
         end;

      elsif T.Kind = Tok_Try then
         State.Current_Token := State.Current_Token + 1; -- Consume TRY
         declare
            Try_Body, Catch_Body : Node_Index := 0;
            First_Stmt, Curr_Stmt, Next_Stmt : Node_Index := 0;
         begin
            Allocate_Node(Tokens, State, Tree, AST_Try_Stmt, Node, Success);
            if not Success then return; end if;

            -- 1. Parse TRY Block
            Allocate_Node(Tokens, State, Tree, AST_Block_Stmt, Try_Body, Success);
            if not Success then return; end if;
            Tree(Node).Left_Child := Try_Body;

            for I in 1 .. 8192 loop
               if State.Current_Token > Max_Tokens then Set_Error(State, Tokens, Err_Parse_Expected_Value); Success := False; return; end if;
               if Tokens(State.Current_Token).Kind = Tok_Catch then exit; end if;

               Parse_Statement(Tokens, State, Tree, Next_Stmt, Success);
               if not Success then return; end if;

               if First_Stmt = 0 then 
                  Tree(Try_Body).Left_Child := Next_Stmt; 
                  First_Stmt := Next_Stmt;
               else 
                  Tree(Curr_Stmt).Next_Sibling := Next_Stmt; 
               end if;
               Curr_Stmt := Next_Stmt;
            end loop;

            -- 2. Consume CATCH and Optional Error Variable
            if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Catch then
               State.Current_Token := State.Current_Token + 1; -- Consume CATCH
               
               if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States | Tok_String_Type
               then
                  Tree(Node).Token_Index := State.Current_Token; -- Stash the Error Variable Name!
                  State.Current_Token := State.Current_Token + 1;
               else
                  Tree(Node).Token_Index := 0; -- Nae error variable provided
               end if;

               -- 3. Parse CATCH Block
               Allocate_Node(Tokens, State, Tree, AST_Block_Stmt, Catch_Body, Success);
               if not Success then return; end if;
               Tree(Node).Right_Child := Catch_Body;
               
               First_Stmt := 0; Curr_Stmt := 0;

               for I in 1 .. 8192 loop
                  if State.Current_Token > Max_Tokens then Set_Error(State, Tokens, Err_Parse_Expected_Value); Success := False; return; end if;
                  
                  if Tokens(State.Current_Token).Kind = Tok_End then
                     State.Current_Token := State.Current_Token + 1; -- Consume END
                     if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Try then
                        State.Current_Token := State.Current_Token + 1; -- Consume TRY
                     end if;
                     exit;
                  end if;

                  Parse_Statement(Tokens, State, Tree, Next_Stmt, Success);
                  if not Success then return; end if;

                  if First_Stmt = 0 then 
                     Tree(Catch_Body).Left_Child := Next_Stmt; 
                     First_Stmt := Next_Stmt;
                  else 
                     Tree(Curr_Stmt).Next_Sibling := Next_Stmt; 
                  end if;
                  Curr_Stmt := Next_Stmt;
               end loop;
            else
               Set_Error(State, Tokens, Err_Parse_Expected_Value); Success := False; return;
            end if;
         end;
         
      -- =========================================================================
      -- DA FILE I/O STATEMENTS FORGE (WRITE / CLOSE)
      -- =========================================================================
      elsif T.Kind = Tok_Write then
         State.Current_Token := State.Current_Token + 1; -- Consume WRITE
         declare
            Expr_Handle, Expr_Data : Node_Index := 0;
            Uses_Parens            : Boolean := False;
         begin
            if State.Current_Token <= Max_Tokens
              and then Tokens(State.Current_Token).Kind = Tok_L_Paren
            then
               Uses_Parens := True;
               State.Current_Token := State.Current_Token + 1;
            end if;

            -- 1. Grab the Handle
            Parse_Expression(Tokens, State, Tree, Expr_Handle, Success);
            if not Success then return; end if;
            
            if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_Comma then
               Set_Error(State, Tokens, Err_Parse_Expected_Value); Success := False; return;
            end if;
            State.Current_Token := State.Current_Token + 1; -- Consume ','
            
            -- 2. Grab the Data String
            Parse_Expression(Tokens, State, Tree, Expr_Data, Success);
            if not Success then return; end if;

            if Uses_Parens then
               if State.Current_Token <= Max_Tokens
                 and then Tokens(State.Current_Token).Kind = Tok_R_Paren
               then
                  State.Current_Token := State.Current_Token + 1;
               else
                  Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
                  Success := False;
                  return;
               end if;
            end if;
            
            Allocate_Node(Tokens, State, Tree, AST_File_Write, Node, Success);
            if not Success then return; end if;
            Tree(Node).Left_Child := Expr_Handle;
            Tree(Node).Right_Child := Expr_Data;
         end;

      elsif T.Kind = Tok_Close then
         State.Current_Token := State.Current_Token + 1; -- Consume CLOSE
         declare
            Expr_Handle : Node_Index := 0;
            Uses_Parens : Boolean := False;
         begin
            if State.Current_Token <= Max_Tokens
              and then Tokens(State.Current_Token).Kind = Tok_L_Paren
            then
               Uses_Parens := True;
               State.Current_Token := State.Current_Token + 1;
            end if;

            Parse_Expression(Tokens, State, Tree, Expr_Handle, Success);
            if not Success then return; end if;

            if Uses_Parens then
               if State.Current_Token <= Max_Tokens
                 and then Tokens(State.Current_Token).Kind = Tok_R_Paren
               then
                  State.Current_Token := State.Current_Token + 1;
               else
                  Set_Error(State, Tokens, Err_Parse_Missing_Bracket);
                  Success := False;
                  return;
               end if;
            end if;
            
            Allocate_Node(Tokens, State, Tree, AST_File_Close, Node, Success);
            if not Success then return; end if;
            Tree(Node).Left_Child := Expr_Handle;
         end;

      elsif T.Kind in Tok_Open | Tok_Read | Tok_Fileseek | Tok_Filelen then
         --  File intrinsics used as bare statements (e.g. FILESEEK(h, 0)).
         --  They live in the expression grammar; the produced node is the
         --  statement.
         Parse_Expression(Tokens, State, Tree, Node, Success);
         if not Success then return; end if;

      -- =====================================================================
      -- DA IF STATEMENT FORGE (Hybrid Single/Multi-Line Parity)
      -- =====================================================================
      elsif T.Kind = Tok_If then
         Allocate_Node(Tokens, State, Tree, AST_If_Stmt, Node, Success);
         if not Success then return; end if;
         Tree(Node).Token_Index := State.Current_Token; 
         State.Current_Token := State.Current_Token + 1; -- Consume IF

         -- 1. Handle Prolog Queries inside IF (e.g., IF ?- knows(X) THEN)
         if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Query then
            declare 
               Query_Node : Node_Index;
            begin
               Allocate_Node(Tokens, State, Tree, AST_Query, Query_Node, Success);
               if not Success then return; end if;
               Tree(Query_Node).Token_Index := State.Current_Token; 
               State.Current_Token := State.Current_Token + 1; -- Consume '?-'
               
               Parse_Predicate(Tokens, State, Tree, Pred_Node, Success);
               
               -- DA FIX: Prevent the Phantom Error! Trap the failure!
               if not Success then 
                  Set_Error(State, Tokens, Err_Parse_Expected_Value);
                  return; 
               end if;
               
               Tree(Query_Node).Left_Child := Pred_Node;
               Tree(Node).Left_Child := Query_Node;
               -- Optional terminator dot for inline queries
               if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Dot then 
                  State.Current_Token := State.Current_Token + 1;
               end if;
            end;
          else
            -- Standard Expression Condition
            Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
             if not Success then return; end if;
             Tree(Node).Left_Child := Expr_Node;
          end if;

          if State.Current_Token <= Max_Tokens
            and then Tokens(State.Current_Token).Kind = Tok_Begin
          then
             declare
                Then_Block : Node_Index := 0;
                Else_Block : Node_Index := 0;
                Else_Stmt  : Node_Index := 0;
             begin
                Parse_Block_Stmt(Tokens, State, Tree, Then_Block, Success);
                if not Success then return; end if;
                Tree(Node).Right_Child := Then_Block;

                if State.Current_Token <= Max_Tokens
                  and then Tokens(State.Current_Token).Kind = Tok_Else
                then
                   State.Current_Token := State.Current_Token + 1;

                   if State.Current_Token <= Max_Tokens
                     and then Tokens(State.Current_Token).Kind = Tok_Begin
                   then
                      Parse_Block_Stmt(Tokens, State, Tree, Else_Block, Success);
                      if not Success then return; end if;
                   else
                      Allocate_Node(Tokens, State, Tree, AST_Block_Stmt, Else_Block, Success);
                      if not Success then return; end if;

                      Parse_Statement(Tokens, State, Tree, Else_Stmt, Success);
                      if not Success then return; end if;
                      Tree(Else_Block).Left_Child := Else_Stmt;
                   end if;

                   Tree(Then_Block).Next_Sibling := Else_Block;
                end if;

                Success := True;
                return;
             end;
          end if;

          -- 2. DA GHOST TOKEN FORGE: Expect THEN (or implicitly insert it!)
          declare 
            Then_Line : Positive;
         begin
            if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_Then then
               -- Log a gentle warning instead of a fatal error!
               Log_Warning(State, Tokens, Err_Parse_Missing_Then);
               -- Infer the line number frae the end of the condition
               if State.Current_Token > 1 then Then_Line := Tokens(State.Current_Token - 1).Line; else Then_Line := 1; end if;
            else
               Then_Line := Tokens(State.Current_Token).Line;
               State.Current_Token := State.Current_Token + 1; -- Consume THEN
            end if;
            
            -- DA HYBRID RULE: Single vs Multi-Line detection!
            if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Line = Then_Line then
               
               -- ==========================================
               -- SINGLE LINE IF / ELSE
               -- ==========================================
               declare
                  Then_Block   : Node_Index := 0;
                  Else_Block   : Node_Index := 0;
                  Active_Block : Node_Index := 0;
                  Inner_Then   : Node_Index := 0;  --  innermost then-block for ELSEIF chains
                  First_Stmt   : Node_Index := 0;
                  Curr_Stmt    : Node_Index := 0;
                  Next_Stmt    : Node_Index := 0;
                  Else_Line    : Natural := 0;
                  Else_Is_Inline : Boolean := False;
               begin
                  Allocate_Node(Tokens, State, Tree, AST_Block_Stmt, Then_Block, Success);
                  if not Success then return; end if;
                  Tree(Node).Right_Child := Then_Block;
                  Active_Block := Then_Block;
                  Inner_Then := Then_Block;

                  -- First, eagerly consume the same-line THEN chain.
                  while State.Current_Token <= Max_Tokens
                    and then Tokens(State.Current_Token).Line = Then_Line
                  loop
                     exit when Tokens(State.Current_Token).Kind = Tok_Else;
                     exit when Tokens(State.Current_Token).Kind = Tok_Elseif;
                     exit when State.Current_Token + 1 <= Max_Tokens
                       and then Tokens(State.Current_Token).Kind = Tok_End
                       and then Tokens(State.Current_Token + 1).Kind = Tok_If
                       and then Tokens(State.Current_Token + 1).Line = Then_Line;

                     Parse_Statement(Tokens, State, Tree, Next_Stmt, Success);
                     if not Success then return; end if;

                     if Next_Stmt = 0 then
                        Set_Error(State, Tokens, Err_Parse_Expected_Value);
                        Success := False;
                        return;
                     elsif Tree(Active_Block).Left_Child = 0 then
                        Tree(Active_Block).Left_Child := Next_Stmt;
                     else
                        Tree(Curr_Stmt).Next_Sibling := Next_Stmt;
                     end if;

                     Curr_Stmt := Next_Stmt;
                  end loop;

                  if Tree(Then_Block).Left_Child = 0 then
                     Set_Error(State, Tokens, Err_Parse_Expected_Value);
                     Success := False;
                     return;
                  end if;

                  -- Hybrid continuation: if the branch started on the THEN
                  -- line, it may still flow into a later ELSE or END IF.
                  for I in 1 .. 16384 loop
                     if State.Current_Token > Max_Tokens
                       or else Tokens(State.Current_Token).Kind = Tok_Error
                     then
                        -- If we hit EOF, the single-line IF implicitly terminates
                        -- only for pure inline branches. A dangling multi-line
                        -- ELSE still requires an END IF closer.
                        if Else_Block = 0 or else Else_Is_Inline then
                           Success := True;
                           return;
                        else
                           Set_Error(State, Tokens, Err_Parse_Expected_Value);
                           Success := False;
                           return;
                        end if;
                     end if;

                     if Is_Bare_End (Tokens, State)
                       or else Same_Line_End_Tag (Tokens, State, Tok_If)
                     then
                        declare
                           End_Line : constant Positive := Tokens (State.Current_Token).Line;
                        begin
                           State.Current_Token := State.Current_Token + 1; -- Consume END
                           if State.Current_Token <= Max_Tokens
                             and then Tokens (State.Current_Token).Kind = Tok_If
                             and then Tokens (State.Current_Token).Line = End_Line
                           then
                              State.Current_Token := State.Current_Token + 1; -- Consume IF
                           end if;
                           Success := True;
                           return;
                        end;

                     elsif Tokens(State.Current_Token).Kind = Tok_Elseif then
                        --  ELSEIF cond THEN: else-block holds a nested IF,
                        --  so a single END IF closes the whole chain.  Each
                        --  ELSEIF allocates a fresh wrapper — `Else_Block`
                        --  only marks that we are inside the else chain.
                        declare
                           Elseif_Tok : constant Natural := State.Current_Token;
                           Nested_If  : Node_Index := 0;
                           Cond_Node  : Node_Index := 0;
                           New_Then   : Node_Index := 0;
                           Wrap       : Node_Index := 0;
                        begin
                           Else_Line := Tokens(State.Current_Token).Line;
                           State.Current_Token := State.Current_Token + 1;
                           Allocate_Node(Tokens, State, Tree, AST_Block_Stmt, Wrap, Success);
                           if not Success then return; end if;
                           Tree(Inner_Then).Next_Sibling := Wrap;
                           if Else_Block = 0 then
                              Else_Block := Wrap;  --  marks "inside else chain"
                           end if;
                           Allocate_Node(Tokens, State, Tree, AST_If_Stmt, Nested_If, Success);
                           if not Success then return; end if;
                           Tree(Nested_If).Token_Index := Elseif_Tok;
                           Tree(Wrap).Left_Child := Nested_If;
                           Parse_Expression(Tokens, State, Tree, Cond_Node, Success);
                           if not Success then return; end if;
                           Tree(Nested_If).Left_Child := Cond_Node;
                           if State.Current_Token <= Max_Tokens
                             and then Tokens(State.Current_Token).Kind = Tok_Then
                           then
                              State.Current_Token := State.Current_Token + 1;
                           else
                              Log_Warning(State, Tokens, Err_Parse_Missing_Then);
                           end if;
                           Allocate_Node(Tokens, State, Tree, AST_Block_Stmt, New_Then, Success);
                           if not Success then return; end if;
                           Tree(Nested_If).Right_Child := New_Then;
                           Inner_Then := New_Then;
                           Active_Block := New_Then;
                           First_Stmt := 0;
                           Curr_Stmt := 0;
                           Else_Is_Inline := State.Current_Token <= Max_Tokens
                             and then Tokens(State.Current_Token).Line = Else_Line;
                        end;
                     elsif Tokens(State.Current_Token).Kind = Tok_Else then
                        Else_Line := Tokens(State.Current_Token).Line;
                        State.Current_Token := State.Current_Token + 1; -- Consume ELSE

                        --  Always allocate a fresh else-block linked from the
                        --  innermost then — after ELSEIFs, Else_Block already
                        --  holds an earlier wrap and can't be reused.
                        declare
                           New_Else : Node_Index := 0;
                        begin
                           Allocate_Node(Tokens, State, Tree, AST_Block_Stmt, New_Else, Success);
                           if not Success then return; end if;
                           Tree(Inner_Then).Next_Sibling := New_Else;
                           if Else_Block = 0 then
                              Else_Block := New_Else;
                           end if;
                           Active_Block := New_Else;
                        end;

                        First_Stmt := 0;
                        Curr_Stmt := 0;
                        Else_Is_Inline := State.Current_Token <= Max_Tokens
                          and then Tokens(State.Current_Token).Line = Else_Line;

                     else
                        -- If we are not inside an Else_Block and we encounter a statement
                        -- that is not ELSE or END IF, the single-line IF is finished!
                        if Else_Block = 0 then
                           Success := True;
                           return;
                        end if;

                        -- A same-line ELSE only auto-terminates if it actually
                        -- started an inline branch on that line.
                        if Else_Is_Inline
                          and then Tokens(State.Current_Token).Line /= Else_Line
                        then
                           Success := True;
                           return;
                        end if;

                        Parse_Statement(Tokens, State, Tree, Next_Stmt, Success);
                        if not Success then return; end if;

                        if Next_Stmt = 0 then
                           Set_Error(State, Tokens, Err_Parse_Expected_Value);
                           Success := False;
                           return;
                        elsif Tree(Active_Block).Left_Child = 0 then
                           Tree(Active_Block).Left_Child := Next_Stmt;
                        else
                           Tree(Curr_Stmt).Next_Sibling := Next_Stmt;
                        end if;

                        Curr_Stmt := Next_Stmt;
                     end if;
                  end loop;

                  Set_Error(State, Tokens, Err_Parse_Block_Overflow);
                  Success := False;
               end;
               
            else
               -- ==========================================
               -- MULTI-LINE BLOCK IF (With ELSE/ELSEIF support)
               -- ==========================================
               declare 
                  Body_Node, Else_Node, Active_Block, First_Stmt, Curr_Stmt, Next_Stmt : Node_Index := 0;
                  Inner_Then : Node_Index := 0;  --  innermost then-block for ELSEIF chains
               begin
                  Allocate_Node(Tokens, State, Tree, AST_Block_Stmt, Body_Node, Success);
                  if not Success then return; end if;
                  Tree(Node).Right_Child := Body_Node;
                  Active_Block := Body_Node;
                  Inner_Then := Body_Node;

                  for I in 1 .. 16384 loop
                     -- Titanium EOF Guard for missing END IF
                     if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind = Tok_Error then
                        Set_Error(State, Tokens, Err_Parse_Expected_Value);
                        Success := False; 
                        return;
                     end if;
                     
                     if Is_Bare_End (Tokens, State)
                       or else Same_Line_End_Tag (Tokens, State, Tok_If)
                     then
                        declare
                           End_Line : constant Positive := Tokens (State.Current_Token).Line;
                        begin
                           State.Current_Token := State.Current_Token + 1; -- Consume END
                           if State.Current_Token <= Max_Tokens
                             and then Tokens (State.Current_Token).Kind = Tok_If
                             and then Tokens (State.Current_Token).Line = End_Line
                           then
                              State.Current_Token := State.Current_Token + 1;
                           end if;
                           Success := True; 
                           return; -- Successful exit!
                        end;
                        
                     elsif Tokens(State.Current_Token).Kind = Tok_Elseif then
                        --  ELSEIF cond THEN: the else-block holds a nested
                        --  AST_If_Stmt, so one END IF closes the whole chain.
                        declare
                           Elseif_Tok  : constant Natural := State.Current_Token;
                           Nested_If   : Node_Index := 0;
                           Cond_Node   : Node_Index := 0;
                           New_Then    : Node_Index := 0;
                        begin
                           State.Current_Token := State.Current_Token + 1;
                           Allocate_Node(Tokens, State, Tree, AST_Block_Stmt, Else_Node, Success);
                           if not Success then return; end if;
                           Tree(Inner_Then).Next_Sibling := Else_Node;
                           Allocate_Node(Tokens, State, Tree, AST_If_Stmt, Nested_If, Success);
                           if not Success then return; end if;
                           Tree(Nested_If).Token_Index := Elseif_Tok;
                           Tree(Else_Node).Left_Child := Nested_If;
                           Parse_Expression(Tokens, State, Tree, Cond_Node, Success);
                           if not Success then return; end if;
                           Tree(Nested_If).Left_Child := Cond_Node;
                           if State.Current_Token <= Max_Tokens
                             and then Tokens(State.Current_Token).Kind = Tok_Then
                           then
                              State.Current_Token := State.Current_Token + 1;
                           else
                              Log_Warning(State, Tokens, Err_Parse_Missing_Then);
                           end if;
                           Allocate_Node(Tokens, State, Tree, AST_Block_Stmt, New_Then, Success);
                           if not Success then return; end if;
                           Tree(Nested_If).Right_Child := New_Then;
                           Inner_Then := New_Then;
                           Active_Block := New_Then;
                           First_Stmt := 0;
                           Curr_Stmt := 0;
                        end;
                     elsif Tokens(State.Current_Token).Kind = Tok_Else then
                        State.Current_Token := State.Current_Token + 1; -- Consume ELSE
                        Allocate_Node(Tokens, State, Tree, AST_Block_Stmt, Else_Node, Success);
                        if not Success then return; end if;

                        -- Store the Else block as the Sibling of the innermost Then block!
                        Tree(Inner_Then).Next_Sibling := Else_Node;
                        Active_Block := Else_Node;

                        -- Reset internal pointers for the new block!
                        First_Stmt := 0;
                        Curr_Stmt := 0;
                     else
                        Parse_Statement(Tokens, State, Tree, Next_Stmt, Success);
                        if not Success then return; end if;
                        
                        if Next_Stmt = 0 then
                           Set_Error(State, Tokens, Err_Parse_Expected_Value);
                           Success := False;
                           return;
                        elsif First_Stmt = 0 then 
                           First_Stmt := Next_Stmt;
                           Tree(Active_Block).Left_Child := First_Stmt;
                        else 
                           Tree(Curr_Stmt).Next_Sibling := Next_Stmt;
                        end if;
                        Curr_Stmt := Next_Stmt;
                     end if;
                  end loop;
                  
                  -- If we hit the 16k statement limit without finding END IF
                  Set_Error(State, Tokens, Err_Parse_Block_Overflow);
                  Success := False;
               end;
            end if;
         end;
      
      -- =====================================================================
      -- DA FOR LOOP FORGE (FOR i = 0 TO 10 THEN ...)
      -- =====================================================================
      elsif T.Kind = Tok_For then
         Allocate_Node(Tokens, State, Tree, AST_For_Stmt, Node, Success);
         if not Success then return; end if;
         
         State.Current_Token := State.Current_Token + 1; -- Consume FOR
         
         -- 1. Guard: Expect Loop Variable
         if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind not in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States then
            Set_Error(State, Tokens, Err_Parse_Expected_Value); 
            Success := False; 
            return; 
         end if;
         
         -- We store the loop variable's token directly on the FOR node! Very efficient!
         Tree(Node).Token_Index := State.Current_Token; 
         State.Current_Token := State.Current_Token + 1;
         
         -- 2. Guard: Expect '='
         if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_Assign then
            Set_Error(State, Tokens, Err_Parse_Missing_Assign); 
            Success := False; 
            return; 
         end if;
         State.Current_Token := State.Current_Token + 1;
         
         declare 
            Start_Expr, End_Expr, Dummy : Node_Index; 
         begin
            -- 3. Parse Start Value
            Parse_Expression(Tokens, State, Tree, Start_Expr, Success);
            if not Success then return; end if;
            
            -- 4. Guard: Expect 'TO'
            if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_To then
               Set_Error(State, Tokens, Err_Parse_Missing_To); 
               Success := False; 
               return; 
            end if;
            State.Current_Token := State.Current_Token + 1;
            
            -- 5. Parse End Value
            Parse_Expression(Tokens, State, Tree, End_Expr, Success);
            if not Success then return; end if;
            -- DA NEW STEP FORGE
            declare 
               Step_Expr : Node_Index := 0;
            begin
               if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Step then
                  State.Current_Token := State.Current_Token + 1; -- Consume STEP
                  Parse_Expression(Tokens, State, Tree, Step_Expr, Success);
                  if not Success then return; end if;
               end if;

               -- 6. Bind to Dummy Container Node
               Allocate_Node(Tokens, State, Tree, AST_Null, Dummy, Success);
               if not Success then return; end if;
               
               Tree(Dummy).Left_Child := Start_Expr;
               
               if Step_Expr /= 0 then
                  -- If we hae a STEP, we pack End and Step inside an Arg_List!
                  declare
                     List_Node : Node_Index;
                  begin
                     Allocate_Node(Tokens, State, Tree, AST_Arg_List, List_Node, Success);
                     if not Success then return; end if;
                     Tree(List_Node).Left_Child := End_Expr;
                     Tree(End_Expr).Next_Sibling := Step_Expr;
                     Tree(Dummy).Right_Child := List_Node;
                  end;
               else
                  -- Standard FOR loop without STEP
                  Tree(Dummy).Right_Child := End_Expr; 
               end if;
               
               Tree(Node).Left_Child := Dummy;
            end;
         end;
         
         -- 7. DA GHOST TOKEN FORGE: Expect THEN (or implicitly insert it!)
         declare 
            Then_Line : Positive;
            Header_Line : Positive;
         begin
            if State.Current_Token > 1 then
               Header_Line := Tokens(State.Current_Token - 1).Line;
            else
               Header_Line := 1;
            end if;
            if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind /= Tok_Then then
               -- `FOR ... TO n` ending its own line is the canonical
               -- multi-line form — implicit THEN, no warning.  Warn only
               -- when a statement follows the header on the SAME line
               -- without THEN (`FOR i=0 TO 5 PRINT i`), where the ghost
               -- THEN is doing real disambiguation work.
               if State.Current_Token <= Max_Tokens
                 and then Tokens(State.Current_Token).Line = Header_Line
               then
                  Log_Warning(State, Tokens, Err_Parse_Missing_Then);
               end if;
               Then_Line := Header_Line;
            else
               Then_Line := Tokens(State.Current_Token).Line;
               State.Current_Token := State.Current_Token + 1; -- Consume THEN
            end if;
            
            -- DA HYBRID RULE: Single vs Multi-Line detection!
            if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Line = Then_Line then
               
               -- ==========================================
               -- SINGLE LINE FOR
               -- ==========================================
               declare 
                  Stmt_Node : Node_Index;
               begin
                  Parse_Statement(Tokens, State, Tree, Stmt_Node, Success);
                  if Success then Tree(Node).Right_Child := Stmt_Node; end if;

                  -- DA FIX: Consume optional END FOR
                  if State.Current_Token + 1 <= Max_Tokens 
                     and then Tokens(State.Current_Token).Kind = Tok_End 
                     and then Tokens(State.Current_Token + 1).Kind = Tok_For 
                  then
                     State.Current_Token := State.Current_Token + 2;
                  end if;
               end;
               
            else
               -- ==========================================
               -- MULTI-LINE BLOCK FOR
               -- ==========================================
               declare 
                  Body_Node, First_Stmt, Curr_Stmt, Next_Stmt : Node_Index := 0; 
               begin
                  Allocate_Node(Tokens, State, Tree, AST_Block_Stmt, Body_Node, Success);
                  if not Success then return; end if;
                  Tree(Node).Right_Child := Body_Node;
                  
                  for I in 1 .. 16384 loop
                     -- DA FIX: Titanium EOF Guard for missing END FOR
                     if State.Current_Token > Max_Tokens or else Tokens(State.Current_Token).Kind = Tok_Error then
                        Set_Error(State, Tokens, Err_Parse_Expected_Value); 
                        Success := False; 
                        return;
                     end if;
                     
                     -- Check for Terminator
                     if Is_Bare_End (Tokens, State)
                       or else Same_Line_End_Tag (Tokens, State, Tok_For)
                     then
                        declare
                           End_Line : Positive := Tokens(State.Current_Token).Line;
                        begin
                           State.Current_Token := State.Current_Token + 1;
                           -- MUST check for Tok_For here!
                           if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_For
                              and then Tokens(State.Current_Token).Line = End_Line
                           then
                              State.Current_Token := State.Current_Token + 1;
                           end if;
                           Success := True;
                           return; -- Clean exit
                        end;
                     end if;
                     
                     Parse_Statement(Tokens, State, Tree, Next_Stmt, Success);
                     if not Success then return; end if;
                     
                     if First_Stmt = 0 then 
                        First_Stmt := Next_Stmt; 
                        Tree(Body_Node).Left_Child := First_Stmt;
                     else 
                        Tree(Curr_Stmt).Next_Sibling := Next_Stmt; 
                     end if;
                     Curr_Stmt := Next_Stmt;
                  end loop;
                  
                  -- DA FIX: True Block Overflow Trap! (Missing in original)
                  Set_Error(State, Tokens, Err_Parse_Block_Overflow); 
                  Success := False;
               end;
            end if;
         end;
      
         
      -- =====================================================================
      -- DA FOREACH LOOP (FOREACH item IN vault THEN ... END FOREACH)
      -- =====================================================================
      --  elsif T.Kind = Tok_Foreach then
      --     declare
      --        Iterator_Tok : Natural;
      --        Array_Node   : Node_Index;
      --        Block_Node   : Node_Index := 0;
      --        Current_Stmt : Node_Index;
      --        Last_Stmt    : Node_Index := 0;
      --     begin
      --        State.Current_Token := State.Current_Token + 1; -- Consume 'FOREACH'
      --  
      --        -- 1. Grab da Iterator Variable
      --        if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States then
      --           Iterator_Tok := State.Current_Token;
      --           State.Current_Token := State.Current_Token + 1;
      --        else
      --           Set_Error(State, Tokens, Err_Parse_Expected_Value);
      --           Success := False; return;
      --        end if;
      --  
      --        -- 2. Consume 'IN'
      --        if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_In then
      --           State.Current_Token := State.Current_Token + 1;
      --        else
      --           Set_Error(State, Tokens, Err_Parse_Expected_Value);
      --           Success := False; return;
      --        end if;
      --  
      --        -- 3. Grab da Array Target (Use Parse_Primary tae get da Var Node)
      --        Parse_Primary(Tokens, State, Tree, Array_Node, Success);
      --        if not Success then return; end if;
      --  
      --        -- 4. Consume 'THEN'
      --        if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Then then
      --           State.Current_Token := State.Current_Token + 1;
      --        else
      --           Set_Error(State, Tokens, Err_Parse_Expected_Value);
      --           Success := False; return;
      --        end if;
      --  
      --        -- 5. Allocate da AST Node
      --        Allocate_Node(Tokens, State, Tree, AST_Foreach_Stmt, Node, Success);
      --        if not Success then return; end if;
      --        Tree(Node).Token_Index := Iterator_Tok;
      --        Tree(Node).Left_Child  := Array_Node;
      --  
      --        -- 6. Parse da Block until 'END FOREACH'
      --        while State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind /= Tok_End loop
      --           Parse_Statement(Tokens, State, Tree, Current_Stmt, Success);
      --           if not Success then return; end if;
      --  
      --           if Block_Node = 0 then
      --              Block_Node := Current_Stmt;
      --              Last_Stmt  := Current_Stmt;
      --           else
      --              Tree(Last_Stmt).Next_Sibling := Current_Stmt;
      --              Last_Stmt := Current_Stmt;
      --           end if;
      --        end loop;
      --  
      --        Tree(Node).Right_Child := Block_Node;
      --  
      --        -- 7. Consume 'END FOREACH'
      --        if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_End then
      --           State.Current_Token := State.Current_Token + 1;
      --  
      --           if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Foreach then
      --              State.Current_Token := State.Current_Token + 1;
      --           else
      --              Set_Error(State, Tokens, Err_Parse_Expected_Value);
      --              Success := False; return;
      --           end if;
      --        else
      --           Set_Error(State, Tokens, Err_Parse_Expected_Value);
      --           Success := False; return;
      --        end if;
      --  
      --        Success := True;
      --     end;
      
      elsif T.Kind = Tok_Foreach then
         declare
            Iterator_Tok : Natural;
            Array_Node   : Node_Index;
            Block_Node   : Node_Index := 0;
            Current_Stmt : Node_Index := 0;
            Last_Stmt    : Node_Index := 0;
         begin
            State.Current_Token := State.Current_Token + 1; -- Consume 'FOREACH'
            
            if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States then
               Iterator_Tok := State.Current_Token;
               State.Current_Token := State.Current_Token + 1;
            else
               Set_Error(State, Tokens, Err_Parse_Expected_Value);
               Success := False; return;
            end if;
            
            if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_In then
               State.Current_Token := State.Current_Token + 1;
            else
               Set_Error(State, Tokens, Err_Parse_Expected_Value);
               Success := False; return;
            end if;
            
            Parse_Primary(Tokens, State, Tree, Array_Node, Success);
            if not Success then return; end if;
            
            if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Then then
               State.Current_Token := State.Current_Token + 1;
            else
               Log_Warning(State, Tokens, Err_Parse_Missing_Then);
            end if;
            
            Allocate_Node(Tokens, State, Tree, AST_Foreach_Stmt, Node, Success);
            if not Success then return; end if;
            Tree(Node).Token_Index := Iterator_Tok;
            Tree(Node).Left_Child  := Array_Node;

            Allocate_Node(Tokens, State, Tree, AST_Block_Stmt, Block_Node, Success);
            if not Success then return; end if;
            Tree(Node).Right_Child := Block_Node;
            
            while State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind /= Tok_End loop
               Parse_Statement(Tokens, State, Tree, Current_Stmt, Success);
               if not Success then return; end if;
               
               if Current_Stmt /= 0 then
                  if Tree(Block_Node).Left_Child = 0 then
                     Tree(Block_Node).Left_Child := Current_Stmt;
                  else
                     Tree(Last_Stmt).Next_Sibling := Current_Stmt;
                  end if;
                  Last_Stmt := Current_Stmt;
               end if;
            end loop;
            
            if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_End then
               declare
                  End_Line : constant Positive := Tokens (State.Current_Token).Line;
               begin
                  State.Current_Token := State.Current_Token + 1;

                  if State.Current_Token <= Max_Tokens
                    and then Tokens(State.Current_Token).Kind = Tok_Foreach
                    and then Tokens(State.Current_Token).Line = End_Line
                  then
                     State.Current_Token := State.Current_Token + 1;
                  end if;
               end;
            else
               Set_Error(State, Tokens, Err_Parse_Expected_Value);
               Success := False; return;
            end if;
            
            Success := True;
         end;

         
         
      --  -- =====================================================================
      --  -- DA PROLOG QUERY FORGE (?- predicate(X), predicate(Y))
      --  -- =====================================================================
      --  elsif T.Kind = Tok_Query then
      --     Allocate_Node(Tokens, State, Tree, AST_Query, Node, Success);
      --     if not Success then return; end if;
      --     Tree(Node).Token_Index := State.Current_Token;
      --     State.Current_Token := State.Current_Token + 1; -- Consume '?-'
      --  
      --     declare
      --        Last_Pred : Node_Index := 0;
      --     begin
      --        for I in 1 .. 64 loop -- DA FIX: Expanded tae 64 tae match the rest o' the engine!
      --           Parse_Predicate(Tokens, State, Tree, Pred_Node, Success);
      --           if not Success then
      --              Set_Error(State, Tokens, Err_Parse_Expected_Value);
      --              return;
      --           end if;
      --  
      --           if Last_Pred = 0 then
      --              Tree(Node).Left_Child := Pred_Node;
      --           else
      --              Tree(Last_Pred).Next_Sibling := Pred_Node;
      --           end if;
      --           Last_Pred := Pred_Node;
      --  
      --           -- Check whit comes neist: A comma means mair predicates, a dot means stop!
      --           if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Comma then
      --              State.Current_Token := State.Current_Token + 1; -- Consume ',' and keep loopin'
      --           elsif State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_Dot then
      --              State.Current_Token := State.Current_Token + 1; -- Consume '.' and finish
      --              exit;
      --           else
      --              -- Inline queries (lik' in an IF) micht not hae a dot, sae we just exit cleanly.
      --              exit;
      --           end if;
      --        end loop;
      --     end;
      
      -- =====================================================================
      -- DA LOGIC SUGAR: PROVE() and ?- Queries! (Expression Level)
      -- =====================================================================
      elsif T.Kind in Tok_Query | Tok_Prove then
         State.Current_Token := State.Current_Token + 1; -- Consume '?-' or 'PROVE'
         
         declare
            Has_Outer_Paren : Boolean := False;
            Expr_Node       : Node_Index := 0;
         begin
            -- Handle optional outer parens for PROVE(Predicate)
            if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_L_Paren then
               Has_Outer_Paren := True;
               State.Current_Token := State.Current_Token + 1;
            end if;
            
            Allocate_Node(Tokens, State, Tree, AST_Find_Query, Node, Success);
            if not Success then return; end if;
            
            -- 1. Grab the Predicate Name
            if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind in Tok_Logic_Var | Tok_Atom | Tok_Mode | Tok_Spacing | Tok_Width | Tok_Height | Tok_Frames | Tok_Frame | Tok_Source | Tok_Format | Tok_Weight | Tok_Buffer_Size | Tok_Size | Tok_Layer | Tok_Epochs | Tok_Bounds | Tok_States then
               Tree(Node).Token_Index := State.Current_Token;
               State.Current_Token := State.Current_Token + 1;
            else
               Set_Error(State, Tokens, Err_Parse_Expected_Value);
               Success := False; return;
            end if;
            
            -- 2. Optional: Check for Argument (e.g., is_valid(1))
            if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_L_Paren then
               State.Current_Token := State.Current_Token + 1;
               Parse_Expression(Tokens, State, Tree, Expr_Node, Success);
               if not Success then return; end if;
               Tree(Node).Left_Child := Expr_Node;
               
               if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_R_Paren then
                  State.Current_Token := State.Current_Token + 1;
               else
                  Set_Error(State, Tokens, Err_Parse_Expected_Value);
                  Success := False; return;
               end if;
            end if;
            
            -- Close outer paren if we had one!
            if Has_Outer_Paren then
               if State.Current_Token <= Max_Tokens and then Tokens(State.Current_Token).Kind = Tok_R_Paren then
                  State.Current_Token := State.Current_Token + 1;
               else
                  Set_Error(State, Tokens, Err_Parse_Expected_Value);
                  Success := False; return;
               end if;
            end if;
         end;
         Success := True;
         return; -- Fast exit frae Parse_Primary!
                 
      --  -- =========================================================
      --  -- DA PHANTOM ERROR TRAP
      --  -- =========================================================
      --  else
      --     Set_Error(State, Tokens, Err_Parse_Expected_Value);
      --     Success := False;
      --     return; -- DA FIX: Explicit return tae match the rest o' the flatline design
      --  end if;
      -- =========================================================
      -- DA PHANTOM ERROR TRAP
      -- =========================================================
      else
         -- DA FIX: The Interface Auto-Closer in Function/Procedure leaves 
         -- the ENDMODULE token on the tape. If we hit it here, we just 
         -- return a Success but with a Node of 0 (a No-Op), sae the 
         -- Module loop can catch it on its neist spin!
         if T.Kind = Tok_EndModule then
            Node := 0;
            Success := True;
            return;
         end if;
         
         Set_Error(State, Tokens, Err_Parse_Expected_Value);
         Success := False;
         return; 
      end if;
   end Parse_Statement;

   -- =========================================================================
   -- DA MASTER ENTRY POINT
   -- =========================================================================
   procedure Parse (Tokens : in Token_Array; Token_Count : in Natural; Tree : out Node_Array; Root : out Node_Index; Success : out Boolean; Diagnostic : out Parser_Diagnostic) is
      State : Parser_State;
      Current : Node_Index := 0; 
      Last_Top_Stmt : Node_Index := 0; 
      RS_Stat : Boolean; 
      Ival : RS_Interval;
   begin
      Root := 0;
      
      -- Only zero whit we'll actually use (Token_Count is a grand upper bound estimate)
      --for I in 1 .. Token_Count loop
      --   Tree(I) := (Kind => AST_Null, Token_Index => 0, Left_Child => 0, Right_Child => 0, Next_Sibling => 0);
      --end loop;
      Success := True;

      for I in 1 .. Max_Tokens loop
         exit when State.Current_Token > Token_Count or not Success;
         
         -- NASA/JPL Compliant Range Spec validation!
         Create(1.0, Long_Float(Max_Tokens), Ival, RS_Stat);
         pragma Assert (RS_Stat and then Contains(Ival, Long_Float(State.Current_Token)));

         Parse_Statement(Tokens, State, Tree, Current, Success);
         if Success then
            if Root = 0 then 
               Root := Current;
               Last_Top_Stmt := Current;
            else 
               Tree(Last_Top_Stmt).Next_Sibling := Current; 
               Last_Top_Stmt := Current; 
            end if;
         end if;
      end loop;
      
      Diagnostic := State.Diag;
   end Parse;

end Parser;


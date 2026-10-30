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
with Tokenizer; use Tokenizer;
with AST;       use AST;
with ALB_Oracle; use ALB_Oracle;

package Parser is
   -- The public parser entry point stays flat even as new parser-only
   -- surface syntax (such as sandbox/firewall declarations) is added.
   
   type Error_Severity is (Warning, Fatal);

   type Error_Record is record
      Line     : Positive := 1;
      Col      : Positive := 1;
      Code     : Oracle_Code := Err_None;
      Severity : Error_Severity := Fatal;
   end record;

  
   Max_Errors : constant := 50;
   type Error_Array is array (1 .. Max_Errors) of Error_Record;

   type Parser_Diagnostic is record
      Success     : Boolean := True;
      Error_Count : Natural := 0;
      Errors      : Error_Array := (others => (Line => 1, Col => 1, Code => Err_None, Severity => Fatal));
      Error_Line  : Positive := 1;
      Error_Col   : Positive := 1;
      Code        : Oracle_Code := Err_None;
   end record;

   type Parser_State is record
      Current_Token : Positive := 1;
      Last_Node     : Node_Index := 0; 
      Stop_At_Stream_Shl : Boolean := False;
      Diag          : Parser_Diagnostic; -- DA FIX: Let the record's internal defaults take over!
   end record;

   procedure Parse (Tokens      : in Token_Array;
                    Token_Count : in Natural;
                    Tree        : out Node_Array;
                    Root        : out Node_Index;
                    Success     : out Boolean;
                    Diagnostic  : out Parser_Diagnostic)
     with 
       Pre  => Token_Count <= Max_Tokens,
       Post => (if Success then Root > 0 else Root = 0);

end Parser;

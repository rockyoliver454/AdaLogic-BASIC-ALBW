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

pragma Ada_2012;

package Float_Expr
  with SPARK_Mode => On
is
   ----------------------------------------------------------------------------
   --  Configuration
   ----------------------------------------------------------------------------
   subtype Real is Float;

   Max_Nodes    : constant Positive := 1024;
   Max_Symbols  : constant Positive := 32;
   Max_Name_Len : constant Positive := 16;

   Max_Parse_Ops  : constant Positive := 128;
   Max_Parse_Out  : constant Positive := 256;
   Max_Parse_Expr : constant Positive := 128;

   ----------------------------------------------------------------------------
   --  Status / Error model
   ----------------------------------------------------------------------------
   type Status_Code is
     (Ok,
      Pool_Full,
      Invalid_Expr,

      Division_By_Zero,
      Domain_Error,
      Numeric_Overflow,

      Parse_Error,
      Token_Overflow,

      Non_Smooth);

   ----------------------------------------------------------------------------
   --  Identifiers / Handles
   ----------------------------------------------------------------------------
   type Node_Id is range 0 .. Max_Nodes;
   Null_Node : constant Node_Id := Node_Id'First;

   type Var_Id is range 1 .. Max_Symbols;

   type Expr is record
      Root : Node_Id := Null_Node;
   end record;

   type Var_Values is array (Var_Id) of Real;

   ----------------------------------------------------------------------------
   --  Fixed-size symbol names
   ----------------------------------------------------------------------------
   type Name is record
      Len  : Natural range 0 .. Max_Name_Len := 0;
      Data : String (1 .. Max_Name_Len) := (others => ' ');
   end record;

   function Name_Equals (A : Name; B : String) return Boolean
     with Pre => B'Length <= Max_Name_Len;

   ----------------------------------------------------------------------------
   --  Operators
   ----------------------------------------------------------------------------
   type Unary_Op is (Neg, Sin, Cos, Tan, Exp, Log, Sqrt, Abs_Op, Sign);
   type Binary_Op is (Add, Sub, Mul, Div, Pow);

   ----------------------------------------------------------------------------
   --  Builder / Arena
   ----------------------------------------------------------------------------
   type Builder is private;

   procedure Reset (B : in out Builder);

   function Nodes_Used   (B : Builder) return Natural;
   function Symbols_Used (B : Builder) return Natural;

   procedure Define_Symbol
     (B      : in out Builder;
      S      : String;
      Id     : out Var_Id;
      Status : out Status_Code)
     with Pre => S'Length > 0 and then S'Length <= Max_Name_Len;

   procedure Lookup_Symbol
     (B      : Builder;
      S      : String;
      Found  : out Boolean;
      Id     : out Var_Id)
     with Pre => S'Length > 0 and then S'Length <= Max_Name_Len;

   ----------------------------------------------------------------------------
   --  Constructors (allocate nodes in Builder)
   ----------------------------------------------------------------------------
   procedure Make_Const
     (B      : in out Builder;
      V      : Real;
      E      : out Expr;
      Status : out Status_Code);

   procedure Make_Var
     (B      : in out Builder;
      Id     : Var_Id;
      E      : out Expr;
      Status : out Status_Code);

   procedure Make_Var_Name
     (B      : in out Builder;
      S      : String;
      E      : out Expr;
      Id     : out Var_Id;
      Status : out Status_Code)
     with Pre => S'Length > 0 and then S'Length <= Max_Name_Len;

   procedure Make_Unary
     (B      : in out Builder;
      Op     : Unary_Op;
      A      : Expr;
      E      : out Expr;
      Status : out Status_Code);

   procedure Make_Binary
     (B      : in out Builder;
      Op     : Binary_Op;
      L, R   : Expr;
      E      : out Expr;
      Status : out Status_Code);

   ----------------------------------------------------------------------------
   --  Evaluation (non-recursive)
   ----------------------------------------------------------------------------
   procedure Evaluate
     (B      : Builder;
      E      : Expr;
      Env    : Var_Values;
      Value  : out Real;
      Status : out Status_Code);

   ----------------------------------------------------------------------------
   --  Transformations (non-recursive) to a destination builder
   ----------------------------------------------------------------------------
   procedure Copy_To
     (Src_B  : Builder;
      Src_E  : Expr;
      Dst_B  : in out Builder;
      Dst_E  : out Expr;
      Status : out Status_Code);

   procedure Simplify_To
     (Src_B  : Builder;
      Src_E  : Expr;
      Dst_B  : in out Builder;
      Dst_E  : out Expr;
      Status : out Status_Code);

   procedure Differentiate_To
     (Src_B           : Builder;
      Src_E           : Expr;
      With_Respect_To : Var_Id;
      Dst_B           : in out Builder;
      Dst_E           : out Expr;
      Status          : out Status_Code);

   ----------------------------------------------------------------------------
   --  Parsing (bounded infix grammar)
   ----------------------------------------------------------------------------
   procedure Parse_Infix
     (B      : in out Builder;
      Text   : String;
      E      : out Expr;
      Status : out Status_Code);

private
   ----------------------------------------------------------------------------
   --  Node representation
   ----------------------------------------------------------------------------
   type Node_Kind is (K_Const, K_Var, K_Unary, K_Binary);

   type Node (Kind : Node_Kind := K_Const) is record
      case Kind is
         when K_Const =>
            C : Real := 0.0;

         when K_Var =>
            V : Var_Id := Var_Id'First;

         when K_Unary =>
            U_Op : Unary_Op := Neg;
            A    : Node_Id  := Null_Node;

         when K_Binary =>
            B_Op : Binary_Op := Add;
            L    : Node_Id   := Null_Node;
            R    : Node_Id   := Null_Node;
      end case;
   end record;

   First_Node : constant Node_Id := Node_Id'Succ(Null_Node);

   type Node_Array   is array (First_Node .. Node_Id(Max_Nodes)) of Node;
   type Symbol_Array is array (Var_Id) of Name;

   type Builder is record
      Nodes     : Node_Array;
      Used      : Natural range 0 .. Max_Nodes := 0;

      Symbols   : Symbol_Array;
      Sym_Used  : Natural range 0 .. Max_Symbols := 0;
   end record;

end Float_Expr;

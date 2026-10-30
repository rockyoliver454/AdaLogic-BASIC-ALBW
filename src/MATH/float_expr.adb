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

with Ada.Numerics;
with Ada.Numerics.Elementary_Functions;

package body Float_Expr
  with SPARK_Mode => On
is
   use Ada.Numerics;
   package EF renames Ada.Numerics.Elementary_Functions;

   ----------------------------------------------------------------------------
   --  Local numeric policy
   ----------------------------------------------------------------------------
   Eval_Zero_Eps : constant Real := 1.0E-6;

   -- Deterministic "e"
   E_Const : constant Real := 2.71828182845904523536;

   function AbsF (X : Real) return Real is
   begin
      if X < 0.0 then return -X; else return X; end if;
   end AbsF;

   function AbsI (X : Integer) return Integer is
   begin
      if X < 0 then
         if X = Integer'First then
            return Integer'Last; -- saturate
         else
            return -X;
         end if;
      else
         return X;
      end if;
   end AbsI;

   function Is_Finite (X : Real) return Boolean is
   begin
      return (X = X) and then (X <= Real'Last) and then (X >= Real'First);
   end Is_Finite;

   ----------------------------------------------------------------------------
   --  Names
   ----------------------------------------------------------------------------
   function Make_Name (S : String) return Name is
      N : Name;
      L : constant Natural := S'Length;
   begin
      N.Len := (if L > Max_Name_Len then Max_Name_Len else L);
      for I in 1 .. N.Len loop
         N.Data(I) := S(S'First + (I - 1));
      end loop;
      return N;
   end Make_Name;

   function Name_Equals (A : Name; B : String) return Boolean is
      L : constant Natural := B'Length;
   begin
      if A.Len /= L then
         return False;
      end if;

      for I in 1 .. L loop
         if A.Data(I) /= B(B'First + (I - 1)) then
            return False;
         end if;
      end loop;

      return True;
   end Name_Equals;

   ----------------------------------------------------------------------------
   --  Builder basics
   ----------------------------------------------------------------------------
   procedure Reset (B : in out Builder) is
   begin
      B.Used     := 0;
      B.Sym_Used := 0;
   end Reset;

   function Nodes_Used (B : Builder) return Natural is
   begin
      return B.Used;
   end Nodes_Used;

   function Symbols_Used (B : Builder) return Natural is
   begin
      return B.Sym_Used;
   end Symbols_Used;

   procedure Lookup_Symbol
     (B      : Builder;
      S      : String;
      Found  : out Boolean;
      Id     : out Var_Id)
   is
      I : Natural := 1;
   begin
      Found := False;
      Id := Var_Id'First;

      while I <= B.Sym_Used loop
         declare
            Vid : constant Var_Id := Var_Id(I);
         begin
            if Name_Equals(B.Symbols(Vid), S) then
               Found := True;
               Id := Vid;
               return;
            end if;
         end;
         I := I + 1;
      end loop;
   end Lookup_Symbol;

   procedure Define_Symbol
     (B      : in out Builder;
      S      : String;
      Id     : out Var_Id;
      Status : out Status_Code)
   is
      Found : Boolean;
      X     : Var_Id;
   begin
      Status := Ok;

      Lookup_Symbol(B, S, Found, X);
      if Found then
         Id := X;
         return;
      end if;

      if B.Sym_Used = Max_Symbols then
         Status := Pool_Full;
         Id := Var_Id'First;
         return;
      end if;

      B.Sym_Used := B.Sym_Used + 1;
      Id := Var_Id(B.Sym_Used);
      B.Symbols(Id) := Make_Name(S);
   end Define_Symbol;

   ----------------------------------------------------------------------------
   --  Node allocation
   ----------------------------------------------------------------------------
   procedure New_Node
     (B      : in out Builder;
      N      : Node;
      Id     : out Node_Id;
      Status : out Status_Code)
   is
   begin
      if B.Used = Max_Nodes then
         Status := Pool_Full;
         Id := Null_Node;
         return;
      end if;

      B.Used := B.Used + 1;
      Id := Node_Id(B.Used);
      B.Nodes(Id) := N;

      Status := Ok;
   end New_Node;

   procedure Make_Const
     (B      : in out Builder;
      V      : Real;
      E      : out Expr;
      Status : out Status_Code)
   is
      Nid : Node_Id;
   begin
      New_Node(B, (Kind => K_Const, C => V), Nid, Status);
      E := (Root => Nid);
   end Make_Const;

   procedure Make_Var
     (B      : in out Builder;
      Id     : Var_Id;
      E      : out Expr;
      Status : out Status_Code)
   is
      Nid : Node_Id;
   begin
      New_Node(B, (Kind => K_Var, V => Id), Nid, Status);
      E := (Root => Nid);
   end Make_Var;

   procedure Make_Var_Name
     (B      : in out Builder;
      S      : String;
      E      : out Expr;
      Id     : out Var_Id;
      Status : out Status_Code)
   is
   begin
      Define_Symbol(B, S, Id, Status);
      if Status /= Ok then
         E := (Root => Null_Node);
         return;
      end if;

      Make_Var(B, Id, E, Status);
   end Make_Var_Name;

   procedure Make_Unary
     (B      : in out Builder;
      Op     : Unary_Op;
      A      : Expr;
      E      : out Expr;
      Status : out Status_Code)
   is
      Nid : Node_Id;
   begin
      if A.Root = Null_Node then
         Status := Invalid_Expr;
         E := (Root => Null_Node);
         return;
      end if;

      New_Node(B, (Kind => K_Unary, U_Op => Op, A => A.Root), Nid, Status);
      E := (Root => Nid);
   end Make_Unary;

   procedure Make_Binary
     (B      : in out Builder;
      Op     : Binary_Op;
      L, R   : Expr;
      E      : out Expr;
      Status : out Status_Code)
   is
      Nid : Node_Id;
   begin
      if L.Root = Null_Node or else R.Root = Null_Node then
         Status := Invalid_Expr;
         E := (Root => Null_Node);
         return;
      end if;

      New_Node(B, (Kind => K_Binary, B_Op => Op, L => L.Root, R => R.Root), Nid, Status);
      E := (Root => Nid);
   end Make_Binary;

   ----------------------------------------------------------------------------
   --  Numeric helpers
   ----------------------------------------------------------------------------
   procedure Try_As_Integer (X : Real; Ok : out Boolean; I : out Integer) is
   begin
      Ok := False;
      I := 0;

      if X < Real(Integer'First) or else X > Real(Integer'Last) then
         return;
      end if;

      I := Integer(X);
      Ok := (Real(I) = X);
   end Try_As_Integer;

   procedure Pow_Int
     (Base   : Real;
      Expo   : Integer;
      Result : out Real;
      Status : out Status_Code)
   is
      E   : Integer := Expo;
      Bv  : Real := Base;
      Res : Real := 1.0;
   begin
      Status := Ok;
      Result := 0.0;

      if E = 0 then
         Result := 1.0;
         return;
      end if;

      if E < 0 then
         if AbsF(Base) <= Eval_Zero_Eps then
            Status := Division_By_Zero;
            return;
         end if;
         E := -E;
         Bv := 1.0 / Base;
      end if;

      while E > 0 loop
         if (E mod 2) = 1 then
            Res := Res * Bv;
            if not Is_Finite(Res) then
               Status := Numeric_Overflow;
               return;
            end if;
         end if;

         E := E / 2;
         exit when E = 0;

         Bv := Bv * Bv;
         if not Is_Finite(Bv) then
            Status := Numeric_Overflow;
            return;
         end if;
      end loop;

      Result := Res;
   end Pow_Int;

   procedure Eval_Unary
     (Op     : Unary_Op;
      X      : Real;
      R      : out Real;
      Status : out Status_Code)
   is
   begin
      Status := Ok;

      case Op is
         when Neg    => R := -X;
         when Sin    => R := EF.Sin(X);
         when Cos    => R := EF.Cos(X);

         when Tan    =>
            if AbsF(EF.Cos(X)) <= Eval_Zero_Eps then
               Status := Division_By_Zero;
               R := 0.0;
            else
               R := EF.Tan(X);
            end if;

         when Exp    => R := EF.Exp(X);

         when Log    =>
            if X <= 0.0 then
               Status := Domain_Error;
               R := 0.0;
            else
               R := EF.Log(X);
            end if;

         when Sqrt   =>
            if X < 0.0 then
               Status := Domain_Error;
               R := 0.0;
            else
               R := EF.Sqrt(X);
            end if;

         when Abs_Op => R := AbsF(X);

         when Sign   =>
            if X > 0.0 then
               R := 1.0;
            elsif X < 0.0 then
               R := -1.0;
            else
               R := 0.0;
            end if;
      end case;

      if Status = Ok and then (not Is_Finite(R)) then
         Status := Numeric_Overflow;
         R := 0.0;
      end if;
   end Eval_Unary;

   procedure Eval_Binary
     (Op     : Binary_Op;
      X, Y   : Real;
      R      : out Real;
      Status : out Status_Code)
   is
      Ii  : Integer;
      OkI : Boolean;
      PS  : Status_Code;
      PR  : Real;
   begin
      Status := Ok;

      case Op is
         when Add => R := X + Y;
         when Sub => R := X - Y;
         when Mul => R := X * Y;

         when Div =>
            if AbsF(Y) <= Eval_Zero_Eps then
               Status := Division_By_Zero;
               R := 0.0;
            else
               R := X / Y;
            end if;

         when Pow =>
            Try_As_Integer(Y, OkI, Ii);
            if OkI and then AbsI(Ii) <= 64 then
               Pow_Int(X, Ii, PR, PS);
               if PS /= Ok then
                  Status := PS;
                  R := 0.0;
               else
                  R := PR;
               end if;
            else
               if X <= 0.0 then
                  Status := Domain_Error;
                  R := 0.0;
               else
                  R := EF.Exp(Y * EF.Log(X));
               end if;
            end if;
      end case;

      if Status = Ok and then (not Is_Finite(R)) then
         Status := Numeric_Overflow;
         R := 0.0;
      end if;
   end Eval_Binary;

   ----------------------------------------------------------------------------
   --  Evaluation (non-recursive postorder)
   ----------------------------------------------------------------------------
   procedure Evaluate
     (B      : Builder;
      E      : Expr;
      Env    : Var_Values;
      Value  : out Real;
      Status : out Status_Code)
   is
      type Stack_Item is record
         Id      : Node_Id;
         Visited : Boolean;
      end record;

      Stack : array (Positive range 1 .. Max_Nodes) of Stack_Item;
      Top   : Natural := 0;

      Done  : array (Node_Id) of Boolean := (others => False);
      Val   : array (Node_Id) of Real    := (others => 0.0);

      procedure Push (Id : Node_Id; Visited : Boolean) is
      begin
         if Top = Max_Nodes then
            Status := Token_Overflow;
            return;
         end if;
         Top := Top + 1;
         Stack(Top) := (Id => Id, Visited => Visited);
      end Push;

      procedure Pop (Item : out Stack_Item) is
      begin
         Item := Stack(Top);
         Top := Top - 1;
      end Pop;

      Item : Stack_Item;
      N    : Node;
      X, Y, R : Real := 0.0;
      S2 : Status_Code;

   begin
      Status := Ok;
      Value := 0.0;

      if E.Root = Null_Node or else Natural(E.Root) > B.Used then
         Status := Invalid_Expr;
         return;
      end if;

      Push(E.Root, False);
      if Status /= Ok then return; end if;

      while Top > 0 loop
         Pop(Item);

         if Item.Id = Null_Node or else Natural(Item.Id) > B.Used then
            Status := Invalid_Expr;
            return;
         end if;

         if Done(Item.Id) then
            null;

         elsif not Item.Visited then
            Push(Item.Id, True);
            if Status /= Ok then return; end if;

            N := B.Nodes(Item.Id);
            case N.Kind is
               when K_Const | K_Var =>
                  null;

               when K_Unary =>
                  if not Done(N.A) then
                     Push(N.A, False);
                     if Status /= Ok then return; end if;
                  end if;

               when K_Binary =>
                  if not Done(N.L) then
                     Push(N.L, False);
                     if Status /= Ok then return; end if;
                  end if;
                  if not Done(N.R) then
                     Push(N.R, False);
                     if Status /= Ok then return; end if;
                  end if;
            end case;

         else
            N := B.Nodes(Item.Id);

            case N.Kind is
               when K_Const =>
                  Val(Item.Id) := N.C;

               when K_Var =>
                  Val(Item.Id) := Env(N.V);

               when K_Unary =>
                  X := Val(N.A);
                  Eval_Unary(N.U_Op, X, R, S2);
                  if S2 /= Ok then
                     Status := S2;
                     return;
                  end if;
                  Val(Item.Id) := R;

               when K_Binary =>
                  X := Val(N.L);
                  Y := Val(N.R);
                  Eval_Binary(N.B_Op, X, Y, R, S2);
                  if S2 /= Ok then
                     Status := S2;
                     return;
                  end if;
                  Val(Item.Id) := R;
            end case;

            if not Is_Finite(Val(Item.Id)) then
               Status := Numeric_Overflow;
               return;
            end if;

            Done(Item.Id) := True;
         end if;
      end loop;

      Value := Val(E.Root);
   end Evaluate;

   ----------------------------------------------------------------------------
   --  Transform helpers: allocate into Dst_B (procedures, SPARK-safe)
   ----------------------------------------------------------------------------
   procedure Dst_Const
     (Dst_B  : in out Builder;
      V      : Real;
      Id     : out Node_Id;
      Status : out Status_Code)
   is
   begin
      New_Node(Dst_B, (Kind => K_Const, C => V), Id, Status);
   end Dst_Const;

   procedure Dst_Var
     (Dst_B  : in out Builder;
      V      : Var_Id;
      Id     : out Node_Id;
      Status : out Status_Code)
   is
   begin
      New_Node(Dst_B, (Kind => K_Var, V => V), Id, Status);
   end Dst_Var;

   procedure Dst_Unary
     (Dst_B  : in out Builder;
      Op     : Unary_Op;
      A      : Node_Id;
      Id     : out Node_Id;
      Status : out Status_Code)
   is
   begin
      if A = Null_Node then
         Status := Invalid_Expr;
         Id := Null_Node;
         return;
      end if;
      New_Node(Dst_B, (Kind => K_Unary, U_Op => Op, A => A), Id, Status);
   end Dst_Unary;

   procedure Dst_Binary
     (Dst_B  : in out Builder;
      Op     : Binary_Op;
      L, R   : Node_Id;
      Id     : out Node_Id;
      Status : out Status_Code)
   is
   begin
      if L = Null_Node or else R = Null_Node then
         Status := Invalid_Expr;
         Id := Null_Node;
         return;
      end if;
      New_Node(Dst_B, (Kind => K_Binary, B_Op => Op, L => L, R => R), Id, Status);
   end Dst_Binary;

   ----------------------------------------------------------------------------
   --  Copy_To (non-recursive postorder)
   ----------------------------------------------------------------------------
   procedure Copy_To
     (Src_B  : Builder;
      Src_E  : Expr;
      Dst_B  : in out Builder;
      Dst_E  : out Expr;
      Status : out Status_Code)
   is
      type Stack_Item is record
         Id      : Node_Id;
         Visited : Boolean;
      end record;

      Stack : array (Positive range 1 .. Max_Nodes) of Stack_Item;
      Top   : Natural := 0;

      Map   : array (Node_Id) of Node_Id := (others => Null_Node);
      Done  : array (Node_Id) of Boolean := (others => False);

      procedure Push (Id : Node_Id; Visited : Boolean) is
      begin
         if Top = Max_Nodes then
            Status := Token_Overflow;
            return;
         end if;
         Top := Top + 1;
         Stack(Top) := (Id => Id, Visited => Visited);
      end Push;

      procedure Pop (Item : out Stack_Item) is
      begin
         Item := Stack(Top);
         Top := Top - 1;
      end Pop;

      Item : Stack_Item;
      N    : Node;
      S2   : Status_Code;
      NewId : Node_Id;

   begin
      Status := Ok;
      Dst_E  := (Root => Null_Node);

      if Src_E.Root = Null_Node or else Natural(Src_E.Root) > Src_B.Used then
         Status := Invalid_Expr;
         return;
      end if;

      Push(Src_E.Root, False);
      if Status /= Ok then return; end if;

      while Top > 0 loop
         Pop(Item);

         if Item.Id = Null_Node or else Natural(Item.Id) > Src_B.Used then
            Status := Invalid_Expr;
            return;
         end if;

         if Done(Item.Id) then
            null;

         elsif not Item.Visited then
            Push(Item.Id, True);
            if Status /= Ok then return; end if;

            N := Src_B.Nodes(Item.Id);
            case N.Kind is
               when K_Const | K_Var =>
                  null;

               when K_Unary =>
                  if not Done(N.A) then
                     Push(N.A, False);
                     if Status /= Ok then return; end if;
                  end if;

               when K_Binary =>
                  if not Done(N.L) then
                     Push(N.L, False);
                     if Status /= Ok then return; end if;
                  end if;
                  if not Done(N.R) then
                     Push(N.R, False);
                     if Status /= Ok then return; end if;
                  end if;
            end case;

         else
            N := Src_B.Nodes(Item.Id);

            case N.Kind is
               when K_Const =>
                  Dst_Const(Dst_B, N.C, NewId, S2);

               when K_Var =>
                  Dst_Var(Dst_B, N.V, NewId, S2);

               when K_Unary =>
                  Dst_Unary(Dst_B, N.U_Op, Map(N.A), NewId, S2);

               when K_Binary =>
                  Dst_Binary(Dst_B, N.B_Op, Map(N.L), Map(N.R), NewId, S2);
            end case;

            if S2 /= Ok then
               Status := S2;
               return;
            end if;

            Map(Item.Id) := NewId;
            Done(Item.Id) := True;
         end if;
      end loop;

      Dst_E := (Root => Map(Src_E.Root));
      if Dst_E.Root = Null_Node then
         Status := Invalid_Expr;
      end if;
   end Copy_To;

   ----------------------------------------------------------------------------
   --  Simplify_To (constant fold + neutral elements, conservative)
   ----------------------------------------------------------------------------
   procedure Simplify_To
     (Src_B  : Builder;
      Src_E  : Expr;
      Dst_B  : in out Builder;
      Dst_E  : out Expr;
      Status : out Status_Code)
   is
      type Stack_Item is record
         Id      : Node_Id;
         Visited : Boolean;
      end record;

      Stack : array (Positive range 1 .. Max_Nodes) of Stack_Item;
      Top   : Natural := 0;

      Map   : array (Node_Id) of Node_Id := (others => Null_Node);
      Done  : array (Node_Id) of Boolean := (others => False);

      procedure Push (Id : Node_Id; Visited : Boolean) is
      begin
         if Top = Max_Nodes then
            Status := Token_Overflow;
            return;
         end if;
         Top := Top + 1;
         Stack(Top) := (Id => Id, Visited => Visited);
      end Push;

      procedure Pop (Item : out Stack_Item) is
      begin
         Item := Stack(Top);
         Top := Top - 1;
      end Pop;

      procedure Is_Const
        (B    : Builder;
         Id   : Node_Id;
         IsC  : out Boolean;
         V    : out Real)
      is
      begin
         IsC := False;
         V := 0.0;

         if Id = Null_Node or else Natural(Id) > B.Used then
            return;
         end if;

         if B.Nodes(Id).Kind = K_Const then
            IsC := True;
            V := B.Nodes(Id).C;
         end if;
      end Is_Const;

      function Is_Zero_Const (B : Builder; Id : Node_Id) return Boolean is
         C : Boolean;
         V : Real;
      begin
         Is_Const(B, Id, C, V);
         return C and then V = 0.0;
      end Is_Zero_Const;

      function Is_One_Const (B : Builder; Id : Node_Id) return Boolean is
         C : Boolean;
         V : Real;
      begin
         Is_Const(B, Id, C, V);
         return C and then V = 1.0;
      end Is_One_Const;

      Item : Stack_Item;
      N    : Node;
      S2   : Status_Code;

      VX, VY, VR : Real := 0.0;
      CX, CY     : Boolean := False;

      Built : Node_Id;

      NewId : Node_Id;

   begin
      Status := Ok;
      Dst_E  := (Root => Null_Node);

      if Src_E.Root = Null_Node or else Natural(Src_E.Root) > Src_B.Used then
         Status := Invalid_Expr;
         return;
      end if;

      Push(Src_E.Root, False);
      if Status /= Ok then return; end if;

      while Top > 0 loop
         Pop(Item);

         if Item.Id = Null_Node or else Natural(Item.Id) > Src_B.Used then
            Status := Invalid_Expr;
            return;
         end if;

         if Done(Item.Id) then
            null;

         elsif not Item.Visited then
            Push(Item.Id, True);
            if Status /= Ok then return; end if;

            N := Src_B.Nodes(Item.Id);
            case N.Kind is
               when K_Const | K_Var =>
                  null;

               when K_Unary =>
                  if not Done(N.A) then
                     Push(N.A, False);
                     if Status /= Ok then return; end if;
                  end if;

               when K_Binary =>
                  if not Done(N.L) then
                     Push(N.L, False);
                     if Status /= Ok then return; end if;
                  end if;
                  if not Done(N.R) then
                     Push(N.R, False);
                     if Status /= Ok then return; end if;
                  end if;
            end case;

         else
            N := Src_B.Nodes(Item.Id);

            case N.Kind is
               when K_Const =>
                  Dst_Const(Dst_B, N.C, NewId, S2);

               when K_Var =>
                  Dst_Var(Dst_B, N.V, NewId, S2);

               when K_Unary =>
                  declare
                     A_New : constant Node_Id := Map(N.A);
                     AV    : Real := 0.0;
                     AC    : Boolean := False;
                     Temp  : Node_Id;
                  begin
                     -- -(-x) -> x
                     if N.U_Op = Neg
                       and then A_New /= Null_Node
                       and then Natural(A_New) <= Dst_B.Used
                       and then Dst_B.Nodes(A_New).Kind = K_Unary
                       and then Dst_B.Nodes(A_New).U_Op = Neg
                     then
                        NewId := Dst_B.Nodes(A_New).A;
                        S2 := Ok;

                     else
                        Is_Const(Dst_B, A_New, AC, AV);

                        if AC then
                           Eval_Unary(N.U_Op, AV, VR, S2);
                           if S2 = Ok then
                              Dst_Const(Dst_B, VR, Temp, S2);
                              NewId := Temp;
                           else
                              -- keep symbolic
                              S2 := Ok;
                              Dst_Unary(Dst_B, N.U_Op, A_New, Temp, S2);
                              NewId := Temp;
                           end if;
                        else
                           Dst_Unary(Dst_B, N.U_Op, A_New, Temp, S2);
                           NewId := Temp;
                        end if;
                     end if;
                  end;

               when K_Binary =>
                  declare
                     L_New : constant Node_Id := Map(N.L);
                     R_New : constant Node_Id := Map(N.R);
                     Temp  : Node_Id;
                  begin
                     Built := Null_Node;
                     S2 := Ok;

                     -- neutral elements
                     case N.B_Op is
                        when Add =>
                           if Is_Zero_Const(Dst_B, L_New) then
                              Built := R_New;
                           elsif Is_Zero_Const(Dst_B, R_New) then
                              Built := L_New;
                           else
                              Dst_Binary(Dst_B, Add, L_New, R_New, Built, S2);
                           end if;

                        when Sub =>
                           if Is_Zero_Const(Dst_B, R_New) then
                              Built := L_New;
                           elsif Is_Zero_Const(Dst_B, L_New) then
                              Dst_Unary(Dst_B, Neg, R_New, Built, S2);
                           else
                              Dst_Binary(Dst_B, Sub, L_New, R_New, Built, S2);
                           end if;

                        when Mul =>
                           if Is_Zero_Const(Dst_B, L_New) or else Is_Zero_Const(Dst_B, R_New) then
                              Dst_Const(Dst_B, 0.0, Built, S2);
                           elsif Is_One_Const(Dst_B, L_New) then
                              Built := R_New;
                           elsif Is_One_Const(Dst_B, R_New) then
                              Built := L_New;
                           else
                              Dst_Binary(Dst_B, Mul, L_New, R_New, Built, S2);
                           end if;

                        when Div =>
                           if Is_Zero_Const(Dst_B, L_New) then
                              Dst_Const(Dst_B, 0.0, Built, S2);
                           elsif Is_One_Const(Dst_B, R_New) then
                              Built := L_New;
                           else
                              Dst_Binary(Dst_B, Div, L_New, R_New, Built, S2);
                           end if;

                        when Pow =>
                           if Is_One_Const(Dst_B, L_New) then
                              Dst_Const(Dst_B, 1.0, Built, S2);
                           elsif Is_One_Const(Dst_B, R_New) then
                              Built := L_New;
                           else
                              Dst_Binary(Dst_B, Pow, L_New, R_New, Built, S2);
                           end if;
                     end case;

                     if S2 /= Ok then
                        Status := S2;
                        return;
                     end if;

                     -- constant fold if both const
                     Is_Const(Dst_B, L_New, CX, VX);
                     Is_Const(Dst_B, R_New, CY, VY);

                     if CX and CY then
                        Eval_Binary(N.B_Op, VX, VY, VR, S2);
                        if S2 = Ok then
                           Dst_Const(Dst_B, VR, Temp, S2);
                           if S2 = Ok then
                              Built := Temp;
                           end if;
                        else
                           -- keep Built as-is
                           S2 := Ok;
                        end if;
                     end if;

                     NewId := Built;
                  end;
            end case;

            if S2 /= Ok then
               Status := S2;
               return;
            end if;

            Map(Item.Id) := NewId;
            Done(Item.Id) := True;
         end if;
      end loop;

      Dst_E := (Root => Map(Src_E.Root));
      if Dst_E.Root = Null_Node then
         Status := Invalid_Expr;
      end if;
   end Simplify_To;

   ----------------------------------------------------------------------------
   --  Differentiate_To (non-recursive postorder)
   ----------------------------------------------------------------------------
   procedure Differentiate_To
     (Src_B           : Builder;
      Src_E           : Expr;
      With_Respect_To : Var_Id;
      Dst_B           : in out Builder;
      Dst_E           : out Expr;
      Status          : out Status_Code)
   is
      type Stack_Item is record
         Id      : Node_Id;
         Visited : Boolean;
      end record;

      Stack : array (Positive range 1 .. Max_Nodes) of Stack_Item;
      Top   : Natural := 0;

      Copy_Map : array (Node_Id) of Node_Id := (others => Null_Node);
      Der_Map  : array (Node_Id) of Node_Id := (others => Null_Node);
      Done     : array (Node_Id) of Boolean := (others => False);

      procedure Push (Id : Node_Id; Visited : Boolean) is
      begin
         if Top = Max_Nodes then
            Status := Token_Overflow;
            return;
         end if;
         Top := Top + 1;
         Stack(Top) := (Id => Id, Visited => Visited);
      end Push;

      procedure Pop (Item : out Stack_Item) is
      begin
         Item := Stack(Top);
         Top := Top - 1;
      end Pop;

      procedure Note_Non_Smooth is
      begin
         if Status = Ok then
            Status := Non_Smooth;
         end if;
      end Note_Non_Smooth;

      procedure Build_Const (V : Real; Id : out Node_Id) is
         S2 : Status_Code;
      begin
         Dst_Const(Dst_B, V, Id, S2);
         if S2 /= Ok then
            Status := S2;
            Id := Null_Node;
         end if;
      end Build_Const;

      procedure Build_Unary (Op : Unary_Op; A : Node_Id; Id : out Node_Id) is
         S2 : Status_Code;
      begin
         Dst_Unary(Dst_B, Op, A, Id, S2);
         if S2 /= Ok then
            Status := S2;
            Id := Null_Node;
         end if;
      end Build_Unary;

      procedure Build_Binary (Op : Binary_Op; L, R : Node_Id; Id : out Node_Id) is
         S2 : Status_Code;
      begin
         Dst_Binary(Dst_B, Op, L, R, Id, S2);
         if S2 /= Ok then
            Status := S2;
            Id := Null_Node;
         end if;
      end Build_Binary;

      procedure Src_Is_Const
        (B    : Builder;
         Id   : Node_Id;
         IsC  : out Boolean;
         V    : out Real)
      is
      begin
         IsC := False;
         V := 0.0;

         if Id = Null_Node or else Natural(Id) > B.Used then
            return;
         end if;

         if B.Nodes(Id).Kind = K_Const then
            IsC := True;
            V := B.Nodes(Id).C;
         end if;
      end Src_Is_Const;

      Item : Stack_Item;
      N    : Node;

      Rc    : Real := 0.0;
      HasRc : Boolean := False;
      Ii    : Integer := 0;
      OkI   : Boolean := False;

      T0, T1, T2, T3 : Node_Id;

   begin
      Status := Ok;
      Dst_E  := (Root => Null_Node);

      if Src_E.Root = Null_Node or else Natural(Src_E.Root) > Src_B.Used then
         Status := Invalid_Expr;
         return;
      end if;

      Push(Src_E.Root, False);
      if Status /= Ok then return; end if;

      while Top > 0 loop
         Pop(Item);

         if Item.Id = Null_Node or else Natural(Item.Id) > Src_B.Used then
            Status := Invalid_Expr;
            return;
         end if;

         if Done(Item.Id) then
            null;

         elsif not Item.Visited then
            Push(Item.Id, True);
            if Status /= Ok then return; end if;

            N := Src_B.Nodes(Item.Id);
            case N.Kind is
               when K_Const | K_Var =>
                  null;

               when K_Unary =>
                  if not Done(N.A) then
                     Push(N.A, False);
                     if Status /= Ok then return; end if;
                  end if;

               when K_Binary =>
                  if not Done(N.L) then
                     Push(N.L, False);
                     if Status /= Ok then return; end if;
                  end if;
                  if not Done(N.R) then
                     Push(N.R, False);
                     if Status /= Ok then return; end if;
                  end if;
            end case;

         else
            N := Src_B.Nodes(Item.Id);

            -- copy into destination
            case N.Kind is
               when K_Const =>
                  Build_Const(N.C, Copy_Map(Item.Id));

               when K_Var =>
                  Dst_Var(Dst_B, N.V, Copy_Map(Item.Id), Status);

               when K_Unary =>
                  Build_Unary(N.U_Op, Copy_Map(N.A), Copy_Map(Item.Id));

               when K_Binary =>
                  Build_Binary(N.B_Op, Copy_Map(N.L), Copy_Map(N.R), Copy_Map(Item.Id));
            end case;

            if Status /= Ok then return; end if;

            -- derivative rules
            case N.Kind is
               when K_Const =>
                  Build_Const(0.0, Der_Map(Item.Id));

               when K_Var =>
                  if N.V = With_Respect_To then
                     Build_Const(1.0, Der_Map(Item.Id));
                  else
                     Build_Const(0.0, Der_Map(Item.Id));
                  end if;

               when K_Unary =>
                  declare
                     A  : constant Node_Id := Copy_Map(N.A);
                     dA : constant Node_Id := Der_Map(N.A);
                  begin
                     case N.U_Op is
                        when Neg =>
                           Build_Unary(Neg, dA, Der_Map(Item.Id));

                        when Sin =>
                           Build_Unary(Cos, A, T0);
                           Build_Binary(Mul, T0, dA, Der_Map(Item.Id));

                        when Cos =>
                           Build_Unary(Sin, A, T0);
                           Build_Binary(Mul, T0, dA, T1);
                           Build_Unary(Neg, T1, Der_Map(Item.Id));

                        when Tan =>
                           Build_Unary(Cos, A, T0);
                           Build_Const(2.0, T1);
                           Build_Binary(Pow, T0, T1, T2);
                           Build_Binary(Div, dA, T2, Der_Map(Item.Id));

                        when Exp =>
                           Build_Unary(Exp, A, T0);
                           Build_Binary(Mul, T0, dA, Der_Map(Item.Id));

                        when Log =>
                           Build_Binary(Div, dA, A, Der_Map(Item.Id));

                        when Sqrt =>
                           Build_Const(2.0, T0);
                           Build_Unary(Sqrt, A, T1);
                           Build_Binary(Mul, T0, T1, T2);
                           Build_Binary(Div, dA, T2, Der_Map(Item.Id));

                        when Abs_Op =>
                           Note_Non_Smooth;
                           Build_Unary(Sign, A, T0);
                           Build_Binary(Mul, T0, dA, Der_Map(Item.Id));

                        when Sign =>
                           Note_Non_Smooth;
                           Build_Const(0.0, Der_Map(Item.Id));
                     end case;
                  end;

               when K_Binary =>
                  declare
                     L  : constant Node_Id := Copy_Map(N.L);
                     R  : constant Node_Id := Copy_Map(N.R);
                     dL : constant Node_Id := Der_Map(N.L);
                     dR : constant Node_Id := Der_Map(N.R);
                  begin
                     case N.B_Op is
                        when Add =>
                           Build_Binary(Add, dL, dR, Der_Map(Item.Id));

                        when Sub =>
                           Build_Binary(Sub, dL, dR, Der_Map(Item.Id));

                        when Mul =>
                           Build_Binary(Mul, dL, R, T0);
                           Build_Binary(Mul, L, dR, T1);
                           Build_Binary(Add, T0, T1, Der_Map(Item.Id));

                        when Div =>
                           Build_Binary(Mul, dL, R, T0);
                           Build_Binary(Mul, L, dR, T1);
                           Build_Binary(Sub, T0, T1, T2);
                           Build_Const(2.0, T3);
                           Build_Binary(Pow, R, T3, T0);
                           Build_Binary(Div, T2, T0, Der_Map(Item.Id));

                        when Pow =>
                           Src_Is_Const(Src_B, N.R, HasRc, Rc);
                           Try_As_Integer(Rc, OkI, Ii);

                           if HasRc and then OkI and then AbsI(Ii) <= 64 then
                              if Ii = 0 then
                                 Build_Const(0.0, Der_Map(Item.Id));
                              else
                                 -- n * L^(n-1) * dL
                                 Build_Const(Real(Ii), T0);
                                 Build_Const(Real(Ii - 1), T1);
                                 Build_Binary(Pow, L, T1, T2);
                                 Build_Binary(Mul, T0, T2, T3);
                                 Build_Binary(Mul, T3, dL, Der_Map(Item.Id));
                              end if;
                           else
                              -- general: L^R * ( dR*log(L) + R*(dL/L) )
                              Build_Unary(Log, L, T0);
                              Build_Binary(Mul, dR, T0, T1);
                              Build_Binary(Div, dL, L, T2);
                              Build_Binary(Mul, R, T2, T3);
                              Build_Binary(Add, T1, T3, T0);
                              Build_Binary(Mul, Copy_Map(Item.Id), T0, Der_Map(Item.Id));
                           end if;
                     end case;
                  end;
            end case;

            if Status /= Ok then return; end if;

            Done(Item.Id) := True;
         end if;
      end loop;

      Dst_E := (Root => Der_Map(Src_E.Root));
      if Dst_E.Root = Null_Node then
         Status := Invalid_Expr;
      end if;
   end Differentiate_To;

   ----------------------------------------------------------------------------
   --  Parsing: shunting-yard (bounded, no continue)
   ----------------------------------------------------------------------------
   type Out_Kind is (O_Number, O_Var, O_Unary, O_Binary, O_Func);

   type Out_Token (Kind : Out_Kind := O_Number) is record
      case Kind is
         when O_Number =>
            Num : Real := 0.0;
         when O_Var =>
            Var : Var_Id := Var_Id'First;
         when O_Unary | O_Func =>
            Uop : Unary_Op := Neg;
         when O_Binary =>
            Bop : Binary_Op := Add;
      end case;
   end record;

   type Op_Kind is (Op_LParen, Op_Unary, Op_Binary, Op_Func);

   type Op_Token (Kind : Op_Kind := Op_LParen) is record
      Prec        : Natural := 0;
      Right_Assoc : Boolean := False;
      case Kind is
         when Op_LParen =>
            null;
         when Op_Unary | Op_Func =>
            Uop : Unary_Op := Neg;
         when Op_Binary =>
            Bop : Binary_Op := Add;
      end case;
   end record;

   function To_Lower (C : Character) return Character is
   begin
      if C >= 'A' and then C <= 'Z' then
         return Character'Val(Character'Pos(C) + (Character'Pos('a') - Character'Pos('A')));
      else
         return C;
      end if;
   end To_Lower;

   function Is_Alpha (C : Character) return Boolean is
   begin
      return (C >= 'A' and then C <= 'Z')
        or else (C >= 'a' and then C <= 'z')
        or else (C = '_');
   end Is_Alpha;

   function Is_Alnum (C : Character) return Boolean is
   begin
      return Is_Alpha(C) or else (C >= '0' and then C <= '9');
   end Is_Alnum;

   function Is_Digit (C : Character) return Boolean is
   begin
      return (C >= '0' and then C <= '9');
   end Is_Digit;

   procedure Skip_Spaces (Text : String; I : in out Integer) is
   begin
      while I <= Text'Last and then Text(I) = ' ' loop
         I := I + 1;
      end loop;
   end Skip_Spaces;

   procedure Parse_Number
     (Text   : String;
      I      : in out Integer;
      Value  : out Real;
      Ok_Num : out Boolean)
   is
      Neg     : Boolean := False;
      IntPart : Real := 0.0;
      FrPart  : Real := 0.0;
      Scale   : Real := 1.0;
      HasAny  : Boolean := False;

      ExpNeg  : Boolean := False;
      ExpVal  : Integer := 0;

      function Pow10 (E : Integer) return Real is
         R : Real := 1.0;
         K : Integer := E;
      begin
         if K < 0 then
            K := -K;
            for J in 1 .. K loop
               R := R / 10.0;
            end loop;
         else
            for J in 1 .. K loop
               R := R * 10.0;
            end loop;
         end if;
         return R;
      end Pow10;

   begin
      Ok_Num := False;
      Value  := 0.0;

      if I > Text'Last then
         return;
      end if;

      if Text(I) = '+' then
         I := I + 1;
      elsif Text(I) = '-' then
         Neg := True;
         I := I + 1;
      end if;

      while I <= Text'Last and then Is_Digit(Text(I)) loop
         HasAny := True;
         IntPart := IntPart * 10.0 + Real(Character'Pos(Text(I)) - Character'Pos('0'));
         I := I + 1;
      end loop;

      if I <= Text'Last and then Text(I) = '.' then
         I := I + 1;
         while I <= Text'Last and then Is_Digit(Text(I)) loop
            HasAny := True;
            Scale := Scale * 10.0;
            FrPart := FrPart + Real(Character'Pos(Text(I)) - Character'Pos('0')) / Scale;
            I := I + 1;
         end loop;
      end if;

      if not HasAny then
         return;
      end if;

      Value := IntPart + FrPart;

      if I <= Text'Last and then (Text(I) = 'e' or else Text(I) = 'E') then
         I := I + 1;

         if I <= Text'Last and then Text(I) = '+' then
            I := I + 1;
         elsif I <= Text'Last and then Text(I) = '-' then
            ExpNeg := True;
            I := I + 1;
         end if;

         if I > Text'Last or else not Is_Digit(Text(I)) then
            return;
         end if;

         while I <= Text'Last and then Is_Digit(Text(I)) loop
            ExpVal := ExpVal * 10 + (Character'Pos(Text(I)) - Character'Pos('0'));
            if ExpVal > 38 then
               ExpVal := 38;
            end if;
            I := I + 1;
         end loop;

         if ExpNeg then
            ExpVal := -ExpVal;
         end if;

         Value := Value * Pow10(ExpVal);
      end if;

      if Neg then
         Value := -Value;
      end if;

      Ok_Num := Is_Finite(Value);
   end Parse_Number;

   procedure Func_Of
     (S       : String;
      Is_Func : out Boolean;
      U       : out Unary_Op)
   is
   begin
      Is_Func := True;
      U := Neg;

      if S = "sin" then U := Sin;
      elsif S = "cos" then U := Cos;
      elsif S = "tan" then U := Tan;
      elsif S = "exp" then U := Exp;
      elsif S = "log" then U := Log;
      elsif S = "sqrt" then U := Sqrt;
      elsif S = "abs" then U := Abs_Op;
      elsif S = "sign" then U := Sign;
      else
         Is_Func := False;
      end if;
   end Func_Of;

   procedure Peek_NonSpace
     (Text : String;
      I    : Integer;
      C    : out Character)
   is
      J : Integer := I;
   begin
      Skip_Spaces(Text, J);
      if J <= Text'Last then
         C := Text(J);
      else
         C := Character'Val(0);
      end if;
   end Peek_NonSpace;

   procedure Parse_Infix
     (B      : in out Builder;
      Text   : String;
      E      : out Expr;
      Status : out Status_Code)
   is
      OutQ : array (Positive range 1 .. Max_Parse_Out) of Out_Token;
      OutN : Natural := 0;

      Ops  : array (Positive range 1 .. Max_Parse_Ops) of Op_Token;
      OpN  : Natural := 0;

      ExprS : array (Positive range 1 .. Max_Parse_Expr) of Node_Id;
      ExprN : Natural := 0;

      Prev_Was_Value : Boolean := False;

      Saved_Used : constant Natural := B.Used;
      Saved_Sym  : constant Natural := B.Sym_Used;

      procedure Fail (S : Status_Code) is
      begin
         Status := S;
         B.Used := Saved_Used;
         B.Sym_Used := Saved_Sym;
         E := (Root => Null_Node);
      end Fail;

      procedure Out_Push (T : Out_Token) is
      begin
         if OutN = Max_Parse_Out then
            Fail(Token_Overflow);
            return;
         end if;
         OutN := OutN + 1;
         OutQ(OutN) := T;
      end Out_Push;

      procedure Op_Push (T : Op_Token) is
      begin
         if OpN = Max_Parse_Ops then
            Fail(Token_Overflow);
            return;
         end if;
         OpN := OpN + 1;
         Ops(OpN) := T;
      end Op_Push;

      procedure Op_Pop_To_Out is
      begin
         if OpN = 0 then
            Fail(Parse_Error);
            return;
         end if;

         case Ops(OpN).Kind is
            when Op_Unary =>
               Out_Push((Kind => O_Unary, Uop => Ops(OpN).Uop));
            when Op_Func =>
               Out_Push((Kind => O_Func, Uop => Ops(OpN).Uop));
            when Op_Binary =>
               Out_Push((Kind => O_Binary, Bop => Ops(OpN).Bop));
            when Op_LParen =>
               Fail(Parse_Error);
         end case;

         if Status /= Ok then
            return;
         end if;

         OpN := OpN - 1;
      end Op_Pop_To_Out;

      procedure Drain_Ops_For (Prec : Natural; Right_Assoc : Boolean) is
      begin
         while OpN > 0 loop
            exit when Ops(OpN).Kind = Op_LParen;

            if Ops(OpN).Prec > Prec then
               Op_Pop_To_Out;
            elsif (not Right_Assoc) and then (Ops(OpN).Prec = Prec) then
               Op_Pop_To_Out;
            else
               exit;
            end if;

            exit when Status /= Ok;
         end loop;
      end Drain_Ops_For;

      procedure Expr_Push (Id : Node_Id) is
      begin
         if ExprN = Max_Parse_Expr then
            Fail(Token_Overflow);
            return;
         end if;
         ExprN := ExprN + 1;
         ExprS(ExprN) := Id;
      end Expr_Push;

      procedure Expr_Pop (Id : out Node_Id) is
      begin
         if ExprN = 0 then
            Fail(Parse_Error);
            Id := Null_Node;
            return;
         end if;

         Id := ExprS(ExprN);
         ExprN := ExprN - 1;
      end Expr_Pop;

      I : Integer := Text'First;

      procedure Read_Identifier (Ident : out String; Len : out Natural) is
         Buf : String (1 .. Max_Name_Len) := (others => ' ');
      begin
         Len := 0;
         while I <= Text'Last and then Is_Alnum(Text(I)) loop
            if Len = Max_Name_Len then
               Len := 0;
               return;
            end if;
            Len := Len + 1;
            Buf(Len) := To_Lower(Text(I));
            I := I + 1;
         end loop;

         Ident := Buf;
      end Read_Identifier;

   begin
      Status := Ok;
      E := (Root => Null_Node);

      if Text'Length = 0 then
         Fail(Parse_Error);
         return;
      end if;

      while I <= Text'Last loop
         Skip_Spaces(Text, I);
         exit when I > Text'Last;

         -- number
         if Is_Digit(Text(I)) or else Text(I) = '.' then
            declare
               Num   : Real := 0.0;
               OkNum : Boolean := False;
            begin
               Parse_Number(Text, I, Num, OkNum);
               if not OkNum then
                  Fail(Parse_Error);
                  return;
               end if;

               Out_Push((Kind => O_Number, Num => Num));
               if Status /= Ok then return; end if;

               Prev_Was_Value := True;
            end;

         -- identifier
         elsif Is_Alpha(Text(I)) then
            declare
               Buf  : String (1 .. Max_Name_Len) := (others => ' ');
               Len  : Natural := 0;
               NextC : Character;
               IsFunc : Boolean;
               U : Unary_Op;
               Found : Boolean;
               Vid   : Var_Id;
            begin
               Read_Identifier(Buf, Len);
               if Len = 0 then
                  Fail(Parse_Error);
                  return;
               end if;

               Peek_NonSpace(Text, I, NextC);

               declare
                  Ident : constant String := Buf(1 .. Len);
               begin
                  if Ident = "pi" then
                     Out_Push((Kind => O_Number, Num => Real(Pi)));
                     Prev_Was_Value := True;

                  elsif Ident = "e" then
                     Out_Push((Kind => O_Number, Num => E_Const));
                     Prev_Was_Value := True;

                  else
                     Func_Of(Ident, IsFunc, U);
                     if IsFunc and then NextC = '(' then
                        Op_Push((Kind => Op_Func, Prec => 4, Right_Assoc => True, Uop => U));
                        Prev_Was_Value := False;
                     else
                        Lookup_Symbol(B, Ident, Found, Vid);
                        if not Found then
                           Define_Symbol(B, Ident, Vid, Status);
                           if Status /= Ok then
                              Fail(Status);
                              return;
                           end if;
                        end if;

                        Out_Push((Kind => O_Var, Var => Vid));
                        Prev_Was_Value := True;
                     end if;
                  end if;
               end;
            end;

         -- operators / punctuation
         else
            case Text(I) is
               when '(' =>
                  Op_Push((Kind => Op_LParen, Prec => 0, Right_Assoc => False));
                  if Status /= Ok then return; end if;
                  I := I + 1;
                  Prev_Was_Value := False;

               when ')' =>
                  I := I + 1;

                  while OpN > 0 and then Ops(OpN).Kind /= Op_LParen loop
                     Op_Pop_To_Out;
                     if Status /= Ok then return; end if;
                  end loop;

                  if OpN = 0 then
                     Fail(Parse_Error);
                     return;
                  end if;

                  OpN := OpN - 1; -- pop '('

                  if OpN > 0 and then Ops(OpN).Kind = Op_Func then
                     Op_Pop_To_Out;
                     if Status /= Ok then return; end if;
                  end if;

                  Prev_Was_Value := True;

               when ',' =>
                  I := I + 1;
                  while OpN > 0 and then Ops(OpN).Kind /= Op_LParen loop
                     Op_Pop_To_Out;
                     if Status /= Ok then return; end if;
                  end loop;

                  if OpN = 0 then
                     Fail(Parse_Error);
                     return;
                  end if;

                  Prev_Was_Value := False;

               when '+' | '-' =>
                  declare
                     C : constant Character := Text(I);
                     Is_Unary : constant Boolean := (not Prev_Was_Value);
                     Bop : Binary_Op;
                     P   : Natural;
                  begin
                     I := I + 1;

                     if Is_Unary then
                        if C = '-' then
                           Drain_Ops_For(4, True);
                           if Status /= Ok then return; end if;
                           Op_Push((Kind => Op_Unary, Prec => 4, Right_Assoc => True, Uop => Neg));
                           if Status /= Ok then return; end if;
                        else
                           null; -- unary '+'
                        end if;
                     else
                        Bop := (if C = '+' then Add else Sub);
                        P := 1;
                        Drain_Ops_For(P, False);
                        if Status /= Ok then return; end if;
                        Op_Push((Kind => Op_Binary, Prec => P, Right_Assoc => False, Bop => Bop));
                        if Status /= Ok then return; end if;
                     end if;

                     Prev_Was_Value := False;
                  end;

               when '*' | '/' | '^' =>
                  if not Prev_Was_Value then
                     Fail(Parse_Error);
                     return;
                  end if;

                  declare
                     C  : constant Character := Text(I);
                     Bop : Binary_Op;
                     P   : Natural;
                     RA  : Boolean;
                  begin
                     if C = '*' then
                        Bop := Mul; P := 2; RA := False;
                     elsif C = '/' then
                        Bop := Div; P := 2; RA := False;
                     else
                        Bop := Pow; P := 3; RA := True;
                     end if;

                     I := I + 1;

                     Drain_Ops_For(P, RA);
                     if Status /= Ok then return; end if;

                     Op_Push((Kind => Op_Binary, Prec => P, Right_Assoc => RA, Bop => Bop));
                     if Status /= Ok then return; end if;

                     Prev_Was_Value := False;
                  end;

               when others =>
                  Fail(Parse_Error);
                  return;
            end case;
         end if;

         if Status /= Ok then return; end if;
      end loop;

      -- drain ops
      while OpN > 0 loop
         if Ops(OpN).Kind = Op_LParen then
            Fail(Parse_Error);
            return;
         end if;
         Op_Pop_To_Out;
         if Status /= Ok then return; end if;
      end loop;

      -- build from RPN into builder nodes
      declare
         S2  : Status_Code := Ok;
         A   : Node_Id;
         L   : Node_Id;
         R   : Node_Id;
         Nid : Node_Id;
      begin
         for K in 1 .. OutN loop
            exit when Status /= Ok;

            case OutQ(K).Kind is
               when O_Number =>
                  New_Node(B, (Kind => K_Const, C => OutQ(K).Num), Nid, S2);
                  if S2 /= Ok then Fail(S2); return; end if;
                  Expr_Push(Nid);

               when O_Var =>
                  New_Node(B, (Kind => K_Var, V => OutQ(K).Var), Nid, S2);
                  if S2 /= Ok then Fail(S2); return; end if;
                  Expr_Push(Nid);

               when O_Unary | O_Func =>
                  Expr_Pop(A);
                  if Status /= Ok then return; end if;
                  New_Node(B, (Kind => K_Unary, U_Op => OutQ(K).Uop, A => A), Nid, S2);
                  if S2 /= Ok then Fail(S2); return; end if;
                  Expr_Push(Nid);

               when O_Binary =>
                  Expr_Pop(R);
                  Expr_Pop(L);
                  if Status /= Ok then return; end if;
                  New_Node(B, (Kind => K_Binary, B_Op => OutQ(K).Bop, L => L, R => R), Nid, S2);
                  if S2 /= Ok then Fail(S2); return; end if;
                  Expr_Push(Nid);
            end case;

            if Status /= Ok then return; end if;
         end loop;

         if ExprN /= 1 then
            Fail(Parse_Error);
            return;
         end if;

         E := (Root => ExprS(1));
         Status := Ok;
      end;
   end Parse_Infix;

end Float_Expr;

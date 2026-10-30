-- ============================================================
--  ALB_JSON body — bounded JSON DOM parser + serializer.
-- ============================================================

package body ALB_JSON is

   function Fail (Msg : String) return J_Index is
   begin
      Parse_Error := To_Unbounded_String (Msg);
      return 0;
   end Fail;

   function Alloc return J_Index is
   begin
      if JCount >= Max_JSON_Nodes then
         return 0;
      end if;
      JCount := JCount + 1;
      JNodes (JCount) := (Kind => J_Null,
                          Value => Null_Unbounded_String,
                          Key   => Null_Unbounded_String,
                          First => 0,
                          Next  => 0);
      return JCount;
   end Alloc;

   ------------------------------------------------- parser

   function Parse (Text : String) return J_Index is

      Pos : Integer := Text'First;

      procedure Skip_WS is
      begin
         while Pos <= Text'Last and then
               Text (Pos) in ' ' | ASCII.HT | ASCII.LF | ASCII.CR
         loop
            Pos := Pos + 1;
         end loop;
      end Skip_WS;

      function Peek return Character is
      begin
         if Pos > Text'Last then
            return ASCII.NUL;
         end if;
         return Text (Pos);
      end Peek;

      function Parse_Value (Depth : Natural) return J_Index;

      function Parse_String (Into : in out Unbounded_String)
                             return Boolean is
         --  Assumes '"' at Pos. Fills Into with unescaped text.
         Ch   : Character;
         Code : Natural;
      begin
         Pos := Pos + 1;
         while True loop
            if Pos > Text'Last then
               return False;
            end if;
            Ch := Text (Pos);
            Pos := Pos + 1;
            exit when Ch = '"';
            if Ch = '\' then
               if Pos > Text'Last then
                  return False;
               end if;
               Ch := Text (Pos);
               Pos := Pos + 1;
               case Ch is
                  when '"' | '\' | '/' =>
                     Append (Into, String'(1 => Ch));
                  when 'b' =>
                     Append (Into, String'(1 => ASCII.BS));
                  when 'f' =>
                     Append (Into, String'(1 => ASCII.FF));
                  when 'n' =>
                     Append (Into, String'(1 => ASCII.LF));
                  when 'r' =>
                     Append (Into, String'(1 => ASCII.CR));
                  when 't' =>
                     Append (Into, String'(1 => ASCII.HT));
                  when 'u' =>
                     Code := 0;
                     for K in 1 .. 4 loop
                        exit when Pos > Text'Last;
                        Ch := Text (Pos);
                        Pos := Pos + 1;
                        Code := Code * 16 +
                          (case Ch is
                           when '0' .. '9' =>
                              Character'Pos (Ch) - Character'Pos ('0'),
                           when 'a' .. 'f' =>
                              Character'Pos (Ch) - Character'Pos ('a') + 10,
                           when 'A' .. 'F' =>
                              Character'Pos (Ch) - Character'Pos ('A') + 10,
                           when others => 0);
                     end loop;
                     if Code < 128 then
                        Append (Into,
                                String'(1 => Character'Val (Code)));
                     else
                        --  Non-ASCII: keep it lossy but safe (UTF-8
                        --  sources are byte-safe in ALB anyway).
                        Append (Into, "?");
                     end if;
                  when others =>
                     Append (Into, String'(1 => Ch));
               end case;
            else
               Append (Into, String'(1 => Ch));
            end if;
         end loop;
         return True;
      end Parse_String;

      function Parse_Number (N : J_Index) return Boolean is
         Start : constant Integer := Pos;
      begin
         while Pos <= Text'Last and then
               Text (Pos) in '0' .. '9' | '-' | '+' | '.' | 'e' | 'E'
         loop
            Pos := Pos + 1;
         end loop;
         if Pos = Start then
            return False;
         end if;
         JNodes (N).Value := To_Unbounded_String (Text (Start .. Pos - 1));
         JNodes (N).Kind := J_Num;
         return True;
      end Parse_Number;

      function Parse_Arr (N : J_Index; Depth : Natural) return Boolean is
         Child : J_Index;
      begin
         JNodes (N).Kind := J_Arr;
         Pos := Pos + 1;   -- '['
         Skip_WS;
         if Peek = ']' then
            Pos := Pos + 1;
            return True;
         end if;
         loop
            Child := Parse_Value (Depth + 1);
            if Child = 0 then
               return False;
            end if;
            Append_Child (N, Child);
            Skip_WS;
            if Peek = ',' then
               Pos := Pos + 1;
               Skip_WS;
            elsif Peek = ']' then
               Pos := Pos + 1;
               return True;
            else
               return False;
            end if;
         end loop;
      end Parse_Arr;

      function Parse_Obj (N : J_Index; Depth : Natural) return Boolean is
         Child : J_Index;
      begin
         JNodes (N).Kind := J_Obj;
         Pos := Pos + 1;   -- '{'
         Skip_WS;
         if Peek = '}' then
            Pos := Pos + 1;
            return True;
         end if;
         loop
            Skip_WS;
            if Peek /= '"' then
               return False;
            end if;
            declare
               K : Unbounded_String := Null_Unbounded_String;
            begin
               if not Parse_String (K) then
                  return False;
               end if;
               Skip_WS;
               if Peek /= ':' then
                  return False;
               end if;
               Pos := Pos + 1;
               Child := Parse_Value (Depth + 1);
               if Child = 0 then
                  return False;
               end if;
               JNodes (Child).Key := K;
            end;
            Append_Child (N, Child);
            Skip_WS;
            if Peek = ',' then
               Pos := Pos + 1;
            elsif Peek = '}' then
               Pos := Pos + 1;
               return True;
            else
               return False;
            end if;
         end loop;
      end Parse_Obj;

      function Lit (S : String) return Boolean is
      begin
         if Pos + S'Length - 1 <= Text'Last
           and then Text (Pos .. Pos + S'Length - 1) = S
         then
            Pos := Pos + S'Length;
            return True;
         end if;
         return False;
      end Lit;

      function Parse_Value (Depth : Natural) return J_Index is
         N : J_Index;
      begin
         if Depth > Max_JSON_Depth then
            return Fail ("json: nesting too deep");
         end if;
         Skip_WS;
         N := Alloc;
         if N = 0 then
            return Fail ("json: node table exhausted");
         end if;
         case Peek is
            when '{' =>
               if not Parse_Obj (N, Depth) then
                  return Fail ("json: bad object at " & Integer'Image (Pos));
               end if;
            when '[' =>
               if not Parse_Arr (N, Depth) then
                  return Fail ("json: bad array at " & Integer'Image (Pos));
               end if;
            when '"' =>
               JNodes (N).Kind := J_Str;
               if not Parse_String (JNodes (N).Value) then
                  return Fail ("json: unterminated string at " &
                               Integer'Image (Pos));
               end if;
            when 't' =>
               if not Lit ("true") then
                  return Fail ("json: bad literal at " & Integer'Image (Pos));
               end if;
               JNodes (N).Kind := J_Bool;
               JNodes (N).Value := To_Unbounded_String ("true");
            when 'f' =>
               if not Lit ("false") then
                  return Fail ("json: bad literal at " & Integer'Image (Pos));
               end if;
               JNodes (N).Kind := J_Bool;
               JNodes (N).Value := To_Unbounded_String ("false");
            when 'n' =>
               if not Lit ("null") then
                  return Fail ("json: bad literal at " & Integer'Image (Pos));
               end if;
               JNodes (N).Kind := J_Null;
            when others =>
               if not Parse_Number (N) then
                  return Fail ("json: bad value at " & Integer'Image (Pos));
               end if;
         end case;
         return N;
      end Parse_Value;

      Root : J_Index;
   begin
      if Text'Length > Max_JSON_Chars then
         return Fail ("json: message too large");
      end if;
      JCount := 0;
      Parse_Error := Null_Unbounded_String;
      Root := Parse_Value (0);
      if Root = 0 then
         return 0;
      end if;
      Skip_WS;
      if Pos <= Text'Last then
         return Fail ("json: trailing data at " & Integer'Image (Pos));
      end if;
      return Root;
   end Parse;

   ------------------------------------------------- accessors

   function Kind (N : J_Index) return Node_Kind is
   begin
      if N = 0 then
         return J_Null;
      end if;
      return JNodes (N).Kind;
   end Kind;

   function First (N : J_Index) return J_Index is
   begin
      if N = 0 then
         return 0;
      end if;
      return JNodes (N).First;
   end First;

   function Next (N : J_Index) return J_Index is
   begin
      if N = 0 then
         return 0;
      end if;
      return JNodes (N).Next;
   end Next;

   function Member_Key (N : J_Index) return String is
   begin
      return To_String (JNodes (N).Key);
   end Member_Key;

   function As_String (N : J_Index) return String is
   begin
      if N = 0 then
         return "";
      end if;
      return To_String (JNodes (N).Value);
   end As_String;

   function As_Integer (N : J_Index) return Long_Long_Integer is
   begin
      return Long_Long_Integer'Value (As_String (N));
   exception
      when others =>
         return 0;
   end As_Integer;

   function As_Bool (N : J_Index) return Boolean is
   begin
      return As_String (N) = "true";
   end As_Bool;

   function Member (Obj : J_Index; Key : String) return J_Index is
      C : J_Index := First (Obj);
   begin
      while C /= 0 loop
         if To_String (JNodes (C).Key) = Key then
            return C;
         end if;
         C := JNodes (C).Next;
      end loop;
      return 0;
   end Member;

   ------------------------------------------------- builders

   function New_Obj return J_Index is
      N : J_Index := Alloc;
   begin
      if N /= 0 then
         JNodes (N).Kind := J_Obj;
      end if;
      return N;
   end New_Obj;

   function New_Arr return J_Index is
      N : J_Index := Alloc;
   begin
      if N /= 0 then
         JNodes (N).Kind := J_Arr;
      end if;
      return N;
   end New_Arr;

   function New_Str (S : String) return J_Index is
      N : J_Index := Alloc;
   begin
      if N /= 0 then
         JNodes (N).Kind := J_Str;
         JNodes (N).Value := To_Unbounded_String (S);
      end if;
      return N;
   end New_Str;

   function New_Num (N : Long_Long_Integer) return J_Index is
      I : J_Index := Alloc;
      S : constant String := Long_Long_Integer'Image (N);
      F : Positive := S'First;
   begin
      if I /= 0 then
         while F < S'Last and then S (F) = ' ' loop
            F := F + 1;
         end loop;
         JNodes (I).Kind := J_Num;
         JNodes (I).Value := To_Unbounded_String (S (F .. S'Last));
      end if;
      return I;
   end New_Num;

   function New_Raw (S : String) return J_Index is
      N : J_Index := Alloc;
   begin
      if N /= 0 then
         JNodes (N).Kind := J_Raw;
         JNodes (N).Value := To_Unbounded_String (S);
      end if;
      return N;
   end New_Raw;

   function New_Bool (B : Boolean) return J_Index is
      N : J_Index := Alloc;
   begin
      if N /= 0 then
         JNodes (N).Kind := J_Bool;
         JNodes (N).Value :=
           To_Unbounded_String ((if B then "true" else "false"));
      end if;
      return N;
   end New_Bool;

   procedure Append_Child (Parent : J_Index; Child : J_Index) is
      C : J_Index := JNodes (Parent).First;
   begin
      if Parent = 0 or else Child = 0 then
         return;
      end if;
      --  A node lives in exactly one list: sever any prior sibling link.
      JNodes (Child).Next := 0;
      if C = 0 then
         JNodes (Parent).First := Child;
         return;
      end if;
      while JNodes (C).Next /= 0 loop
         C := JNodes (C).Next;
      end loop;
      JNodes (C).Next := Child;
   end Append_Child;

   procedure Put_Member (Obj : J_Index; Key : String; Child : J_Index) is
   begin
      if Obj = 0 or else Child = 0 then
         return;
      end if;
      JNodes (Child).Key := To_Unbounded_String (Key);
      Append_Child (Obj, Child);
   end Put_Member;

   ------------------------------------------------- serializer

   procedure Escape (S : String; Into : in out Unbounded_String) is
   begin
      for Ch of S loop
         case Ch is
            when '"'      => Append (Into, String'(1 => '\',
                                                   2 => '"'));
            when '\'      => Append (Into, String'(1 => '\',
                                                   2 => '\'));
            when ASCII.LF => Append (Into, "\n");
            when ASCII.CR => Append (Into, "\r");
            when ASCII.HT => Append (Into, "\t");
            when ASCII.BS => Append (Into, "\b");
            when ASCII.FF => Append (Into, "\f");
            when others =>
               if Ch < ' ' then
                  Append (Into, "\u00");
                  declare
                     C : constant Natural := Character'Pos (Ch);
                     Hex : constant String := "0123456789abcdef";
                  begin
                     Append (Into, String'(1 => Hex (C / 16 + 1)));
                     Append (Into, String'(1 => Hex (C mod 16 + 1)));
                  end;
               else
                  Append (Into, String'(1 => Ch));
               end if;
         end case;
      end loop;
   end Escape;

   function Serialize (N : J_Index) return String is
      Buf : Unbounded_String := Null_Unbounded_String;

      procedure Walk (I : J_Index) is
         C     : J_Index;
         FirstC : Boolean := True;
      begin
         if I = 0 then
            Append (Buf, "null");
            return;
         end if;
         case JNodes (I).Kind is
            when J_Null =>
               Append (Buf, "null");
            when J_Bool | J_Num | J_Raw =>
               Append (Buf, To_String (JNodes (I).Value));
            when J_Str =>
               Append (Buf, '"');
               Escape (To_String (JNodes (I).Value), Buf);
               Append (Buf, '"');
            when J_Arr =>
               Append (Buf, '[');
               C := JNodes (I).First;
               while C /= 0 loop
                  if not FirstC then
                     Append (Buf, ',');
                  end if;
                  FirstC := False;
                  Walk (C);
                  C := JNodes (C).Next;
               end loop;
               Append (Buf, ']');
            when J_Obj =>
               Append (Buf, '{');
               C := JNodes (I).First;
               while C /= 0 loop
                  if not FirstC then
                     Append (Buf, ',');
                  end if;
                  FirstC := False;
                  Append (Buf, '"');
                  Escape (To_String (JNodes (C).Key), Buf);
                  Append (Buf, String'(1 => '"', 2 => ':'));
                  Walk (C);
                  C := JNodes (C).Next;
               end loop;
               Append (Buf, '}');
         end case;
      end Walk;

   begin
      Walk (N);
      return To_String (Buf);
   end Serialize;

end ALB_JSON;

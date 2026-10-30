-- ============================================================
--  ALB_JSON — minimal bounded JSON DOM, parser, and serializer
--
--  Used by ALBW's --mcp mode (JSON-RPC over stdio). Deliberately
--  tiny and bounded in the house style: fixed node table + counts,
--  no recursion past Max_JSON_Depth, all failure via return codes.
-- ============================================================

with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

package ALB_JSON is

   Max_JSON_Nodes : constant := 524_288;
   Max_JSON_Depth : constant := 128;
   Max_JSON_Chars : constant := 4_194_304;   -- 4 MiB, mirrors Input_Buffer

   type Node_Kind is (J_Null, J_Bool, J_Num, J_Str, J_Arr, J_Obj, J_Raw);
   subtype J_Index is Integer range 0 .. Max_JSON_Nodes;

   type JNode is record
      Kind  : Node_Kind := J_Null;
      Value : Unbounded_String := Null_Unbounded_String;  -- str text / num raw / "true"/"false"
      Key   : Unbounded_String := Null_Unbounded_String;  -- object member key
      First : J_Index := 0;   -- first child of an arr/obj
      Next  : J_Index := 0;   -- next sibling
   end record;

   JNodes : array (1 .. Max_JSON_Nodes) of JNode;
   JCount : Natural := 0;

   Parse_Error : Unbounded_String := Null_Unbounded_String;

   --  Parse Text into the DOM. Returns the root index, or 0 on error
   --  (Parse_Error carries the reason). Resets the table each call.
   function Parse (Text : String) return J_Index;

   --  Accessors.
   function Kind (N : J_Index) return Node_Kind;
   function First (N : J_Index) return J_Index;
   function Next (N : J_Index) return J_Index;
   function Member_Key (N : J_Index) return String;
   function As_String (N : J_Index) return String;  -- J_Str/J_Num/J_Bool text
   function As_Integer (N : J_Index) return Long_Long_Integer;
   function As_Bool (N : J_Index) return Boolean;

   --  Object member lookup: first child whose Key matches.
   function Member (Obj : J_Index; Key : String) return J_Index;

   --  Builders (append into the DOM).
   function New_Obj return J_Index;
   function New_Arr return J_Index;
   function New_Str (S : String) return J_Index;
   function New_Num (N : Long_Long_Integer) return J_Index;
   function New_Bool (B : Boolean) return J_Index;
   --  Verbatim JSON text (pre-built objects/arrays that must not go
   --  through Parse while the DOM is live).
   function New_Raw (S : String) return J_Index;
   procedure Append_Child (Parent : J_Index; Child : J_Index);    -- arr/obj
   procedure Put_Member (Obj : J_Index; Key : String; Child : J_Index);

   --  Serialize a subtree to compact JSON text.
   function Serialize (N : J_Index) return String;

   --  Append S to Into, JSON-escaped (without the quotes).
   procedure Escape (S : String; Into : in out Unbounded_String);

end ALB_JSON;

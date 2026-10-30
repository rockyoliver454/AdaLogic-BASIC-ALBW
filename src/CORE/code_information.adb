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

with Ada.Text_IO;
with Ada.Directories;
with Ada.Characters.Handling;

package body Code_Information is
   pragma SPARK_Mode (Off); 
   
   Max_Stack_Depth : constant := 128;
   Max_Path_Length : constant := 1024;

   subtype Path_Buffer is String (1 .. Max_Path_Length);
   type Stack_Range is range 0 .. Max_Stack_Depth;
   
   Stack_Paths : array (Stack_Range range 1 .. Stack_Range'Last) of Path_Buffer;
   Stack_Lens  : array (Stack_Range range 1 .. Stack_Range'Last) of Natural;
   Top         : Stack_Range := 0;

   -- DA RUNNING TALLIES
   Total_Lines_Count : Natural := 0;
   SLOC_Count        : Natural := 0;
   File_Count_Num    : Natural := 0;

   function Is_Code_Line (Line : String) return Boolean is
      use Ada.Characters.Handling;
      First_Char : Integer := 0;
   begin
      for I in Line'Range loop
         if not Is_Space (Line (I)) then
            First_Char := I;
            exit;
         end if;
      end loop;
      if First_Char = 0 then return False; end if;
      if First_Char < Line'Last then
         if Line (First_Char) = '-' and then Line (First_Char + 1) = '-' then
            return False;
         end if;
      end if;
      return True;
   end Is_Code_Line;

   procedure Count_File (Path : String) is
      File : Ada.Text_IO.File_Type;
   begin
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
      while not Ada.Text_IO.End_Of_File (File) loop
         declare
            Line : constant String := Ada.Text_IO.Get_Line (File);
         begin
            Total_Lines_Count := Total_Lines_Count + 1;
            if Is_Code_Line (Line) then
               SLOC_Count := SLOC_Count + 1;
            end if;
         end;
      end loop;
      Ada.Text_IO.Close (File);
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
   end Count_File;

   procedure Walk_Tree_Iterative (Start_Dir : String) is
      use Ada.Directories;
      Search : Search_Type;
      Item   : Directory_Entry_Type;
      Current_Dir_Buf : Path_Buffer;
      Current_Dir_Len : Natural;
      
      procedure Push (P : String) is
      begin
         if Top < Stack_Range'Last and then P'Length <= Max_Path_Length then
            Top := Top + 1;
            Stack_Paths(Top)(1 .. P'Length) := P;
            Stack_Lens(Top) := P'Length;
         end if;
      end Push;

      procedure Pop (Buf : out Path_Buffer; Len : out Natural) is
      begin
         if Top > 0 then
            Buf := Stack_Paths(Top);
            Len := Stack_Lens(Top);
            Top := Top - 1;
         else
            Len := 0; Buf := (others => ' '); 
         end if;
      end Pop;

   begin
      Push(Start_Dir);
      while Top > 0 loop
         Pop(Current_Dir_Buf, Current_Dir_Len);
         declare
            Current_Dir_Str : String := Current_Dir_Buf(1 .. Current_Dir_Len);
         begin
            begin
               Start_Search (Search, Current_Dir_Str, "");
               while More_Entries (Search) loop
                  Get_Next_Entry (Search, Item);
                  declare
                     Simple : constant String := Simple_Name (Item);
                     Full   : constant String := Full_Name (Item);
                     Ext    : String (1 .. 5); -- Extended for .albi
                  begin
                     if Simple /= "." and then Simple /= ".." then
                        case Kind (Item) is
                           when Directory => Push(Full);
                           when Ordinary_File =>
                              if Simple'Length >= 4 then
                                 if Simple'Length >= 5 then
                                    Ext := Simple (Simple'Last - 4 .. Simple'Last);
                                    if Ext = ".albi" or else Ext = ".ALBI" then
                                       Count_File (Full);
                                       File_Count_Num := File_Count_Num + 1;
                                    end if;
                                 end if;
                                 
                                 declare Ext4 : String := Simple (Simple'Last - 3 .. Simple'Last); begin
                                    if Ext4 = ".alb" or else Ext4 = ".ALB" or else Ext4 = ".ads" or else Ext4 = ".adb" then
                                       Count_File (Full);
                                       File_Count_Num := File_Count_Num + 1;
                                    end if;
                                 end;
                              end if;
                           when others => null;
                        end case;
                     end if;
                  end;
               end loop;
               End_Search (Search);
            exception
               when others =>
                  if More_Entries(Search) then End_Search(Search); end if;
            end;
         end;
      end loop;
   end Walk_Tree_Iterative;

   procedure Reset_Metrics is
   begin
      Total_Lines_Count := 0;
      SLOC_Count := 0;
      File_Count_Num := 0;
   end Reset_Metrics;

   procedure Scan_Target (Target_Path : String) is
      use Ada.Directories;
   begin
      if Exists (Target_Path) then
         if Kind (Target_Path) = Ordinary_File then
            Count_File (Target_Path);
            File_Count_Num := File_Count_Num + 1;
         elsif Kind (Target_Path) = Directory then
            Walk_Tree_Iterative (Target_Path);
         end if;
      else
         Ada.Text_IO.Put_Line ("[FORGE-LOG]   Warning: Target '" & Target_Path & "' not found for metrics.");
      end if;
   end Scan_Target;

   
   -----------------------------------------------------------------------------
   --  Public Interface
   -----------------------------------------------------------------------------
   procedure Print_Metrics is
   begin
      Ada.Text_IO.New_Line;
      Ada.Text_IO.Put_Line ("[FORGE-LOG] ==================================================");
      Ada.Text_IO.Put_Line ("[FORGE-LOG]   ALB COMPILER METRICS");
      Ada.Text_IO.Put_Line ("[FORGE-LOG] ==================================================");
      Ada.Text_IO.Put_Line ("[FORGE-LOG]   Total Files:       " & File_Count_Num'Image);
      Ada.Text_IO.Put_Line ("[FORGE-LOG]   Total Lines:       " & Total_Lines_Count'Image);
      Ada.Text_IO.Put_Line ("[FORGE-LOG]   SLOC (Code Only):  " & SLOC_Count'Image);
      
      if Total_Lines_Count > 0 then
         Ada.Text_IO.Put_Line ("[FORGE-LOG]   Code Density:      " & 
            Integer(Float(SLOC_Count) / Float(Total_Lines_Count) * 100.0)'Image & "%");
      end if;
      Ada.Text_IO.Put_Line ("[FORGE-LOG] ==================================================");
      Ada.Text_IO.New_Line;
   end Print_Metrics;

end Code_Information;

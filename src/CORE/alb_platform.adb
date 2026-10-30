with Ada.Directories;
with Ada.Environment_Variables;

package body Alb_Platform is

   function Temp_Dir return String is
      use Ada.Environment_Variables;

      function Try_Var (Name : String) return String is
      begin
         if Exists (Name) then
            declare
               V : constant String := Value (Name);
            begin
               if V'Length > 0 and then Ada.Directories.Exists (V) then
                  return V;
               end if;
            end;
         end if;
         return "";
      end Try_Var;

      T : constant String :=
        (if On_Windows then Try_Var ("TEMP") else Try_Var ("TMPDIR"));
   begin
      if T'Length > 0 then
         return T;
      elsif On_Windows then
         declare
            T2 : constant String := Try_Var ("TMP");
         begin
            if T2'Length > 0 then
               return T2;
            end if;
            return Ada.Directories.Current_Directory;
         end;
      else
         return "/tmp";
      end if;
   end Temp_Dir;

end Alb_Platform;

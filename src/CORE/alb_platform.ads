--  Host-platform constants shared by the drivers.
--  Single source of truth for directory separators, PATH-list
--  separators, temp-directory resolution, and executable naming so
--  drivers stop hardcoding Windows conventions ("\", ";", %TEMP%).
with GNAT.OS_Lib;

package Alb_Platform is

   Dir_Sep  : constant Character := GNAT.OS_Lib.Directory_Separator;
   Path_Sep : constant Character := GNAT.OS_Lib.Path_Separator;

   On_Windows : constant Boolean := (Dir_Sep = '\');

   --  True when C splits an ALB_LIB-style directory list.  ';' is
   --  accepted on every host (uniform launcher scripts); ':' is
   --  additionally accepted on POSIX hosts where it is the native
   --  PATH separator.  On Windows ':' is NOT a separator — it is the
   --  drive-letter delimiter ("C:\...").
   function Is_List_Sep (C : Character) return Boolean is
     (C = ';' or else (not On_Windows and then C = Path_Sep));

   --  Writable scratch directory: TEMP/TMP on Windows, TMPDIR -> /tmp
   --  on POSIX, current directory as the last resort either way.
   function Temp_Dir return String;

end Alb_Platform;
